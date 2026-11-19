import { HdsNavDestination } from '@kit.UIDesignKit';
/**
 * PersonalizedPage.ets —— 个人化精选页（Phase 14-Q 正式接入 + StandardPageScaffold 迁移）
 *
 * 数据：POST /api/favoritesrecommend { page } → { status, info: Book[], len }，每页 20。
 */
import { Comic } from '../model/Comic';
import { ROUTE_LOGIN } from '../model/ProfileMenu';
import { RecommendViewModel } from '../viewmodel/RecommendViewModel';
import { PaginationBar } from '../components/PaginationBar';
import { ComicListItem } from '../components/ComicListItem';
import { StandardPageScaffold } from '../components/StandardPageScaffold';
import { ViewportState } from '../utils/ViewportState';
import { ResponsiveLayoutMetrics, resolveLayoutPolicy } from '../responsive/LayoutPolicy';
import { paginationFloatingInsetVp } from '../utils/Pagination';
import { LocalizationManager } from '../utils/LocalizationManager';
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import { prefetchComicsAround, cancelPrefetch } from '../utils/ImagePrefetch';
import { BlockedTagManager } from '../utils/BlockedTagManager';
import { RatingBridge } from '../utils/RatingBridge';

@ComponentV2
export struct PersonalizedPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local vm: RecommendViewModel = new RecommendViewModel();
  @Local containerWidth: number = 0;
  @Local layout: ResponsiveLayoutMetrics = ViewportState.getInstance().getLayoutPolicy();
  private lm: LocalizationManager = LocalizationManager.getInstance();
  private readonly syncViewport = (): void => {
    const vp: ViewportState = ViewportState.getInstance();
    const targetW: number = this.containerWidth > 0 ? this.containerWidth : vp.widthVp;
    this.layout = resolveLayoutPolicy(targetW, vp.isLandscape());
  };

  /** 上次渲染时的屏蔽标签版本：返回页面时若变化则回到第一页重载（Phase 14-R） */
  private blockedRevision: number = 0;
  /** 内容分级变化订阅（Phase 14-T）：被设置页覆盖时仍生效，广播即按新分级重取 */
  private ratingBridge: RatingBridge = new RatingBridge((): void => {
    this.vm.refreshForRating();
  });

  // 说明：`onPageShow` 只对 @Entry 页面有效，NavDestination 页面不会被调用，
  // 「返回页面」的处理统一收敛到 `onPageRevealed()`（由 NavDestination.onShown 触发）。

  aboutToAppear(): void {
    this.syncViewport();
    ViewportState.getInstance().addListener(this.syncViewport);
    this.ratingBridge.start();
    // 记录进入页面时的黑名单版本，避免首次触发时重复加载
    this.blockedRevision = BlockedTagManager.getInstance().revision;
    if (!this.vm.reloadIfRatingChanged()) {
      this.vm.load(true);
    }
  }

  aboutToDisappear(): void {
    ViewportState.getInstance().removeListener(this.syncViewport);
    this.ratingBridge.stop();
    cancelPrefetch('recommend');
  }

  /** 页面重新可见（Phase 14-T 兜底）：分级或屏蔽标签变化时回到第 1 页重载 */
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

  private prefetchItems(index: number): void {
    prefetchComicsAround(this.vm.items, index, 'recommend');
  }


  build() {
    HdsNavDestination() {
      StandardPageScaffold({
        title: $r('app.string.personalized_title'),
        isLoading: this.vm.isLoading,
        hasContent: this.vm.items.length > 0,
        isEmpty: this.vm.isEmpty,
        errorMessage: this.vm.errorMessage,
        emptyIcon: $r('sys.symbol.doc_plaintext'),
        emptyTitle: $r('app.string.recommend_empty_title'),
        emptyMessage: this.lm.getString($r('app.string.recommend_empty_desc'), ''),
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
        content: () => {
          this.RecommendList()
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
  RecommendList() {
    Stack({ alignContent: Alignment.Bottom }) {
      List({ space: ThemeDims.SPACE_S }) {
        ForEach(this.vm.items, (item: Comic, index: number) => {
          ListItem() {
            ComicListItem({ comic: item, coverWidth: ThemeDims.LIST_COVER_WIDTH })
          }
          .onAppear(() => {
            this.prefetchItems(index);
          })
        }, (item: Comic) => item.id)
      }
      .lanes(this.layout.listLanes, this.layout.listGutterVp)
      .padding({ left: this.layout.pagePaddingVp, right: this.layout.pagePaddingVp, top: 6 })
      .width('100%')
      .height('100%')
      .contentEndOffset(paginationFloatingInsetVp(this.vm.totalPages > 0, ViewportState.getInstance().bottomVp))
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
          compact: this.layout.listLanes >= 2 || this.containerWidth >= 600,
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

}

/** 系统路由表构建函数：与 route_map.json 的 "PersonalizedPageBuilder" 对应。 */
@Builder
export function PersonalizedPageBuilder(name: string, param?: object) {
  PersonalizedPage()
}
