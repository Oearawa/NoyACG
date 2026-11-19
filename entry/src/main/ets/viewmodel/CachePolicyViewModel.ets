/**
 * CachePolicyViewModel.ets —— 缓存容量策略视图模型（Phase 14-R）
 *
 * 只包装 ImageCacheManager 的三个能力：真实占用统计、上限读写、按上限执行 LRU 清理。
 * 不自己算容量，也不自己删文件 —— 删除红线只在 CacheCleaner / ImageCacheManager。
 */
import { ImageCacheManager } from '../utils/ImageCacheManager';
import { DEFAULT_CACHE_LIMIT_BYTES, normalizeCacheLimit } from '../utils/PreferenceManager';
import { CacheEvictionResult, isUnlimited } from '../utils/CachePolicy';
import { CacheViewModel } from './CacheViewModel';

const USAGE_CALC_TIMEOUT_MS: number = 8000;

function withTimeoutFallback(task: Promise<number>, timeoutMs: number, fallbackValue: number): Promise<number> {
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

@ObservedV2
export class CachePolicyViewModel {
  /** 当前上限（字节；-1 = 无限制） */
  @Trace limitBytes: number = DEFAULT_CACHE_LIMIT_BYTES;
  /** 真实占用（字节） */
  @Trace usageBytes: number = 0;
  /** 统计/清理进行中 */
  @Trace isBusy: boolean = false;
  /** 最近一次清理是否已执行过（区分「从未清理」与「清理了 0 个」） */
  @Trace hasEvictionResult: boolean = false;
  @Trace lastDeletedCount: number = 0;
  @Trace lastFreedBytes: number = 0;
  @Trace lastRemainingBytes: number = -1;
  @Trace errorMessage: string = '';

  /** 初始化：同步读取持久化上限 + 统计真实占用 */
  async load(): Promise<void> {
    this.limitBytes = ImageCacheManager.getInstance().getCacheLimitBytes();
    const last: CacheEvictionResult = ImageCacheManager.getInstance().getLastEviction();
    this.applyResult(last);
    await this.refreshUsage();
  }

  /** 只统计真实占用（不触发清理） */
  async refreshUsage(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    this.errorMessage = '';
    try {
      this.usageBytes = await withTimeoutFallback(
        ImageCacheManager.getInstance().getCacheSize(),
        USAGE_CALC_TIMEOUT_MS,
        this.usageBytes
      );
    } catch (e) {
      this.errorMessage = (e as Error).message;
    } finally {
      this.isBusy = false;
    }
  }

  /**
   * 切换容量上限：先持久化 → 再按新上限执行一次清理 → 重新统计。
   * 持久化失败时回滚到旧值，避免「界面显示已改但重启回退」。
   */
  async selectLimit(bytes: number): Promise<void> {
    if (this.isBusy) {
      return;
    }
    const next: number = normalizeCacheLimit(bytes);
    const previous: number = this.limitBytes;
    this.isBusy = true;
    this.errorMessage = '';
    try {
      const ok: boolean = await ImageCacheManager.getInstance().setCacheLimitBytes(next);
      if (!ok) {
        this.limitBytes = previous;
        this.errorMessage = 'not_persisted';
        return;
      }
      this.limitBytes = next;
      this.applyResult(ImageCacheManager.getInstance().getLastEviction());
      this.usageBytes = await ImageCacheManager.getInstance().getCacheSize();
    } catch (e) {
      this.limitBytes = previous;
      this.errorMessage = (e as Error).message;
    } finally {
      this.isBusy = false;
    }
  }

  /** 立即按当前上限检查并清理一次 */
  async enforceNow(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    this.errorMessage = '';
    try {
      const result: CacheEvictionResult = await ImageCacheManager.getInstance().enforceCacheLimit();
      this.applyResult(result);
      this.usageBytes = result.remainingBytes >= 0
        ? result.remainingBytes : await ImageCacheManager.getInstance().getCacheSize();
    } catch (e) {
      this.errorMessage = (e as Error).message;
    } finally {
      this.isBusy = false;
    }
  }

  /** 是否无限制 */
  isUnlimited(): boolean {
    return isUnlimited(this.limitBytes);
  }

  /** 占用是否已超出上限（UI 用警示色提示） */
  isOverLimit(): boolean {
    return !this.isUnlimited() && this.usageBytes > this.limitBytes;
  }

  /** 人类可读占用 */
  usageText(): string {
    return CacheViewModel.formatBytes(this.usageBytes);
  }

  /** 人类可读上限 */
  limitText(): string {
    if (this.isUnlimited()) {
      return '';
    }
    return CacheViewModel.formatBytes(this.limitBytes);
  }

  private applyResult(result: CacheEvictionResult): void {
    if (!result.ran) {
      return;
    }
    this.hasEvictionResult = true;
    this.lastDeletedCount = result.deletedCount;
    this.lastFreedBytes = result.freedBytes;
    this.lastRemainingBytes = result.remainingBytes;
  }
}
