/**
 * HistoryViewModel.ets —— 阅读历史视图模型与元数据水合器
 *
 * 职责：
 * - 从 HistoryStorePort 读取最近阅读历史（按时间倒序、按漫画 ID 去重）；
 * - 对历史记录缺失作品元数据（title / coverUrl）的旧条目，优先用 ComicMetaCache 补全，
 *   再并发请求 IComicSource.getComicDetail(bid) 水合补齐并回写本地存储；
 * - 支持单条删除（remove）与一键清空（clearAll）。
 */
import { Comic } from '../model/Comic';
import { ComicDetail } from '../model/ComicDetail';
import { IComicSource } from '../source/IComicSource';
import { noyAcgSource } from '../source/NoyAcgSource';
import { DatabaseManager, HistoryRecord } from '../utils/DatabaseManager';
import { ComicMetaCache, HistoryMetadata } from '../utils/ComicMetaCache';
import { Logger } from '../utils/Logger';

const TAG: string = 'HistoryViewModel';

export interface HistoryStorePort {
  getRecentHistories(limit?: number): Promise<HistoryRecord[]>;
  updateHistoryMetadata(comicId: string, meta: HistoryMetadata): Promise<void>;
  removeHistory(comicId: string): Promise<void>;
  clearAllHistories(): Promise<void>;
}

class DefaultHistoryStore implements HistoryStorePort {
  async getRecentHistories(limit?: number): Promise<HistoryRecord[]> {
    return await DatabaseManager.getInstance().getRecentHistories(limit);
  }

  async updateHistoryMetadata(comicId: string, meta: HistoryMetadata): Promise<void> {
    await DatabaseManager.getInstance().updateHistoryMetadata(comicId, meta);
  }

  async removeHistory(comicId: string): Promise<void> {
    await DatabaseManager.getInstance().removeHistory(comicId);
  }

  async clearAllHistories(): Promise<void> {
    await DatabaseManager.getInstance().clearAllHistories();
  }
}

@ObservedV2
export class HistoryViewModel {
  @Trace records: HistoryRecord[] = [];
  @Trace isLoading: boolean = false;
  @Trace errorMessage: string = '';

  private store: HistoryStorePort;
  private source: IComicSource;
  private loadGeneration: number = 0;

  constructor(store?: HistoryStorePort, source?: IComicSource) {
    this.store = store ?? new DefaultHistoryStore();
    this.source = source ?? noyAcgSource;
  }

  /** 将 HistoryRecord 转为官方横向卡片 Comic 数据模型 */
  static toComic(record: HistoryRecord): Comic {
    const title: string = (record.title ?? '') !== '' ? record.title! : `作品 #${record.comicId}`;
    const comic: Comic = new Comic(
      record.comicId,
      title,
      record.coverUrl ?? '',
      record.author ?? '',
      record.tags ?? ''
    );
    comic.isCompleted = record.isCompleted ?? false;
    comic.views = record.views ?? 0;
    comic.favorites = record.favorites ?? 0;
    return comic;
  }

  /** 加载阅读历史并水合补全缺失的作品元数据 */
  async load(limit: number = 100): Promise<void> {
    const gen: number = ++this.loadGeneration;
    this.isLoading = true;
    this.errorMessage = '';
    try {
      const rawList: HistoryRecord[] = await this.store.getRecentHistories(limit);
      if (gen !== this.loadGeneration) {
        return;
      }
      const initial: HistoryRecord[] = [];
      for (let i = 0; i < rawList.length; i++) {
        initial.push(HistoryViewModel.applyCacheIfMissing(rawList[i]));
      }
      this.records = initial;
      this.isLoading = false;

      await this.hydrateMissingRecords(initial, gen);
    } catch (e) {
      if (gen !== this.loadGeneration) {
        return;
      }
      this.errorMessage = `读取阅读历史失败: ${(e as Error).message}`;
      Logger.warn(TAG, this.errorMessage);
    } finally {
      if (gen === this.loadGeneration) {
        this.isLoading = false;
      }
    }
  }

  private static applyCacheIfMissing(record: HistoryRecord): HistoryRecord {
    if ((record.title ?? '') !== '' && (record.coverUrl ?? '') !== '') {
      return record;
    }
    const cached: HistoryMetadata | null = ComicMetaCache.get(record.comicId);
    if (cached === null) {
      return record;
    }
    return HistoryViewModel.mergeMetadata(record, cached);
  }

  private static mergeMetadata(record: HistoryRecord, meta: HistoryMetadata): HistoryRecord {
    return {
      comicId: record.comicId,
      chapterId: record.chapterId,
      chapterTitle: record.chapterTitle,
      pageIndex: record.pageIndex,
      totalPages: record.totalPages,
      updateTime: record.updateTime,
      title: meta.title,
      coverUrl: meta.coverUrl,
      author: meta.author,
      tags: meta.tags,
      isCompleted: meta.isCompleted,
      views: meta.views,
      favorites: meta.favorites
    };
  }

  private async hydrateMissingRecords(list: HistoryRecord[], gen: number): Promise<void> {
    const missingIds: string[] = [];
    for (let i = 0; i < list.length; i++) {
      const r: HistoryRecord = list[i];
      if ((r.title ?? '') === '' || (r.coverUrl ?? '') === '') {
        if (missingIds.indexOf(r.comicId) < 0) {
          missingIds.push(r.comicId);
        }
      }
    }
    if (missingIds.length === 0) {
      return;
    }

    const hydratedMap: Map<string, HistoryMetadata> = new Map<string, HistoryMetadata>();
    const batchSize: number = 4;
    for (let start = 0; start < missingIds.length; start += batchSize) {
      if (gen !== this.loadGeneration) {
        return;
      }
      const slice: string[] = missingIds.slice(start, start + batchSize);
      await Promise.all(slice.map(async (comicId: string): Promise<void> => {
        try {
          const detail: ComicDetail = await this.source.getComicDetail(comicId);
          const meta: HistoryMetadata = ComicMetaCache.putFromDetail(detail);
          hydratedMap.set(comicId, meta);
          await this.store.updateHistoryMetadata(comicId, meta);
        } catch (_e) {
          // 单条详情补全失败静默跳过，不阻断其它记录展示
        }
      }));
    }

    if (gen !== this.loadGeneration || hydratedMap.size === 0) {
      return;
    }
    const nextList: HistoryRecord[] = [];
    for (let i = 0; i < this.records.length; i++) {
      const cur: HistoryRecord = this.records[i];
      const meta: HistoryMetadata | undefined = hydratedMap.get(cur.comicId);
      nextList.push(meta !== undefined ? HistoryViewModel.mergeMetadata(cur, meta) : cur);
    }
    this.records = nextList;
  }

  /** 删除单条历史记录 */
  async remove(comicId: string): Promise<boolean> {
    try {
      await this.store.removeHistory(comicId);
      this.records = this.records.filter((r: HistoryRecord): boolean => r.comicId !== comicId);
      return true;
    } catch (e) {
      Logger.warn(TAG, `删除历史记录失败: ${(e as Error).message}`);
      return false;
    }
  }

  /** 清空全部历史记录 */
  async clearAll(): Promise<boolean> {
    try {
      await this.store.clearAllHistories();
      this.records = [];
      return true;
    } catch (e) {
      Logger.warn(TAG, `清空历史记录失败: ${(e as Error).message}`);
      return false;
    }
  }
}
