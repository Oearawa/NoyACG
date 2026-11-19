/**
 * ImageCacheManager.ets —— 原生图片沙盒缓存管理器（单例）
 *
 * 全部使用 API 26 原生能力（rcp + @ohos.file.fs + cryptoFramework），零第三方依赖：
 * 1. 文件名 = MD5(url) + 扩展名，URL → 确定性安全文件名；
 * 2. 缓存目录 = context.cacheDir（应用专属沙盒，系统磁盘紧张时可自动清理，无需任何权限）；
 * 3. 命中链路：LRU 内存缓存 → 磁盘 fs.accessSync → rcp 下载（HttpManager 注入防盗链 Header）→ 落盘；
 * 4. 同 URL 并发请求合并（pending Map）：瀑布流中重复封面只下载一次；
 * 5. 故障隔离：任何一步失败都「降级返回原 URL」交给系统 Image 直连，本方法永不 reject；
 * 6. Phase 14-O：有界后台预取、调试计数、LRU 淘汰，避免列表滚动时重复网络请求和整屏占位闪烁。
 *
 * 上下文注入：EntryAbility.onCreate 中调用 init(context) 一次性注入。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { HttpBytesResult, HttpError, HttpManager, NOY_WEB_ORIGIN } from '../api/HttpManager';
import { CancelToken, RequestCanceledError } from '../api/CancelToken';
import { Logger } from './Logger';
import { CacheCleaner, CacheClearResult, CacheService, SandboxCacheFs } from './CacheCleaner';
import { LruStringCache } from './LruStringCache';
import { PreferenceManager } from './PreferenceManager';
import {
  MIN_IMAGE_BYTES,
  ParsedImageUrl,
  detectImageFormat,
  extensionForFormat,
  formatImageDiagRecord,
  isMimeCompatibleWithImage,
  isSupportedImageFormat,
  redactImageUrl,
  validateImageUrl
} from './ImageValidator';
import { IS_DEBUG_BUILD } from './BuildInfo';
import {
  CacheEvictionResult,
  CacheFileMeta,
  isUnlimited,
  pruneAccessIndex,
  selectEvictions,
  shouldEvict
} from './CachePolicy';

const TAG: string = 'ImageCacheManager';

/** url → file:// URI 内存缓存上限（LRU） */
const MEMORY_CACHE_LIMIT: number = 128;
/** 前台图片并发下载上限：避免分类/搜索网格首帧 20+ 卡片同时建连导致超时/429 */
const MAX_FOREGROUND_CONCURRENCY: number = 6;
/** 预取队列上限：绝不提前加载整页图片 */
const MAX_PREFETCH_QUEUE: number = 24;
/** 预取并发上限 */
const MAX_PREFETCH_CONCURRENCY: number = 2;

const CACHE_FILE_PATTERN: RegExp = /^[0-9a-f]{32}\.(jpg|png|webp|gif|avif)$/;
/** 访问时间索引文件名（放 filesDir：缓存目录被系统清理后索引仍可读，靠 prune 自愈） */
const ACCESS_INDEX_FILE: string = 'image_cache_index.json';
/** 索引落盘最小间隔（毫秒）：避免每次图片访问都写文件 */
const ACCESS_INDEX_SAVE_INTERVAL_MS: number = 5000;
/** 每写入多少次缓存触发一次后台容量检查（避免每次落盘都扫目录） */
const ENFORCE_AFTER_WRITES: number = 25;

export interface ImageCacheCounters {
  memoryHitCount: number;
  memoryMissCount: number;
  networkRequestCount: number;
  dedupedRequestCount: number;
  prefetchQueuedCount: number;
  prefetchRequestCount: number;
}

export interface ImageMetricsSnapshot {
  totalRequests: number;
  successCount: number;
  failureCount: number;
  timeoutCount: number;
  decodeFailureCount: number;
  cacheHitCount: number;
  cacheMissCount: number;
  retryCount: number;
}

export class ImageLoadError extends Error {
  readonly kind: string;
  readonly statusCode: number;

  constructor(kind: string, message: string, statusCode: number = -1) {
    super(message);
    this.name = 'ImageLoadError';
    this.kind = kind;
    this.statusCode = statusCode;
  }
}

export interface ImageCacheDebugSnapshot {
  memoryKeys: string[];
  pendingCount: number;
  prefetchQueueSize: number;
  counters: ImageCacheCounters;
}

interface PrefetchTask {
  url: string;
  token: string;
}

class SharedDownloadEntry {
  readonly url: string;
  readonly internalToken: CancelToken = new CancelToken();
  activeConsumers: number = 0;
  settled: boolean = false;
  promise: Promise<string>;

  constructor(url: string, promise: Promise<string>) {
    this.url = url;
    this.promise = promise;
  }
}

interface ConcurrencyWaiter {
  resolve: () => void;
  reject: (err: Object) => void;
  token?: CancelToken;
}

export class ImageCacheManager implements CacheService {
  private static instance?: ImageCacheManager;
  private appContext?: common.Context;
  /** url → 本地 file:// URI，LRU 有界缓存 */
  private memory: LruStringCache = new LruStringCache(MEMORY_CACHE_LIMIT);
  /** 进行中的下载任务（同 URL 并发去重 + 多消费者安全取消） */
  private pending: Map<string, SharedDownloadEntry> = new Map<string, SharedDownloadEntry>();
  /** 前台并发控制 */
  private foregroundRunning: number = 0;
  private foregroundWaiters: ConcurrencyWaiter[] = [];
  /** 正在写入的缓存文件名：清理时跳过 */
  private writingFiles: Set<string> = new Set<string>();
  private cacheCleaner?: CacheCleaner;

  private counters: ImageCacheCounters = {
    memoryHitCount: 0,
    memoryMissCount: 0,
    networkRequestCount: 0,
    dedupedRequestCount: 0,
    prefetchQueuedCount: 0,
    prefetchRequestCount: 0
  };
  private metrics: ImageMetricsSnapshot = {
    totalRequests: 0,
    successCount: 0,
    failureCount: 0,
    timeoutCount: 0,
    decodeFailureCount: 0,
    cacheHitCount: 0,
    cacheMissCount: 0,
    retryCount: 0
  };
  private prefetchQueue: PrefetchTask[] = [];
  private prefetchQueued: Set<string> = new Set<string>();
  private activePrefetchTokens: Set<string> = new Set<string>();
  private prefetchRunning: number = 0;
  /** 缓存文件名 → 最近访问时间（毫秒）；持久化到 filesDir，缺失时按 0（最旧）处理 */
  private accessIndex: Map<string, number> = new Map<string, number>();
  private accessIndexLoaded: boolean = false;
  private lastIndexSaveTs: number = 0;
  private writesSinceEnforce: number = 0;
  /** 清理单飞锁：同一时间只允许一个清理任务，避免并发删除 */
  private enforceRunning: boolean = false;
  private lastEviction: CacheEvictionResult = CacheEvictionResult.skipped(-1);
  /** 测试钩子：无文件系统/网络能力的宿主单测中注入模拟下载器 */
  private testDownloader?: (url: string, token: CancelToken) => Promise<HttpBytesResult>;

  private constructor() {
  }

  static getInstance(): ImageCacheManager {
    if (ImageCacheManager.instance === undefined) {
      ImageCacheManager.instance = new ImageCacheManager();
    }
    return ImageCacheManager.instance;
  }

  init(context: common.Context): void {
    this.appContext = context;
  }

  async getImage(url: string, context?: common.Context,
    consumerToken?: CancelToken): Promise<string> {
    if (consumerToken !== undefined && consumerToken.isCanceled()) {
      throw new RequestCanceledError();
    }
    const parsed: ParsedImageUrl = validateImageUrl(url);
    if (!parsed.valid) {
      this.metrics.totalRequests++;
      this.metrics.failureCount++;
      throw new ImageLoadError('invalid_url', `非法图片 URL (${parsed.reason})`);
    }
    const normalized: string = parsed.normalizedUrl;
    // 离线章节的 file:// 沙盒 URI 直接渲染，绝不当成远程 URL 下载。
    if (parsed.isLocalFile) {
      return normalized;
    }

    this.metrics.totalRequests++;
    const memo: string | undefined = this.memory.get(normalized);
    if (memo !== undefined) {
      this.counters.memoryHitCount++;
      this.metrics.cacheHitCount++;
      this.metrics.successCount++;
      return memo;
    }
    this.counters.memoryMissCount++;

    let entry: SharedDownloadEntry | undefined = this.pending.get(normalized);
    if (entry !== undefined) {
      this.counters.dedupedRequestCount++;
    } else {
      const ctx: common.Context | undefined = context ?? this.appContext;
      if (ctx === undefined && this.testDownloader === undefined) {
        this.metrics.failureCount++;
        Logger.warn(TAG, '未注入上下文，无法下载缓存图片');
        throw new ImageLoadError('io', '缓存尚未初始化（未注入应用上下文）');
      }
      const created: SharedDownloadEntry = new SharedDownloadEntry(normalized, Promise.resolve(''));
      created.promise = this.runSharedDownload(normalized, ctx, created);
      this.pending.set(normalized, created);
      entry = created;
    }

    return await this.awaitSharedEntry(entry, consumerToken);
  }

  private async awaitSharedEntry(entry: SharedDownloadEntry,
    consumerToken?: CancelToken): Promise<string> {
    entry.activeConsumers++;
    if (consumerToken === undefined) {
      try {
        return await entry.promise;
      } finally {
        entry.activeConsumers = Math.max(0, entry.activeConsumers - 1);
      }
    }
    if (consumerToken.isCanceled()) {
      this.releaseConsumer(entry);
      throw new RequestCanceledError();
    }
    return await new Promise<string>((resolve: (uri: string) => void, reject: (err: Object) => void) => {
      let settled: boolean = false;
      const unregister: () => void = consumerToken.onCancel((): void => {
        if (settled) {
          return;
        }
        settled = true;
        this.releaseConsumer(entry);
        reject(new RequestCanceledError());
      });
      entry.promise.then((uri: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        unregister();
        entry.activeConsumers = Math.max(0, entry.activeConsumers - 1);
        resolve(uri);
      }).catch((err: Object): void => {
        if (settled) {
          return;
        }
        settled = true;
        unregister();
        entry.activeConsumers = Math.max(0, entry.activeConsumers - 1);
        reject(err);
      });
    });
  }

  private releaseConsumer(entry: SharedDownloadEntry): void {
    entry.activeConsumers = Math.max(0, entry.activeConsumers - 1);
    if (entry.activeConsumers === 0 && !entry.settled) {
      entry.internalToken.cancel();
    }
  }

  private async runSharedDownload(url: string, context: common.Context | undefined,
    entry: SharedDownloadEntry): Promise<string> {
    try {
      const uri: string = await this.downloadToCache(url, context, entry.internalToken);
      this.metrics.successCount++;
      return uri;
    } catch (e) {
      if (e instanceof RequestCanceledError) {
        throw e;
      }
      if (e instanceof ImageLoadError) {
        if (e.kind === 'timeout') {
          this.metrics.timeoutCount++;
        } else if (e.kind === 'decode') {
          this.metrics.decodeFailureCount++;
        }
        this.metrics.failureCount++;
        throw e;
      }
      this.metrics.failureCount++;
      throw e instanceof Error ? e : new Error(String(e));
    } finally {
      entry.settled = true;
      this.pending.delete(url);
    }
  }

  private acquireForegroundSlot(token: CancelToken): Promise<void> {
    if (token.isCanceled()) {
      return Promise.reject(new RequestCanceledError());
    }
    if (this.foregroundRunning < MAX_FOREGROUND_CONCURRENCY) {
      this.foregroundRunning++;
      return Promise.resolve();
    }
    return new Promise<void>((resolve: () => void, reject: (err: Object) => void) => {
      const waiter: ConcurrencyWaiter = {
        resolve: resolve,
        reject: reject,
        token: token
      };
      this.foregroundWaiters.push(waiter);
      token.onCancel((): void => {
        const idx: number = this.foregroundWaiters.indexOf(waiter);
        if (idx >= 0) {
          this.foregroundWaiters.splice(idx, 1);
          reject(new RequestCanceledError());
        }
      });
    });
  }

  private releaseForegroundSlot(): void {
    this.foregroundRunning = Math.max(0, this.foregroundRunning - 1);
    while (this.foregroundRunning < MAX_FOREGROUND_CONCURRENCY && this.foregroundWaiters.length > 0) {
      const next: ConcurrencyWaiter | undefined = this.foregroundWaiters.shift();
      if (next === undefined) {
        return;
      }
      if (next.token !== undefined && next.token.isCanceled()) {
        next.reject(new RequestCanceledError());
        continue;
      }
      this.foregroundRunning++;
      next.resolve();
    }
  }

  private isValidCachedFile(cachePath: string): boolean {
    try {
      if (!fs.accessSync(cachePath)) {
        return false;
      }
      const stat: fs.Stat = fs.statSync(cachePath);
      if (stat.isDirectory() || stat.size < MIN_IMAGE_BYTES) {
        fs.unlinkSync(cachePath);
        return false;
      }
      const file: fs.File = fs.openSync(cachePath, fs.OpenMode.READ_ONLY);
      try {
        const head: ArrayBuffer = new ArrayBuffer(MIN_IMAGE_BYTES);
        const readLen: number = fs.readSync(file.fd, head, { length: MIN_IMAGE_BYTES });
        if (readLen < MIN_IMAGE_BYTES) {
          return false;
        }
        const fmt: string = detectImageFormat(new Uint8Array(head));
        return isSupportedImageFormat(fmt);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      return false;
    }
  }

  private async downloadToCache(url: string, context: common.Context | undefined,
    token: CancelToken): Promise<string> {
    const safeUrl: string = redactImageUrl(url);
    const md5: string = await ImageCacheManager.md5Hex(url);
    const defaultExt: string = this.extOf(url);
    const defaultFileName: string = `${md5}${defaultExt}`;
    const defaultCachePath: string = context !== undefined ? `${context.cacheDir}/${defaultFileName}` : '';

    if (context !== undefined && this.isValidCachedFile(defaultCachePath)) {
      Logger.debug(TAG, `磁盘命中: ${defaultFileName}`);
      if (IS_DEBUG_BUILD) {
        Logger.debug(TAG, formatImageDiagRecord(
          '-', url, 'disk-hit', 200, 'image/*', 0, 'none', 'cached'));
      }
      this.metrics.cacheHitCount++;
      this.touchAccess(defaultFileName);
      const diskUri: string = `file://${defaultCachePath}`;
      this.remember(url, diskUri);
      return diskUri;
    }

    this.metrics.cacheMissCount++;
    await this.acquireForegroundSlot(token);
    let res: HttpBytesResult;
    try {
      if (token.isCanceled()) {
        throw new RequestCanceledError();
      }
      const antiLeechHeaders: Record<string, string> = {
        'referer': `${NOY_WEB_ORIGIN}/`,
        'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' +
          ' (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
      };
      this.counters.networkRequestCount++;
      if (this.testDownloader !== undefined) {
        res = await this.testDownloader(url, token);
      } else {
        res = await HttpManager.getInstance().getBytesWithMeta(url, antiLeechHeaders, token);
      }
    } catch (e) {
      if (e instanceof RequestCanceledError) {
        throw e;
      }
      if (e instanceof HttpError) {
        if (e.retryHint === 'cancel') {
          throw new RequestCanceledError();
        }
        const msgLower: string = e.message.toLowerCase();
        const isTimeout: boolean = e.statusCode === 408 || msgLower.indexOf('timeout') >= 0;
        Logger.warn(TAG, `图片下载失败 (${e.statusCode}): ${safeUrl}`);
        throw new ImageLoadError(isTimeout ? 'timeout' : (e.statusCode > 0 ? 'http' : 'network'),
          e.message, e.statusCode);
      }
      const msg: string = (e as BusinessError).message ?? String(e);
      Logger.warn(TAG, `图片下载异常: ${msg} (${safeUrl})`);
      throw new ImageLoadError('network', msg);
    } finally {
      this.releaseForegroundSlot();
    }

    const detectedFmt: string = detectImageFormat(res.bytes);
    if (!isSupportedImageFormat(detectedFmt) ||
      !isMimeCompatibleWithImage(res.contentType, detectedFmt)) {
      if (IS_DEBUG_BUILD) {
        Logger.debug(TAG, formatImageDiagRecord(
          '-', url, 'miss', res.statusCode, res.contentType, res.bytes.byteLength, `fmt:${detectedFmt}`, 'rejected'));
      }
      Logger.warn(TAG,
        `图片格式校验失败 fmt=${detectedFmt} ct=${res.contentType} len=${res.bytes.byteLength} (${safeUrl})`);
      throw new ImageLoadError('decode', `无效图片响应 (${detectedFmt})`, res.statusCode);
    }
    if (IS_DEBUG_BUILD) {
      Logger.debug(TAG, formatImageDiagRecord(
        '-', url, 'network-ok', res.statusCode, res.contentType, res.bytes.byteLength, 'none', `fmt:${detectedFmt}`));
    }

    const actualExt: string = extensionForFormat(detectedFmt);
    const fileName: string = `${md5}${actualExt !== '' ? actualExt : defaultExt}`;
    if (context === undefined) {
      const virtualUri: string = `file://test-cache/${fileName}`;
      this.remember(url, virtualUri);
      return virtualUri;
    }
    const cachePath: string = `${context.cacheDir}/${fileName}`;
    const tmpPath: string = `${cachePath}.tmp`;

    this.writingFiles.add(fileName);
    let file: fs.File | undefined = undefined;
    try {
      file = fs.openSync(tmpPath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, res.bytes.buffer, {
        offset: res.bytes.byteOffset,
        length: res.bytes.byteLength
      });
      fs.closeSync(file);
      file = undefined;
      fs.renameSync(tmpPath, cachePath);
      Logger.debug(TAG, `落盘成功: ${fileName} (${res.bytes.byteLength}B, ${detectedFmt})`);
    } catch (e) {
      Logger.error(TAG, `图片落盘失败: ${(e as BusinessError).message}`);
      try {
        if (fs.accessSync(tmpPath)) {
          fs.unlinkSync(tmpPath);
        }
      } catch (_cleanupErr) {
        // 清理临时文件失败忽略
      }
      throw new ImageLoadError('io', `图片落盘失败: ${(e as BusinessError).message}`);
    } finally {
      if (file !== undefined) {
        fs.closeSync(file);
      }
      this.writingFiles.delete(fileName);
    }

    this.touchAccess(fileName);
    const localUri: string = `file://${cachePath}`;
    this.remember(url, localUri);
    // 有界触发：每 ENFORCE_AFTER_WRITES 次落盘检查一次容量，绝不在每次写盘时扫目录
    this.writesSinceEnforce++;
    if (this.writesSinceEnforce >= ENFORCE_AFTER_WRITES) {
      this.writesSinceEnforce = 0;
      this.enforceCacheLimitInBackground();
    }
    return localUri;
  }

  /** 仅淘汰内存 LRU 引用（保留磁盘缓存，供长章节滑动窗口释放内存） */
  releaseMemoryEntry(url: string): boolean {
    if (url === '' || url.startsWith('file://')) {
      return false;
    }
    if (this.memory.get(url) !== undefined) {
      this.memory.delete(url);
      return true;
    }
    return false;
  }

  /** 解码失败时清除内存与磁盘中的损坏缓存，避免下次命中同一坏文件 */
  async invalidateCache(url: string): Promise<void> {
    if (url === '' || url.startsWith('file://')) {
      return;
    }
    const memo: string | undefined = this.memory.get(url);
    this.memory.delete(url);
    if (memo !== undefined && memo.startsWith('file://')) {
      const memoPath: string = memo.substring(7);
      try {
        if (fs.accessSync(memoPath)) {
          fs.unlinkSync(memoPath);
        }
      } catch (_e) {
        // 忽略清理异常
      }
    }
    const ctx: common.Context | undefined = this.appContext;
    if (ctx === undefined) {
      return;
    }
    try {
      const md5: string = await ImageCacheManager.md5Hex(url);
      const exts: string[] = ['.webp', '.jpg', '.png', '.gif', '.avif'];
      for (let i = 0; i < exts.length; i++) {
        const p: string = `${ctx.cacheDir}/${md5}${exts[i]}`;
        try {
          if (fs.accessSync(p)) {
            fs.unlinkSync(p);
          }
        } catch (_e) {
          // 忽略单文件清理异常
        }
      }
    } catch (_e) {
      // 忽略 md5 异常
    }
  }

  recordDecodeFailure(): void {
    this.metrics.decodeFailureCount++;
    this.metrics.failureCount++;
  }

  getMetrics(): ImageMetricsSnapshot {
    return {
      totalRequests: this.metrics.totalRequests,
      successCount: this.metrics.successCount,
      failureCount: this.metrics.failureCount,
      timeoutCount: this.metrics.timeoutCount,
      decodeFailureCount: this.metrics.decodeFailureCount,
      cacheHitCount: this.metrics.cacheHitCount,
      cacheMissCount: this.metrics.cacheMissCount,
      retryCount: this.metrics.retryCount
    };
  }

  private remember(url: string, localUri: string): void {
    this.memory.set(url, localUri);
  }

  /**
   * 有界后台预取。已缓存、在途、排队中的 URL 自动跳过；
   * token 用于页面退出时取消尚未开始的队列任务，在途网络请求不强行中断。
   */
  prefetch(urls: string[], token: string, maxConcurrent: number = MAX_PREFETCH_CONCURRENCY): void {
    if (urls.length === 0 || token === '') {
      return;
    }
    this.activePrefetchTokens.add(token);
    const limit: number = Math.max(1, Math.min(maxConcurrent, MAX_PREFETCH_CONCURRENCY));
    for (let i = 0; i < urls.length; i++) {
      const url: string = urls[i];
      if (url === '' || url.startsWith('file://')) {
        continue;
      }
      if (this.memory.has(url) || this.pending.has(url) || this.prefetchQueued.has(url)) {
        continue;
      }
      if (this.prefetchQueue.length >= MAX_PREFETCH_QUEUE) {
        break;
      }
      this.prefetchQueued.add(url);
      this.prefetchQueue.push({ url: url, token: token });
      this.counters.prefetchQueuedCount++;
    }
    this.drainPrefetch(limit);
  }

  cancelPrefetch(token: string): void {
    if (token === '') {
      return;
    }
    this.activePrefetchTokens.delete(token);
    const kept: PrefetchTask[] = [];
    for (let i = 0; i < this.prefetchQueue.length; i++) {
      const task: PrefetchTask = this.prefetchQueue[i];
      if (task.token === token) {
        this.prefetchQueued.delete(task.url);
      } else {
        kept.push(task);
      }
    }
    this.prefetchQueue = kept;
  }

  private drainPrefetch(limit: number): void {
    while (this.prefetchRunning < limit && this.prefetchQueue.length > 0) {
      const task: PrefetchTask | undefined = this.prefetchQueue.shift();
      if (task === undefined) {
        return;
      }
      if (!this.activePrefetchTokens.has(task.token)) {
        this.prefetchQueued.delete(task.url);
        continue;
      }
      this.prefetchRunning++;
      this.counters.prefetchRequestCount++;
      this.runPrefetchTask(task.url, task.token, limit).catch((e: Error) => {
        Logger.warn(TAG, `prefetch task rejected: ${e.message}`);
      });
    }
  }

  private async runPrefetchTask(url: string, token: string, limit: number): Promise<void> {
    try {
      await this.getImage(url);
    } catch (e) {
      Logger.warn(TAG, `预取失败，忽略: ${url}`);
    } finally {
      this.prefetchRunning--;
      this.prefetchQueued.delete(url);
      this.drainPrefetch(limit);
    }
  }

  // ==================== 缓存治理 / 调试 ====================

  static isImageCacheFile(name: string): boolean {
    return CACHE_FILE_PATTERN.test(name);
  }

  async getCacheSize(): Promise<number> {
    const context: common.Context | undefined = this.appContext;
    if (context === undefined) {
      Logger.warn(TAG, '未注入上下文，缓存统计返回 0');
      return 0;
    }
    try {
      const size: number = await this.cleaner().sum(context.cacheDir);
      Logger.info(TAG, `图片缓存占用: ${size}B`);
      return size;
    } catch (e) {
      Logger.error(TAG, `缓存统计失败: ${(e as BusinessError).message}`);
      return 0;
    }
  }

  async clearImageCache(): Promise<CacheClearResult> {
    const context: common.Context | undefined = this.appContext;
    if (context === undefined) {
      return new CacheClearResult(false, 0, 0, 0, '缓存尚未初始化（未注入应用上下文）');
    }
    try {
      const result: CacheClearResult = await this.cleaner().clear(context.cacheDir);
      this.resetMemoryCache();
      this.accessIndex.clear();
      this.accessIndexLoaded = true;
      this.persistAccessIndex(true);
      this.lastEviction = CacheEvictionResult.skipped(this.getCacheLimitBytes());
      return result;
    } catch (e) {
      this.resetMemoryCache();
      const message: string = (e as BusinessError).message;
      return new CacheClearResult(false, 0, 0, 0, `缓存清理异常: ${message}`);
    }
  }

  private cleaner(): CacheCleaner {
    if (this.cacheCleaner === undefined) {
      this.cacheCleaner = new CacheCleaner(
        new SandboxCacheFs(),
        (name: string): boolean => ImageCacheManager.isImageCacheFile(name),
        (name: string): boolean => this.writingFiles.has(name),
        (message: string): void => {
          Logger.warn(TAG, message);
        });
    }
    return this.cacheCleaner;
  }

  private resetMemoryCache(): void {
    this.memory.clear();
  }

  getCounters(): ImageCacheCounters {
    return {
      memoryHitCount: this.counters.memoryHitCount,
      memoryMissCount: this.counters.memoryMissCount,
      networkRequestCount: this.counters.networkRequestCount,
      dedupedRequestCount: this.counters.dedupedRequestCount,
      prefetchQueuedCount: this.counters.prefetchQueuedCount,
      prefetchRequestCount: this.counters.prefetchRequestCount
    };
  }

  getDebugSnapshot(): ImageCacheDebugSnapshot {
    return {
      memoryKeys: this.memory.keys(),
      pendingCount: this.pending.size,
      prefetchQueueSize: this.prefetchQueue.length,
      counters: this.getCounters()
    };
  }

  resetCountersForTest(): void {
    this.counters = {
      memoryHitCount: 0,
      memoryMissCount: 0,
      networkRequestCount: 0,
      dedupedRequestCount: 0,
      prefetchQueuedCount: 0,
      prefetchRequestCount: 0
    };
  }

  setMemoryCacheForTest(url: string, localUri: string): void {
    this.remember(url, localUri);
  }

  getMemoryKeysForTest(): string[] {
    return this.memory.keys();
  }

  clearMemoryForTest(): void {
    this.resetMemoryCache();
  }

  setTestDownloaderForTest(
    downloader?: (url: string, token: CancelToken) => Promise<HttpBytesResult>
  ): void {
    this.testDownloader = downloader;
  }

  resetMetricsForTest(): void {
    this.metrics = {
      totalRequests: 0,
      successCount: 0,
      failureCount: 0,
      timeoutCount: 0,
      decodeFailureCount: 0,
      cacheHitCount: 0,
      cacheMissCount: 0,
      retryCount: 0
    };
  }

  // ==================== 容量上限与 LRU 清理（Phase 14-R） ====================

  /** 当前容量上限（字节；-1 = 无限制）。唯一来源是 PreferenceManager。 */
  getCacheLimitBytes(): number {
    return PreferenceManager.getInstance().getCacheLimitBytesSync();
  }

  /**
   * 设置容量上限并立即按新上限执行一次清理。
   * @returns true = 已持久化（清理结果见 getLastEviction）
   */
  async setCacheLimitBytes(bytes: number): Promise<boolean> {
    const ok: boolean = await PreferenceManager.getInstance().setCacheLimitBytes(bytes);
    await this.enforceCacheLimit();
    return ok;
  }

  /** 最近一次清理结果（UI 展示「上次清理释放了多少」） */
  getLastEviction(): CacheEvictionResult {
    return this.lastEviction;
  }

  /** 后台触发一次容量检查（不等待、不抛异常；单飞锁保证不会并发删除） */
  enforceCacheLimitInBackground(): void {
    this.enforceCacheLimit().catch((e: Error) => {
      Logger.warn(TAG, `后台缓存清理失败: ${e.message}`);
    });
  }

  /** 记录一次访问（同文件多次访问只更新时间戳；落盘按 5s 节流） */
  private touchAccess(fileName: string): void {
    this.loadAccessIndex();
    this.accessIndex.set(fileName, Date.now());
    this.persistAccessIndex(false);
  }

  private indexFilePath(): string | undefined {
    const ctx: common.Context | undefined = this.appContext;
    if (ctx === undefined) {
      return undefined;
    }
    return `${ctx.filesDir}/${ACCESS_INDEX_FILE}`;
  }

  /** 读取访问索引（失败 / 损坏一律当作空索引，不影响图片读取） */
  private loadAccessIndex(): void {
    if (this.accessIndexLoaded) {
      return;
    }
    this.accessIndexLoaded = true;
    const path: string | undefined = this.indexFilePath();
    if (path === undefined) {
      return;
    }
    try {
      if (!fs.accessSync(path)) {
        return;
      }
      const text: string = fs.readTextSync(path);
      const parsed: Record<string, number> = JSON.parse(text) as Record<string, number>;
      const keys: string[] = Object.keys(parsed);
      for (let i = 0; i < keys.length; i++) {
        const value: number = parsed[keys[i]];
        if (typeof value === 'number' && value > 0) {
          this.accessIndex.set(keys[i], value);
        }
      }
    } catch (e) {
      Logger.warn(TAG, `访问索引读取失败，按空索引处理: ${(e as BusinessError).message}`);
      this.accessIndex.clear();
    }
  }

  /** 写入访问索引（force=false 时按间隔节流；失败只记日志，绝不影响图片链路） */
  private persistAccessIndex(force: boolean): void {
    const now: number = Date.now();
    if (!force && now - this.lastIndexSaveTs < ACCESS_INDEX_SAVE_INTERVAL_MS) {
      return;
    }
    const path: string | undefined = this.indexFilePath();
    if (path === undefined) {
      return;
    }
    this.lastIndexSaveTs = now;
    try {
      const payload: Record<string, number> = {};
      this.accessIndex.forEach((value: number, key: string) => {
        payload[key] = value;
      });
      const file: fs.File = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(payload));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      Logger.warn(TAG, `访问索引写入失败: ${(e as BusinessError).message}`);
    }
  }

  /** 列出缓存目录中的图片文件（带体积与最近访问时间） */
  private async listCacheFiles(): Promise<CacheFileMeta[]> {
    const ctx: common.Context | undefined = this.appContext;
    if (ctx === undefined) {
      return [];
    }
    const result: CacheFileMeta[] = [];
    let names: string[] = [];
    try {
      names = await fs.listFile(ctx.cacheDir);
    } catch (e) {
      Logger.warn(TAG, `缓存目录读取失败，跳过清理: ${(e as BusinessError).message}`);
      return [];
    }
    this.loadAccessIndex();
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      if (!ImageCacheManager.isImageCacheFile(name)) {
        continue;
      }
      try {
        const stat: fs.Stat = await fs.stat(`${ctx.cacheDir}/${name}`);
        if (stat.isDirectory()) {
          continue;
        }
        const access: number | undefined = this.accessIndex.get(name);
        result.push(new CacheFileMeta(name, stat.size, access !== undefined ? access : 0));
      } catch (e) {
        Logger.warn(TAG, `缓存文件信息读取失败，跳过: ${name}`);
      }
    }
    return result;
  }

  /**
   * 按当前上限执行一次 LRU 清理。
   * 安全约束：
   * 1. 只删 cacheDir 下文件名符合图片缓存规则的文件（离线下载在 filesDir/Downloads，完全不受影响）；
   * 2. 正在写入的文件（writingFiles）一律跳过；
   * 3. 单飞锁：并发调用直接返回上次结果，绝不并行删除；
   * 4. 单次最多删除 MAX_EVICTIONS_PER_RUN 个文件（由 CachePolicy 限制）。
   */
  async enforceCacheLimit(): Promise<CacheEvictionResult> {
    const limit: number = this.getCacheLimitBytes();
    if (isUnlimited(limit)) {
      const skipped: CacheEvictionResult = CacheEvictionResult.skipped(limit);
      this.lastEviction = skipped;
      return skipped;
    }
    if (this.enforceRunning) {
      return this.lastEviction;
    }
    this.enforceRunning = true;
    try {
      const currentBytes: number = await this.getCacheSize();
      if (!shouldEvict(currentBytes, limit)) {
        const skipped: CacheEvictionResult = CacheEvictionResult.skipped(limit);
        this.lastEviction = skipped;
        return skipped;
      }
      const files: CacheFileMeta[] = pruneAccessIndex(await this.listCacheFiles(), this.accessIndex);
      const selected: CacheFileMeta[] = selectEvictions(files, currentBytes, limit,
        (name: string): boolean => this.writingFiles.has(name));
      let deleted: number = 0;
      let freed: number = 0;
      for (let i = 0; i < selected.length; i++) {
        const file: CacheFileMeta = selected[i];
        const ctx: common.Context | undefined = this.appContext;
        if (ctx === undefined) {
          break;
        }
        try {
          await fs.unlink(`${ctx.cacheDir}/${file.name}`);
          this.accessIndex.delete(file.name);
          deleted++;
          freed += file.size;
        } catch (e) {
          Logger.warn(TAG, `LRU 删除失败，跳过: ${file.name}`);
        }
      }
      this.persistAccessIndex(true);
      // 清理后必须重新统计真实占用，不能用工号推算值冒充
      const remaining: number = await this.getCacheSize();
      const result: CacheEvictionResult =
        new CacheEvictionResult(true, deleted, freed, remaining, limit);
      this.lastEviction = result;
      Logger.info(TAG, `LRU 清理完成: 删除${deleted}个, 释放${freed}B, 剩余${remaining}B, 上限${limit}B`);
      return result;
    } catch (e) {
      Logger.error(TAG, `LRU 清理异常: ${(e as BusinessError).message}`);
      const failed: CacheEvictionResult = CacheEvictionResult.skipped(limit);
      this.lastEviction = failed;
      return failed;
    } finally {
      this.enforceRunning = false;
    }
  }

  /** 测试钩子：直接注入访问时间，避免依赖真实文件系统 */
  setAccessTimeForTest(fileName: string, timestamp: number): void {
    this.accessIndexLoaded = true;
    this.accessIndex.set(fileName, timestamp);
  }

  private static async md5Hex(text: string): Promise<string> {
    try {
      const md: cryptoFramework.Md = cryptoFramework.createMd('MD5');
      const encoder: util.TextEncoder = new util.TextEncoder();
      const blob: cryptoFramework.DataBlob = { data: encoder.encodeInto(text) };
      await md.update(blob);
      const digest: cryptoFramework.DataBlob = await md.digest();
      if (digest.data !== undefined && digest.data.length > 0) {
        let hex: string = '';
        for (let i = 0; i < digest.data.length; i++) {
          hex += (digest.data[i] & 0xFF).toString(16).padStart(2, '0');
        }
        if (hex !== '' && !/^0+$/.test(hex)) {
          return hex;
        }
      }
    } catch (_e) {
      // 宿主单测运行时或不支持 MD5 的环境回退纯 ArkTS 128-bit 哈希
    }
    return ImageCacheManager.fallbackHash128Hex(text);
  }

  private static fallbackHash128Hex(text: string): string {
    const seeds: number[] = [0x811c9dc5, 0x9e3779b9, 0x85ebca6b, 0xc2b2ae35];
    const primes: number[] = [0x01000193, 0x010001a7, 0x010001b5, 0x010001c9];
    let hex: string = '';
    for (let lane = 0; lane < 4; lane++) {
      let h: number = seeds[lane];
      for (let i = 0; i < text.length; i++) {
        h = h ^ (text.charCodeAt(i) + lane * 31);
        h = Math.imul(h, primes[lane]);
      }
      hex += (h >>> 0).toString(16).padStart(8, '0');
    }
    return hex;
  }

  private extOf(url: string): string {
    const path: string = url.split('?')[0];
    const match: RegExpMatchArray | null = path.match(/\.(jpe?g|png|webp|gif|avif)$/i);
    if (match !== null) {
      const ext: string = match[1].toLowerCase();
      return ext === 'jpeg' ? '.jpg' : `.${ext}`;
    }
    return '.jpg';
  }
}
