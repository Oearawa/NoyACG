/**
 * DownloadPorts.ets —— 下载子系统端口与统一数据模型（Phase 12）
 *
 * 架构原则：
 * 1. **与 NoyAcg 数据协议解耦**：DownloadManager 只认 `ChapterImagePlanProvider`
 *    （返回「有序图片 URL 列表」），不 import NoyAcgSource / NoyAcgProtocol / HttpManager；
 * 2. **全部外部能力端口化**：文件、网络、数据库都有接口，生产实现注入真机 Kit，
 *    单元测试注入内存桩；Mock 只验证业务逻辑，绝不冒充真机沙盒/SQLite/RCP；
 * 3. **统一图片模型**：在线与离线都产出 `ChapterImageSet`（`string[]` + 来源/完整性），
 *    NoyAcgSource 与 OfflineChapterSource 不会各自演化出互不兼容的图片模型。
 */
import { DownloadTask } from '../model/DownloadTask';

/** 永久下载根目录（相对 context.filesDir；**绝不放在 cacheDir**） */
export const DOWNLOAD_ROOT_DIR: string = 'Downloads';
/** 临时文件后缀（写入中文件，提交前一律带此后缀） */
export const DOWNLOAD_TEMP_SUFFIX: string = '.part';
/** 默认全局图片下载并发数（任务书建议从 3 开始，不盲目提高） */
export const DEFAULT_IMAGE_CONCURRENCY: number = 3;
/** 默认章节级并发上限（P2 双层并发：章节 <= 2，单章内/全局图片 <= 3） */
export const DEFAULT_CHAPTER_CONCURRENCY: number = 2;
/** 最小剩余磁盘安全余量（200MB） */
export const MIN_FREE_SPACE_BYTES: number = 200 * 1024 * 1024;
/** 允许配置的并发上下限（限制并发即限制同时驻留内存的图片数） */
export const MIN_IMAGE_CONCURRENCY: number = 1;
export const MAX_IMAGE_CONCURRENCY: number = 6;
/** 单张图片最小合法字节数（小于此视为损坏/错误页） */
export const MIN_IMAGE_BYTES: number = 1;

/**
 * 取消令牌：连接「任务状态」与「已经发出的 HTTP 请求」。
 *
 * 关键事实（任务书 Step 5）：修改任务状态**不能**立即取消已发出的请求。
 * API 26 的 `rcp.Session.cancel(requestToCancel)` 支持取消指定 Request，
 * 因此下载器在请求创建时通过 `onCancel()` 注册真正的取消动作；
 * 暂停/取消时先置 cancelled 标记，再触发已注册的 RCP 取消。
 */
export class DownloadToken {
  readonly key: string;
  private canceled: boolean = false;
  private action?: () => void;

  constructor(key: string) {
    this.key = key;
  }

  /** 由下载器注册「取消在途 RCP 请求」的动作 */
  onCancel(action: () => void): void {
    this.action = action;
  }

  get isCanceled(): boolean {
    return this.canceled;
  }

  cancel(): void {
    this.canceled = true;
    const act: (() => void) | undefined = this.action;
    if (act !== undefined) {
      try {
        act();
      } catch (e) {
        // 取消动作本身失败（如请求已结束）不得影响状态机
      }
    }
  }
}

/** 章节图片清单端口（与站点协议解耦：只要求「有序 URL 列表」） */
export interface ChapterImagePlanProvider {
  getImageUrls(bookId: string, chapterId: string): Promise<string[]>;
}

/** 下载专用文件系统端口（永久下载目录，与图片缓存端口 CacheFsPort 完全分离） */
export interface DownloadFsPort {
  /** 递归创建目录（已存在则直接返回） */
  ensureDir(path: string): Promise<void>;
  /** 路径是否存在 */
  exists(path: string): Promise<boolean>;
  /** 文件大小；-1 = 不存在或不可读 */
  fileSize(path: string): Promise<number>;
  /** 向临时文件追加一段二进制数据；返回追加后的累计字节数 */
  appendChunk(path: string, chunk: ArrayBuffer): Promise<number>;
  /** 原子提交：临时文件 → 正式文件（生产用 fs.rename） */
  commit(tempPath: string, finalPath: string): Promise<void>;
  /** 删除单个文件（不存在时静默成功） */
  remove(path: string): Promise<void>;
  /** 递归删除章节目录（用于删除已下载章节） */
  removeDirRecursive(path: string): Promise<void>;
  /** 列出目录下的文件名（不存在返回空数组） */
  listFiles(dirPath: string): Promise<string[]>;
  /** 递归统计目录内所有文件字节数（下载占用独立统计） */
  totalSize(dirPath: string): Promise<number>;
  /** 可选：读取文件前 N 字节用于魔数校验 */
  readHeader?(path: string, maxBytes: number): Promise<Uint8Array | null>;
  /** 可选：查询所在文件系统可用空间字节数 */
  availableBytes?(dirPath: string): Promise<number>;
}

/**
 * 图片下载端口：把 url 的响应体流式写入临时文件，返回写入字节数。
 * 实现必须自行处理「取消 / 网络错误 / 写入错误」，失败时由调用方清理临时文件。
 */
export interface DownloadImagePort {
  fetch(url: string, tempPath: string, headers: Record<string, string>,
    token: DownloadToken): Promise<number>;
}

/** 下载任务仓储端口（生产由 DatabaseManager 适配，测试用内存实现） */
export interface DownloadRepositoryPort {
  upsert(task: DownloadTask): Promise<void>;
  get(bookId: string, chapterId: string): Promise<DownloadTask | null>;
  list(): Promise<DownloadTask[]>;
  remove(bookId: string, chapterId: string): Promise<void>;
  /** 清除已完成/已取消的任务记录（不动文件），返回删除条数 */
  clearFinished(): Promise<number>;
}

/**
 * 统一章节图片结果：在线与离线来源共用。
 * - `images` 为**按阅读顺序**排列的地址（在线 = https URL，离线 = file:// 沙盒 URI）；
 * - `complete=false` 时必须给出 `message`，阅读器据此显示「章节不完整」，不能静默跳过缺图。
 */
export class ChapterImageSet {
  readonly images: string[];
  readonly offline: boolean;
  readonly complete: boolean;
  readonly message: string;

  constructor(images: string[], offline: boolean, complete: boolean, message: string = '') {
    this.images = images;
    this.offline = offline;
    this.complete = complete;
    this.message = message;
  }

  static online(urls: string[]): ChapterImageSet {
    return new ChapterImageSet(urls, false, true, '');
  }

  static local(urls: string[]): ChapterImageSet {
    return new ChapterImageSet(urls, true, true, '');
  }

  static incomplete(message: string): ChapterImageSet {
    return new ChapterImageSet([], true, false, message);
  }
}

/** 阅读器统一图片来源接口（不破坏既有 IComicSource.getChapterImages 的 string[] 契约） */
export interface ChapterImageProvider {
  getChapterImages(bookId: string, chapterId: string): Promise<ChapterImageSet>;
}

/** 下载占用独立统计端口（供个人中心与缓存占用并列展示） */
export interface DownloadSizeProvider {
  getDownloadSize(): Promise<number>;
}

/**
 * 下载控制端口（UI / ViewModel 依赖抽象）：
 * 页面不得直接操作底层文件系统或数据库，只能通过本接口发指令。
 */
export interface DownloadControlPort {
  listTasks(): Promise<DownloadTask[]>;
  /** 从详情页把某章节加入下载队列，返回可展示的结果文案（UI 不接触底层实现） */
  enqueueChapter(bookId: string, chapterId: string, bookTitle: string,
    chapterTitle: string): Promise<string>;
  pause(bookId: string, chapterId: string): boolean;
  resume(bookId: string, chapterId: string): Promise<boolean>;
  retry(bookId: string, chapterId: string): Promise<boolean>;
  cancel(bookId: string, chapterId: string): boolean;
  cancelAllPending(): number;
  deleteChapter(bookId: string, chapterId: string, deleteFiles: boolean): Promise<void>;
  clearFinishedRecords(): Promise<number>;
  getDownloadSize(): Promise<number>;
  repairChapter?(bookId: string, chapterId: string): Promise<boolean>;
  pauseTask?(bookId: string, chapterId: string): Promise<boolean>;
  cancelTask?(bookId: string, chapterId: string): Promise<boolean>;
  pauseAll?(): number;
  pauseAllTasks?(): Promise<number>;
  cancelAllPendingTasks?(): Promise<number>;
  resumeAll?(): Promise<number>;
  getBookSize?(bookId: string): Promise<number>;
  deleteBook?(bookId: string): Promise<number>;
  deleteAllOfflineResources?(): Promise<number>;
  addListener(listener: () => void): void;
  removeListener(listener: () => void): void;
  dispose(): void;
}

/** 恢复报告（UI / 测试可据此断言，不掩盖任何异常状态） */
export class DownloadRecoveryReport {
  readonly total: number;
  readonly interrupted: number;
  readonly completedVerified: number;
  readonly incomplete: number;
  readonly resumable: number;

  constructor(total: number, interrupted: number, completedVerified: number,
    incomplete: number, resumable: number) {
    this.total = total;
    this.interrupted = interrupted;
    this.completedVerified = completedVerified;
    this.incomplete = incomplete;
    this.resumable = resumable;
  }
}

/** 重启恢复端口（ViewModel 只触发，不关心存储细节） */
export interface DownloadRecoveryPort {
  recover(): Promise<DownloadRecoveryReport>;
}

/**
 * 安全空实现：下载子系统尚未初始化（或本地单测环境）时使用，
 * 不伪造任务、不触碰文件与数据库。
 */
export class NoopDownloadControl implements DownloadControlPort {
  async listTasks(): Promise<DownloadTask[]> {
    return [];
  }

  async enqueueChapter(bookId: string, chapterId: string, bookTitle: string,
    chapterTitle: string): Promise<string> {
    return '下载子系统尚未初始化';
  }

  pause(bookId: string, chapterId: string): boolean {
    return false;
  }

  async resume(bookId: string, chapterId: string): Promise<boolean> {
    return false;
  }

  async retry(bookId: string, chapterId: string): Promise<boolean> {
    return false;
  }

  cancel(bookId: string, chapterId: string): boolean {
    return false;
  }

  cancelAllPending(): number {
    return 0;
  }

  async deleteChapter(bookId: string, chapterId: string,
    deleteFiles: boolean): Promise<void> {
  }

  async clearFinishedRecords(): Promise<number> {
    return 0;
  }

  async getDownloadSize(): Promise<number> {
    return 0;
  }

  addListener(listener: () => void): void {
  }

  removeListener(listener: () => void): void {
  }

  dispose(): void {
  }
}

/** 下载失败（携带可诊断原因，不吞异常） */
export class DownloadError extends Error {
  readonly causeKind: string;

  constructor(causeKind: string, message: string) {
    super(message);
    this.name = 'DownloadError';
    this.causeKind = causeKind;
  }
}

/** 取消/暂停导致的中断（区别于真实失败，不写入 failedImages） */
export class DownloadInterrupted extends Error {
  constructor(message: string = '下载已暂停或取消') {
    super(message);
    this.name = 'DownloadInterrupted';
  }
}
