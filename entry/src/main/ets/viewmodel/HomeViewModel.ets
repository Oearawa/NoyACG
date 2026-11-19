/**
 * HomeViewModel.ets —— 首页视图模型（MVVM 之 VM 层）
 *
 * 职责：承接首页全部分区数据请求（readDay / favDay / collection / quality / latest）
 * 与「下拉刷新 / 触底加载更多 / 年龄分级同步」统一状态机。
 *
 * 状态设计说明：
 * - 各分区均通过独立的 `BasicDataSource<Comic>` + `reloadData()` 主动派发 `onDataReloaded()`，
 *   配合独立 `@ComponentV2` 子组件 + `LazyForEach` 彻底消除 `@Builder` 值传递盲区；
 * - 所有全量重载统一收敛至 `reloadAllSections(loadMode, includeHome)`，使用 `requestGeneration`
 *   防并发乱序覆盖，全部成功后才原子提交 `committedRatingRevision`。
 */
import { Comic } from '../model/Comic';
import { PageInfo } from '../model/PageInfo';
import { HomeFeed } from '../model/HomeFeed';
import { BasicDataSource } from '../utils/BasicDataSource';
import { IComicSource } from '../source/IComicSource';
import { noyAcgSource } from '../source/NoyAcgSource';
import { BOOKLIST_SORT_NEW, BOOKLIST_FINISHED_ALL } from '../source/NoyAcgProtocol';
import { HttpError } from '../api/HttpManager';
import { AuthRequiredError } from '../api/ApiErrors';
import { Logger } from '../utils/Logger';
import { filterComics } from '../api/ContentFilter';
import { ContentRatingPolicy } from '../utils/ContentRatingPolicy';
import { RatingSyncState } from '../utils/RatingSync';

const TAG: string = 'HomeViewModel';

/** 首页全量加载模式：仅 PULL_TO_REFRESH 触发顶部 Refresh 动画 */
export type HomeLoadMode = 'INITIAL' | 'SILENT_SYNC' | 'PULL_TO_REFRESH';

@ObservedV2
export class HomeViewModel {
  /** 最新推荐书单懒加载数据源（直接绑定 LazyForEach；readonly 保证实例引用稳定） */
  readonly comicDataSource: BasicDataSource<Comic> = new BasicDataSource<Comic>();
  /** 今日阅读榜分区数据源 */
  readonly readDaySource: BasicDataSource<Comic> = new BasicDataSource<Comic>();
  /** 今日收藏榜分区数据源 */
  readonly favDaySource: BasicDataSource<Comic> = new BasicDataSource<Comic>();
  /** 收藏推荐（fs）分区数据源 */
  readonly collectionSource: BasicDataSource<Comic> = new BasicDataSource<Comic>();
  /** 高质量推荐（proportion）分区数据源 */
  readonly qualitySource: BasicDataSource<Comic> = new BasicDataSource<Comic>();

  /** 最新推荐数据源别名 */
  get latestSource(): BasicDataSource<Comic> {
    return this.comicDataSource;
  }

  /** 各榜单当前条数（驱动外层显隐） */
  @Trace readDayCount: number = 0;
  @Trace favDayCount: number = 0;
  @Trace collectionCount: number = 0;
  @Trace qualityCount: number = 0;

  /** 触底加载更多中（控制 WaterFlow 底部 Loading 条） */
  @Trace isLoading: boolean = false;
  /** 首屏冷加载中（列表仍为空时的自动/首次加载，不触发 Refresh 下拉圈） */
  @Trace isInitialLoading: boolean = false;
  /** 仅用户显式下拉刷新时为 true（通过 !! 双向绑定 Refresh 组件） */
  @Trace isManualRefreshing: boolean = false;
  /** 分页重置加载中（兼容内部状态/既有调用方，不再直接绑定 Refresh 组件） */
  @Trace isRefreshing: boolean = false;
  /** 已加载到的页码（0 表示尚未加载过任何数据） */
  @Trace currentPage: number = 0;
  /** 是否还有下一页（为 false 时 onReachEnd 不再发起请求） */
  @Trace hasMore: boolean = true;
  /** 列表当前是否为空（驱动「错误重试 / 空态」与瀑布流的切换） */
  @Trace isEmpty: boolean = true;
  /** 最近一次错误信息（空串表示无错误） */
  @Trace errorMessage: string = '';
  /** 失败是否由「未登录 / 会话失效」引起 */
  @Trace needsLogin: boolean = false;
  /** 排序：new/views/favorites/rating，默认最新 */
  @Trace sort: string = BOOKLIST_SORT_NEW;
  /** 完结筛选：''/true/false，默认全部 */
  @Trace finished: string = BOOKLIST_FINISHED_ALL;

  /** 首页聚合数据（null = 尚未加载成功） */
  @Trace homeFeed: HomeFeed | null = null;
  /** 首页聚合数据版本号（每次成功替换 homeFeed 自增） */
  @Trace homeFeedRevision: number = 0;
  /** 首页聚合是否加载中 */
  @Trace homeLoading: boolean = false;
  /** 首页聚合最近一次错误信息（空串 = 无错误） */
  @Trace homeError: string = '';
  /** 首页聚合失败是否由「未登录/会话失效」引起 */
  @Trace homeNeedsLogin: boolean = false;
  /** 已原子提交的内容分级版本号（仅当对应请求的全部目标分区成功后更新） */
  @Trace committedRatingRevision: number = 0;

  /** 请求防重入锁 */
  private requesting: boolean = false;
  /** 本实例是否请求过聚合首页（区分「首页」与「最新页」两种用法） */
  private homeRequested: boolean = false;
  /** 漫画源 */
  private source: IComicSource;
  /** 统一请求代际序号（防并发乱序覆盖） */
  private requestGeneration: number = 0;
  private listGeneration: number = 0;
  private homeGeneration: number = 0;
  /** 正在同步中的目标分级版本号（防止同修订号在途期间重复触发） */
  private inFlightTargetRevision: number = -1;
  /** 轻量分级判据（用于与 RatingSync 语义对齐） */
  private ratingSync: RatingSyncState = new RatingSyncState();

  constructor(source?: IComicSource) {
    this.source = source ?? noyAcgSource;
    this.committedRatingRevision = this.ratingSync.currentSeenRevision();
  }

  /** 当前列表已应用的内容分级版本号 */
  get appliedRatingRevision(): number {
    return this.committedRatingRevision;
  }

  /** 组件销毁时释放列表数据 */
  dispose(): void {
    this.comicDataSource.clear();
  }

  /**
   * 原子化全量重载协调器：统一收口首次冷加载、年龄限制静默同步与手动下拉刷新。
   * - 仅 `'PULL_TO_REFRESH'` 驱动 `isManualRefreshing = true`；
   * - 使用单调 `requestGeneration` 丢弃过期乱序响应；
   * - 全部目标请求成功后才提交 `committedRatingRevision`，失败则保留旧版本以便下次重试。
   */
  async reloadAllSections(loadMode: HomeLoadMode = 'SILENT_SYNC',
    includeHome: boolean = true): Promise<boolean> {
    const targetRevision: number = ContentRatingPolicy.getInstance().revisionNow();
    const gen: number = ++this.requestGeneration;
    this.listGeneration = gen;
    this.homeGeneration = gen;
    this.inFlightTargetRevision = targetRevision;

    this.isRefreshing = true;
    this.isManualRefreshing = loadMode === 'PULL_TO_REFRESH';
    this.isInitialLoading = loadMode === 'INITIAL' && this.isEmpty;
    this.isLoading = false;
    this.requesting = true;
    this.errorMessage = '';
    this.needsLogin = false;

    if (includeHome) {
      this.homeRequested = true;
      this.homeLoading = true;
      this.homeError = '';
      this.homeNeedsLogin = false;
    }

    let latestOk: boolean = false;
    let homeOk: boolean = !includeHome;

    const latestTask: Promise<void> = (async (): Promise<void> => {
      try {
        const result: PageInfo<Comic> = await this.source.getHomeList(1, this.sort, this.finished);
        if (gen !== this.requestGeneration) {
          return;
        }
        const visible: Comic[] = filterComics(result.list);
        this.comicDataSource.reloadData(visible);
        this.currentPage = result.page;
        this.hasMore = result.hasMore;
        this.isEmpty = this.comicDataSource.isEmpty();
        latestOk = true;
        Logger.info(TAG, `(重载:${loadMode}) 第${result.page}页成功, 本页${visible.length}/${result.list.length}条`);
      } catch (e) {
        if (gen !== this.requestGeneration) {
          return;
        }
        const message: string = e instanceof HttpError ? e.message : '未知错误，请稍后重试';
        this.errorMessage = message;
        this.needsLogin = e instanceof AuthRequiredError;
        Logger.error(TAG, `书单重载失败(needsLogin=${this.needsLogin}): ${message}`);
      }
    })();

    const homeTask: Promise<void> = includeHome
      ? (async (): Promise<void> => {
        try {
          const feed: HomeFeed = await this.source.getHomeFeed();
          if (gen !== this.requestGeneration) {
            return;
          }
          const nextFeed: HomeFeed = new HomeFeed();
          nextFeed.bulletin = feed.bulletin;
          nextFeed.readDay = filterComics(feed.readDay);
          nextFeed.favDay = filterComics(feed.favDay);
          nextFeed.fs = filterComics(feed.fs);
          nextFeed.proportion = filterComics(feed.proportion);
          nextFeed.stream = feed.stream;
          nextFeed.tags = feed.tags.slice();

          this.readDaySource.reloadData(nextFeed.readDay);
          this.favDaySource.reloadData(nextFeed.favDay);
          this.collectionSource.reloadData(nextFeed.fs);
          this.qualitySource.reloadData(nextFeed.proportion);
          this.readDayCount = nextFeed.readDay.length;
          this.favDayCount = nextFeed.favDay.length;
          this.collectionCount = nextFeed.fs.length;
          this.qualityCount = nextFeed.proportion.length;
          this.homeFeed = nextFeed;
          this.homeFeedRevision++;
          homeOk = true;
          Logger.info(TAG, `首页聚合成功: readDay=${nextFeed.readDay.length} favDay=${nextFeed.favDay.length} ` +
            `fs=${nextFeed.fs.length} proportion=${nextFeed.proportion.length} tags=${nextFeed.tags.length}`);
        } catch (e) {
          if (gen !== this.requestGeneration) {
            return;
          }
          const message: string = e instanceof HttpError ? e.message : '未知错误，请稍后重试';
          this.homeError = message;
          this.homeNeedsLogin = e instanceof AuthRequiredError;
          Logger.warn(TAG, `首页聚合失败(needsLogin=${this.homeNeedsLogin}): ${message}`);
        }
      })()
      : Promise.resolve();

    try {
      await Promise.all([latestTask, homeTask]);
      if (gen !== this.requestGeneration) {
        return false;
      }
      const allOk: boolean = latestOk && homeOk;
      if (allOk) {
        this.committedRatingRevision = targetRevision;
        this.ratingSync.rollback(targetRevision);
      }
      return allOk;
    } finally {
      if (gen === this.requestGeneration) {
        this.requesting = false;
        this.isRefreshing = false;
        this.isManualRefreshing = false;
        this.isInitialLoading = false;
        this.isLoading = false;
        if (includeHome) {
          this.homeLoading = false;
        }
        this.inFlightTargetRevision = -1;
      }
    }
  }

  /** 内容分级切换后主动静默刷新 */
  reloadForRating(includeHome: boolean = this.homeRequested): void {
    this.reloadAllSections('SILENT_SYNC', includeHome);
  }

  /** 分级变化广播即时入口 */
  refreshForRating(includeHome: boolean = this.homeRequested): void {
    this.reloadForRating(includeHome);
  }

  /**
   * 分级已变化则静默重载：
   * - 对比 `committedRatingRevision` 与全局 `ContentRatingPolicy.revisionNow()`；
   * - 若同一目标版本已在途则不重复发起；失败后不提交版本，下次返回自动重试。
   */
  reloadIfRatingChanged(includeHome: boolean = this.homeRequested): boolean {
    const current: number = ContentRatingPolicy.getInstance().revisionNow();
    if (this.committedRatingRevision === current) {
      return false;
    }
    if (this.inFlightTargetRevision === current) {
      return false;
    }
    this.reloadAllSections('SILENT_SYNC', includeHome);
    return true;
  }

  /** 首次进入触发：仅在从未加载过时拉取第一页 */
  initLoad(): void {
    if (this.reloadIfRatingChanged(this.homeRequested)) {
      return;
    }
    if (this.currentPage === 0 || this.comicDataSource.isEmpty()) {
      this.loadData(true);
    }
  }

  /** 分段页切入栏位时按需加载：若尚未加载或筛选条件变化则加载第 1 页 */
  ensureLatestTabLoaded(sort: string, finished: string): boolean {
    if (this.sort !== sort || this.finished !== finished) {
      this.sort = sort;
      this.finished = finished;
      this.loadData(true);
      return true;
    }
    if (this.currentPage === 0 && !this.requesting) {
      this.loadData(true);
      return true;
    }
    return false;
  }

  /** 单独加载首页聚合数据 */
  async loadHome(force: boolean = false): Promise<void> {
    if (this.homeLoading && !force) {
      return;
    }
    this.homeRequested = true;
    this.homeLoading = true;
    this.homeError = '';
    this.homeNeedsLogin = false;
    const gen: number = ++this.homeGeneration;
    try {
      const feed: HomeFeed = await this.source.getHomeFeed();
      if (gen !== this.homeGeneration) {
        return;
      }
      const nextFeed: HomeFeed = new HomeFeed();
      nextFeed.bulletin = feed.bulletin;
      nextFeed.readDay = filterComics(feed.readDay);
      nextFeed.favDay = filterComics(feed.favDay);
      nextFeed.fs = filterComics(feed.fs);
      nextFeed.proportion = filterComics(feed.proportion);
      nextFeed.stream = feed.stream;
      nextFeed.tags = feed.tags.slice();

      this.readDaySource.reloadData(nextFeed.readDay);
      this.favDaySource.reloadData(nextFeed.favDay);
      this.collectionSource.reloadData(nextFeed.fs);
      this.qualitySource.reloadData(nextFeed.proportion);
      this.readDayCount = nextFeed.readDay.length;
      this.favDayCount = nextFeed.favDay.length;
      this.collectionCount = nextFeed.fs.length;
      this.qualityCount = nextFeed.proportion.length;
      this.homeFeed = nextFeed;
      this.homeFeedRevision++;
      Logger.info(TAG, `首页聚合成功: readDay=${nextFeed.readDay.length} favDay=${nextFeed.favDay.length} ` +
        `fs=${nextFeed.fs.length} proportion=${nextFeed.proportion.length} tags=${nextFeed.tags.length}`);
    } catch (e) {
      if (gen !== this.homeGeneration) {
        return;
      }
      const message: string = e instanceof HttpError ? e.message : '未知错误，请稍后重试';
      this.homeError = message;
      this.homeNeedsLogin = e instanceof AuthRequiredError;
      Logger.warn(TAG, `首页聚合失败(needsLogin=${this.homeNeedsLogin}): ${message}`);
    } finally {
      if (gen === this.homeGeneration) {
        this.homeLoading = false;
      }
    }
  }

  /** 切换排序：更新状态并从第 1 页重载 */
  setSort(sort: string): void {
    if (sort === this.sort) {
      return;
    }
    this.sort = sort;
    this.loadData(true);
  }

  /** 切换完结筛选：更新状态并从第 1 页重载 */
  setFinished(finished: string): void {
    if (finished === this.finished) {
      return;
    }
    this.finished = finished;
    this.loadData(true);
  }

  /**
   * 用户显式下拉刷新入口：仅此路径将 `isManualRefreshing` 置为 true。
   */
  async onPullToRefresh(includeHome: boolean = false): Promise<void> {
    await this.reloadAllSections('PULL_TO_REFRESH', includeHome);
  }

  /**
   * 分页加载方法
   * @param isRefresh true  = 重置到第 1 页，整表重载 DataSource
   *                  false = 触底加载更多：追加下一页（pushDataList 增量通知）
   * @param manualRefresh 是否为用户显式下拉刷新
   */
  async loadData(isRefresh: boolean, manualRefresh: boolean = false): Promise<void> {
    if (this.requesting) {
      if (manualRefresh) {
        this.isManualRefreshing = false;
      }
      return;
    }
    if (!isRefresh && !this.hasMore) {
      return;
    }

    const nextPage: number = isRefresh ? 1 : this.currentPage + 1;
    const gen: number = isRefresh ? ++this.listGeneration : this.listGeneration;
    if (isRefresh) {
      this.isRefreshing = true;
      if (manualRefresh) {
        this.isManualRefreshing = true;
      } else if (this.isEmpty) {
        this.isInitialLoading = true;
      }
    } else {
      this.isLoading = true;
    }
    this.errorMessage = '';
    this.needsLogin = false;
    this.requesting = true;

    try {
      const result: PageInfo<Comic> = await this.source.getHomeList(nextPage, this.sort, this.finished);
      if (gen !== this.listGeneration) {
        return;
      }
      const visible: Comic[] = filterComics(result.list);
      if (isRefresh) {
        this.comicDataSource.reloadData(visible);
      } else {
        this.comicDataSource.pushDataList(visible);
      }
      this.currentPage = result.page;
      this.hasMore = result.hasMore;
      this.isEmpty = this.comicDataSource.isEmpty();
      Logger.info(TAG, `${isRefresh ? '(刷新)' : '(更多)'} 第${result.page}页加载成功, 本页${visible.length}/${result.list.length}条`);
    } catch (e) {
      if (gen !== this.listGeneration) {
        return;
      }
      const message: string = e instanceof HttpError ? e.message : '未知错误，请稍后重试';
      this.errorMessage = message;
      this.needsLogin = e instanceof AuthRequiredError;
      Logger.error(TAG, `加载失败(needsLogin=${this.needsLogin}): ${message}`);
    } finally {
      if (gen === this.listGeneration) {
        this.requesting = false;
        this.isRefreshing = false;
        this.isManualRefreshing = false;
        this.isInitialLoading = false;
        this.isLoading = false;
      }
    }
  }
}
