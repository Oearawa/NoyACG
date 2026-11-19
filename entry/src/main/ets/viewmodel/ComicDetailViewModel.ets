/**
 * ComicDetailViewModel.ets —— 漫画详情页视图模型（Phase 11 重写，状态管理 V2）
 *
 * 状态机：IDLE → LOADING → SUCCESS / EMPTY / ERROR / AUTH_REQUIRED
 * - `AUTH_REQUIRED` 是**独立状态**，不并入普通网络错误，UI 据此给出「去登录」；
 * - `EMPTY` 表示详情实体存在但没有可展示章节、且不是明确的单本(Mode=0)形态。
 *
 * 关键约束：
 * 1. 请求代际 `generation`：旧请求晚到一律丢弃，不覆盖新结果；
 * 2. `disposed` 守卫：页面销毁后不再回写任何 @Trace 状态；
 * 3. 同 ID 去重：已成功/空态的同一漫画不重复请求（retry 显式 force=true）；
 * 4. 不在 Build 中发请求（由页面 onReady 调用），VM 不拼接任何 API URL；
 * 5. 网络请求失败才进入错误态；本地收藏/历史查询失败降级为默认值，不掩盖网络结果；
 * 6. 章节选择返回 `ComicReaderParam`，同时携带 bookId + chapterId，并带上该章节自己的起始页。
 *
 * I-000002（收藏写入与状态同步）：
 * - 星标 = 账号收藏态，服务端为准：详情响应 `F`（favorited）已知时用它初始化，
 *   页面重新可见时再以 /api/v4/favorites/get 校准（不依赖本地乐观缓存）；
 * - toggle 写路径 POST /api/v4/favorites/toggle 表单 { bid }（契约证据 PHASE14J2_REPORT.md §3）；
 * - 防抖：toggle 在途忽略第二次点击；失败回滚：优先 /get 重取校准，重取失败回滚到操作前状态；
 * - 本地收藏库仅作镜像同步（尽力而为），镜像失败不阻断、不谎报远端结果。
 */
import { ComicDetail, BOOK_MODE_SINGLE } from '../model/ComicDetail';
import { Chapter } from '../model/Chapter';
import { ChapterGroup } from '../model/ChapterGroup';
import { DownloadStatus, DownloadTask } from '../model/DownloadTask';
import { ReaderChapterItem } from '../reader/ReaderTypes';
import { ChapterRow } from '../model/ChapterRow';
import { ComicReaderParam } from '../model/ReaderParam';
import { BookComment, CommentPage } from '../model/BookComment';
import { BasicDataSource } from '../utils/BasicDataSource';
import { IComicSource } from '../source/IComicSource';
import { noyAcgSource } from '../source/NoyAcgSource';
import { AccountFavoritePort } from '../source/AccountFavoritePort';
import { FAVORITE_CLASS_ALL } from '../source/NoyAcgProtocol';
import { PageInfo } from '../model/PageInfo';
import { Comic } from '../model/Comic';
import { HttpError } from '../api/HttpManager';
import { AuthRequiredError, ProtocolError } from '../api/ApiErrors';
import { DatabaseManager, HistoryRecord, ReadingStorePort } from '../utils/DatabaseManager';
import { ComicMetaCache, HistoryMetadata } from '../utils/ComicMetaCache';
import { DownloadControlPort, NoopDownloadControl } from '../download/DownloadPorts';
import { DownloadFactory, DownloadServices } from '../download/DownloadFactory';
import { AuthManager } from '../utils/AuthManager';
import { Logger } from '../utils/Logger';
import { RatingSyncState } from '../utils/RatingSync';

const TAG: string = 'ComicDetailViewModel';

/** 详情加载状态（显式枚举，UI 按状态切换视图） */
export enum DetailState {
  IDLE = 'idle',
  LOADING = 'loading',
  SUCCESS = 'success',
  EMPTY = 'empty',
  ERROR = 'error',
  AUTH_REQUIRED = 'auth_required'
}

/** 失败原因分类（保留可诊断信息，不把所有错误都叫「加载失败」） */
export enum DetailErrorKind {
  NONE = 'none',
  AUTH_REQUIRED = 'auth_required',
  NETWORK = 'network',
  PROTOCOL = 'protocol',
  UNKNOWN = 'unknown'
}

@ObservedV2
export class ComicDetailViewModel {
  /** 当前加载状态 */
  @Trace state: DetailState = DetailState.IDLE;
  /** 详情实体（null = 尚未加载成功） */
  @Trace detail: ComicDetail | null = null;
  /** 可诊断的错误信息（含异常类型与状态码） */
  @Trace errorMessage: string = '';
  /** 失败分类 */
  @Trace errorKind: DetailErrorKind = DetailErrorKind.NONE;
  /** 是否因登录失效失败（UI 显示「去登录」） */
  @Trace needsLogin: boolean = false;

  /** 星标展示态 = 账号收藏态（服务端为准；未登录/未知为 false） */
  @Trace isFavorite: boolean = false;
  /** toggle 写请求在途（重复点击防抖 + UI 处理中提示） */
  @Trace isFavoritePending: boolean = false;
  /** 收藏操作反馈（成功/失败/需要登录提示，UI 顶部 banner 展示） */
  @Trace favoriteNotice: string = '';
  /** 简介是否展开 */
  @Trace isDescriptionExpanded: boolean = false;
  /** 当前选中的章节 id（用于 UI 高亮） */
  @Trace selectedChapterId: string = '';
  /** 章节目录是否倒序展示（默认 false = 服务端正序） */
  @Trace isChapterReversed: boolean = false;
  /** 展示用章节总数（单本归一化后为 1，避免出现 0 话 / 0 分组） */
  @Trace displayChapterCount: number = 0;
  /** 展示用分组总数 */
  @Trace displayGroupCount: number = 0;

  /** Phase 12：加入下载队列后的操作反馈（UI 直接展示） */
  @Trace downloadNotice: string = '';
  /** 当前详情是否来自本地离线降级缓存 */
  @Trace isOfflineFallback: boolean = false;
  /** 本地已完成离线下载的章节 ID 列表 */
  @Trace offlineChapterIds: string[] = [];
  /** 最近一次阅读的章节（空串 = 无有效历史） */
  @Trace historyChapterId: string = '';
  @Trace historyChapterTitle: string = '';
  @Trace historyPageIndex: number = 0;

  /** Phase 14-I：评论分页状态（官方置顶评论在 detail.comments 里单独展示，不入此列表） */
  @Trace comments: BookComment[] = [];
  @Trace commentLoading: boolean = false;
  @Trace commentHasMore: boolean = false;
  @Trace commentError: string = '';
  /** 已加载到的评论页码（0 = 尚未加载） */
  @Trace commentPage: number = 0;
  /** 用户当前提交的星级评分（0 = 未评分，1..5） */
  @Trace userRatingStars: number = 0;
  /** 评分操作提示 */
  @Trace ratingNotice: string = '';

  /** 章节目录懒加载数据源（分组头 + 章节行共用一个 LazyForEach） */
  readonly chapterRows: BasicDataSource<ChapterRow> = new BasicDataSource<ChapterRow>();

  /** 漫画源 / 本地存储端口（可注入桩，便于无设备测试） */
  private source: IComicSource;
  private local: ReadingStorePort;
  /** 请求代际：每次真实请求自增，用于废弃过期响应 */
  private generation: number = 0;
  /** 页面是否已销毁 */
  private disposed: boolean = false;
  /** 最近一次请求的漫画 id（retry 用） */
  private currentComicId: string = '';
  /** 内容分级变更判据（Phase 14-S） */
  private ratingSync: RatingSyncState = new RatingSyncState();
  /** 已成功加载过的 id（同 ID 去重） */
  private loadedComicId: string = '';
  /** 在途请求的 id（防同一 ID 并发重复触发） */
  private inFlightId: string = '';
  /** 章节级起始页缓存：chapterId → pageIndex（来自本地 HistoryV2） */
  private pageByChapter: Record<string, number> = {};
  /** 下载控制端口（UI 不接触底层文件/数据库；测试可注入桩） */
  private downloadControl: DownloadControlPort;
  /** 账号收藏端口（I-000002：toggle 写 + /get 校准；测试可注入桩） */
  private accountFav: AccountFavoritePort;
  /** /get 校准在途（防重复并行校准） */
  private favoriteSyncing: boolean = false;

  constructor(source?: IComicSource, local?: ReadingStorePort,
    downloadControl?: DownloadControlPort, accountFav?: AccountFavoritePort) {
    this.source = source ?? noyAcgSource;
    this.local = local ?? DatabaseManager.getInstance();
    const services: DownloadServices | undefined = DownloadFactory.get();
    this.downloadControl = downloadControl ?? (services === undefined
      ? new NoopDownloadControl() : services.manager);
    // 默认实现为 NoyAcgSource（implements AccountFavoritePort：/get + /toggle 同源）
    this.accountFav = accountFav ?? noyAcgSource;
  }

  /**
   * Phase 12 核心流程「详情页 → 选择章节 → 加入下载队列」。
   * 只经 DownloadControlPort，不直接调用 DownloadManager / 文件系统 / 数据库。
   */
  isChapterDownloaded(chapterId: string): boolean {
    return this.offlineChapterIds.indexOf(chapterId) >= 0;
  }

  /** 一键将所有未完成离线下载的章节加入下载队列 */
  async downloadAllMissingChapters(): Promise<number> {
    if (this.disposed) {
      return 0;
    }
    const detail: ComicDetail | null = this.detail;
    if (detail === null || detail.id === '' || detail.chapters.length === 0) {
      this.downloadNotice = '暂无可下载章节';
      return 0;
    }
    await this.refreshOfflineChapterIds(detail.id);
    let enqueued: number = 0;
    for (let i = 0; i < detail.chapters.length; i++) {
      const ch: Chapter = detail.chapters[i];
      if (this.isChapterDownloaded(ch.id)) {
        continue;
      }
      try {
        await this.downloadControl.enqueueChapter(detail.id, ch.id, detail.title, ch.title);
        enqueued++;
      } catch (e) {
        this.downloadNotice = `批量入队中断: ${(e as Error).message}`;
        return enqueued;
      }
    }
    this.downloadNotice = enqueued > 0
      ? `已将 ${enqueued} 个未下载章节加入队列`
      : '全部章节均已离线缓存';
    return enqueued;
  }

  async downloadChapter(chapter: Chapter): Promise<void> {
    if (this.disposed) {
      return;
    }
    const detail: ComicDetail | null = this.detail;
    if (detail === null || detail.id === '' || chapter.id === '') {
      this.downloadNotice = '章节信息不完整，无法加入下载';
      return;
    }
    try {
      this.downloadNotice = await this.downloadControl.enqueueChapter(
        detail.id, chapter.id, detail.title, chapter.title);
    } catch (e) {
      this.downloadNotice = `加入下载失败: ${(e as Error).message}`;
      Logger.warn(TAG, this.downloadNotice);
    }
  }

  /** 是否有「有效」的继续阅读记录（章节仍在目录中，或为单本 cid=0） */
  get hasValidHistory(): boolean {
    if (this.historyChapterId === '' || this.detail === null) {
      return false;
    }
    if (this.detail.isSingleBook) {
      return this.historyChapterId === '0';
    }
    return this.findChapter(this.historyChapterId) !== null;
  }

  /** 是否处于加载中（UI 便捷判断） */
  get isLoading(): boolean {
    return this.state === DetailState.LOADING;
  }

  /**
   * 加载详情。
   * @param comicId 漫画 id（由路由参数传入，VM 不拼 URL）
   * @param force   true = 忽略去重（重试 / 换书强制刷新）
   */
  /**
   * 分级已变化则强制重新校验当前详情（Phase 14-S）。
   * 详情可能因分级变化而不可见 / 字段变化，因此 force=true 绕过缓存。
   */
  /**
   * 页面重新可见时恢复工作状态（Phase 14-T）：清除 `dispose()` 留下的销毁标记，
   * 否则被保留复用的详情页在返回后无法再发起任何请求（`loadDetail` 直接 return）。
   */
  activate(): void {
    if (!this.disposed) {
      return; // 幂等：避免每次页面可见都作废在途请求
    }
    this.disposed = false;
    this.generation++;
    this.inFlightId = '';
  }

  /**
   * 分级变化广播的即时入口（Phase 14-T）：用原 comicId 强制重取详情，
   * 相关推荐随详情一起重新下发，因此不需要额外请求。
   */
  refreshForRating(): void {
    this.ratingSync.markCurrent();
    if (this.currentComicId === '' || this.disposed) {
      return;
    }
    this.loadDetail(this.currentComicId, true);
  }

  reloadIfRatingChanged(): boolean {
    if (!this.ratingSync.takeChange()) {
      return false;
    }
    if (this.currentComicId !== '') {
      this.loadDetail(this.currentComicId, true);
    }
    return true;
  }

  async loadDetail(comicId: string, force: boolean = false): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (!force && this.loadedComicId === comicId &&
      (this.state === DetailState.SUCCESS || this.state === DetailState.EMPTY)) {
      return; // 同 ID 已加载，不重复请求
    }
    if (!force && this.inFlightId === comicId && this.state === DetailState.LOADING) {
      return; // 同 ID 在途，防重复触发
    }

    const gen: number = ++this.generation;
    this.currentComicId = comicId;
    this.inFlightId = comicId;
    this.state = DetailState.LOADING;
    this.errorMessage = '';
    this.errorKind = DetailErrorKind.NONE;
    this.needsLogin = false;

    try {
      const detail: ComicDetail = await this.source.getComicDetail(comicId);
      if (this.disposed || gen !== this.generation) {
        Logger.debug(TAG, `废弃过期详情响应 gen=${gen}, id=${comicId}`);
        return;
      }
      // 本地查询各自容错：失败不阻断详情展示，也不伪装成网络成功/失败
      const favorite: boolean = await this.safeIsFavorite(comicId);
      const histories: HistoryRecord[] = await this.safeHistories(comicId);
      if (this.disposed || gen !== this.generation) {
        return;
      }

      this.detail = detail;
      detail.comments = ComicDetailViewModel.filterComments(detail.comments);
      this.collapseAllGroups(detail);
      this.userRatingStars = 0;
      this.ratingNotice = '';
      const meta: HistoryMetadata = ComicMetaCache.putFromDetail(detail);
      if (histories.length > 0) {
        void DatabaseManager.getInstance().updateHistoryMetadata(detail.id, meta).catch(() => {});
      }
      this.isOfflineFallback = false;
      await this.refreshOfflineChapterIds(detail.id);
      // I-000002：星标以服务端为准——详情响应 F（favorited）已知时用它初始化；
      // 未知（null）回退本地镜像，再异步用 /get 校准（不依赖本地乐观缓存）
      const serverFav: boolean | null = detail.favorited;
      this.isFavorite = serverFav === null ? favorite : serverFav;
      if (serverFav === null) {
        this.syncAccountFavorite(detail.id, favorite).then((synced: boolean): void => {
          if (!this.disposed && gen === this.generation) {
            this.isFavorite = synced;
          }
        }).catch((e: Error): void => {
          Logger.warn(TAG, `收藏校准失败（降级默认值）: ${e.message}`);
        });
      } else {
        this.mirrorLocalFavorite(detail.id, detail.title, detail.cover, serverFav);
      }
      this.isDescriptionExpanded = false;
      this.selectedChapterId = '';
      this.applyHistories(histories);
      this.rebuildChapterRows();
      this.loadedComicId = comicId;
      // 无章节且不是明确单本 → EMPTY（不编造章节，也不把缺失字段当成功）
      this.state = (detail.hasChapters || detail.mode === BOOK_MODE_SINGLE)
        ? DetailState.SUCCESS : DetailState.EMPTY;
      Logger.info(TAG, `详情加载成功 id=${comicId}, 分组=${detail.groups.length}, ` +
        `章节=${detail.chapters.length}, state=${this.state}`);
      // Phase 14-I：详情成功后加载评论第 1 页（不阻塞详情渲染；官方置顶在 detail.comments）
      this.loadComments(false);
    } catch (e) {
      if (this.disposed || gen !== this.generation) {
        return;
      }
      this.needsLogin = e instanceof AuthRequiredError;
      if (!this.needsLogin && await this.tryLoadOfflineFallback(comicId, gen)) {
        return;
      }
      this.errorKind = ComicDetailViewModel.classify(e);
      this.errorMessage = ComicDetailViewModel.describe(e);
      this.state = this.needsLogin ? DetailState.AUTH_REQUIRED : DetailState.ERROR;
      Logger.warn(TAG, `详情加载失败(${this.errorKind}): ${this.errorMessage}`);
    } finally {
      if (gen === this.generation) {
        this.inFlightId = '';
      }
    }
  }

  /** 重试：忽略同 ID 去重，重新发起当前漫画的详情请求 */
  async retry(): Promise<void> {
    if (this.currentComicId === '') {
      return;
    }
    await this.loadDetail(this.currentComicId, true);
  }

  /**
   * Phase 14-I：加载书籍评论分页。
   * @param append true = 追加下一页；false = 从第 1 页重载（清空已有列表）
   */
  async loadComments(append: boolean): Promise<void> {
    const detail: ComicDetail | null = this.detail;
    if (detail === null || detail.id === '') {
      return;
    }
    if (this.commentLoading) {
      return;
    }
    const nextPage: number = append ? this.commentPage + 1 : 1;
    if (append && !this.commentHasMore) {
      return;
    }
    this.commentLoading = true;
    this.commentError = '';
    try {
      const page: CommentPage = await this.source.getBookComments(detail.id, nextPage);
      if (this.disposed) {
        return;
      }
      const filtered: BookComment[] = ComicDetailViewModel.filterComments(page.comments);
      if (append) {
        this.comments = this.comments.concat(filtered);
      } else {
        this.comments = filtered;
      }
      this.commentPage = page.page;
      this.commentHasMore = page.hasMore;
      Logger.info(TAG, `评论 id=${detail.id} 第${page.page}页: ${filtered.length}条, ` +
        `hasMore=${page.hasMore}`);
    } catch (e) {
      if (this.disposed) {
        return;
      }
      this.commentError = e instanceof HttpError ? e.message : '评论加载失败';
      Logger.warn(TAG, `评论加载失败: ${this.commentError}`);
    } finally {
      this.commentLoading = false;
    }
  }

  /** 展开/收起某个章节分组（只重建目录行，不重新请求网络） */
  toggleGroup(groupId: string): void {
    if (this.detail === null) {
      return;
    }
    const groups: ChapterGroup[] = this.detail.groups;
    for (let i = 0; i < groups.length; i++) {
      if (groups[i].id === groupId) {
        groups[i].isExpanded = !groups[i].isExpanded;
        this.rebuildChapterRows();
        return;
      }
    }
  }

  /** 展开/收起简介 */
  toggleDescription(): void {
    this.isDescriptionExpanded = !this.isDescriptionExpanded;
  }

  /** 切换章节目录正序 / 倒序展示（不改变 detail.chapters 原始顺序） */
  toggleChapterOrder(): void {
    this.isChapterReversed = !this.isChapterReversed;
    this.rebuildChapterRows();
  }

  /**
   * 选择章节 → 生成阅读器参数。
   * 必须同时携带 bookId 与 chapterId；起始页取**该章节自己**的本地记录，没有则从第 1 页开始。
   */
  private buildReaderChapters(detail: ComicDetail): ReaderChapterItem[] {
    if (detail.isSingleBook) {
      return [new ReaderChapterItem('0', detail.title, 1)];
    }
    const items: ReaderChapterItem[] = [];
    for (let i = 0; i < detail.chapters.length; i++) {
      const ch: Chapter = detail.chapters[i];
      items.push(new ReaderChapterItem(ch.id, ch.title, ch.order));
    }
    return items;
  }

  selectChapter(chapter: Chapter): ComicReaderParam | null {
    const detail: ComicDetail | null = this.detail;
    if (detail === null || detail.id === '' || chapter.id === '') {
      return null;
    }
    this.selectedChapterId = chapter.id;
    const startPage: number = this.pageOf(chapter.id);
    Logger.info(TAG, `选择章节 bid=${detail.id} cid=${chapter.id} startPage=${startPage}`);
    return new ComicReaderParam(
      detail.id,
      chapter.id,
      chapter.title,
      startPage,
      this.buildReaderChapters(detail)
    );
  }

  /** 开始阅读：优先第一章；单本(Mode=0)用首方约定的 cid='0' */
  startReading(): ComicReaderParam | null {
    const detail: ComicDetail | null = this.detail;
    if (detail === null || detail.id === '') {
      return null;
    }
    if (detail.isSingleBook) {
      this.selectedChapterId = '0';
      return new ComicReaderParam(
        detail.id,
        '0',
        detail.title,
        this.pageOf('0'),
        this.buildReaderChapters(detail)
      );
    }
    if (!detail.hasChapters) {
      return null;
    }
    return this.selectChapter(detail.chapters[0]);
  }

  /** 继续阅读：仅在历史记录仍有效时返回参数 */
  continueReading(): ComicReaderParam | null {
    const detail: ComicDetail | null = this.detail;
    if (detail === null || !this.hasValidHistory) {
      return null;
    }
    this.selectedChapterId = this.historyChapterId;
    return new ComicReaderParam(
      detail.id,
      this.historyChapterId,
      this.historyChapterTitle === '' ? '继续阅读' : this.historyChapterTitle,
      Math.max(this.historyPageIndex, 1),
      this.buildReaderChapters(detail)
    );
  }

  /** 该章节是否有可信的本地阅读记录（用于「已读」标记） */
  isChapterRead(chapterId: string): boolean {
    return this.pageByChapter[chapterId] !== undefined;
  }

  /** 是否为「上次阅读到」的章节 */
  isCurrentChapter(chapterId: string): boolean {
    return this.historyChapterId === chapterId;
  }

  /**
   * 切换账号收藏（I-000002 写路径）。
   * - 防抖：toggle 在途时忽略重复点击；
   * - 乐观更新 UI；失败回滚（优先 /get 重取校准，重取失败回滚到操作前状态）；
   * - 本地收藏库仅作镜像同步（尽力而为），镜像失败不阻断、不谎报远端结果。
   */
  async toggleFavorite(): Promise<void> {
    const detail: ComicDetail | null = this.detail;
    if (detail === null || detail.id === '') {
      return;
    }
    if (this.isFavoritePending) {
      return; // 防抖：toggle 在途时忽略第二次点击
    }
    this.isFavoritePending = true;
    this.favoriteNotice = '';
    const previous: boolean = this.isFavorite;
    const optimistic: boolean = !previous;
    this.isFavorite = optimistic; // 乐观更新
    try {
      await this.accountFav.toggleFavorite(detail.id);
      // 成功：以 /get 校准最终态（不信任乐观值）
      const synced: boolean = await this.syncAccountFavorite(detail.id, previous);
      if (!this.disposed) {
        this.isFavorite = synced;
        this.mirrorLocalFavorite(detail.id, detail.title, detail.cover, synced);
        this.favoriteNotice = synced === optimistic
          ? '已同步收藏' : '收藏状态已按服务端校准';
      }
    } catch (e) {
      // 失败回滚：优先 /get 重取；重取失败回滚到操作前状态
      const authFailed: boolean = e instanceof AuthRequiredError;
      let restored: boolean = previous;
      try {
        restored = await this.syncAccountFavorite(detail.id, previous);
      } catch (syncErr) {
        if (this.disposed) {
          return;
        }
        this.isFavorite = previous; // 明确回滚
        Logger.warn(TAG, `收藏回滚重取失败，已回滚到操作前状态: ${(syncErr as Error).message}`);
      }
      if (!this.disposed) {
        this.isFavorite = restored;
        this.favoriteNotice = authFailed
          ? '登录已失效，收藏未保存'
          : `收藏切换失败: ${(e as Error).message}`;
      }
      Logger.error(TAG, `账号收藏切换失败，已回滚(${authFailed ? 'auth' : 'other'}): ${(e as Error).message}`);
    } finally {
      if (!this.disposed) {
        this.isFavoritePending = false;
      }
    }
  }

  /**
   * 页面重新可见时以服务端为准校准收藏态（I-000002 状态同步）。
   * 不弹提示；失败静默保留当前值，下次进入再校准。
   */
  async resyncFavoriteOnReentry(): Promise<void> {
    const detail: ComicDetail | null = this.detail;
    if (detail === null || detail.id === '' || this.disposed || this.isFavoritePending) {
      return;
    }
    try {
      const synced: boolean = await this.syncAccountFavorite(detail.id, this.isFavorite);
      if (!this.disposed) {
        this.isFavorite = synced;
      }
    } catch (e) {
      Logger.warn(TAG, `重新进入收藏校准失败（保留当前值）: ${(e as Error).message}`);
    }
  }

  /** 重新进入详情页时同步本地阅读进度与离线下载状态（跨页面数据一致性） */
  async resyncProgressAndDownloadsOnReentry(): Promise<void> {
    const detail: ComicDetail | null = this.detail;
    if (detail === null || detail.id === '' || this.disposed) {
      return;
    }
    const histories: HistoryRecord[] = await this.safeHistories(detail.id);
    if (!this.disposed) {
      this.applyHistories(histories);
    }
    await this.refreshOfflineChapterIds(detail.id);
  }

  /** 页面销毁：标记 + 让在途响应作废 */
  dispose(): void {
    this.disposed = true;
    this.generation++;
    this.inFlightId = '';
  }

  // ==================== 内部方法 ====================

  /** 本地收藏查询容错：失败按「未收藏」降级，不掩盖网络结果 */
  private async safeIsFavorite(comicId: string): Promise<boolean> {
    try {
      return await this.local.isFavorite(comicId);
    } catch (e) {
      Logger.warn(TAG, `收藏状态读取失败: ${(e as Error).message}`);
      return false;
    }
  }

  /** 本地历史查询容错：失败按「无历史」降级 */
  private async safeHistories(comicId: string): Promise<HistoryRecord[]> {
    try {
      return await this.local.getHistories(comicId);
    } catch (e) {
      Logger.warn(TAG, `阅读历史读取失败: ${(e as Error).message}`);
      return [];
    }
  }

  /**
   * 以服务端为准校准收藏态（I-000002 状态同步）。
   * 读 /api/v4/favorites/get 第 1 页，按 Bid 匹配当前漫画；未登录抛 AuthRequiredError。
   * @param comicId 当前漫画 id
   * @param fallback /get 异常且非登录失效时返回的兜底值
   */
  private async syncAccountFavorite(comicId: string, fallback: boolean): Promise<boolean> {
    if (this.favoriteSyncing) {
      return this.isFavorite; // 防重复并行校准
    }
    this.favoriteSyncing = true;
    try {
      const page: PageInfo<Comic> = await this.accountFav.fetchAccountFavorites(1, FAVORITE_CLASS_ALL);
      if (this.disposed) {
        return this.isFavorite;
      }
      const list: Comic[] = page.list;
      for (let i = 0; i < list.length; i++) {
        if (list[i].id === comicId) {
          return true;
        }
      }
      return false;
    } catch (e) {
      if (e instanceof AuthRequiredError) {
        throw e; // 登录失效需要上抛，由调用方决定提示
      }
      Logger.warn(TAG, `收藏状态重取失败: ${(e as Error).message}`);
      return fallback;
    } finally {
      this.favoriteSyncing = false;
    }
  }

  /** 本地收藏库镜像同步（尽力而为）：失败只记日志，不阻断、不改变远端结果 */
  private async mirrorLocalFavorite(comicId: string, title: string, cover: string,
    serverState: boolean): Promise<void> {
    try {
      const localBefore: boolean = await this.local.isFavorite(comicId);
      if (localBefore === serverState) {
        return;
      }
      await this.local.toggleFavorite(comicId, title, cover);
    } catch (e) {
      Logger.warn(TAG, `本地收藏镜像同步失败（忽略）: ${(e as Error).message}`);
    }
  }

  /** 把章节级历史写入内存缓存，并计算「最近阅读」章节（列表已按时间降序） */
  private applyHistories(histories: HistoryRecord[]): void {
    this.pageByChapter = {};
    for (let i = 0; i < histories.length; i++) {
      const record: HistoryRecord = histories[i];
      if (record.chapterId === '') {
        continue;
      }
      this.pageByChapter[record.chapterId] = Math.max(record.pageIndex, 1);
    }
    if (histories.length > 0) {
      const latest: HistoryRecord = histories[0];
      this.historyChapterId = latest.chapterId;
      this.historyChapterTitle = latest.chapterTitle;
      this.historyPageIndex = Math.max(latest.pageIndex, 1);
    } else {
      this.historyChapterId = '';
      this.historyChapterTitle = '';
      this.historyPageIndex = 0;
    }
  }

  /** 章节起始页：无记录一律回到第 1 页，绝不复用上一章节页码 */
  private pageOf(chapterId: string): number {
    const page: number | undefined = this.pageByChapter[chapterId];
    return page === undefined ? 1 : Math.max(page, 1);
  }

  /** 按分组顺序 + 展开状态重建目录行（LazyForEach 单一数据源；单本自动归一化为 1 话） */
  private rebuildChapterRows(): void {
    const rows: ChapterRow[] = [];
    const detail: ComicDetail | null = this.detail;
    if (detail === null) {
      this.displayChapterCount = 0;
      this.displayGroupCount = 0;
      this.chapterRows.setData(rows);
      return;
    }

    const groups: ChapterGroup[] = detail.groups;
    if (groups.length === 0 && detail.isSingleBook) {
      const singleChapter: Chapter = new Chapter('0', '全一话', 1);
      singleChapter.groupId = 'single';
      singleChapter.groupName = '单本';
      rows.push(ChapterRow.header('single', '单本', true, 1));
      rows.push(ChapterRow.item('single', '单本', singleChapter));
      this.displayChapterCount = 1;
      this.displayGroupCount = 1;
      this.chapterRows.setData(rows);
      return;
    }

    let chapterTotal: number = 0;
    for (let i = 0; i < groups.length; i++) {
      const group: ChapterGroup = groups[i];
      chapterTotal += group.chapters.length;
      rows.push(ChapterRow.header(group.id, group.name, group.isExpanded, group.count));
      if (group.isExpanded) {
        const chapters: Chapter[] = group.chapters;
        if (this.isChapterReversed) {
          for (let j = chapters.length - 1; j >= 0; j--) {
            rows.push(ChapterRow.item(group.id, group.name, chapters[j]));
          }
        } else {
          for (let j = 0; j < chapters.length; j++) {
            rows.push(ChapterRow.item(group.id, group.name, chapters[j]));
          }
        }
      }
    }
    this.displayChapterCount = chapterTotal;
    this.displayGroupCount = groups.length;
    this.chapterRows.setData(rows);
  }

  /** 在拍平章节中按 id 查找（校验历史章节是否仍存在） */
  private async refreshOfflineChapterIds(comicId: string): Promise<void> {
    try {
      const tasks: DownloadTask[] = await this.downloadControl.listTasks();
      if (this.disposed) {
        return;
      }
      const ids: string[] = [];
      for (let i = 0; i < tasks.length; i++) {
        const t: DownloadTask = tasks[i];
        if (t.bookId === comicId && t.status === DownloadStatus.COMPLETED && t.isComplete) {
          ids.push(t.chapterId);
        }
      }
      this.offlineChapterIds = ids;
    } catch (_e) {
      // 忽略本地任务列表查询异常，不影响详情主流程
    }
  }

  /** 无网/详情拉取失败时，若本地存在已下载章节，降级构建离线详情与章节目录 */
  private async tryLoadOfflineFallback(comicId: string, gen: number): Promise<boolean> {
    try {
      const tasks: DownloadTask[] = await this.downloadControl.listTasks();
      if (this.disposed || gen !== this.generation) {
        return false;
      }
      const bookTasks: DownloadTask[] = [];
      for (let i = 0; i < tasks.length; i++) {
        const t: DownloadTask = tasks[i];
        if (t.bookId === comicId && (t.status === DownloadStatus.COMPLETED || t.completedImages > 0)) {
          bookTasks.push(t);
        }
      }
      if (bookTasks.length === 0) {
        return false;
      }
      bookTasks.sort((a: DownloadTask, b: DownloadTask): number => a.createdAt - b.createdAt);

      const fallbackDetail: ComicDetail = new ComicDetail(comicId,
        bookTasks[0].bookTitle === '' ? `漫画 #${comicId}` : bookTasks[0].bookTitle, '');
      const isSingleOffline: boolean = bookTasks.length === 1 && bookTasks[0].chapterId === '0';
      if (isSingleOffline) {
        fallbackDetail.mode = BOOK_MODE_SINGLE;
      }
      const chapters: Chapter[] = [];
      const offlineIds: string[] = [];
      for (let i = 0; i < bookTasks.length; i++) {
        const t: DownloadTask = bookTasks[i];
        const ch: Chapter = new Chapter(
          t.chapterId,
          t.chapterTitle === '' ? (t.chapterId === '0' ? '全一话' : `章节 #${t.chapterId}`) : t.chapterTitle,
          i + 1
        );
        ch.pageCount = t.totalImages;
        ch.groupId = 'offline';
        ch.groupName = isSingleOffline ? '单本' : '已离线章节';
        chapters.push(ch);
        if (t.status === DownloadStatus.COMPLETED && t.isComplete) {
          offlineIds.push(t.chapterId);
        }
      }
      fallbackDetail.chapters = chapters;
      fallbackDetail.groups = [new ChapterGroup('offline', isSingleOffline ? '单本' : '已离线章节', chapters)];

      const favorite: boolean = await this.safeIsFavorite(comicId);
      const histories: HistoryRecord[] = await this.safeHistories(comicId);
      if (this.disposed || gen !== this.generation) {
        return false;
      }
      this.detail = fallbackDetail;
      this.collapseAllGroups(fallbackDetail);
      this.isOfflineFallback = true;
      this.offlineChapterIds = offlineIds;
      this.isFavorite = favorite;
      this.applyHistories(histories);
      this.rebuildChapterRows();
      this.loadedComicId = comicId;
      this.errorMessage = '';
      this.state = DetailState.SUCCESS;
      Logger.info(TAG, `详情离线降级成功 id=${comicId}, 离线章节=${chapters.length}`);
      return true;
    } catch (_e) {
      return false;
    }
  }

  private collapseAllGroups(detail: ComicDetail): void {
    for (let i = 0; i < detail.groups.length; i++) {
      detail.groups[i].isExpanded = false;
    }
  }

  /** 判断是否全部章节均已离线 */
  isAllChaptersDownloaded(): boolean {
    const detail: ComicDetail | null = this.detail;
    if (detail === null) {
      return false;
    }
    if (detail.isSingleBook) {
      return this.offlineChapterIds.indexOf('0') >= 0;
    }
    if (detail.chapters.length === 0) {
      return false;
    }
    for (let i = 0; i < detail.chapters.length; i++) {
      if (this.offlineChapterIds.indexOf(detail.chapters[i].id) < 0) {
        return false;
      }
    }
    return true;
  }

  /** 提交星级评分（1..5）并实时更新评分状态与人数 */
  submitRating(stars: number, loggedInOverride?: boolean): boolean {
    const detail: ComicDetail | null = this.detail;
    if (detail === null || detail.id === '') {
      return false;
    }
    const loggedIn: boolean = loggedInOverride !== undefined
      ? loggedInOverride : AuthManager.getInstance().isAuthenticated;
    if (!loggedIn) {
      this.ratingNotice = '请先登录后评分';
      return false;
    }
    const clamped: number = Math.max(1, Math.min(5, Math.round(stars)));
    const prevStars: number = this.userRatingStars;
    const prevCount: number = Math.max(detail.ratingCount, 0);
    const prevScore10: number = detail.rating >= 0 ? detail.rating : 0;
    const nextScore10: number = clamped * 2;
    if (prevStars === 0) {
      const nextCount: number = prevCount + 1;
      detail.rating = Number(((prevScore10 * prevCount + nextScore10) / nextCount).toFixed(1));
      detail.ratingCount = nextCount;
    } else if (prevCount > 0) {
      detail.rating = Number(
        Math.max(0, Math.min(10, (prevScore10 * prevCount - prevStars * 2 + nextScore10) / prevCount)).toFixed(1)
      );
    }
    this.userRatingStars = clamped;
    this.ratingNotice = `已评分 ${ComicDetailViewModel.ratingLabelForStars(clamped)}`;
    return true;
  }

  /** 可见评论数（过滤官方旧版升级公告后保持列表与数量一致） */
  visibleCommentCount(): number {
    const detail: ComicDetail | null = this.detail;
    if (detail === null) {
      return this.comments.length;
    }
    if (this.comments.length > 0) {
      return Math.max(detail.commentCount, this.comments.length);
    }
    return detail.comments.length;
  }

  /** 过滤官方旧版客户端升级公告 */
  static isOfficialUpgradeNotice(c: BookComment): boolean {
    if (c.isOfficial) {
      return true;
    }
    if (c.username.trim().includes('官方公告')) {
      return true;
    }
    const body: string = c.content;
    return body.includes('舊版本將會緩慢停止服務') ||
      body.includes('旧版本将会缓慢停止服务') ||
      body.includes('2.x 和 3.x 是圖標長得完全一樣') ||
      body.includes('2.x 和 3.x 是图标长得完全一樣') ||
      body.includes('2.x 和 3.x 是图标长得完全一样');
  }

  static filterComments(list: BookComment[]): BookComment[] {
    const out: BookComment[] = [];
    for (let i = 0; i < list.length; i++) {
      if (!ComicDetailViewModel.isOfficialUpgradeNotice(list[i])) {
        out.push(list[i]);
      }
    }
    return out;
  }

  static ratingLabelForStars(stars: number, locale: string = 'zh-CN'): string {
    if (locale === 'en-US') {
      if (stars === 1) {
        return '1★ Poor';
      }
      if (stars === 2) {
        return '2★ Fair';
      }
      if (stars === 3) {
        return '3★ Average';
      }
      if (stars === 4) {
        return '4★ Good';
      }
      if (stars === 5) {
        return '5★ Excellent';
      }
      return '';
    }
    if (locale === 'zh-TW') {
      if (stars === 1) {
        return '1星 較差';
      }
      if (stars === 2) {
        return '2星 一般';
      }
      if (stars === 3) {
        return '3星 還行';
      }
      if (stars === 4) {
        return '4星 推薦';
      }
      if (stars === 5) {
        return '5星 非常好';
      }
      return '';
    }
    if (stars === 1) {
      return '1星 较差';
    }
    if (stars === 2) {
      return '2星 一般';
    }
    if (stars === 3) {
      return '3星 还行';
    }
    if (stars === 4) {
      return '4星 推荐';
    }
    if (stars === 5) {
      return '5星 非常好';
    }
    return '点击星星评分';
  }

  static buildShareLink(comicId: string): string {
    return `https://noy.asia/comic/${comicId.trim()}`;
  }

  static buildShareText(title: string, comicId: string): string {
    const cleanTitle: string = title.trim();
    const link: string = ComicDetailViewModel.buildShareLink(comicId);
    return cleanTitle === '' ? link : `${cleanTitle} ${link}`;
  }

  private findChapter(chapterId: string): Chapter | null {
    const detail: ComicDetail | null = this.detail;
    if (detail === null) {
      return null;
    }
    const chapters: Chapter[] = detail.chapters;
    for (let i = 0; i < chapters.length; i++) {
      if (chapters[i].id === chapterId) {
        return chapters[i];
      }
    }
    return null;
  }

  /** 错误分类：认证失效 / 协议 / 网络 / 未知 */
  private static classify(e: Object): DetailErrorKind {
    if (e instanceof AuthRequiredError) {
      return DetailErrorKind.AUTH_REQUIRED;
    }
    if (e instanceof ProtocolError || (e instanceof HttpError && e.statusCode === -1)) {
      return DetailErrorKind.PROTOCOL;
    }
    if (e instanceof HttpError) {
      return DetailErrorKind.NETWORK;
    }
    return DetailErrorKind.UNKNOWN;
  }

  /** 可诊断错误文本：带异常名与 HTTP 状态码，便于定位而不泄露敏感数据 */
  private static describe(e: Object): string {
    if (e instanceof HttpError) {
      return `${e.name}(statusCode=${e.statusCode}): ${e.message}`;
    }
    const err: Error = e as Error;
    return `${err.name ?? 'Error'}: ${err.message ?? '未知错误'}`;
  }
}
