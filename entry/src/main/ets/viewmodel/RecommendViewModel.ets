/**
 * RecommendViewModel.ets —— 个人化精选状态机（Phase 14-Q）
 *
 * 数据：POST /api/favoritesrecommend { page } → { status, info: Book[], len }，每页 20。
 * 语义：这是官方「收藏推荐/个人化精选」独立数据源，**不得**用以下数据替代：
 *   /api/home.fs、readDay、proportion、/api/b1/booklist、/api/v4/book/random、book.recommend[]
 *
 * Phase 14-N 的 PersonalizedViewModel（API_UNVERIFIED 占位）保留未动，
 * 仅为不破坏既有测试；新页面只使用本 VM。
 */
import { Comic } from '../model/Comic';
import { PageInfo } from '../model/PageInfo';
import { NOY_PAGE_SIZE } from '../source/NoyAcgProtocol';
import { AuthRequiredError } from '../api/ApiErrors';
import { RecommendRepository } from '../api/DiscoveryRepository';
import { RecommendPort } from '../source/DiscoverySourcePort';
import {
  COUNT_MODE_SERVER_TOTAL,
  COUNT_MODE_UNKNOWN,
  canChangePage,
  normalizePage
} from '../utils/Pagination';
import { RatingSyncState } from '../utils/RatingSync';

@ObservedV2
export class RecommendViewModel {
  @Trace currentPage: number = 1;
  /** 服务端总量 len；-1 = 未知 */
  @Trace totalCount: number = -1;
  @Trace totalPages: number = 0;
  @Trace countMode: string = COUNT_MODE_SERVER_TOTAL;
  @Trace items: Comic[] = [];
  @Trace isLoading: boolean = false;
  @Trace errorMessage: string = '';
  @Trace needsLogin: boolean = false;
  /** 已成功加载过至少一页（用于区分「首屏空」与「未加载」） */
  @Trace loaded: boolean = false;
  @Trace isEmpty: boolean = false;

  readonly pageSize: number = NOY_PAGE_SIZE;

  private port: RecommendPort;
  private generation: number = 0;  /** 内容分级变更判据（Phase 14-S） */
  private ratingSync: RatingSyncState = new RatingSyncState();

  constructor(port?: RecommendPort) {
    this.port = port ?? new RecommendRepository();
  }

  /** 分级已变化则重新请求第 1 页（缓存按分级隔离，由 Repository 自愈） */
  reloadIfRatingChanged(): boolean {
    if (!this.ratingSync.takeChange()) {
      return false;
    }
    this.load(true);
    return true;
  }

  /** 分级变化广播的即时入口（Phase 14-T）：丢弃旧分级结果，重取第 1 页 */
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

  /** 翻页：请求服务端对应页。 */
  goToPage(page: number): void {
    if (!canChangePage(this.isLoading, this.currentPage, this.totalPages, page)) {
      return;
    }
    this.fetch(page);
  }

  retry(): void {
    this.fetch(this.currentPage);
  }

  private async fetch(page: number): Promise<void> {
    const gen: number = ++this.generation;
    this.isLoading = true;
    this.errorMessage = '';
    this.needsLogin = false;
    try {
      const result: PageInfo<Comic> = await this.port.fetchRecommend(page);
      if (gen !== this.generation) {
        return;
      }
      await this.applyResult(result, page, gen);
      if (gen !== this.generation) {
        return;
      }
      this.loaded = true;
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

  private async applyResult(result: PageInfo<Comic>, requested: number, gen: number): Promise<void> {
    const known: boolean = result.totalCount >= 0;
    this.countMode = known ? COUNT_MODE_SERVER_TOTAL : COUNT_MODE_UNKNOWN;
    this.totalCount = known ? result.totalCount : -1;
    this.totalPages = result.totalPages > 0 ? result.totalPages : 0;
    if (known && this.totalPages > 0) {
      const clamped: number = normalizePage(requested, this.totalPages);
      if (clamped !== requested) {
        this.currentPage = clamped;
        const retried: PageInfo<Comic> = await this.port.fetchRecommend(clamped);
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
