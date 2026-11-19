/**
 * RankViewModel.ets —— 排行榜页状态机（Phase 14-N / 14-N1）
 *
 * 数据：复用 POST /api/home 本次响应返回的 readDay / proportion 数组。
 * 14-N1 审计修正：stream_all=1 的语义在仓库内未定义，响应结构无 total/count/len，
 * 数组长度按既有模型注释会波动，故不能证明「服务端完整排行榜」。
 * 因此 totalCount 只表示「本次已获取条数」，totalPages 只表示「本地页数」。
 * 排名语义：两个数组都没有服务端 rank/score 字段，proportion 排序规则明确标注未确认，
 * 故不把客户端数组下标宣传为官方排名。
 * 请求代际守卫保证快速切换榜单时旧响应不会覆盖新榜单。
 */
import { Comic } from '../model/Comic';
import { HomeFeed } from '../model/HomeFeed';
import { RankItem } from '../model/DiscoveryModels';
import {
  RANK_TYPE_READING,
  RANK_TYPE_HIGH_QUALITY,
  RANK_TYPE_VALUES,
  RANK_PERIOD_DAY,
  isRankPeriodSupported,
  rankFeedField,
  localPage,
  rankNumber
} from '../model/DiscoveryModels';
import { NOY_PAGE_SIZE } from '../source/NoyAcgProtocol';
import { DiscoveryRepository, HomeFeedPort } from '../api/DiscoveryRepository';
import { AuthRequiredError } from '../api/ApiErrors';
import { computeLocalPages, canChangePage, normalizePage, COUNT_MODE_LOCAL_LOADED } from '../utils/Pagination';

/**
 * 榜单顺序语义（14-N1 审计结论）：
 * 未找到服务端 rank / score 字段，也未找到任何「数组顺序 = 官方排名」的协议证据；
 * HomeFeed.ets:75 明确把 proportion 标为「规则未确认」。
 * 因此在获得真实证据之前，不允许把数组下标渲染成官方排名 Badge。
 */
export const RANK_ORDER_STATUS_UNVERIFIED: string = 'RANK_ORDER_UNVERIFIED';

export function rankOrderStatus(): string {
  return RANK_ORDER_STATUS_UNVERIFIED;
}

/** 是否允许展示「官方排名」徽标；未验证时恒为 false。 */
export function officialRankBadgeVisible(): boolean {
  return false;
}

/**
 * 列表序号：只代表本次返回数组的顺序位置，不代表官方排名。
 * 语义未验证时返回 0，ComicListItem 按约定不渲染排名 Badge。
 */
export function displayRankNumber(ordinal: number): number {
  return officialRankBadgeVisible() ? ordinal : 0;
}

/**
 * 是否需要展示「排序规则尚未验证」提示：
 * proportion 既有模型注释即标注未确认；readDay 也没有排序规则证据，故两者都需要。
 */
export function rankSemanticsNoticeRequired(rankType: string): boolean {
  return rankType === RANK_TYPE_READING || rankType === RANK_TYPE_HIGH_QUALITY;
}

@ObservedV2
export class RankViewModel {
  @Trace rankType: string = RANK_TYPE_READING;
  @Trace period: string = RANK_PERIOD_DAY;
  @Trace currentPage: number = 1;
  /** 本次 /api/home 响应中实际取得的数组长度，不是服务端全局总量。 */
  @Trace totalCount: number = 0;
  /** 本地页数，不是服务端总页数。 */
  @Trace totalPages: number = 0;
  /** PaginationBar 统计口径：本地已获取条数 + 本地页数。 */
  @Trace countMode: string = COUNT_MODE_LOCAL_LOADED;
  @Trace items: RankItem[] = [];
  @Trace isLoading: boolean = false;
  @Trace errorMessage: string = '';
  @Trace needsLogin: boolean = false;

  /** 本地分页大小沿用工程既有书单/搜索页大小，不是服务端请求参数。 */
  readonly pageSize: number = NOY_PAGE_SIZE;

  private allItems: Comic[] = [];
  private repo: HomeFeedPort;
  private generation: number = 0;

  constructor(repo?: HomeFeedPort) {
    this.repo = repo ?? new DiscoveryRepository();
  }

  async load(resetPage: boolean = true): Promise<void> {
    const gen: number = ++this.generation;
    this.isLoading = true;
    this.errorMessage = '';
    this.needsLogin = false;
    if (resetPage) {
      this.currentPage = 1;
    }
    try {
      const feed: HomeFeed = await this.repo.getHomeFeed();
      if (gen !== this.generation) {
        return;
      }
      const field: string = rankFeedField(this.rankType);
      this.allItems = field === 'proportion' ? feed.proportion : feed.readDay;
      this.totalCount = this.allItems.length;
      this.totalPages = computeLocalPages(this.totalCount, this.pageSize);
      this.currentPage = normalizePage(this.currentPage, this.totalPages);
      this.applyLocalPage();
      this.isLoading = false;
    } catch (e) {
      if (gen !== this.generation) {
        return;
      }
      this.errorMessage = e instanceof Error ? e.message : '';
      this.needsLogin = e instanceof AuthRequiredError;
      this.isLoading = false;
    }
  }

  /** 切换榜单类型：清旧数据、回第 1 页、作废在途请求。 */
  setRankType(next: string): void {
    if (RANK_TYPE_VALUES.indexOf(next) < 0 || next === this.rankType) {
      return;
    }
    this.rankType = next;
    this.clearForNewSource();
    this.load(true);
  }

  /** 切换时间维度：仓库内只有日数据，周/月禁用，不允许伪造。 */
  setPeriod(next: string): void {
    if (!isRankPeriodSupported(next) || next === this.period) {
      return;
    }
    this.period = next;
    this.clearForNewSource();
    this.load(true);
  }

  /** 本地分页翻页：不发起新请求，但受加载态与边界约束。 */
  goToPage(page: number): void {
    if (!canChangePage(this.isLoading, this.currentPage, this.totalPages, page)) {
      return;
    }
    this.currentPage = page;
    this.applyLocalPage();
  }

  retry(): void {
    this.load(true);
  }

  private clearForNewSource(): void {
    this.currentPage = 1;
    this.totalCount = 0;
    this.totalPages = 0;
    this.items = [];
    this.allItems = [];
    this.errorMessage = '';
    this.needsLogin = false;
  }

  private applyLocalPage(): void {
    const pageItems: Comic[] = localPage(this.allItems, this.currentPage, this.pageSize);
    const result: RankItem[] = [];
    for (let i = 0; i < pageItems.length; i++) {
      result.push(new RankItem(rankNumber(this.currentPage, this.pageSize, i), pageItems[i]));
    }
    this.items = result;
  }
}
