/**
 * ShelfViewModel.ets —— 收藏页视图模型（Phase 14-J2：账号收藏 + 本地收藏分离）
 *
 * 两套数据源严格区分、互不写入：
 *   - 账号收藏：AccountFavoriteRepository → POST /api/v4/favorites/get（只读，需登录）
 *   - 本地收藏：DatabaseManager.Favorite（设备本地，离线可用）
 *
 * 登录用户默认「账号收藏」，游客默认「本地收藏」；不自动双向同步、不修改远端状态。
 * 本 VM 实例由 Index 持有并注入 ShelfComponent。
 */
import { Comic } from '../model/Comic';
import { BasicDataSource } from '../utils/BasicDataSource';
import { DatabaseManager, FavoriteRecord } from '../utils/DatabaseManager';
import { AccountFavoriteRepository } from '../api/AccountFavoriteRepository';
import { FAVORITE_CLASS_ALL } from '../source/NoyAcgProtocol';
import { AuthRequiredError } from '../api/ApiErrors';
import { HttpError } from '../api/HttpManager';
import { AuthManager } from '../utils/AuthManager';
import { PageInfo } from '../model/PageInfo';
import { Logger } from '../utils/Logger';
import { comicDisplayFingerprint } from '../utils/StableLayout';
import { RatingSyncState } from '../utils/RatingSync';

const TAG: string = 'ShelfViewModel';

/** 收藏数据源：账号收藏 */
export const SHELF_SOURCE_ACCOUNT: string = 'account';
/** 收藏数据源：本地收藏 */
export const SHELF_SOURCE_LOCAL: string = 'local';

@ObservedV2
export class ShelfViewModel {
  /** 当前展示的数据源（account / local） */
  @Trace activeSource: string = SHELF_SOURCE_LOCAL;

  // ==================== 本地收藏 ====================
  /** 本地收藏列表（原始数组，驱动空态/计数） */
  @Trace favoriteList: Comic[] = [];
  /** 本地收藏加载中 */
  @Trace isLoading: boolean = false;
  /** 本地收藏懒加载数据源 */
  readonly shelfDataSource: BasicDataSource<Comic> = new BasicDataSource<Comic>();
  private requesting: boolean = false;

  // ==================== 账号收藏 ====================
  /** 账号收藏列表（按 Bid 去重，保留服务端顺序） */
  @Trace accountList: Comic[] = [];
  /** 账号收藏加载中 */
  @Trace accountLoading: boolean = false;
  /** 账号收藏错误信息 */
  @Trace accountError: string = '';
  /** 未登录/会话失效 */
  @Trace accountNeedsLogin: boolean = false;
  /** 已加载页码（0 = 未加载） */
  @Trace accountPage: number = 0;
  /** 是否还有下一页 */
  @Trace accountHasMore: boolean = false;
  /** 服务端账号收藏总条数（-1 = 未知，R1 数量校准） */
  @Trace accountTotalCount: number = -1;
  /** 是否已成功加载过（用于避免重复首屏请求） */
  @Trace accountLoaded: boolean = false;
  /** 账号收藏懒加载数据源 */
  readonly accountDataSource: BasicDataSource<Comic> = new BasicDataSource<Comic>();

  private accountRepo: AccountFavoriteRepository;
  private accountRequesting: boolean = false;
  /** 代际：刷新/切换账号时作废旧请求 */
  private accountGeneration: number = 0;
  /** 内容分级变更判据（Phase 14-S）：只刷新当前数据源，不动本地收藏/下载 */
  private ratingSync: RatingSyncState = new RatingSyncState();

  /** 可注入账号收藏仓储（单元测试用；默认走生产只读接口） */
  constructor(repo?: AccountFavoriteRepository) {
    this.accountRepo = repo ?? new AccountFavoriteRepository();
  }

  /** 组件进入时初始化默认数据源（登录→账号，游客→本地） */
  initDefaultSource(): void {
    this.refreshActive(false);
  }

  /** 切回收藏 Tab 时刷新（force=true 表示强制重拉账号收藏） */
  onTabSelected(): void {
    this.refreshActive(true);
  }

  private refreshActive(force: boolean): void {
    if (AuthManager.getInstance().isAuthenticated) {
      this.activeSource = SHELF_SOURCE_ACCOUNT;
      if (force || !this.accountLoaded) {
        this.loadAccount(true);
      }
    } else {
      this.activeSource = SHELF_SOURCE_LOCAL;
      this.loadFavorites();
    }
  }

  /** 切换数据源（用户手动点分段选择器） */
  setActiveSource(source: string): void {
    if (this.activeSource === source) {
      return;
    }
    this.activeSource = source;
    if (source === SHELF_SOURCE_ACCOUNT) {
      if (!this.accountLoaded && !this.accountLoading) {
        this.loadAccount(true);
      }
    } else {
      this.loadFavorites();
    }
  }

  // ==================== 本地收藏加载 ====================

  /** 从数据库加载本地收藏（毫秒级，不阻塞 UI） */
  async loadFavorites(): Promise<void> {
    if (this.requesting) {
      return;
    }
    this.requesting = true;
    this.isLoading = true;
    try {
      const records: FavoriteRecord[] = await DatabaseManager.getInstance().getAllFavorites();
      const list: Comic[] = records.map((record: FavoriteRecord): Comic =>
        new Comic(record.comicId, record.title, record.coverUrl, '', '', '', ''));
      this.favoriteList = list;
      this.shelfDataSource.setDataStable(list, (comic: Comic): string => comic.id, comicDisplayFingerprint);
      Logger.info(TAG, `本地收藏加载完成, 共${list.length}部`);
    } catch (e) {
      Logger.error(TAG, `本地收藏加载失败: ${(e as Error).message}`);
    } finally {
      this.requesting = false;
      this.isLoading = false;
    }
  }

  // ==================== 账号收藏加载 ====================

  /**
   * 加载账号收藏。
   * @param refresh true = 从第 1 页重载（替换）；false = 追加下一页
   */
  async loadAccount(refresh: boolean): Promise<void> {
    if (this.accountRequesting) {
      return;
    }
    if (!refresh && (!this.accountHasMore || !this.accountLoaded)) {
      return;
    }
    const nextPage: number = refresh ? 1 : this.accountPage + 1;
    const gen: number = refresh ? ++this.accountGeneration : this.accountGeneration;
    this.accountRequesting = true;
    this.accountLoading = true;
    this.accountError = '';
    this.accountNeedsLogin = false;
    try {
      const result: PageInfo<Comic> = await this.accountRepo.fetchPage(nextPage, FAVORITE_CLASS_ALL);
      if (gen !== this.accountGeneration) {
        return; // 代际已变，丢弃旧响应
      }
      const base: Comic[] = refresh ? [] : this.accountList;
      const merged: Comic[] = ShelfViewModel.appendDeduped(base, result.list);
      this.accountList = merged;
      this.accountDataSource.setDataStable(merged, (comic: Comic): string => comic.id, comicDisplayFingerprint);
      this.accountPage = result.page;
      if (result.totalCount >= 0) {
        this.accountTotalCount = Math.max(result.totalCount, merged.length);
      } else if (refresh) {
        this.accountTotalCount = -1;
      }
      this.accountHasMore = result.hasMore &&
        (this.accountTotalCount < 0 || merged.length < this.accountTotalCount);
      this.accountLoaded = true;
      Logger.info(TAG, `账号收藏第${result.page}页完成, 累计${merged.length}/${this.accountTotalCount}部, hasMore=${this.accountHasMore}`);
    } catch (e) {
      if (gen !== this.accountGeneration) {
        return;
      }
      if (e instanceof AuthRequiredError) {
        this.accountNeedsLogin = true;
        this.accountError = '登录后可查看账号收藏';
        this.accountList = [];
        this.accountDataSource.setDataStable([], (comic: Comic): string => comic.id, comicDisplayFingerprint);
        this.accountLoaded = false;
      } else {
        this.accountError = e instanceof HttpError ? e.message : '账号收藏加载失败，请稍后重试';
        Logger.warn(TAG, `账号收藏加载失败: ${(e as Error).message}`);
      }
    } finally {
      if (gen === this.accountGeneration) {
        this.accountRequesting = false;
        this.accountLoading = false;
      }
    }
  }

  /** 触底加载下一页账号收藏 */
  async loadMoreAccount(): Promise<void> {
    await this.loadAccount(false);
  }

  /** 下拉刷新当前数据源 */
  /** 分级已变化则刷新当前数据源（Phase 14-S） */
  /**
   * 分级变化广播的即时入口（Phase 14-T）：
   * 只刷新「当前数据源」，不触碰本地收藏、下载与阅读历史。
   */
  refreshForRating(): void {
    this.ratingSync.markCurrent();
    this.refreshActiveSource();
  }

  reloadIfRatingChanged(): boolean {
    if (!this.ratingSync.takeChange()) {
      return false;
    }
    this.refreshActiveSource();
    return true;
  }

  async refreshActiveSource(): Promise<void> {
    if (this.activeSource === SHELF_SOURCE_ACCOUNT) {
      await this.loadAccount(true);
    } else {
      await this.loadFavorites();
    }
  }

  /** 当前数据源列表（UI 统一读取） */
  currentList(): Comic[] {
    return this.activeSource === SHELF_SOURCE_ACCOUNT ? this.accountList : this.favoriteList;
  }

  /** R1 校准后的账号收藏展示总数（优先服务端 totalCount，未知时退回已加载去重数） */
  accountDisplayCount(): number {
    if (this.accountTotalCount >= 0) {
      return Math.max(this.accountTotalCount, this.accountList.length);
    }
    return this.accountList.length;
  }

  /** R1：详情页切换收藏后同步校准本地缓存的账号收藏列表与总数 */
  reconcileFavoriteChange(comic: Comic, isFavorited: boolean): void {
    if (comic.id === '') {
      return;
    }
    const existingIdx: number = this.accountList.findIndex((c: Comic): boolean => c.id === comic.id);
    if (isFavorited) {
      if (existingIdx < 0) {
        const next: Comic[] = [comic].concat(this.accountList);
        this.accountList = next;
        this.accountDataSource.setDataStable(next, (c: Comic): string => c.id, comicDisplayFingerprint);
        if (this.accountTotalCount >= 0) {
          this.accountTotalCount = Math.max(this.accountTotalCount + 1, next.length);
        }
      }
    } else if (existingIdx >= 0) {
      const next: Comic[] = this.accountList.filter((c: Comic): boolean => c.id !== comic.id);
      this.accountList = next;
      this.accountDataSource.setDataStable(next, (c: Comic): string => c.id, comicDisplayFingerprint);
      if (this.accountTotalCount > 0) {
        this.accountTotalCount = Math.max(next.length, this.accountTotalCount - 1);
      }
    }
  }

  /** 当前数据源是否加载中 */
  currentLoading(): boolean {
    return this.activeSource === SHELF_SOURCE_ACCOUNT ? this.accountLoading : this.isLoading;
  }

  /** 按 Bid 去重追加（保留 base 顺序 + 新条目按服务端顺序；空 id 跳过） */
  private static appendDeduped(base: Comic[], incoming: Comic[]): Comic[] {
    const result: Comic[] = base.slice();
    const seen: string[] = [];
    for (let i = 0; i < result.length; i++) {
      seen.push(result[i].id);
    }
    for (let i = 0; i < incoming.length; i++) {
      const comic: Comic = incoming[i];
      if (comic.id === '' || seen.indexOf(comic.id) >= 0) {
        continue;
      }
      seen.push(comic.id);
      result.push(comic);
    }
    return result;
  }
}
