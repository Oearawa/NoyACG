/**
 * ImagePrefetch.ets —— 有界图片预取工具（Phase 14-O）
 *
 * 只预取当前可见项前后少量图片；实际下载仍走 ImageCacheManager 的
 * 缓存命中 / pending 合并 / 后台异步队列，不阻塞 UI，不提前加载整页。
 */
import { Comic } from '../model/Comic';
import { ThemeDims } from './Theme';
import { ImageCacheManager } from './ImageCacheManager';

/** 纯函数：取 [index-radius, index+radius] 内的非空远程 URL。 */
export function selectPrefetchUrls(
  urls: string[],
  currentIndex: number,
  radius: number
): string[] {
  const result: string[] = [];
  if (urls.length === 0 || currentIndex < 0 || currentIndex >= urls.length || radius < 0) {
    return result;
  }
  const start: number = Math.max(0, currentIndex - radius);
  const end: number = Math.min(urls.length - 1, currentIndex + radius);
  for (let i = start; i <= end; i++) {
    const url: string = urls[i];
    if (url !== '' && !url.startsWith('file://')) {
      result.push(url);
    }
  }
  return result;
}

export function prefetchUrlsAround(urls: string[], index: number, token: string): void {
  const selected: string[] = selectPrefetchUrls(urls, index, ThemeDims.PREFETCH_RADIUS);
  ImageCacheManager.getInstance().prefetch(
    selected,
    token,
    ThemeDims.PREFETCH_MAX_CONCURRENCY
  );
}

export function prefetchComicsAround(comics: Comic[], index: number, token: string): void {
  const urls: string[] = [];
  for (let i = 0; i < comics.length; i++) {
    urls.push(comics[i].cover);
  }
  prefetchUrlsAround(urls, index, token);
}

export function cancelPrefetch(token: string): void {
  ImageCacheManager.getInstance().cancelPrefetch(token);
}
