/**
 * ReaderPreloadWindow.ets —— 阅读器滑动窗口预加载与内存回收调度器（防长章节 OOM）
 *
 * 窗口区间定义（以 currentIndex 为中心，钳制于 [0, totalPages - 1]）：
 * - 高优先级预加载窗口：[currentIndex - 1, currentIndex + 3]（当前页最优先，向后预取 3 页，向前保留 1 页）
 * - 内存保留窗口：[currentIndex - 3, currentIndex + 5]
 *
 * 调度策略：
 * 1. 快速拖拽或跳页时，立即 cancel() 滑出保留窗口的在途预加载 CancelToken，避免队头阻塞与带宽浪费；
 * 2. 滑出保留窗口的页面立即从 retainedIndices/retainedUrls 淘汰并触发资源释放回调；
 * 3. 切章或退出阅读器时调用 dispose()，全量取消在途请求并清空窗口状态。
 */
import { CancelToken } from '../api/CancelToken';
import { ImageCacheManager } from '../utils/ImageCacheManager';
import { clampPageIndex } from './ReaderLayout';

export const PRELOAD_BACKWARD_COUNT: number = 2;
export const PRELOAD_FORWARD_COUNT: number = 4;
export const RETAIN_BACKWARD_COUNT: number = 5;
export const RETAIN_FORWARD_COUNT: number = 8;

export class WindowRange {
  readonly start: number;
  readonly end: number;

  constructor(start: number, end: number) {
    this.start = start;
    this.end = end;
  }

  contains(index: number): boolean {
    return this.start <= this.end && index >= this.start && index <= this.end;
  }
}

export class PreloadWindowUpdate {
  readonly preloadRange: WindowRange;
  readonly retainRange: WindowRange;
  readonly orderedPreloadIndices: number[];
  readonly canceledIndices: number[];
  readonly evictedIndices: number[];

  constructor(
    preloadRange: WindowRange,
    retainRange: WindowRange,
    orderedPreloadIndices: number[],
    canceledIndices: number[],
    evictedIndices: number[]
  ) {
    this.preloadRange = preloadRange;
    this.retainRange = retainRange;
    this.orderedPreloadIndices = orderedPreloadIndices;
    this.canceledIndices = canceledIndices;
    this.evictedIndices = evictedIndices;
  }
}

export interface ReaderImageFetcher {
  fetch(url: string, token: CancelToken): Promise<string>;
  release?(url: string): void;
}

class DefaultCacheImageFetcher implements ReaderImageFetcher {
  async fetch(url: string, token: CancelToken): Promise<string> {
    return await ImageCacheManager.getInstance().getImage(url, undefined, token);
  }

  release(url: string): void {
    ImageCacheManager.getInstance().releaseMemoryEntry(url);
  }
}

/** 计算高优先级预加载窗口 [currentIndex - 1, currentIndex + 3] */
export function computePreloadRange(currentIndex: number, totalPages: number): WindowRange {
  if (!Number.isFinite(totalPages) || totalPages <= 0) {
    return new WindowRange(0, -1);
  }
  const safeTotal: number = Math.floor(totalPages);
  const center: number = clampPageIndex(currentIndex, safeTotal);
  const start: number = Math.max(0, center - PRELOAD_BACKWARD_COUNT);
  const end: number = Math.min(safeTotal - 1, center + PRELOAD_FORWARD_COUNT);
  return new WindowRange(start, end);
}

/** 计算内存保留窗口 [currentIndex - 3, currentIndex + 5] */
export function computeRetainRange(currentIndex: number, totalPages: number): WindowRange {
  if (!Number.isFinite(totalPages) || totalPages <= 0) {
    return new WindowRange(0, -1);
  }
  const safeTotal: number = Math.floor(totalPages);
  const center: number = clampPageIndex(currentIndex, safeTotal);
  const start: number = Math.max(0, center - RETAIN_BACKWARD_COUNT);
  const end: number = Math.min(safeTotal - 1, center + RETAIN_FORWARD_COUNT);
  return new WindowRange(start, end);
}

/** 按优先级生成预加载下标序列：当前页 -> 向后 1..3 -> 向前 1 */
export function computePreloadOrder(currentIndex: number, totalPages: number): number[] {
  const range: WindowRange = computePreloadRange(currentIndex, totalPages);
  if (range.start > range.end) {
    return [];
  }
  const center: number = clampPageIndex(currentIndex, totalPages);
  const order: number[] = [center];
  for (let offset = 1; offset <= PRELOAD_FORWARD_COUNT; offset++) {
    const idx: number = center + offset;
    if (idx <= range.end) {
      order.push(idx);
    }
  }
  for (let offset = 1; offset <= PRELOAD_BACKWARD_COUNT; offset++) {
    const idx: number = center - offset;
    if (idx >= range.start) {
      order.push(idx);
    }
  }
  return order;
}

/** 找出滑出保留窗口的已追踪下标 */
export function computeEvictedIndices(trackedIndices: number[], retainRange: WindowRange): number[] {
  const evicted: number[] = [];
  for (let i = 0; i < trackedIndices.length; i++) {
    const idx: number = trackedIndices[i];
    if (!retainRange.contains(idx)) {
      evicted.push(idx);
    }
  }
  return evicted;
}

export class ReaderPreloadScheduler {
  private readonly fetcher: ReaderImageFetcher;
  private readonly inFlightTokens: Map<number, CancelToken> = new Map<number, CancelToken>();
  private readonly retainedUrls: Map<number, string> = new Map<number, string>();
  private urls: string[] = [];
  private generation: number = 0;

  constructor(fetcher?: ReaderImageFetcher) {
    this.fetcher = fetcher ?? new DefaultCacheImageFetcher();
  }

  /** 绑定新章节图片列表，同时取消上一章所有在途预加载并清空保留集 */
  setChapterUrls(urls: string[]): void {
    this.dispose();
    this.urls = urls.slice();
  }

  /** 页码变化时推进滑动窗口：取消越界请求、淘汰过期引用、按优先级预加载新窗口 */
  onPageChanged(currentIndex: number): PreloadWindowUpdate {
    const total: number = this.urls.length;
    const preloadRange: WindowRange = computePreloadRange(currentIndex, total);
    const retainRange: WindowRange = computeRetainRange(currentIndex, total);
    const ordered: number[] = computePreloadOrder(currentIndex, total);

    const canceledIndices: number[] = [];
    const inFlightKeys: number[] = [];
    this.inFlightTokens.forEach((_token: CancelToken, idx: number): void => {
      inFlightKeys.push(idx);
    });
    for (let i = 0; i < inFlightKeys.length; i++) {
      const idx: number = inFlightKeys[i];
      if (!retainRange.contains(idx)) {
        const token: CancelToken | undefined = this.inFlightTokens.get(idx);
        if (token !== undefined) {
          token.cancel();
        }
        this.inFlightTokens.delete(idx);
        canceledIndices.push(idx);
      }
    }

    const trackedKeys: number[] = [];
    this.retainedUrls.forEach((_url: string, idx: number): void => {
      trackedKeys.push(idx);
    });
    const evictedIndices: number[] = computeEvictedIndices(trackedKeys, retainRange);
    for (let i = 0; i < evictedIndices.length; i++) {
      const idx: number = evictedIndices[i];
      const url: string | undefined = this.retainedUrls.get(idx);
      this.retainedUrls.delete(idx);
      if (url !== undefined && this.fetcher.release !== undefined) {
        this.fetcher.release(url);
      }
    }

    const gen: number = this.generation;
    for (let i = 0; i < ordered.length; i++) {
      const idx: number = ordered[i];
      if (this.retainedUrls.has(idx) || this.inFlightTokens.has(idx)) {
        continue;
      }
      const url: string = this.urls[idx];
      if (url === '') {
        continue;
      }
      const token: CancelToken = new CancelToken();
      this.inFlightTokens.set(idx, token);
      void this.runPreload(gen, idx, url, token);
    }

    return new PreloadWindowUpdate(preloadRange, retainRange, ordered, canceledIndices, evictedIndices);
  }

  private async runPreload(gen: number, index: number, url: string, token: CancelToken): Promise<void> {
    try {
      await this.fetcher.fetch(url, token);
      if (gen === this.generation && !token.isCanceled()) {
        this.retainedUrls.set(index, url);
      }
    } catch (_e) {
      // 预加载失败或取消不阻断当前阅读流，交由可见页 MangaImage 兜底提示与重试
    } finally {
      if (this.inFlightTokens.get(index) === token) {
        this.inFlightTokens.delete(index);
      }
    }
  }

  getInFlightCount(): number {
    return this.inFlightTokens.size;
  }

  getRetainedCount(): number {
    return this.retainedUrls.size;
  }

  /** 切章或退出阅读器时全量取消在途任务并释放保留引用 */
  dispose(): void {
    this.generation++;
    this.inFlightTokens.forEach((token: CancelToken): void => {
      token.cancel();
    });
    this.inFlightTokens.clear();
    if (this.fetcher.release !== undefined) {
      this.retainedUrls.forEach((url: string): void => {
        if (this.fetcher.release !== undefined) {
          this.fetcher.release(url);
        }
      });
    }
    this.retainedUrls.clear();
  }
}
