/**
 * CacheViewModel.ets —— 图片缓存管理视图模型（状态管理 V2）
 *
 * 职责：把「统计 / 清理」两个耗时操作包装成 UI 可观察的状态机，
 * 页面只读 @Trace 字段，不接触任何文件系统细节。
 *
 * 状态机：
 *   IDLE ──refresh()──▶ CALCULATING ──▶ IDLE（cacheSizeBytes 更新 / errorMessage 更新）
 *   IDLE ──clear()──▶ CLEARING ──▶ IDLE（清理成功→自动重算占用；失败→保留真实错误）
 *
 * 并发保护：
 * - isCalculating / isClearing 同时充当 UI 状态与防重入锁，重复点击直接返回；
 * - 清理刚结束时禁用统计入口，避免「统计中读到半清理状态」。
 */
import { ImageCacheManager } from '../utils/ImageCacheManager';
import { CacheClearResult, CacheService } from '../utils/CacheCleaner';
import { DownloadSizeProvider } from '../download/DownloadPorts';
import { DownloadFactory, DownloadServices } from '../download/DownloadFactory';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../utils/Logger';

const TAG: string = 'CacheViewModel';
const BYTES_PER_MB: number = 1024 * 1024;
const BYTES_PER_KB: number = 1024;
const DEFAULT_SIZE_CALC_TIMEOUT_MS: number = 8000;

/**
 * 为异步统计操作增加超时保护，避免文件系统遍历挂起导致 UI 永远停留在「计算中...」。
 */
function runWithTimeout(task: Promise<number>, timeoutMs: number, fallbackValue: number): Promise<number> {
  if (timeoutMs <= 0) {
    return task;
  }
  return new Promise<number>((resolve: (value: number) => void, reject: (reason: Error) => void) => {
    let settled: boolean = false;
    const timerId: number = setTimeout(() => {
      if (!settled) {
        settled = true;
        resolve(fallbackValue);
      }
    }, timeoutMs);
    task.then((value: number) => {
      if (!settled) {
        settled = true;
        clearTimeout(timerId);
        resolve(value);
      }
    }).catch((err: Error) => {
      if (!settled) {
        settled = true;
        clearTimeout(timerId);
        reject(err);
      }
    });
  });
}

/** 生产下载占用提供者：未初始化下载子系统时返回 0（不伪造占用） */
class DefaultDownloadSizeProvider implements DownloadSizeProvider {
  async getDownloadSize(): Promise<number> {
    const services: DownloadServices | undefined = DownloadFactory.get();
    if (services === undefined) {
      return 0;
    }
    return await services.manager.getDownloadSize();
  }
}

@ObservedV2
export class CacheViewModel {
  /** 缓存占用（字节，统计结果） */
  @Trace cacheSizeBytes: number = 0;
  /** 缓存占用（MB，保留两位小数，UI 直接展示） */
  @Trace cacheSizeMB: number = 0;
  /** 统计进行中（驱动 Loading 态，同时作为防重入锁） */
  @Trace isCalculating: boolean = false;
  /** 清理进行中（驱动按钮禁用态，同时作为防重入锁） */
  @Trace isClearing: boolean = false;
  /** 是否已成功统计过（区分「还没算」与「算出来是 0」） */
  @Trace hasCalculated: boolean = false;
  /** 最近一次错误信息（空串 = 无错误） */
  @Trace errorMessage: string = '';
  /** 永久下载占用（字节）——与 cacheSizeBytes **独立统计**，互不混算 */
  @Trace downloadSizeBytes: number = 0;
  /** 下载占用统计进行中（Phase 14-J4：UI 需要「统计中」而不是直接显示 0 B） */
  @Trace isDownloadCalculating: boolean = false;
  /**
   * 下载占用统计失败（Phase 14-J4）。
   * 失败时**不得**把占用显示成 `0 B` —— 那会让用户以为离线数据为空，
   * 进而误判「下载被清理了」。UI 据此显示「统计失败」并提供重试。
   */
  @Trace downloadSizeError: boolean = false;

  /** 缓存服务（默认 ImageCacheManager 单例；单元测试可注入桩实现） */
  private service: CacheService;
  /** 下载占用服务（独立端口；测试可注入桩） */
  private downloadSizeService: DownloadSizeProvider;

  constructor(service?: CacheService, downloadSizeService?: DownloadSizeProvider) {
    this.service = service ?? ImageCacheManager.getInstance();
    this.downloadSizeService = downloadSizeService ?? new DefaultDownloadSizeProvider();
  }

  /**
   * 单独刷新永久下载占用（Phase 12）。
   * 缓存统计与下载统计走完全不同的服务与目录，清理缓存不会改动此值。
   *
   * Phase 14-J4：补充「统计中 / 统计失败」状态 —— 失败时保留上一次的字节数，
   * 但把 downloadSizeError 置位，由 UI 明确显示「统计失败」而不是伪装成 0 B。
   */
  async refreshDownloadSize(timeoutMs: number = DEFAULT_SIZE_CALC_TIMEOUT_MS): Promise<void> {
    if (this.isDownloadCalculating) {
      return;
    }
    this.isDownloadCalculating = true;
    this.downloadSizeError = false;
    try {
      this.downloadSizeBytes = await runWithTimeout(
        this.downloadSizeService.getDownloadSize(),
        timeoutMs,
        this.downloadSizeBytes
      );
    } catch (e) {
      Logger.error(TAG, `下载占用统计失败: ${(e as Error).message}`);
      this.downloadSizeError = true;
    } finally {
      this.isDownloadCalculating = false;
    }
  }

  /** 人类可读的下载占用 */
  formattedDownloadSize(): string {
    return CacheViewModel.formatBytes(this.downloadSizeBytes);
  }

  /**
   * 下载占用的展示文案（Phase 14-J4）：统计中 / 统计失败 / 真实占用 三态。
   * 不要在页面里各写一套 if —— 三态判断集中在此，避免某个页面漏掉失败态又显示 0 B。
   */
  downloadSizeText(): string {
    if (this.isDownloadCalculating) {
      return '统计中...';
    }
    if (this.downloadSizeError) {
      return '统计失败';
    }
    return this.formattedDownloadSize();
  }

  /** 统计缓存占用（页面 onReady / 清理成功后调用） */
  async refresh(timeoutMs: number = DEFAULT_SIZE_CALC_TIMEOUT_MS): Promise<void> {
    if (this.isCalculating || this.isClearing) {
      return;
    }
    this.isCalculating = true;
    this.errorMessage = '';
    try {
      const bytes: number = await runWithTimeout(
        this.service.getCacheSize(),
        timeoutMs,
        this.cacheSizeBytes
      );
      this.cacheSizeBytes = bytes;
      this.cacheSizeMB = Math.round(bytes / BYTES_PER_MB * 100) / 100;
      this.hasCalculated = true;
      Logger.info(TAG, `缓存占用统计完成: ${this.formattedSize()}`);
    } catch (e) {
      this.errorMessage = `缓存统计失败: ${(e as BusinessError).message}`;
      Logger.error(TAG, this.errorMessage);
    } finally {
      this.isCalculating = false;
    }
  }

  /**
   * 清理图片缓存（仅图片缓存，不含下载目录 / 数据库 / 登录信息）。
   * @returns 清理结果（失败时 errorMessage 为真实原因）；重入调用返回 null
   */
  async clear(): Promise<CacheClearResult | null> {
    if (this.isClearing || this.isCalculating) {
      return null;
    }
    this.isClearing = true;
    this.errorMessage = '';
    try {
      const result: CacheClearResult = await this.service.clearImageCache();
      if (!result.success) {
        this.errorMessage = result.errorMessage === ''
          ? '缓存清理失败，请稍后重试' : result.errorMessage;
        Logger.error(TAG, this.errorMessage);
        return result;
      }
      // 清理成功：立即用「已知释放量」回写 UI，再异步重算，避免用户看到旧数字
      this.cacheSizeBytes = Math.max(this.cacheSizeBytes - result.freedBytes, 0);
      this.cacheSizeMB = Math.round(this.cacheSizeBytes / BYTES_PER_MB * 100) / 100;
      Logger.info(TAG,
        `缓存清理成功: 删除${result.deletedCount}个, 释放${result.freedBytes}B`);
      return result;
    } catch (e) {
      this.errorMessage = `缓存清理失败: ${(e as BusinessError).message}`;
      Logger.error(TAG, this.errorMessage);
      return null;
    } finally {
      this.isClearing = false;
    }
  }

  /** 人类可读的占用文本（B / KB / MB 自适应，两位有效小数） */
  formattedSize(): string {
    return CacheViewModel.formatBytes(this.cacheSizeBytes);
  }

  /** 字节数 → 人类可读文本（清理结果提示等场景复用） */
  static formatBytes(bytes: number): string {
    if (bytes < BYTES_PER_KB) {
      return `${bytes} B`;
    }
    if (bytes < BYTES_PER_MB) {
      return `${(Math.round(bytes / BYTES_PER_KB * 10) / 10).toFixed(1)} KB`;
    }
    return `${(Math.round(bytes / BYTES_PER_MB * 100) / 100).toFixed(2)} MB`;
  }
}
