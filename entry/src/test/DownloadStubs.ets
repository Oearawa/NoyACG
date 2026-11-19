/**
 * DownloadStubs.ets —— Phase 12 下载子系统测试端口（全部内存实现）
 *
 * ⚠ 重要声明：这些桩**只验证业务逻辑**，不触网、不写真机沙盒、不写真实 SQLite/RCP。
 * 真实 HTTP 图片下载、真机文件系统、真机离线阅读仍需账号 + API 26 设备验证
 * （报告中标为未验证）。所有 URL 均为 `stub.local` 派生样例，不是真实抓包。
 */
import {
  ChapterImagePlanProvider,
  ChapterImageProvider,
  ChapterImageSet,
  DownloadControlPort,
  DownloadError,
  DownloadImagePort,
  DownloadInterrupted,
  DownloadRepositoryPort,
  DownloadFsPort,
  DownloadToken
} from '../main/ets/download/DownloadPorts';
import { CacheFsPort, CacheStat } from '../main/ets/utils/CacheCleaner';
import { DownloadStatus, DownloadTask, downloadTaskKey } from '../main/ets/model/DownloadTask';
import { HttpError } from '../main/ets/api/HttpManager';

export function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/** 派生图片 URL 列表（明确不是真实章节响应） */
export function derivedImageUrls(bookId: string, chapterId: string, count: number): string[] {
  const urls: string[] = [];
  for (let n = 1; n <= count; n++) {
    urls.push(`https://stub.local/${bookId}/${chapterId}/${n}.webp`);
  }
  return urls;
}

/**
 * 共享内存文件系统：同时实现缓存端口与下载端口。
 * 缓存隔离测试用**同一个实例**放两类文件，才能真实验证「清缓存不删下载」。
 */
export class SharedMemoryFs implements CacheFsPort, DownloadFsPort {
  files: Map<string, Uint8Array> = new Map<string, Uint8Array>();
  dirs: Set<string> = new Set<string>();
  /** 让指定路径的写入抛错（模拟磁盘满 / 权限问题） */
  writeFailPaths: Set<string> = new Set<string>();
  /** 让指定路径的删除抛错 */
  unlinkFailPaths: Set<string> = new Set<string>();
  /** 让 commit 抛错（模拟 rename 失败） */
  commitFails: boolean = false;
  /** 记录被 unlink 的路径，便于隔离测试断言 */
  deletedPaths: string[] = [];

  private static parentOf(path: string): string {
    const i: number = path.lastIndexOf('/');
    return i <= 0 ? '' : path.substring(0, i);
  }

  private ensureParents(path: string): void {
    let parent: string = SharedMemoryFs.parentOf(path);
    while (parent !== '') {
      this.dirs.add(parent);
      parent = SharedMemoryFs.parentOf(parent);
    }
  }

  async ensureDir(path: string): Promise<void> {
    this.dirs.add(path);
    this.ensureParents(path);
  }

  async exists(path: string): Promise<boolean> {
    return this.dirs.has(path) || this.files.has(path);
  }

  // ===== CacheFsPort =====

  async access(path: string): Promise<boolean> {
    return await this.exists(path);
  }

  async list(path: string): Promise<string[]> {
    return await this.listFiles(path);
  }

  async stat(path: string): Promise<CacheStat> {
    if (this.dirs.has(path)) {
      return new CacheStat(true, 0);
    }
    const data: Uint8Array | undefined = this.files.get(path);
    return new CacheStat(false, data === undefined ? 0 : data.length);
  }

  async unlink(path: string): Promise<void> {
    if (this.unlinkFailPaths.has(path)) {
      throw new Error(`unlink failed: ${path}`);
    }
    this.files.delete(path);
    this.deletedPaths.push(path);
  }

  // ===== DownloadFsPort =====

  async fileSize(path: string): Promise<number> {
    if (this.dirs.has(path)) {
      return -1;
    }
    const data: Uint8Array | undefined = this.files.get(path);
    return data === undefined ? -1 : data.length;
  }

  async appendChunk(path: string, chunk: ArrayBuffer): Promise<number> {
    if (this.writeFailPaths.has(path)) {
      throw new Error(`write failed: ${path}`);
    }
    const incoming: Uint8Array = new Uint8Array(chunk);
    const prev: Uint8Array = this.files.get(path) ?? new Uint8Array(0);
    const merged: Uint8Array = new Uint8Array(prev.length + incoming.length);
    merged.set(prev, 0);
    merged.set(incoming, prev.length);
    this.files.set(path, merged);
    this.ensureParents(path);
    return merged.length;
  }

  async commit(tempPath: string, finalPath: string): Promise<void> {
    if (this.commitFails) {
      throw new Error(`rename failed: ${tempPath}`);
    }
    const data: Uint8Array | undefined = this.files.get(tempPath);
    if (data === undefined) {
      throw new Error(`temp file missing: ${tempPath}`);
    }
    this.files.delete(finalPath);
    this.files.set(finalPath, data);
    this.files.delete(tempPath);
    this.ensureParents(finalPath);
  }

  async remove(path: string): Promise<void> {
    await this.unlink(path);
  }

  async removeDirRecursive(path: string): Promise<void> {
    const prefix: string = `${path}/`;
    const toDelete: string[] = [];
    this.files.forEach((value: Uint8Array, key: string): void => {
      if (key === path || key.startsWith(prefix)) {
        toDelete.push(key);
      }
    });
    for (let i = 0; i < toDelete.length; i++) {
      await this.remove(toDelete[i]);
    }
    const dirsToDelete: string[] = [];
    this.dirs.forEach((dir: string): void => {
      if (dir === path || dir.startsWith(prefix)) {
        dirsToDelete.push(dir);
      }
    });
    for (let i = 0; i < dirsToDelete.length; i++) {
      this.dirs.delete(dirsToDelete[i]);
    }
  }

  async listFiles(dirPath: string): Promise<string[]> {
    if (!this.dirs.has(dirPath)) {
      return [];
    }
    const prefix: string = `${dirPath}/`;
    const names: string[] = [];
    this.files.forEach((value: Uint8Array, key: string): void => {
      if (key.startsWith(prefix)) {
        const rest: string = key.substring(prefix.length);
        if (rest.indexOf('/') < 0 && names.indexOf(rest) < 0) {
          names.push(rest);
        }
      }
    });
    this.dirs.forEach((dir: string): void => {
      if (dir !== dirPath && dir.startsWith(prefix)) {
        const rest: string = dir.substring(prefix.length);
        if (rest.indexOf('/') < 0 && names.indexOf(rest) < 0) {
          names.push(rest);
        }
      }
    });
    return names;
  }

  async totalSize(dirPath: string): Promise<number> {
    let total: number = 0;
    const prefix: string = `${dirPath}/`;
    this.files.forEach((value: Uint8Array, key: string): void => {
      if (key.startsWith(prefix)) {
        total += value.length;
      }
    });
    return total;
  }

  /** 测试辅助：直接放入一个文件 */
  seedFile(path: string, bytes: number): void {
    this.files.set(path, new Uint8Array(bytes));
    this.ensureParents(path);
  }

  /** 测试辅助：文件是否存在 */
  hasFile(path: string): boolean {
    return this.files.has(path);
  }
}

/** 内存图片下载器：可模拟成功 / 失败 / 空文件 / 在途取消 / 延迟 */
export class MemoryImageFetcher implements DownloadImagePort {
  private fs: SharedMemoryFs;
  failUrls: Set<string> = new Set<string>();
  emptyUrls: Set<string> = new Set<string>();
  delayMs: number = 0;
  calls: string[] = [];
  /** 收到取消通知的 URL（验证「在途请求被真正取消」） */
  canceledUrls: string[] = [];
  /** 当前在途请求数 / 历史峰值（验证全局并发上限） */
  inFlight: number = 0;
  maxInFlight: number = 0;

  constructor(fs: SharedMemoryFs) {
    this.fs = fs;
  }

  async fetch(url: string, tempPath: string, headers: Record<string, string>,
    token: DownloadToken): Promise<number> {
    this.calls.push(url);
    this.inFlight++;
    if (this.inFlight > this.maxInFlight) {
      this.maxInFlight = this.inFlight;
    }
    try {
      // 模拟 SDK 的真实取消动作注册（生产是 rcp.Session.cancel(request)）
      token.onCancel((): void => {
        this.canceledUrls.push(url);
      });
      if (this.delayMs > 0) {
        await delay(this.delayMs);
      }
      if (token.isCanceled) {
        throw new DownloadInterrupted();
      }
      if (this.failUrls.has(url)) {
        throw new DownloadError('NETWORK', `模拟网络失败: ${url}`);
      }
      if (this.emptyUrls.has(url)) {
        return 0;
      }
      const payload: Uint8Array = new Uint8Array([0x57, 0x45, 0x42, 0x50,
        url.length & 0xFF, (url.length >> 8) & 0xFF]);
      const buffer: ArrayBuffer = payload.buffer as ArrayBuffer;
      return await this.fs.appendChunk(tempPath, buffer);
    } finally {
      this.inFlight--;
    }
  }
}

/** 内存任务仓储（含写失败开关，验证「数据库写入失败不谎报成功」） */
export class MemoryDownloadRepository implements DownloadRepositoryPort {
  rows: Map<string, DownloadTask> = new Map<string, DownloadTask>();
  failOnUpsert: boolean = false;
  upsertCalls: number = 0;

  async upsert(task: DownloadTask): Promise<void> {
    this.upsertCalls++;
    if (this.failOnUpsert) {
      throw new Error('模拟数据库写入失败');
    }
    this.rows.set(task.taskId, task.snapshot());
  }

  async get(bookId: string, chapterId: string): Promise<DownloadTask | null> {
    const found: DownloadTask | undefined = this.rows.get(downloadTaskKey(bookId, chapterId));
    return found === undefined ? null : found.snapshot();
  }

  async list(): Promise<DownloadTask[]> {
    const result: DownloadTask[] = [];
    this.rows.forEach((value: DownloadTask): void => {
      result.push(value.snapshot());
    });
    return result;
  }

  async remove(bookId: string, chapterId: string): Promise<void> {
    this.rows.delete(downloadTaskKey(bookId, chapterId));
  }

  async clearFinished(): Promise<number> {
    const keys: string[] = [];
    this.rows.forEach((value: DownloadTask, key: string): void => {
      if (value.status === DownloadStatus.COMPLETED
        || value.status === DownloadStatus.CANCELED) {
        keys.push(key);
      }
    });
    for (let i = 0; i < keys.length; i++) {
      this.rows.delete(keys[i]);
    }
    return keys.length;
  }

  /** 测试辅助：直接塞入一条任务（模拟上次异常退出） */
  seed(task: DownloadTask): void {
    this.rows.set(task.taskId, task.snapshot());
  }
}

/** 章节图片清单桩（与协议解耦，返回派生 URL 列表） */
export class StubPlanProvider implements ChapterImagePlanProvider {
  urls: string[] = [];
  error: HttpError | null = null;
  calls: string[] = [];

  async getImageUrls(bookId: string, chapterId: string): Promise<string[]> {
    this.calls.push(`${bookId}/${chapterId}`);
    if (this.error !== null) {
      throw this.error;
    }
    return this.urls;
  }
}

/** 阅读器统一图片来源桩 */
export class StubChapterImageProvider implements ChapterImageProvider {
  result: ChapterImageSet | null = null;
  error: HttpError | null = null;
  calls: string[] = [];

  async getChapterImages(bookId: string, chapterId: string): Promise<ChapterImageSet> {
    this.calls.push(`${bookId}/${chapterId}`);
    if (this.error !== null) {
      throw this.error;
    }
    return this.result ?? ChapterImageSet.online([]);
  }
}

/** ViewModel 测试用的下载控制桩（不触发真实调度） */
export class StubDownloadControl implements DownloadControlPort {
  tasks: DownloadTask[] = [];
  size: number = 0;
  listeners: (() => void)[] = [];
  paused: string[] = [];
  resumed: string[] = [];
  canceled: string[] = [];
  deleted: string[] = [];
  deleteWithFiles: boolean = false;
  cleared: number = 0;
  listShouldThrow: boolean = false;

  enqueued: string[] = [];

  async listTasks(): Promise<DownloadTask[]> {
    if (this.listShouldThrow) {
      throw new Error('模拟读取任务失败');
    }
    return this.tasks;
  }

  async enqueueChapter(bookId: string, chapterId: string, bookTitle: string,
    chapterTitle: string): Promise<string> {
    this.enqueued.push(downloadTaskKey(bookId, chapterId));
    return '已加入下载队列';
  }

  pause(bookId: string, chapterId: string): boolean {
    this.paused.push(downloadTaskKey(bookId, chapterId));
    return true;
  }

  async resume(bookId: string, chapterId: string): Promise<boolean> {
    this.resumed.push(downloadTaskKey(bookId, chapterId));
    return true;
  }

  async retry(bookId: string, chapterId: string): Promise<boolean> {
    this.resumed.push(downloadTaskKey(bookId, chapterId));
    return true;
  }

  cancel(bookId: string, chapterId: string): boolean {
    this.canceled.push(downloadTaskKey(bookId, chapterId));
    return true;
  }

  cancelAllPending(): number {
    return this.tasks.length;
  }

  async deleteChapter(bookId: string, chapterId: string,
    deleteFiles: boolean): Promise<void> {
    this.deleted.push(downloadTaskKey(bookId, chapterId));
    this.deleteWithFiles = deleteFiles;
  }

  async clearFinishedRecords(): Promise<number> {
    this.cleared = 1;
    return 1;
  }

  async getDownloadSize(): Promise<number> {
    return this.size;
  }

  addListener(listener: () => void): void {
    this.listeners.push(listener);
  }

  removeListener(listener: () => void): void {
    const i: number = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }

  dispose(): void {
    this.listeners = [];
  }
}

/**
 * 等待调度器把所有任务跑到终态（避免测试依赖固定的 sleep）。
 * 参数用生产端口类型而非内联对象字面量类型（ArkTS 不支持结构类型隐式赋值）。
 */
export async function waitForIdle(manager: DownloadControlPort,
  timeoutMs: number = 3000): Promise<void> {
  const start: number = Date.now();
  while (Date.now() - start < timeoutMs) {
    const tasks: DownloadTask[] = await manager.listTasks();
    let busy: boolean = false;
    for (let i = 0; i < tasks.length; i++) {
      const s: DownloadStatus = tasks[i].status;
      if (s === DownloadStatus.QUEUED || s === DownloadStatus.PREPARING
        || s === DownloadStatus.DOWNLOADING) {
        busy = true;
      }
    }
    if (!busy) {
      return;
    }
    await delay(5);
  }
}
