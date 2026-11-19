/**
 * ComicMetaCache.ets —— 漫画基础元数据内存缓存
 *
 * 用于在详情页加载成功、阅读器写入进度、以及历史记录水合补全之间共享作品元数据，
 * 确保即使阅读进度记录发生在详情缓存之后，也能立即携带完整标题/封面/作者/标签落盘。
 */
import { ComicDetail } from '../model/ComicDetail';

export interface HistoryMetadata {
  title: string;
  coverUrl: string;
  author: string;
  tags: string;
  isCompleted: boolean;
  views: number;
  favorites: number;
}

export class ComicMetaCache {
  private static cache: Map<string, HistoryMetadata> = new Map<string, HistoryMetadata>();

  static put(comicId: string, meta: HistoryMetadata): void {
    const id: string = comicId.trim();
    if (id === '' || meta.title === '') {
      return;
    }
    ComicMetaCache.cache.set(id, meta);
  }

  static putFromDetail(detail: ComicDetail): HistoryMetadata {
    const meta: HistoryMetadata = {
      title: detail.title,
      coverUrl: detail.cover,
      author: detail.author,
      tags: detail.tags.join(' '),
      isCompleted: detail.isCompleted === true,
      views: detail.views,
      favorites: detail.favorites
    };
    ComicMetaCache.put(detail.id, meta);
    return meta;
  }

  static get(comicId: string): HistoryMetadata | null {
    const id: string = comicId.trim();
    if (id === '') {
      return null;
    }
    return ComicMetaCache.cache.get(id) ?? null;
  }

  static clear(): void {
    ComicMetaCache.cache.clear();
  }
}
