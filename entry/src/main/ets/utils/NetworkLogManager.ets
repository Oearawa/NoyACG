/**
 * NetworkLogManager.ets —— 应用内网络请求日志（Phase 14-R）
 *
 * 只记录**本应用自己发出的 HTTP 请求的元数据**：
 *   时间 / 方法 / 脱敏路径（不含查询值）/ 耗时 / HTTP 状态 / 业务是否成功 / 响应字节 / 错误类型。
 *
 * 明确不是抓包工具：不做 MITM、不装证书、不拦截其他应用流量、不保存请求/响应正文。
 * 目的：用户遇到「打开某个页面一直失败」时，能在应用内看到是超时、401 还是 5xx。
 *
 * 隐私：路径只保留 path（查询值全部打码）；不记录 Header、Cookie、Token、正文。
 */
import { common } from '@kit.AbilityKit';
import {
  LogExportResult,
  diagnosticsDir,
  ensureDir,
  exportLogWithDocumentPicker,
  exportsDir,
  formatTimestamp,
  readTextFile,
  timestampedFileName,
  writeTextFile
} from './LogStore';
import { sanitizePath, sanitizeText } from './LogSanitizer';

const FILE_NAME: string = 'network_requests.json';
const MAX_ENTRIES: number = 200;
const PERSIST_INTERVAL_MS: number = 8000;
const PERSIST_EVERY: number = 10;
const MAX_FILE_BYTES: number = 512 * 1024;

/** 一条网络日志（已脱敏） */
export class NetworkLogEntry {
  id: string = '';
  timestamp: number = 0;
  method: string = 'GET';
  /** 脱敏后的路径（无 origin、无查询值） */
  path: string = '';
  durationMs: number = 0;
  /** HTTP 状态码（0 = 没有拿到响应） */
  statusCode: number = 0;
  /** 是否成功（2xx 且无异常） */
  ok: boolean = false;
  /** 响应体字符数（-1 = 未统计，如图片二进制不统计） */
  bytes: number = -1;
  /** 错误类型 / 摘要（已脱敏；成功时为空串） */
  error: string = '';

  constructor() {
  }

  timeText(): string {
    return formatTimestamp(this.timestamp);
  }

  /** 状态展示：「200」「超时」等由 UI 决定，这里给出原始码 */
  statusText(): string {
    return this.statusCode > 0 ? `${this.statusCode}` : '—';
  }
}

/** 一次请求的追踪上下文（由调用方创建并传入 HttpManager） */
export class NetworkTrace {
  readonly id: string;
  readonly method: string;
  readonly path: string;
  readonly startedAt: number;
  statusCode: number = 0;
  /** 响应体字符数；-1 = 未统计 */
  bytes: number = -1;
  /** 失败原因（已由 HttpManager 给出，写日志前还会再脱敏一次） */
  error: string = '';
  /** 是否已结束（防止重复入库） */
  ended: boolean = false;

  constructor(id: string, method: string, path: string, startedAt: number) {
    this.id = id;
    this.method = method;
    this.path = path;
    this.startedAt = startedAt;
  }
}

interface RawNetworkEntry {
  id?: string;
  timestamp?: number;
  method?: string;
  path?: string;
  durationMs?: number;
  statusCode?: number;
  ok?: boolean;
  bytes?: number;
  error?: string;
}

/** 筛选条件（页面上的三档：全部 / 仅失败 / 仅成功） */
export const NET_FILTER_ALL: string = '';
export const NET_FILTER_ERROR: string = 'error';
export const NET_FILTER_OK: string = 'ok';

export class NetworkLogManager {
  private static instance?: NetworkLogManager;

  private context?: common.Context;
  private entries: NetworkLogEntry[] = [];
  private seq: number = 0;
  private sincePersist: number = 0;
  private lastPersistTs: number = 0;
  private persisting: boolean = false;
  /** 是否启用采集（默认开启；关闭后 begin 返回 null，调用方无需判空以外的处理） */
  private enabled: boolean = true;

  private constructor() {
  }

  static getInstance(): NetworkLogManager {
    if (NetworkLogManager.instance === undefined) {
      NetworkLogManager.instance = new NetworkLogManager();
    }
    return NetworkLogManager.instance;
  }

  init(context: common.Context): void {
    this.context = context;
    this.loadPersisted().catch((): void => {
      // 加载失败：内存态仍然可用
    });
  }

  setEnabled(enabled: boolean): void {
    this.enabled = enabled;
  }

  isEnabled(): boolean {
    return this.enabled;
  }

  /** 开始一次请求追踪（路径在此处即脱敏，后续任何环节都拿不到原始 query 值） */
  begin(method: string, url: string): NetworkTrace {
    this.seq++;
    return new NetworkTrace(`${Date.now()}_${this.seq}`, method.toUpperCase(),
      sanitizePath(url), Date.now());
  }

  /** 结束并入库（幂等：同一 trace 重复调用只入一次） */
  end(trace: NetworkTrace | null): void {
    if (trace === null || trace.ended) {
      return;
    }
    trace.ended = true;
    if (!this.enabled) {
      return;
    }
    try {
      const entry: NetworkLogEntry = new NetworkLogEntry();
      entry.id = trace.id;
      entry.timestamp = trace.startedAt;
      entry.method = trace.method;
      entry.path = trace.path;
      entry.durationMs = Math.max(0, Date.now() - trace.startedAt);
      entry.statusCode = trace.statusCode;
      entry.ok = trace.error === '' && trace.statusCode >= 200 && trace.statusCode < 300;
      entry.bytes = trace.bytes;
      entry.error = trace.error === '' ? '' : sanitizeText(trace.error);
      this.entries.push(entry);
      if (this.entries.length > MAX_ENTRIES) {
        this.entries = this.entries.slice(this.entries.length - MAX_ENTRIES);
      }
      this.sincePersist++;
      this.maybePersist();
    } catch (e) {
      // 日志失败绝不影响网络请求本身
    }
  }

  /** 列表（最新在前） */
  list(filter: string = NET_FILTER_ALL, keyword: string = ''): NetworkLogEntry[] {
    const result: NetworkLogEntry[] = [];
    const key: string = keyword.trim().toLowerCase();
    for (let i = this.entries.length - 1; i >= 0; i--) {
      const entry: NetworkLogEntry = this.entries[i];
      if (filter === NET_FILTER_ERROR && entry.ok) {
        continue;
      }
      if (filter === NET_FILTER_OK && !entry.ok) {
        continue;
      }
      if (key !== '' && entry.path.toLowerCase().indexOf(key) < 0) {
        continue;
      }
      result.push(entry);
    }
    return result;
  }

  count(): number {
    return this.entries.length;
  }

  failureCount(): number {
    let count: number = 0;
    for (let i = 0; i < this.entries.length; i++) {
      if (!this.entries[i].ok) {
        count++;
      }
    }
    return count;
  }

  async clear(): Promise<boolean> {
    this.entries = [];
    this.sincePersist = 0;
    const ctx: common.Context | undefined = this.context;
    if (ctx === undefined) {
      return false;
    }
    return await writeTextFile(`${diagnosticsDir(ctx)}/${FILE_NAME}`, '[]');
  }

  exportText(): string {
    const lines: string[] = [];
    lines.push('# NoyAcg 网络请求日志');
    lines.push(`# 导出时间: ${formatTimestamp(Date.now())}`);
    lines.push(`# 条目数: ${this.entries.length}（失败 ${this.failureCount()}）`);
    lines.push('# 说明: 仅本应用发出的请求元数据；不含 Header / Cookie / 正文');
    lines.push('');
    for (let i = this.entries.length - 1; i >= 0; i--) {
      const entry: NetworkLogEntry = this.entries[i];
      const state: string = entry.ok ? 'OK' : 'FAIL';
      lines.push(`[${entry.timeText()}] ${entry.method} ${entry.path}`);
      lines.push(`  ${state} http=${entry.statusCode} ${entry.durationMs}ms` +
        `${entry.bytes >= 0 ? ` bytes=${entry.bytes}` : ''}`);
      if (entry.error !== '') {
        lines.push(`  error: ${entry.error}`);
      }
    }
    return lines.join('\n');
  }

  async exportToFile(): Promise<string> {
    const ctx: common.Context | undefined = this.context;
    if (ctx === undefined) {
      return '';
    }
    try {
      const dir: string = exportsDir(ctx);
      if (!ensureDir(dir)) {
        return '';
      }
      const path: string = `${dir}/${timestampedFileName('network', 'txt')}`;
      const ok: boolean = await writeTextFile(path, this.exportText());
      return ok ? path : '';
    } catch (e) {
      return '';
    }
  }

  /** 通过系统 DocumentViewPicker 让用户自选导出位置保存网络日志 */
  async exportWithPicker(uiContext?: common.Context): Promise<LogExportResult> {
    const fileName: string = timestampedFileName('noyacg_network', 'txt');
    return await exportLogWithDocumentPicker(uiContext ?? this.context, fileName, this.exportText());
  }

  private filePath(): string {
    const ctx: common.Context | undefined = this.context;
    return ctx === undefined ? '' : `${diagnosticsDir(ctx)}/${FILE_NAME}`;
  }

  private async loadPersisted(): Promise<void> {
    const path: string = this.filePath();
    if (path === '') {
      return;
    }
    const text: string = await readTextFile(path);
    if (text === '') {
      return;
    }
    try {
      const raw: RawNetworkEntry[] = JSON.parse(text) as RawNetworkEntry[];
      if (!Array.isArray(raw)) {
        return;
      }
      for (let i = 0; i < raw.length; i++) {
        const item: RawNetworkEntry = raw[i];
        if (item === null || item === undefined || typeof item.path !== 'string') {
          continue;
        }
        const entry: NetworkLogEntry = new NetworkLogEntry();
        entry.id = typeof item.id === 'string' ? item.id : `${i}`;
        entry.timestamp = typeof item.timestamp === 'number' ? item.timestamp : 0;
        entry.method = typeof item.method === 'string' ? item.method : 'GET';
        entry.path = item.path;
        entry.durationMs = typeof item.durationMs === 'number' ? item.durationMs : 0;
        entry.statusCode = typeof item.statusCode === 'number' ? item.statusCode : 0;
        entry.ok = item.ok === true;
        entry.bytes = typeof item.bytes === 'number' ? item.bytes : -1;
        entry.error = typeof item.error === 'string' ? item.error : '';
        this.entries.push(entry);
      }
      if (this.entries.length > MAX_ENTRIES) {
        this.entries = this.entries.slice(this.entries.length - MAX_ENTRIES);
      }
    } catch (e) {
      this.entries = this.entries.slice();
    }
  }

  private maybePersist(): void {
    const now: number = Date.now();
    if (this.sincePersist >= PERSIST_EVERY || now - this.lastPersistTs >= PERSIST_INTERVAL_MS) {
      this.persist().catch((): void => {
      });
    }
  }

  private async persist(): Promise<boolean> {
    if (this.persisting) {
      return false;
    }
    const ctx: common.Context | undefined = this.context;
    if (ctx === undefined) {
      return false;
    }
    if (!ensureDir(diagnosticsDir(ctx))) {
      return false;
    }
    this.persisting = true;
    try {
      let text: string = JSON.stringify(this.entries);
      if (text.length > MAX_FILE_BYTES) {
        text = JSON.stringify(this.entries.slice(-80));
      }
      const ok: boolean = await writeTextFile(this.filePath(), text);
      if (ok) {
        this.sincePersist = 0;
        this.lastPersistTs = Date.now();
      }
      return ok;
    } finally {
      this.persisting = false;
    }
  }

  /** 测试钩子：直接注入（不落盘） */
  injectForTest(entries: NetworkLogEntry[]): void {
    this.entries = entries.slice();
  }

  snapshotForTest(): NetworkLogEntry[] {
    return this.entries.slice();
  }
}
