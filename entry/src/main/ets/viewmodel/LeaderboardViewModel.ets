/**
 * LeaderboardViewModel.ets —— 排行榜状态机（Phase 14-Q）
 *
 * 与 Phase 14-N 的 RankViewModel（基于 /api/home 数组做本地分页）并存但**互不替代**：
 * 新页面只使用本 VM，走官方服务端分页端点；旧 VM 保留是为了不破坏 Phase 14-N/N1 的既有测试。
 *
 * 数据（首方 Web 前端证据）：
 *   reading  → POST /api/readLeaderboard   { page, type }
 *   favorite → POST /api/favLeaderboard    { page, type }
 *   quality  → POST /api/proportion        { page }   ← 无 type
 * 响应 { status, info: Book[], len }，每页 20；totalCount = len，totalPages = max(1, ceil(len/20))。
 *
 * 排序语义：服务端返回顺序即列表顺序；官方不提供 rank 字段、官方页面也不显示名次，
 * 因此这里不生成任何「官方排名」数值，UI 也不渲染排名 Badge。
 */
import { Comic } from '../model/Comic';
import { PageInfo } from '../model/PageInfo';
import { NOY_PAGE_SIZE } from '../source/NoyAcgProtocol';
import { AuthRequiredError } from '../api/ApiErrors';
import { LeaderboardRepository } from '../api/DiscoveryRepository';
import { LeaderboardPort } from '../source/DiscoverySourcePort';
import {
  RANK_KIND_READING,
  RANK_PERIOD_DAY,
  isValidRankKind,
  normalizeRankPeriod,
  rankKindSupportsPeriod
} from '../model/LeaderboardModels';
import {
  COUNT_MODE_SERVER_TOTAL,
  COUNT_MODE_UNKNOWN,
  canChangePage,
  normalizePage
} from '../utils/Pagination';
import { RatingSyncState } from '../utils/RatingSync';

@ObservedV2
export class LeaderboardViewModel {
  /** 当前榜单：reading | favorite | quality */
  @Trace kind: string = RANK_KIND_READING;
  /** 当前周期：day | week | moon（quality 不使用） */
  @Trace period: string = RANK_PERIOD_DAY;
  @Trace currentPage: number = 1;
  /** 服务端总量 len；-1 表示未知（不得当成 0 条） */
  @Trace totalCount: number = -1;
  @Trace totalPages: number = 0;
  /** PaginationBar 统计口径：服务端有 len 时 serverTotal，否则 unknown */
  @Trace countMode: string = COUNT_MODE_SERVER_TOTAL;
  @Trace items: Comic[] = [];
  @Trace isLoading: boolean = false;
  @Trace errorMessage: string = '';
  @Trace needsLogin: boolean = false;
  @Trace isEmpty: boolean = false;

  readonly pageSize: number = NOY_PAGE_SIZE;

  private port: LeaderboardPort;
  private generation: number = 0;  /** 内容分级变更判据（Phase 14-S：切换分级后回到页面能自愈） */
  private ratingSync: RatingSyncState = new RatingSyncState();

  constructor(port?: LeaderboardPort) {
    this.port = port ?? new LeaderboardRepository();
  }

  /** 首次加载 / 重试：resetPage=true 时回到第 1 页。 */
  /**
   * 分级已变化则重置到第一页重新请求（Phase 14-S）。
   * @returns true = 触发了重载（页面无需再自己判断）
   */
  reloadIfRatingChanged(): boolean {
    if (!this.ratingSync.takeChange()) {
      return false;
    }
    this.load(true);
    return true;
  }

  /**
   * 分级变化广播的即时入口（Phase 14-T）：保留当前榜单类型与周期，回到第 1 页重新请求。
   * 不清空 `items`，避免页面在请求返回前闪空。
   */
  refreshForRating(): void {
    this.ratingSync.markCurrent();
    this.load(true);
  }

  async load(resetPage: boolean = true): Promise<void> {
    if (resetPage) {
      this.currentPage = 1;
    }
    await this.fetch(this.currentPage);
  }

  /**
   * 应用路由参数（首页「更多」入口）。
   * 非法 kind 保持默认 reading；quality 强制丢弃周期。
   */
  applyInitial(kind: string, period: string): void {
    if (isValidRankKind(kind)) {
      this.kind = kind;
    }
    this.period = rankKindSupportsPeriod(this.kind) ? normalizeRankPeriod(period) : RANK_PERIOD_DAY;
    this.resetForNewSource();
  }

  /** 切换榜单：清旧数据、回第 1 页、作废在途请求。 */
  setKind(next: string): void {
    if (!isValidRankKind(next) || next === this.kind) {
      return;
    }
    this.kind = next;
    if (!rankKindSupportsPeriod(next)) {
      this.period = RANK_PERIOD_DAY;
    }
    this.resetForNewSource();
    this.load(true);
  }

  /** 切换周期：仅 reading/favorite 有效；quality 调用会被忽略。 */
  setPeriod(next: string): void {
    if (!rankKindSupportsPeriod(this.kind)) {
      return;
    }
    const normalized: string = normalizeRankPeriod(next);
    if (normalized === this.period) {
      return;
    }
    this.period = normalized;
    this.resetForNewSource();
    this.load(true);
  }

  /** 翻页：请求服务端对应页（不做本地切片）。 */
  goToPage(page: number): void {
    if (!canChangePage(this.isLoading, this.currentPage, this.totalPages, page)) {
      return;
    }
    this.fetch(page);
  }

  retry(): void {
    this.fetch(this.currentPage);
  }

  private resetForNewSource(): void {
    this.currentPage = 1;
    this.totalCount = -1;
    this.totalPages = 0;
    this.countMode = COUNT_MODE_SERVER_TOTAL;
    this.items = [];
    this.errorMessage = '';
    this.needsLogin = false;
    this.isEmpty = false;
  }

  private async fetch(page: number): Promise<void> {
    const gen: number = ++this.generation;
    this.isLoading = true;
    this.errorMessage = '';
    this.needsLogin = false;
    try {
      const result: PageInfo<Comic> = await this.port.fetchLeaderboard(this.kind, page, this.period);
      if (gen !== this.generation) {
        return;
      }
      await this.applyResult(result, page, gen);
      if (gen !== this.generation) {
        return;
      }
      this.isLoading = false;
    } catch (e) {
      if (gen !== this.generation) {
        return;
      }
      this.errorMessage = e instanceof Error ? e.message : '';
      this.needsLogin = e instanceof AuthRequiredError;
      // 错误态不是空态：未登录/网络失败必须交给 ErrorState/登录引导，
      // 否则会被误显示成「暂无数据」。
      this.isEmpty = false;
      this.isLoading = false;
    }
  }

  /**
   * 落地一页结果。
   * 服务端总量变化导致当前页越界时（例如停在第 10 页但 len 变小），
   * 按最新总页数夹取页码，并**最多自动补请求一次**，不做无限重试。
   */
  private async applyResult(result: PageInfo<Comic>, requested: number, gen: number): Promise<void> {
    const known: boolean = result.totalCount >= 0;
    this.countMode = known ? COUNT_MODE_SERVER_TOTAL : COUNT_MODE_UNKNOWN;
    this.totalCount = known ? result.totalCount : -1;
    this.totalPages = result.totalPages > 0 ? result.totalPages : 0;
    if (known && this.totalPages > 0) {
      const clamped: number = normalizePage(requested, this.totalPages);
      if (clamped !== requested) {
        this.currentPage = clamped;
        const retried: PageInfo<Comic> = await this.port.fetchLeaderboard(
          this.kind, clamped, this.period);
        if (gen !== this.generation) {
          return;
        }
        this.currentPage = clamped;
        this.items = retried.list;
        this.isEmpty = retried.list.length === 0;
        return;
      }
    }
    this.currentPage = requested;
    this.items = result.list;
    this.isEmpty = result.list.length === 0;
  }
}
