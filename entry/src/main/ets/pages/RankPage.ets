import { HdsNavDestination } from '@kit.UIDesignKit';
/**
 * RankPage.ets —— 排行榜页（Phase 14-Q 正式接入 + StandardPageScaffold 迁移）
 *
 * 数据（首方 Web 前端证据，见 Phase 14-P 报告）：
 *   阅读榜   POST /api/readLeaderboard   { page, type }
 *   收藏榜   POST /api/favLeaderboard    { page, type }
 *   高质量榜 POST /api/proportion        { page }      ← 无 type，无周期维度
 */
import { Comic } from '../model/Comic';
import {
  RANK_KIND_FAVORITE,
  RANK_KIND_QUALITY,
  RANK_KIND_READING,
  RANK_PERIOD_VALUES,
  rankKindSupportsPeriod
} from '../model/LeaderboardModels';
import { ROUTE_LOGIN } from '../model/ProfileMenu';
import { RankPageParam } from '../model/NavParams';
import { LeaderboardViewModel } from '../viewmodel/LeaderboardViewModel';
import { PaginationBar } from '../components/PaginationBar';
import { ComicListItem } from '../components/ComicListItem';
import { CapsuleSelect } from '../components/CapsuleSelect';
import { SegmentSelector } from '../components/SegmentSelector';
import { StandardPageScaffold } from '../components/StandardPageScaffold';
import { shouldUseInlineSecondaryHeader } from '../utils/StandardScaffoldLayout';
import { ViewportState } from '../utils/ViewportState';
import { ResponsiveLayoutMetrics, resolveLayoutPolicy } from '../responsive/LayoutPolicy';
import { paginationFloatingInsetVp } from '../utils/Pagination';
import { LocalizationManager } from '../utils/LocalizationManager';
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import { prefetchComicsAround, cancelPrefetch } from '../utils/ImagePrefetch';
import { BlockedTagManager } from '../utils/BlockedTagManager';
import { RatingBridge } from '../utils/RatingBridge';

@ComponentV2
export struct RankPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local vm: LeaderboardViewModel = new LeaderboardViewModel();
  @Local layout: ResponsiveLayoutMetrics = ViewportState.getInstance().getLayoutPolicy();
  @Local columns: number = ViewportState.getInstance().getLayoutPolicy().listLanes;
  @Local containerWidth: number = ViewportState.getInstance().widthVp;
  @Local viewportHeightVp: number = ViewportState.getInstance().heightVp;
  private readonly kindSwiperController: SwiperController = new SwiperController();
  private readonly syncViewport = (): void => {
    const vp: ViewportState = ViewportState.getInstance();
    const targetW: number = this.containerWidth > 0 ? this.containerWidth : vp.widthVp;
    const metrics: ResponsiveLayoutMetrics = resolveLayoutPolicy(targetW, vp.isLandscape());
    this.layout = metrics;
    if (metrics.listLanes !== this.columns) {
      this.columns = metrics.listLanes;
    }
    if (vp.heightVp > 0 && Math.abs(vp.heightVp - this.viewportHeightVp) >= 0.5) {
      this.viewportHeightVp = vp.heightVp;
    }
  };
  /** 首页「更多」传入的初始榜单/周期（空串 = 默认 reading/day） */
  @Param initialKind: string = '';
  @Param initialPeriod: string = '';
  private lm: LocalizationManager = LocalizationManager.getInstance();

  /** 上次渲染时的屏蔽标签版本：返回页面时若变化则回到第一页重载（Phase 14-R） */
  private blockedRevision: number = 0;
  /**
   * 内容分级变化订阅（Phase 14-T）：页面被设置页覆盖时仍然存活，
   * 广播到达即按新分级重取；页面销毁时退订。
   */
  private ratingBridge: RatingBridge = new RatingBridge((): void => {
    this.vm.refreshForRating();
  });

  // 说明：`onPageShow` 只对 @Entry 页面有效，NavDestination 页面不会被调用，
  // 因此「返回页面」的处理统一收敛到 `onPageRevealed()`（由 NavDestination.onShown 触发）。

  aboutToAppear(): void {
    this.syncViewport();
    ViewportState.getInstance().addListener(this.syncViewport);
    this.ratingBridge.start();
    // 记录进入页面时的黑名单版本，避免 onPageShow 首次触发时重复加载
    this.blockedRevision = BlockedTagManager.getInstance().revision;
    if (this.initialKind !== '' || this.initialPeriod !== '') {
      this.vm.applyInitial(this.initialKind, this.initialPeriod);
    }
    // Phase 14-S：分级变化时由 VM 自行按新分级重载，避免这里再发一次重复请求
    if (!this.vm.reloadIfRatingChanged()) {
      this.vm.load(true);
    }
  }

  aboutToDisappear(): void {
    ViewportState.getInstance().removeListener(this.syncViewport);
    this.ratingBridge.stop();
    cancelPrefetch('rank');
  }

  /**
   * 页面重新可见（Phase 14-T 兜底）：被设置页覆盖后返回时，`aboutToAppear` 不会再次执行，
   * 因此这里主动做一次分级判据检查；无变化时不会产生任何请求。
   */
  private onPageRevealed(): void {
    this.ratingBridge.start();
    if (this.vm.reloadIfRatingChanged()) {
      return;
    }
    const revision: number = BlockedTagManager.getInstance().revision;
    if (revision !== this.blockedRevision) {
      this.blockedRevision = revision;
      this.vm.load(true);
    }
  }

  private prefetchRank(index: number): void {
    prefetchComicsAround(this.vm.items, index, 'rank');
  }

  private bottomListInset(): number {
    const bottomSafe: number = ViewportState.getInstance().bottomVp;
    return paginationFloatingInsetVp(this.vm.totalPages > 0, bottomSafe);
  }

  private isInlineHeader(): boolean {
    const w: number = this.containerWidth > 0 ? this.containerWidth : ViewportState.getInstance().widthVp;
    return shouldUseInlineSecondaryHeader(w, this.viewportHeightVp);
  }

  private periodLabels(): string[] {
    return [
      this.periodLabel(RANK_PERIOD_VALUES[0]),
      this.periodLabel(RANK_PERIOD_VALUES[1]),
      this.periodLabel(RANK_PERIOD_VALUES[2])
    ];
  }

  private periodSelectedIndex(): number {
    const idx: number = RANK_PERIOD_VALUES.indexOf(this.vm.period);
    return idx >= 0 ? idx : 0;
  }

  private kindSelectedIndex(): number {
    if (this.vm.kind === RANK_KIND_FAVORITE) {
      return 1;
    }
    if (this.vm.kind === RANK_KIND_QUALITY) {
      return 2;
    }
    return 0;
  }

  private kindLabels(): string[] {
    return [
      this.lm.getString($r('app.string.rank_reading'), ''),
      this.lm.getString($r('app.string.rank_favorite'), ''),
      this.lm.getString($r('app.string.rank_high_quality'), '')
    ];
  }

  private periodRes(period: string): Resource {
    if (period === 'week') {
      return $r('app.string.rank_week');
    }
    if (period === 'moon') {
      return $r('app.string.rank_month');
    }
    return $r('app.string.rank_day');
  }

  private periodLabel(period: string): string {
    return this.lm.getString(this.periodRes(period), '');
  }

  private onKindSelect(index: number): void {
    this.kindSwiperController.changeIndex(index, true);
    if (index === 1) {
      this.vm.setKind(RANK_KIND_FAVORITE);
    } else if (index === 2) {
      this.vm.setKind(RANK_KIND_QUALITY);
    } else {
      this.vm.setKind(RANK_KIND_READING);
    }
  }


  @Builder
  RankHeaderBottom() {
    this.KindTabs()
  }

  @Builder
  RankContent() {
    Swiper(this.kindSwiperController) {
      ForEach([0, 1, 2], (tabIdx: number) => {
        Column() {
          if (tabIdx === this.kindSelectedIndex()) {
            this.RankTabBody()
          }
        }
        .width('100%')
        .height('100%')
      }, (tabIdx: number) => `${tabIdx}`)
    }
    .index(this.kindSelectedIndex())
    .loop(false)
    .indicator(false)
    .duration(220)
    .curve(Curve.FastOutSlowIn)
    .cachedCount(1)
    .width('100%')
    .layoutWeight(1)
    .onChange((index: number) => {
      if (index !== this.kindSelectedIndex()) {
        this.onKindSelect(index);
      }
    })
  }

  @Builder
  RankTabBody() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 统一响应式列表：单一 List 组件通过 .lanes() 原地重排 1 栏 / 2 栏，旋转不销毁滚动状态
      List({ space: 10 }) {
        ForEach(this.vm.items, (item: Comic, index: number) => {
          ListItem() {
            // 官方无 rank 字段：不传 rank，ComicListItem 不渲染名次徽标
            ComicListItem({ comic: item, coverWidth: ThemeDims.LIST_COVER_WIDTH })
          }
          .onAppear(() => {
            this.prefetchRank(index);
          })
        }, (item: Comic) => item.id)
      }
      .lanes(this.layout.listLanes, this.layout.listGutterVp)
      .padding({
        left: 16,
        right: 16,
        top: 6
      })
      .width('100%')
      .height('100%')
      .contentEndOffset(this.bottomListInset())
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .cachedCount(ThemeDims.LIST_CACHED_COUNT)

      if (this.vm.totalPages > 0) {
        PaginationBar({
          currentPage: this.vm.currentPage,
          totalPages: this.vm.totalPages,
          totalCount: this.vm.totalCount,
          countMode: this.vm.countMode,
          loading: this.vm.isLoading,
          compact: this.columns >= 2 || this.containerWidth >= 600,
          bottomSafeInset: ViewportState.getInstance().bottomVp,
          useMaterialSurface: true,
          onPageChange: (page: number): void => {
            this.vm.goToPage(page);
          }
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  InlineKindHeader() {
    Row() {
      SegmentSelector({
        labels: this.kindLabels(),
        selectedIndex: this.kindSelectedIndex(),
        compact: true,
        onSelect: (index: number): void => {
          this.onKindSelect(index);
        }
      })
    }
    .width('100%')
    .constraintSize({ maxWidth: 260 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  InlinePeriodHeader() {
    if (rankHasPeriodSelector(this.vm.kind)) {
      CapsuleSelect({
        label: this.periodLabel(this.vm.period),
        options: this.periodLabels(),
        selectedIndex: this.periodSelectedIndex(),
        compact: this.isInlineHeader(),
        onSelect: (index: number): void => {
          const target: string = RANK_PERIOD_VALUES[index] ?? RANK_PERIOD_VALUES[0];
          this.vm.setPeriod(target);
        }
      })
    }
  }

  build() {
    HdsNavDestination() {
      StandardPageScaffold({
        title: $r('app.string.rank_title'),
        inlineHeaderCenter: this.isInlineHeader(),
        showHeaderBottom: !this.isInlineHeader(),
        isLoading: this.vm.isLoading,
        hasContent: this.vm.items.length > 0,
        isEmpty: this.vm.isEmpty,
        errorMessage: this.vm.errorMessage,
        emptyIcon: $r('sys.symbol.doc_plaintext'),
        emptyTitle: $r('app.string.rank_empty'),
        emptyMessage: this.lm.getString($r('app.string.rank_empty_desc'), ''),
        showSecondaryAction: this.vm.needsLogin,
        secondaryActionText: this.lm.getString($r('app.string.profile_login'), ''),
        onRetry: (): void => {
          this.vm.retry();
        },
        onSecondaryAction: (): void => {
          this.pageStack.pushPathByName(ROUTE_LOGIN, null);
        },
        onWidthMeasured: (w: number): void => {
          this.containerWidth = w;
          this.syncViewport();
        },
        headerCenter: () => {
          if (this.isInlineHeader()) {
            this.InlineKindHeader()
          }
        },
        rightAction: () => {
          this.InlinePeriodHeader()
        },
        headerBottom: () => {
          if (!this.isInlineHeader()) {
            this.RankHeaderBottom()
          }
        },
        content: () => {
          this.RankContent()
        }
      })
    }
    .withTheme({ enableThemeColorMode: true })
    .hideTitleBar(true)
    .backgroundColor(ThemeColors.BG)
    .onShown(() => {
      this.onPageRevealed();
    })
    .onHidden(() => {
      // Phase 14-T2：被其它 Navigation 页面覆盖时立即退订，避免隐藏页继续监听分级广播
      this.ratingBridge.stop();
    })
  }


  @Builder
  KindTabs() {
    Column() {
      SegmentSelector({
        labels: this.kindLabels(),
        selectedIndex: this.kindSelectedIndex(),
        onSelect: (index: number): void => {
          this.onKindSelect(index);
        }
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 10 })
  }
}

export const RANK_LAYER_COUNT: number = 2;

export function rankHasPeriodSelector(kind: string): boolean {
  return rankKindSupportsPeriod(kind);
}

export interface RankRoutePayload {
  kind?: string;
  rankType?: string;
  period?: string;
}

/** 系统路由表构建函数：与 route_map.json 的 "RankPageBuilder" 对应。 */
@Builder
export function RankPageBuilder(name: string, param?: object) {
  RankPage({
    initialKind: resolveRankInitialKind(param),
    initialPeriod: resolveRankInitialPeriod(param)
  })
}

function normalizeRankTypeToken(raw: string): string {
  const token: string = raw.trim().toLowerCase();
  if (token === 'read' || token === 'reading') {
    return RANK_KIND_READING;
  }
  if (token === 'like' || token === 'fav' || token === 'favorite') {
    return RANK_KIND_FAVORITE;
  }
  if (token === 'quality' || token === 'proportion') {
    return RANK_KIND_QUALITY;
  }
  return raw;
}

/** 参数收窄：支持 RankPageParam 及 { rankType, period } 对象。 */
export function resolveRankInitialKind(param?: object): string {
  if (param === undefined || param === null) {
    return '';
  }
  if (param instanceof RankPageParam) {
    return normalizeRankTypeToken(param.kind);
  }
  const payload: RankRoutePayload = param as RankRoutePayload;
  if (typeof payload.kind === 'string' && payload.kind !== '') {
    return normalizeRankTypeToken(payload.kind);
  }
  if (typeof payload.rankType === 'string' && payload.rankType !== '') {
    return normalizeRankTypeToken(payload.rankType);
  }
  return '';
}

export function resolveRankInitialPeriod(param?: object): string {
  if (param === undefined || param === null) {
    return '';
  }
  if (param instanceof RankPageParam) {
    return param.period;
  }
  const payload: RankRoutePayload = param as RankRoutePayload;
  if (typeof payload.period === 'string') {
    return payload.period;
  }
  return '';
}
