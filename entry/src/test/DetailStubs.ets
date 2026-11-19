/**
 * DetailStubs.ets —— Phase 11 测试共用桩（不联网、不碰真实数据库）
 *
 * - StubDetailSource：可编程详情源，支持按 id 配置响应/异常/延迟，用于验证请求代际与去重；
 * - InMemoryReadingStore：`ReadingStorePort` 的内存实现，按真实语义
 *   （复合主键 (comicId, chapterId) UPSERT、按 updateTime 降序）模拟，
 *   用于验证章节进度隔离、幂等与写入失败语义。
 *
 * ⚠ 本地单测的 relationalStore 是桩实现（Phase 8 已确认），
 * 因此这里验证的是**端口契约与 ViewModel 行为**，不代表真实 SQLite 已验证；
 * 真实表结构/迁移另有静态断言（ReadingStore.test.ets）。
 */
import { Comic } from '../main/ets/model/Comic';
import { ComicDetail } from '../main/ets/model/ComicDetail';
import { PageInfo } from '../main/ets/model/PageInfo';
import { HomeFeed } from '../main/ets/model/HomeFeed';
import { AdItem } from '../main/ets/model/AdItem';
import { CommentPage } from '../main/ets/model/BookComment';
import { IComicSource } from '../main/ets/source/IComicSource';
import { AccountFavoritePort } from '../main/ets/source/AccountFavoritePort';
import { FavoriteClass } from '../main/ets/model/FavoriteClass';
import { HttpError } from '../main/ets/api/HttpManager';
import { HistoryRecord, ReadingStorePort } from '../main/ets/utils/DatabaseManager';

/** 异步延时（用于制造「旧请求晚到」） */
export function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/** 可编程详情源桩 */
export class StubDetailSource implements IComicSource {
  readonly sourceId: string = 'stub-detail';
  readonly sourceName: string = 'StubDetail';
  readonly baseUrl: string = 'https://stub.local';

  /** 默认预设详情（null 表示用 error） */
  detail: ComicDetail | null = null;
  /** 按 id 覆盖详情（验证旧响应不会覆盖新结果） */
  detailById: Record<string, ComicDetail> = {};
  /** 非空则抛出该异常（全部异常都是 HttpError 子类，规避 ArkTS 结构类型限制） */
  error: HttpError | null = null;
  /** 默认请求延时（毫秒） */
  delayMs: number = 0;
  /** 按 id 覆盖延时（用于制造「旧请求晚到」） */
  delayById: Record<string, number> = {};
  /** getComicDetail 调用记录 */
  calls: string[] = [];

  async getComicDetail(id: string): Promise<ComicDetail> {
    this.calls.push(id);
    const perId: number | undefined = this.delayById[id];
    const wait: number = perId === undefined ? this.delayMs : perId;
    if (wait > 0) {
      await delay(wait);
    }
    if (this.error !== null) {
      throw this.error;
    }
    const byId: ComicDetail | undefined = this.detailById[id];
    if (byId !== undefined) {
      return byId;
    }
    if (this.detail === null) {
      throw new HttpError(-1, '桩未配置详情响应');
    }
    return this.detail;
  }

  async getHomeList(page: number, sort?: string, finished?: string): Promise<PageInfo<Comic>> {
    return new PageInfo<Comic>(page, 1, [], false);
  }

  async search(keyword: string, page: number): Promise<PageInfo<Comic>> {
    return new PageInfo<Comic>(page, 1, [], false);
  }

  async getChapterImages(bookId: string, chapterId: string): Promise<string[]> {
    return [];
  }

  async getHomeFeed(adultLevel?: string): Promise<HomeFeed> {
    return new HomeFeed();
  }

  async getAds(adultLevel?: string): Promise<AdItem[]> {
    return [];
  }

  async getBookComments(bookId: string, page: number): Promise<CommentPage> {
    return new CommentPage([], page, true);
  }
}

/** 可编程阅读图片源桩（阅读器衔接测试用） */
export class StubReaderImageSource implements IComicSource {
  readonly sourceId: string = 'stub-reader-images';
  readonly sourceName: string = 'StubReaderImages';
  readonly baseUrl: string = 'https://stub.local';
  images: string[] = [];
  error: HttpError | null = null;
  calls: string[] = [];
  lastBookId: string = '';
  lastChapterId: string = '';

  async getChapterImages(bookId: string, chapterId: string): Promise<string[]> {
    this.calls.push(`${bookId}/${chapterId}`);
    this.lastBookId = bookId;
    this.lastChapterId = chapterId;
    if (this.error !== null) {
      throw this.error;
    }
    return this.images;
  }

  async getHomeList(page: number, sort?: string, finished?: string): Promise<PageInfo<Comic>> {
    return new PageInfo<Comic>(page, 1, [], false);
  }

  async search(keyword: string, page: number): Promise<PageInfo<Comic>> {
    return new PageInfo<Comic>(page, 1, [], false);
  }

  async getComicDetail(id: string): Promise<ComicDetail> {
    return new ComicDetail();
  }

  async getHomeFeed(adultLevel?: string): Promise<HomeFeed> {
    return new HomeFeed();
  }

  async getAds(adultLevel?: string): Promise<AdItem[]> {
    return [];
  }

  async getBookComments(bookId: string, page: number): Promise<CommentPage> {
    return new CommentPage([], page, true);
  }
}

/** 内存版 ReadingStorePort：复刻复合主键 UPSERT 与按时间降序语义 */
export class InMemoryReadingStore implements ReadingStorePort {
  /** 已存记录（key = `${comicId}/${chapterId}`） */
  private readonly records: Map<string, HistoryRecord> = new Map<string, HistoryRecord>();
  favorite: boolean = false;
  /** 让 saveHistory 抛错，验证「写失败不谎报成功」 */
  failOnSave: boolean = false;
  /** 让本地读取抛错，验证「本地失败不影响详情展示」 */
  failOnRead: boolean = false;
  /** 让 toggleFavorite 抛错，验证回滚 */
  failOnFavorite: boolean = false;
  /** saveHistory 调用次数 */
  saveCalls: number = 0;

  private static key(comicId: string, chapterId: string): string {
    return `${comicId}/${chapterId}`;
  }

  async isFavorite(comicId: string): Promise<boolean> {
    if (this.failOnRead) {
      throw new Error('模拟收藏读取失败');
    }
    return this.favorite;
  }

  async toggleFavorite(comicId: string, title: string, coverUrl: string): Promise<boolean> {
    if (this.failOnFavorite) {
      throw new Error('模拟收藏写入失败');
    }
    this.favorite = !this.favorite;
    return this.favorite;
  }

  async saveHistory(record: HistoryRecord): Promise<void> {
    this.saveCalls++;
    if (this.failOnSave) {
      throw new Error('模拟数据库写入失败');
    }
    if (record.comicId === '' || record.chapterId === '') {
      throw new Error('保存阅读进度需要 comicId 与 chapterId');
    }
    this.records.set(InMemoryReadingStore.key(record.comicId, record.chapterId), {
      comicId: record.comicId,
      chapterId: record.chapterId,
      chapterTitle: record.chapterTitle,
      pageIndex: Math.max(record.pageIndex, 1),
      totalPages: record.totalPages ?? 0,
      updateTime: record.updateTime
    });
  }

  async getHistoryForChapter(comicId: string, chapterId: string): Promise<HistoryRecord | null> {
    if (this.failOnRead) {
      throw new Error('模拟历史读取失败');
    }
    const found: HistoryRecord | undefined =
      this.records.get(InMemoryReadingStore.key(comicId, chapterId));
    return found === undefined ? null : found;
  }

  async getHistories(comicId: string): Promise<HistoryRecord[]> {
    if (this.failOnRead) {
      throw new Error('模拟历史读取失败');
    }
    const result: HistoryRecord[] = [];
    this.records.forEach((value: HistoryRecord, key: string): void => {
      if (value.comicId === comicId) {
        result.push(value);
      }
    });
    result.sort((a: HistoryRecord, b: HistoryRecord): number => b.updateTime - a.updateTime);
    return result;
  }

  async getHistory(comicId: string): Promise<HistoryRecord | null> {
    const all: HistoryRecord[] = await this.getHistories(comicId);
    return all.length > 0 ? all[0] : null;
  }

  /** 测试辅助：直接塞入一条历史（绕过 saveHistory 的失败开关） */
  seed(record: HistoryRecord): void {
    this.records.set(InMemoryReadingStore.key(record.comicId, record.chapterId), record);
  }

  /** 测试辅助：当前记录条数 */
  size(): number {
    return this.records.size;
  }
}

/**
 * 账号收藏端口桩（I-000002）：可编程 toggle 结果与 /get 收藏列表。
 * - favoriteIds：/get 命中的书籍 id（服务端「已收藏」依据）；
 * - toggleError：toggle 写抛错（验证失败回滚）；
 * - getError：/get 校准抛错（验证「重取失败回滚到操作前」）；
 * - toggleDelayMs：toggle 在途时长（验证重复点击防抖）。
 */
export class StubAccountFavPort implements AccountFavoritePort {
  favoriteIds: string[] = [];
  toggleError: HttpError | null = null;
  getError: HttpError | null = null;
  toggleDelayMs: number = 0;
  toggleCalls: string[] = [];
  getCalls: number = 0;

  async fetchAccountFavorites(page: number, classId: string): Promise<PageInfo<Comic>> {
    this.getCalls++;
    if (this.getError !== null) {
      throw this.getError;
    }
    const list: Comic[] = [];
    for (let i = 0; i < this.favoriteIds.length; i++) {
      list.push(new Comic(this.favoriteIds[i], `收藏 ${this.favoriteIds[i]}`, ''));
    }
    return new PageInfo<Comic>(page, 1, list, false);
  }

  async fetchFavoriteClasses(): Promise<FavoriteClass[]> {
    return [];
  }

  async toggleFavorite(bid: string): Promise<void> {
    this.toggleCalls.push(bid);
    if (this.toggleError !== null) {
      throw this.toggleError;
    }
    if (this.toggleDelayMs > 0) {
      await delay(this.toggleDelayMs);
    }
  }
}
