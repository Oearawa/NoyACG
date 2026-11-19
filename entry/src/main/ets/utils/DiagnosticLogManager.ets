/**
 * DiagnosticLogManager.ets —— 应用内诊断日志（Phase 14-R）
 *
 * 能力边界（必须如实理解）：
 * - 能捕获：**应用主动记录**的 error / warn（含业务异常、网络异常、初始化失败）
 *   以及通过 `recordException()` 显式上报的 ArkTS 异常对象；
 * - 不能捕获：Native 进程崩溃、系统级故障、其他进程异常 —— 这些仍然只能靠系统 hilog / 故障日志；
 * - 不做自动上报：没有服务端接收接口，因此本模块只提供「本机查看 / 导出」。
 *
 * 有界性：最多保留 MAX_ENTRIES 条（超出丢弃最旧），持久化文件同时受 MAX_FILE_BYTES 限制。
 * 隐私：所有正文与堆栈在**写入前**经 LogSanitizer 脱敏，绝不保存 Cookie / Token / 邮箱 / UID。
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { isReportableAppError } from './ErrorFilter';
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
import { sanitizeStack, sanitizeText, summarize } from './LogSanitizer';

const TAG_FILE: string = 'diagnostic_errors.json';
const MAX_ENTRIES: number = 300;
const MAX_STACK_LINES: number = 20;
const MAX_FILE_BYTES: number = 512 * 1024;
/** 批量落盘阈值：积累到该条数或距上次落盘超过间隔就写盘 */
const PERSIST_EVERY: number = 10;
const PERSIST_INTERVAL_MS: number = 8000;

export const LOG_LEVEL_ERROR: string = 'error';
export const LOG_LEVEL_WARN: string = 'warn';

/** 一条诊断记录（已脱敏） */
export class DiagnosticLogEntry {
  id: string = '';
  timestamp: number = 0;
  level: string = LOG_LEVEL_ERROR;
  module: string = '';
  message: string = '';
  /** 脱敏后的堆栈（可能为空串） */
  stack: string = '';

  constructor() {
  }

  /** 列表摘要（单行，限长） */
  summary(): string {
    return summarize(this.message, 160);
  }

  /** 时间文本 */
  timeText(): string {
    return formatTimestamp(this.timestamp);
  }
}

/** 反序列化用的原始形状（避免把任意 JSON 直接塞进实体） */
interface RawLogEntry {
  id?: string;
  timestamp?: number;
  level?: string;
  module?: string;
  message?: string;
  stack?: string;
}

export class DiagnosticLogManager {
  private static instance?: DiagnosticLogManager;

  private context?: common.Context;
  private entries: DiagnosticLogEntry[] = [];
  private loaded: boolean = false;
  private seq: number = 0;
  private sincePersist: number = 0;
  private lastPersistTs: number = 0;
  private persisting: boolean = false;
  /** 重入保护：Logger.error → record → （内部不再调用 Logger）→ 无递归，但仍加锁防御 */
  private recording: boolean = false;

  private constructor() {
  }

  static getInstance(): DiagnosticLogManager {
    if (DiagnosticLogManager.instance === undefined) {
      DiagnosticLogManager.instance = new DiagnosticLogManager();
    }
    return DiagnosticLogManager.instance;
  }

  /** 注入上下文并异步加载历史日志（EntryAbility.onCreate 调用一次） */
  init(context: common.Context): void {
    this.context = context;
    this.loadPersisted().catch((e: Error) => {
      // 初始加载失败不影响功能：内存态仍然可用
      this.entries = [];
      this.loaded = true;
    });
  }

  /** 记录一条（自动脱敏；level 只接受 error / warn） */
  record(level: string, module: string, message: string, stack?: string): void {
    if (this.recording) {
      return;
    }
    const text: string = sanitizeText(message).trim();
    if (text === '') {
      return;
    }
    this.recording = true;
    try {
      const entry: DiagnosticLogEntry = new DiagnosticLogEntry();
      this.seq++;
      entry.id = `${Date.now()}_${this.seq}`;
      entry.timestamp = Date.now();
      entry.level = level === LOG_LEVEL_WARN ? LOG_LEVEL_WARN : LOG_LEVEL_ERROR;
      entry.module = sanitizeText(module).substring(0, 40);
      entry.message = text;
      entry.stack = sanitizeStack(stack, MAX_STACK_LINES);
      this.entries.push(entry);
      this.trim();
      this.sincePersist++;
      this.maybePersist();
    } finally {
      this.recording = false;
    }
  }

  /** 显式上报一个异常对象（业务 catch 分支使用） */
  recordException(module: string, error: Error | null | undefined): void {
    if (error === null || error === undefined) {
      return;
    }
    if (!isReportableAppError(LOG_LEVEL_ERROR, module, error.message, error.stack)) {
      return;
    }
    this.record(LOG_LEVEL_ERROR, module, error.message, error.stack);
  }

  /** 全部记录（最新在前）；可按级别与关键词过滤 */
  list(level: string = '', keyword: string = ''): DiagnosticLogEntry[] {
    const result: DiagnosticLogEntry[] = [];
    const key: string = keyword.trim().toLowerCase();
    for (let i = this.entries.length - 1; i >= 0; i--) {
      const entry: DiagnosticLogEntry = this.entries[i];
      if (level !== '' && entry.level !== level) {
        continue;
      }
      if (key !== '') {
        const haystack: string =
          `${entry.module} ${entry.message} ${entry.stack}`.toLowerCase();
        if (haystack.indexOf(key) < 0) {
          continue;
        }
      }
      result.push(entry);
    }
    return result;
  }

  count(): number {
    return this.entries.length;
  }

  errorCount(): number {
    let count: number = 0;
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].level === LOG_LEVEL_ERROR) {
        count++;
      }
    }
    return count;
  }

  /** 清空（内存 + 磁盘） */
  async clear(): Promise<boolean> {
    this.entries = [];
    this.sincePersist = 0;
    return await this.persist(true);
  }

  /** 导出为纯文本（已脱敏）；无内容时仍返回带表头的空文件内容 */
  exportText(): string {
    const lines: string[] = [];
    lines.push('# NoyAcg 诊断日志导出');
    lines.push(`# 导出时间: ${formatTimestamp(Date.now())}`);
    lines.push(`# 条目数: ${this.entries.length}`);
    lines.push('# 说明: 正文与堆栈已脱敏；不含 Cookie / Token / 邮箱 / UID');
    lines.push('');
    for (let i = this.entries.length - 1; i >= 0; i--) {
      const entry: DiagnosticLogEntry = this.entries[i];
      lines.push(`[${entry.timeText()}] [${entry.level.toUpperCase()}] [${entry.module}]`);
      lines.push(entry.message);
      if (entry.stack !== '') {
        lines.push('--- stack ---');
        lines.push(entry.stack);
      }
      lines.push('');
    }
    return lines.join('\n');
  }

  /**
   * 导出到应用可访问目录 `<filesDir>/exports/`。
   * @returns 成功时返回完整文件路径；失败返回空串（UI 如实提示失败，不假装成功）
   */
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
      const path: string = `${dir}/${timestampedFileName('diagnostic', 'txt')}`;
      const ok: boolean = await writeTextFile(path, this.exportText());
      return ok ? path : '';
    } catch (e) {
      return '';
    }
  }

  /** 通过系统 DocumentViewPicker 让用户自选导出位置保存错误报告 */
  async exportWithPicker(uiContext?: common.Context): Promise<LogExportResult> {
    const fileName: string = timestampedFileName('noyacg_diagnostic', 'txt');
    return await exportLogWithDocumentPicker(uiContext ?? this.context, fileName, this.exportText());
  }

  // ==================== 持久化 ====================

  private filePath(): string {
    const ctx: common.Context | undefined = this.context;
    return ctx === undefined ? '' : `${diagnosticsDir(ctx)}/${TAG_FILE}`;
  }

  private async loadPersisted(): Promise<void> {
    const path: string = this.filePath();
    if (path === '') {
      this.loaded = true;
      return;
    }
    const text: string = await readTextFile(path);
    if (text === '') {
      this.loaded = true;
      return;
    }
    try {
      const raw: RawLogEntry[] = JSON.parse(text) as RawLogEntry[];
      const parsed: DiagnosticLogEntry[] = [];
      if (Array.isArray(raw)) {
        for (let i = 0; i < raw.length; i++) {
          const item: RawLogEntry = raw[i];
          if (item === null || item === undefined) {
            continue;
          }
          const entry: DiagnosticLogEntry = new DiagnosticLogEntry();
          entry.id = typeof item.id === 'string' ? item.id : `${i}`;
          entry.timestamp = typeof item.timestamp === 'number' ? item.timestamp : 0;
          entry.level = item.level === LOG_LEVEL_WARN ? LOG_LEVEL_WARN : LOG_LEVEL_ERROR;
          entry.module = typeof item.module === 'string' ? item.module : '';
          entry.message = typeof item.message === 'string' ? item.message : '';
          entry.stack = typeof item.stack === 'string' ? item.stack : '';
          if (entry.message !== '' &&
            isReportableAppError(entry.level, entry.module, entry.message, entry.stack)) {
            parsed.push(entry);
          }
        }
      }
      // 追加到内存（保留本次会话已记录的内容，历史在前）
      this.entries = parsed.concat(this.entries);
      this.trim();
      if (Array.isArray(raw) && parsed.length < raw.length) {
        this.persist(true).catch((_e: Error) => {
          // 清理历史噪音落盘失败不影响内存状态
        });
      }
    } catch (e) {
      // 文件损坏：直接丢弃并覆盖，不能让脏文件卡死日志功能
      this.entries = this.entries.slice();
    }
    this.loaded = true;
  }

  private trim(): void {
    if (this.entries.length > MAX_ENTRIES) {
      this.entries = this.entries.slice(this.entries.length - MAX_ENTRIES);
    }
  }

  private maybePersist(): void {
    const now: number = Date.now();
    if (this.sincePersist >= PERSIST_EVERY || now - this.lastPersistTs >= PERSIST_INTERVAL_MS) {
      this.persist(false).catch((e: Error) => {
        // 落盘失败仅影响重启后可见性，不打断业务流程
      });
    }
  }

  private async persist(force: boolean): Promise<boolean> {
    if (this.persisting) {
      return false;
    }
    const ctx: common.Context | undefined = this.context;
    if (ctx === undefined) {
      return false;
    }
    const dir: string = diagnosticsDir(ctx);
    if (!ensureDir(dir)) {
      return false;
    }
    this.persisting = true;
    try {
      let text: string = JSON.stringify(this.entries);
      if (text.length > MAX_FILE_BYTES) {
        // 超限：只保留最新的 100 条，保证文件不会无限增长
        const keep: DiagnosticLogEntry[] = this.entries.slice(-100);
        text = JSON.stringify(keep);
      }
      const ok: boolean = await writeTextFile(this.filePath(), text);
      if (ok) {
        this.sincePersist = 0;
        this.lastPersistTs = Date.now();
      }
      return ok;
    } catch (e) {
      const err = e as BusinessError;
      return false;
    } finally {
      this.persisting = false;
    }
  }

  /** 测试钩子：直接注入条目（不落盘） */
  injectForTest(entries: DiagnosticLogEntry[]): void {
    this.entries = entries.slice();
    this.loaded = true;
  }

  /** 测试钩子：读取当前条目（按存储顺序） */
  snapshotForTest(): DiagnosticLogEntry[] {
    return this.entries.slice();
  }
}
