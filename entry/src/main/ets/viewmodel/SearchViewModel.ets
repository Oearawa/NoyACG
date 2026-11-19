/**
 * SearchViewModel.ets —— 全局搜索视图模型（MVVM 之 VM 层 · 状态管理 V2）
 *
 * 职责：承接「关键词输入 → 防抖提交 → 分页请求 → 结果去重 / 状态流转」全部逻辑，
 * SearchPage 只负责渲染与事件转发，不出现任何网络调用。
 *
 * 搜索状态机：
 *   IDLE ──search()──▶ SEARCHING ──▶ SUCCESS / EMPTY / ERROR
 *   SUCCESS ──loadMore()──▶ LOAD_MORE ──▶ SUCCESS / ERROR（保留已加载结果）
 *
 * 并发安全（两道独立防线，缺一不可）：
 * 1. 防抖：连续输入只在停顿 debounceMs 后自动发起搜索，避免逐字请求；
 *    但防抖不能替代重入控制 —— 用户连续按回车时防抖计时器会被清空；
 * 2. 请求代际（requestGeneration）：每次真实请求自增，响应回来时若代际已过期
 *    则整包丢弃，确保「旧请求晚于新请求返回」不会覆盖新关键词的结果。
 *    底层 rcp 不支持按请求取消，故采用代际废弃而非 abort。
 *
 * 分页规则（对齐 IComicSource.search(keyword, page) 与 PageInfo.hasMore）：
 * - 首页返回空列表 → 判定无下一页；
 * - 加载更多返回的全是已存在条目（去重后 0 新增）→ 判定无下一页，杜绝
 *   「页码自增但永远请求空数据」的死循环；
 * - 页码只在请求成功后才推进，失败保持原页码，重试即重发同一页。
 */
import { Comic } from '../model/Comic';
import { PageInfo } from '../model/PageInfo';
import { SEARCH_MODE_DEFAULT, normalizeSearchMode } from '../model/NavParams';
import {
  SEARCH_SORT_DEFAULT,
  SEARCH_TYPE_DEFAULT,
  SEARCH_FINISHED_ALL
} from '../source/NoyAcgSource';
import { BasicDataSource } from '../utils/BasicDataSource';
import { IComicSource } from '../source/IComicSource';
import { noyAcgSource } from '../source/NoyAcgSource';
import { HttpError } from '../api/HttpManager';
import { AuthRequiredError } from '../api/ApiErrors';
import { Logger } from '../utils/Logger';
import { comicDisplayFingerprint } from '../utils/StableLayout';
import { filterComics } from '../api/ContentFilter';
import { RatingSyncState } from '../utils/RatingSync';
import { COUNT_MODE_SERVER_TOTAL, COUNT_MODE_UNKNOWN } from '../utils/Pagination';

const TAG: string = 'SearchViewModel';

/** 输入防抖窗口（毫秒）：输入停顿超过该时长才自动发起搜索 */
const DEBOUNCE_MS: number = 600;

@ObservedV2
export class SearchViewModel {
  /** 搜索结果懒加载数据源（直接绑定 WaterFlow + LazyForEach，readonly 保证引用稳定） */
  readonly searchDataSource: BasicDataSource<Comic> = new BasicDataSource<Comic>();

  /** 当前关键词（与 Search 组件双向绑定，输入即时回写） */
  @Trace keyword: string = '';
  /**
   * 搜索范围（协议 mode：default / tag / author）。
   * 首页关键词 Chips 进入时使用 tag；用户自行改写关键词后自动回退 default，
   * 避免把普通关键词当成标签去搜（否则结果恒为空）。
   */
  @Trace mode: string = SEARCH_MODE_DEFAULT;
  /** 排序筛选（I-000003：''/views/favorites/rating，协议合法值见 API_PROTOCOL_AUDIT.md §2.1） */
  @Trace sort: string = SEARCH_SORT_DEFAULT;
  /** 类型筛选（I-000003：''/book/stream） */
  @Trace type: string = SEARCH_TYPE_DEFAULT;
  /** 完结筛选（I-000003：''/true/false） */
  @Trace finished: string = SEARCH_FINISHED_ALL;
  /** 首页请求进行中（控制整页 Loading 态） */
  @Trace isSearching: boolean = false;
  /** 加载更多进行中（控制底部 Loading 条） */
  @Trace isLoadMore: boolean = false;
  /** 已成功加载到的页码（0 = 尚未成功搜索过） */
  @Trace currentPage: number = 0;
  /** 总页数（0 = 尚未加载或无分页） */
  @Trace totalPages: number = 0;
  /** 服务端返回的总数（-1 = 未知） */
  @Trace totalCount: number = -1;
  /** 分页统计口径 */
  @Trace countMode: string = COUNT_MODE_UNKNOWN;
  /** 当前已展示条目数 */
  @Trace loadedCount: number = 0;
  /** 结果列表是否为空（驱动空态视图） */
  @Trace isEmpty: boolean = true;
  /** 是否还有下一页 */
  @Trace hasMore: boolean = false;
  /** 是否发生过一次成功搜索（区分「初始态」与「无结果态」） */
  @Trace hasSearched: boolean = false;
  /** 首屏错误（无结果可展示时的整页错误态） */
  @Trace hasError: boolean = false;
  /** 加载更多错误（保留已加载结果，仅底部提示重试） */
  @Trace loadMoreError: boolean = false;
  /** 最近一次错误信息（空串 = 无错误） */
  @Trace errorMessage: string = '';
  /** 是否因「未登录 / 登录失效」失败（UI 据此给出明确的登录提示，而不是笼统的搜索失败） */
  @Trace needsLogin: boolean = false;

  /** 漫画源适配器（构造注入，默认使用全局 NoyAcg 源；单元测试可注入桩实现） */
  private source: IComicSource;
  /** 请求代际：每次真实请求自增，用于废弃过期响应（非 UI 状态，不加 @Trace） */
  private requestGeneration: number = 0;  /** 内容分级变更判据（Phase 14-S） */
  private ratingSync: RatingSyncState = new RatingSyncState();
  /** 防抖计时器句柄（-1 = 无待执行任务） */
  private debounceTimer: number = -1;
  /** 最近一次真正发往服务端的关键词（用于跳过「同词重复提交」） */
  private lastSubmittedKeyword: string = '';
  /** 带参进入时的初始关键词（用户改写后据此把 mode 回退为 default） */
  private initialQuery: string = '';
  /** 在途请求对应的关键词（空串 = 无在途请求） */
  private inFlightKeyword: string = '';
  /** 在途请求对应的筛选组合签名（I-000003：筛选变化时同词在途不再短路） */
  private inFlightFilterSig: string = '';
  /** 已收录的漫画 id 集合（跨页去重，稳定 key 的唯一来源） */
  private seenIds: Set<string> = new Set<string>();
  /** 页面是否已销毁（销毁后一切异步回调直接返回） */
  private disposed: boolean = false;

  constructor(source?: IComicSource) {
    this.source = source ?? noyAcgSource;
  }

  // ==================== 输入与触发 ====================

  /**
   * 带参进入（Phase 14-J3）：回填关键词 + 搜索范围，并立即搜索一次。
   * 供 SearchPage 在 aboutToAppear 调用（首页关键词 Chips → mode='tag'）。
   * 空关键词直接忽略，不产生任何请求。
   */
  applyInitialQuery(keyword: string, mode: string): void {
    const text: string = keyword.trim();
    if (text === '') {
      return;
    }
    this.keyword = text;
    this.initialQuery = text;
    this.mode = normalizeSearchMode(mode);
    this.submit();
  }

  /**
   * 关键词变化回调（Search.onChange 转发）。
   * 只更新内存关键词 + 重置防抖计时器；真正的搜索在停顿后自动触发。
   */
  onKeywordInput(text: string): void {
    if (this.disposed) {
      return; // 页面已销毁：不再注册任何防抖计时器
    }
    this.keyword = text;
    // 关键词被改写（与带参进入的初始词不同）→ 搜索范围回退默认，避免误用 tag 模式
    if (text.trim() !== this.initialQuery) {
      this.mode = SEARCH_MODE_DEFAULT;
    }
    this.cancelDebounce();
    if (text.trim() === '') {
      // 清空输入：回到初始态（历史标签视图），不发起请求
      this.resetToIdle();
      return;
    }
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = -1;
      this.search(true);
    }, DEBOUNCE_MS);
  }

  /** 显式提交（Search.onSubmit / 点击历史标签 / 点击重试）：强制重查，跳过「同词去重」 */
  submit(): void {
    this.cancelDebounce();
    this.search(true, true);
  }

  /**
   * 筛选条件变化（SearchPage 筛选控件转发；I-000003）。
   * 值变化 → 立即以新组合重查第 1 页（search 成功路径会把 currentPage 重置为 1）；
   * 同值跳过；未搜索过（无关键词）时仅更新状态，不发请求。
   */
  onFilterChanged(kind: string, value: string): void {
    if (this.disposed) {
      return;
    }
    if (kind === 'sort') {
      if (this.sort === value) {
        return;
      }
      this.sort = value;
    } else if (kind === 'type') {
      if (this.type === value) {
        return;
      }
      this.type = value;
    } else if (kind === 'finished') {
      if (this.finished === value) {
        return;
      }
      this.finished = value;
    } else {
      Logger.warn(TAG, `未知筛选类型: ${kind}`);
      return;
    }
    this.search(true, true);
  }

  /** 重置所有筛选条件为默认值，并在已搜索状态下重查第 1 页 */
  resetFilters(): void {
    if (this.disposed) {
      return;
    }
    this.sort = SEARCH_SORT_DEFAULT;
    this.type = SEARCH_TYPE_DEFAULT;
    this.finished = SEARCH_FINISHED_ALL;
    if (this.keyword.trim() !== '') {
      this.search(true, true);
    }
  }

  /** 数字分页跳转到指定页（供 PaginationBar 调用） */
  goToPage(targetPage: number): void {
    if (this.disposed || this.isSearching) {
      return;
    }
    const text: string = this.keyword.trim();
    if (text === '') {
      return;
    }
    const safePage: number = targetPage >= 1 ? Math.floor(targetPage) : 1;
    if (this.totalPages > 0 && safePage > this.totalPages) {
      return;
    }
    void this.fetchPageReplace(text, safePage);
  }

  private async fetchPageReplace(text: string, targetPage: number): Promise<void> {
    this.cancelDebounce();
    const generation: number = ++this.requestGeneration;
    this.isSearching = true;
    this.isLoadMore = false;
    this.hasError = false;
    this.loadMoreError = false;
    this.errorMessage = '';
    this.needsLogin = false;
    try {
      const result: PageInfo<Comic> = await this.source.search(text, targetPage, this.mode,
        this.sort, this.type, this.finished);
      if (!this.isCurrent(generation)) {
        return;
      }
      this.seenIds.clear();
      const filtered: Comic[] = filterComics(result.list);
      const fresh: Comic[] = this.filterNewComics(filtered);
      this.searchDataSource.setDataStable(fresh,
        (comic: Comic): string => comic.id, comicDisplayFingerprint);
      this.currentPage = targetPage;
      this.loadedCount = fresh.length;
      this.hasSearched = true;
      this.isEmpty = fresh.length === 0;
      this.applyPaginationMeta(result, targetPage, fresh.length);
    } catch (e) {
      if (!this.isCurrent(generation)) {
        return;
      }
      this.hasError = true;
      this.needsLogin = e instanceof AuthRequiredError;
      this.errorMessage = e instanceof HttpError ? e.message : '搜索失败，请稍后重试';
    } finally {
      if (generation === this.requestGeneration) {
        this.isSearching = false;
      }
    }
  }

  private applyPaginationMeta(result: PageInfo<Comic>, page: number, pageCount: number): void {
    this.totalCount = result.totalCount;
    this.countMode = result.totalCount >= 0 ? COUNT_MODE_SERVER_TOTAL : COUNT_MODE_UNKNOWN;
    if (result.totalPages > 0) {
      this.totalPages = result.totalPages;
    } else if (result.totalCount > 0 && result.list.length > 0) {
      this.totalPages = Math.max(page, Math.ceil(result.totalCount / result.list.length));
    } else {
      this.totalPages = result.hasMore ? page + 1 : page;
    }
    this.hasMore = result.hasMore && result.list.length > 0 && pageCount > 0;
  }

  /** 当前筛选组合签名（用于在途请求去重与短路判定） */
  private filterSignature(): string {
    return `${this.sort}|${this.type}|${this.finished}`;
  }

  /** 清空关键词并回到初始态 */
  clearKeyword(): void {
    this.cancelDebounce();
    this.keyword = '';
    this.resetToIdle();
  }

  /** 取消待执行的防抖任务（提交、清空、页面销毁时必须调用） */
  private cancelDebounce(): void {
    if (this.debounceTimer !== -1) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
  }

  // ==================== 搜索主流程 ====================

  /**
   * 发起搜索 / 刷新
   * @param isRefresh true = 从第 1 页重查（新关键词、重试、下拉刷新）
   * @param force     true = 显式提交，跳过「同关键词已有结果」的短路（在途重复提交仍然拦截）
   */
  /**
   * 分级已变化则用**当前关键词与模式**重新搜索（Phase 14-S）。
   * 未搜索过（关键词为空）时不做任何事，避免发出空查询。
   */
  /**
   * 页面重新可见时恢复工作状态（Phase 14-T）。
   *
   * 背景：`dispose()` 会把 `disposed` 置 true 并作废在途请求（这是防止退栈后回写 UI 所必需的）。
   * 但 NavDestination 的页面实例可能被保留复用，若 `aboutToAppear` 再次执行时不清除该标记，
   * 之后所有搜索都会被 `disposed` 守卫吞掉 —— 表现为「切换分级后搜索页彻底不刷新」。
   * 因此重新进入页面必须先 `activate()`，并自增代次让上一轮的迟到响应彻底作废。
   */
  activate(): void {
    if (!this.disposed) {
      return; // 幂等：页面本来就活着时不得自增代次，否则会误废在途请求
    }
    this.disposed = false;
    this.requestGeneration++;
    this.isSearching = false;
    this.isLoadMore = false;
  }

  /**
   * 分级变化广播的即时入口（Phase 14-T）：
   * 保留关键词与搜索模式，按新分级重新搜索第 1 页。
   */
  refreshForRating(): void {
    this.ratingSync.markCurrent();
    if (this.lastSubmittedKeyword === '' || this.disposed) {
      return;
    }
    this.search(true, true);
  }

  reloadIfRatingChanged(): boolean {
    if (!this.ratingSync.takeChange()) {
      return false;
    }
    if (this.lastSubmittedKeyword !== '') {
      this.search(true, true);
    }
    return true;
  }

  async search(isRefresh: boolean, force: boolean = false): Promise<void> {
    // 页面已销毁：任何入口都不再产生状态变更（
    // 防止「退出后异步回调重新点亮 isSearching / hasSearched」这类无效 UI 更新）
    if (this.disposed) {
      Logger.debug(TAG, '页面已销毁，忽略搜索请求');
      return;
    }
    const text: string = this.keyword.trim();
    if (text === '') {
      this.resetToIdle();
      return;
    }
    // 同词在途重复提交：关键词与筛选组合均未变才忽略（防抖替代不了请求重入锁）；
    // 筛选变化时强制重发，旧响应靠请求代际废弃
    if (isRefresh && this.isSearching && this.inFlightKeyword === text
      && this.inFlightFilterSig === this.filterSignature()) {
      Logger.debug(TAG, `忽略同词在途重复提交: ${text}`);
      return;
    }
    // 防抖自动搜索的同词短路：已有结果、无错误时不重复打网络
    if (isRefresh && !force && text === this.lastSubmittedKeyword && !this.isEmpty
      && !this.hasError) {
      Logger.debug(TAG, `跳过同词重复搜索: ${text}`);
      return;
    }

    const generation: number = ++this.requestGeneration;
    this.inFlightKeyword = text;
    this.inFlightFilterSig = this.filterSignature();
    this.isSearching = true;
    this.isLoadMore = false;
    this.hasError = false;
    this.loadMoreError = false;
    this.errorMessage = '';
    this.needsLogin = false;

    try {
      const result: PageInfo<Comic> = await this.source.search(text, 1, this.mode,
        this.sort, this.type, this.finished);
      if (!this.isCurrent(generation)) {
        Logger.debug(TAG, `废弃过期搜索响应 gen=${generation}`);
        return;
      }
      this.seenIds.clear();
      const filtered: Comic[] = filterComics(result.list);
      const fresh: Comic[] = this.filterNewComics(filtered);
      // 稳定 key 增量替换；新关键词导致 key 集合变化时自然回退整表 reload
      this.searchDataSource.setDataStable(fresh,
        (comic: Comic): string => comic.id, comicDisplayFingerprint);
      this.currentPage = 1;
      this.loadedCount = fresh.length;
      this.lastSubmittedKeyword = text;
      this.hasSearched = true;
      this.isEmpty = fresh.length === 0;
      this.applyPaginationMeta(result, 1, fresh.length);
      this.hasMore = result.hasMore && result.list.length > 0 &&
        (fresh.length > 0 || filtered.length < result.list.length);
      Logger.info(TAG, `搜索完成 "${text}": 本页${fresh.length}条, hasMore=${this.hasMore}`);
    } catch (e) {
      if (!this.isCurrent(generation)) {
        return;
      }
      this.hasError = true;
      this.needsLogin = e instanceof AuthRequiredError;
      this.errorMessage = e instanceof HttpError ? e.message : '搜索失败，请稍后重试';
      // 首屏失败：清空旧结果，避免「新关键词 + 旧结果」错配
      this.seenIds.clear();
      this.searchDataSource.clear();
      this.currentPage = 0;
      this.hasSearched = true;
      this.isEmpty = true;
      this.hasMore = false;
      this.lastSubmittedKeyword = '';
      Logger.error(TAG, `搜索失败 "${text}": ${this.errorMessage}`);
    } finally {
      if (generation === this.requestGeneration) {
        this.isSearching = false;
        this.inFlightKeyword = '';
      }
    }
  }

  /**
   * 触底加载下一页（WaterFlow.onReachEnd 转发）。
   * 多重守卫：未搜索过 / 无下一页 / 正在加载 / 已销毁 一律忽略，
   * 杜绝连续触底回调把同一页重复请求。
   */
  async loadMore(): Promise<void> {
    if (this.disposed || this.isSearching || this.isLoadMore) {
      return;
    }
    if (!this.hasSearched || !this.hasMore || this.isEmpty) {
      return;
    }
    const text: string = this.lastSubmittedKeyword;
    if (text === '') {
      return;
    }

    const nextPage: number = this.currentPage + 1;
    const generation: number = ++this.requestGeneration;
    this.isLoadMore = true;
    this.loadMoreError = false;

    try {
      const result: PageInfo<Comic> = await this.source.search(text, nextPage, this.mode,
        this.sort, this.type, this.finished);
      if (!this.isCurrent(generation)) {
        Logger.debug(TAG, `废弃过期分页响应 gen=${generation}`);
        return;
      }
      const filtered: Comic[] = filterComics(result.list);
      const fresh: Comic[] = this.filterNewComics(filtered);
      if (fresh.length > 0) {
        this.searchDataSource.pushDataList(fresh);
      }
      this.currentPage = nextPage;
      // 空页 / 全重复页 → 认为已到底，避免无限请求空数据
      // Phase 14-R：本页若被标签过滤掉一部分，仍按服务端信号继续翻页；
      // 若整页都是已出现过的漫画（服务端未推进），则判定到底，避免无限重复请求。
      this.hasMore = result.hasMore && result.list.length > 0 &&
        (fresh.length > 0 || filtered.length < result.list.length);
      this.isEmpty = this.searchDataSource.isEmpty();
      Logger.info(TAG, `加载第${nextPage}页: 新增${fresh.length}条, hasMore=${this.hasMore}`);
    } catch (e) {
      if (!this.isCurrent(generation)) {
        return;
      }
      // 分页失败保留已加载结果，仅底部提示，页码不推进（重试即重发同一页）
      this.loadMoreError = true;
      this.needsLogin = e instanceof AuthRequiredError;
      this.errorMessage = e instanceof HttpError ? e.message : '加载更多失败，请稍后重试';
      Logger.error(TAG, `加载第${nextPage}页失败: ${this.errorMessage}`);
    } finally {
      if (generation === this.requestGeneration) {
        this.isLoadMore = false;
      }
    }
  }

  /** 重试入口：首屏错误→重查第一页；分页错误→重发下一页 */
  retry(): void {
    if (this.hasError) {
      this.search(true);
      return;
    }
    if (this.loadMoreError) {
      this.loadMore();
    }
  }

  /**
   * 过滤掉已收录的漫画（跨页去重），并把新条目登记进 seenIds。
   * 空 id 的脏数据同样剔除：LazyForEach 的 key 必须稳定唯一。
   */
  private filterNewComics(list: Comic[]): Comic[] {
    const result: Comic[] = [];
    for (let i = 0; i < list.length; i++) {
      const comic: Comic = list[i];
      if (comic.id === '' || this.seenIds.has(comic.id)) {
        continue;
      }
      this.seenIds.add(comic.id);
      result.push(comic);
    }
    return result;
  }

  /** 当前请求是否仍为最新（代际未过期且页面未销毁） */
  private isCurrent(generation: number): boolean {
    return !this.disposed && generation === this.requestGeneration;
  }

  /** 回到初始态（清空结果、复位全部状态位，数据源一次性释放） */
  private resetToIdle(): void {
    this.requestGeneration++; // 使在途请求全部过期
    this.searchDataSource.clear();
    this.seenIds.clear();
    this.currentPage = 0;
    this.totalPages = 0;
    this.totalCount = -1;
    this.countMode = COUNT_MODE_UNKNOWN;
    this.loadedCount = 0;
    this.hasMore = false;
    this.isEmpty = true;
    this.hasError = false;
    this.loadMoreError = false;
    this.errorMessage = '';
    this.hasSearched = false;
    this.needsLogin = false;
    this.lastSubmittedKeyword = '';
    this.initialQuery = '';
    this.mode = SEARCH_MODE_DEFAULT;
    this.sort = SEARCH_SORT_DEFAULT;
    this.type = SEARCH_TYPE_DEFAULT;
    this.finished = SEARCH_FINISHED_ALL;
    this.inFlightKeyword = '';
    this.isSearching = false;
    this.isLoadMore = false;
  }

  /**
   * 页面销毁（SearchPage.aboutToDisappear 调用）：
   * 取消防抖 + 作废在途请求，确保晚到的响应不再驱动已销毁页面的状态。
   */
  dispose(): void {
    this.cancelDebounce();
    this.disposed = true;
    this.requestGeneration++;
    this.inFlightKeyword = '';
    this.searchDataSource.clear();
    this.seenIds.clear();
  }
}
