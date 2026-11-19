/**
 * ShelfComponent.ets —— 收藏页（账号收藏 / 本地收藏，Phase 14-J2）
 *
 * 结构：
 *   标题栏（收藏 + 计数）
 *   分段选择器（账号收藏 / 本地收藏）
 *   列表（Grid + LazyForEach + ComicCardView，与首页一致）
 *
 * - 登录用户默认「账号收藏」（只读接口 /api/v4/favorites/get），游客默认「本地收藏」；
 * - 账号收藏支持下拉刷新 / 触底分页 / 空态 / 错误 / 登录失效；
 * - 本地收藏保持原有本地数据库逻辑，两套数据严格区分、互不写入。
 */
import { Comic } from '../model/Comic';
import { ShelfViewModel, SHELF_SOURCE_ACCOUNT } from '../viewmodel/ShelfViewModel';
import { ComicCardView } from './ComicCardView';
import { SegmentSelector } from './SegmentSelector';
import { LoadingState, EmptyState } from './StatusViews';
import { SafeAreaManager } from '../utils/SafeAreaManager';
import { ViewportState } from '../utils/ViewportState';
import { ResponsiveLayoutMetrics, resolveLayoutPolicy } from '../responsive/LayoutPolicy';
import { mainTabBottomClearanceVp, normalizeAvoid } from '../utils/BottomInset';
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import {
  computeColumns,
  buildColumnsTemplate,
  computeTileWidth,
  computeCoverHeight,
} from '../utils/ResponsiveGrid';
import { Logger } from '../utils/Logger';
import { STABLE_COVER_FALLBACK_HEIGHT } from '../utils/StableLayout';
import { prefetchComicsAround, cancelPrefetch } from '../utils/ImagePrefetch';
import { RatingBridge } from '../utils/RatingBridge';
import { LocalizationManager } from '../utils/LocalizationManager';

const TAG: string = 'ShelfComponent';

@ComponentV2
export struct ShelfComponent {
  /** 视图模型（Index 注入，跨组件共享同一实例） */
  @Require @Param vm: ShelfViewModel;
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();
  /** 全局路由栈（账号收藏未登录时跳登录） */
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  /** 状态栏高度（安全区避让） */
  @Local statusBarHeight: number = 36;
  /** 统一响应式布局策略 */
  @Local layout: ResponsiveLayoutMetrics = ViewportState.getInstance().getLayoutPolicy();
  /** 容器实测宽度（vp；0 = 尚未测出） */
  @Local containerWidth: number = 0;
  /** 当前列数 */
  @Local columns: number = ViewportState.getInstance().getLayoutPolicy().gridColumns;
  /** 卡片封面高度（vp） */
  @Local coverHeight: number = ViewportState.getInstance().getLayoutPolicy().coverHeightVp;
  /** 下拉刷新状态 */
  @Local refreshing: boolean = false;
  private readonly shelfSwiperController: SwiperController = new SwiperController();
  private readonly syncViewport = (): void => {
    const vp: ViewportState = ViewportState.getInstance();
    const targetW: number = this.containerWidth > 0 ? this.containerWidth : vp.widthVp;
    const metrics: ResponsiveLayoutMetrics = resolveLayoutPolicy(targetW, vp.isLandscape());
    this.layout = metrics;
    if (metrics.gridColumns !== this.columns) {
      this.columns = metrics.gridColumns;
    }
    if (Math.abs(metrics.coverHeightVp - this.coverHeight) >= 0.01) {
      this.coverHeight = metrics.coverHeightVp;
    }
  };
  /**
   * 本 Tab 是否为当前活动 Tab（由 Index 注入，Phase 14-T2）。
   * 非活动时停止分级订阅，避免被保留的隐藏 Tab 继续发请求；切回时恢复订阅并检查 revision。
   */
  @Param active: boolean = true;
  /** 是否作为独立二级路由页面（ShelfPage）挂载；为 true 时隐藏冗余顶栏并只保留系统底部避让 */
  @Param inSubPage: boolean = false;

  /** 内容末尾留白（公式唯一来源 utils/BottomInset.mainTabBottomClearanceVp） */
  private navEndInset(): number {
    const vp: ViewportState = ViewportState.getInstance();
    if (this.inSubPage) {
      return normalizeAvoid(vp.bottomVp);
    }
    return mainTabBottomClearanceVp(ThemeDims.BOTTOM_BAR_HEIGHT, vp.isBottomNav(), vp.bottomVp);
  }

  /** 内容分级变化订阅（Phase 14-T）：只刷新当前数据源，不动本地收藏/下载/历史 */
  private ratingBridge: RatingBridge = new RatingBridge((): void => {
    this.vm.refreshForRating();
  });

  /** Tab 活动状态变化（Phase 14-T2）：活动 → 订阅并检查 revision；非活动 → 退订 */
  @Monitor('active')
  onActiveChanged(): void {
    if (this.active) {
      this.ratingBridge.start();
      this.vm.reloadIfRatingChanged();
    } else {
      this.ratingBridge.stop();
    }
  }

  aboutToAppear(): void {
    this.syncViewport();
    ViewportState.getInstance().addListener(this.syncViewport);
    if (this.active) {
      this.ratingBridge.start();
    }
    SafeAreaManager.getStatusBarHeight().then((height: number) => {
      this.statusBarHeight = height;
    });
    // 登录 → 账号收藏；游客 → 本地收藏
    // Phase 14-S：先让 VM 检查分级是否变化（变化则自动重载当前数据源）
    this.vm.reloadIfRatingChanged();
    this.vm.initDefaultSource();
  }

  aboutToDisappear(): void {
    ViewportState.getInstance().removeListener(this.syncViewport);
    this.ratingBridge.stop();
    cancelPrefetch('shelf_account');
    cancelPrefetch('shelf_local');
  }

  private isAccount(): boolean {
    return this.vm.activeSource === SHELF_SOURCE_ACCOUNT;
  }

  private onSegment(index: number): void {
    this.vm.setActiveSource(index === 0 ? SHELF_SOURCE_ACCOUNT : 'local');
  }

  private doRefresh(): void {
    this.refreshing = true;
    this.vm.refreshActiveSource().then(() => {
      this.refreshing = false;
    }).catch(() => {
      this.refreshing = false;
    });
  }

  build() {
    Column() {
      if (!this.inSubPage) {
        // 标题栏：统一 52vp 高 + 16vp 水平边距 + 无边框状态胶囊
        Row() {
          Text($r('app.string.shelf_title'))
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.TEXT_STRONG)
          Blank()
          Text(this.isAccount()
            ? this.lm.getString($r('app.string.shelf_count_account'), '账号 %d 部', this.vm.accountDisplayCount())
            : this.lm.getString($r('app.string.shelf_count_local'), '本地 %d 部', this.vm.favoriteList.length))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.TEXT_STRONG)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(ThemeColors.SURFACE)
            .borderRadius(16)
        }
        .width('100%')
        .height(this.statusBarHeight + 52)
        .alignItems(VerticalAlign.Center)
        .padding({ left: 16, right: 16, top: this.statusBarHeight })
      } else {
        Column().width('100%').height(8)
      }

      // 分段：账号收藏 / 本地收藏
      Column() {
        SegmentSelector({
          labels: [
            this.lm.getString($r('app.string.shelf_seg_account'), '账号收藏'),
            this.lm.getString($r('app.string.shelf_seg_local'), '本地收藏')
          ],
          selectedIndex: this.isAccount() ? 0 : 1,
          onSelect: (index: number) => {
            this.shelfSwiperController.changeIndex(index, true);
            this.onSegment(index);
          }
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6, bottom: 10 })

      // 内容：Swiper 左右滑动切换账号收藏 / 本地收藏
      Swiper(this.shelfSwiperController) {
        Column() {
          this.AccountContent()
        }
        .width('100%')
        .height('100%')

        Column() {
          this.LocalContent()
        }
        .width('100%')
        .height('100%')
      }
      .index(this.isAccount() ? 0 : 1)
      .loop(false)
      .indicator(false)
      .duration(220)
      .curve(Curve.FastOutSlowIn)
      .cachedCount(1)
      .layoutWeight(1)
      .width('100%')
      .onChange((index: number) => {
        this.onSegment(index);
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeColors.BG)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const w: number = Number(newValue.width);
      if (!Number.isFinite(w) || w <= 0) {
        return;
      }
      if (Math.abs(w - this.containerWidth) < 1) {
        return;
      }
      this.containerWidth = w;
      this.syncViewport();
      Logger.info(TAG,
        `grid W=${w.toFixed(1)} bp=${this.layout.breakpoint} cols=${this.columns} cardW=${this.layout.cardWidthVp.toFixed(1)} coverH=${this.coverHeight.toFixed(1)}`);
    })
  }

  // ==================== 账号收藏 ====================

  @Builder
  AccountContent() {
    if (this.vm.accountLoading && this.vm.accountList.length === 0) {
      LoadingState()
    } else if (this.vm.accountNeedsLogin) {
      this.LoginPrompt()
    } else if (this.vm.accountError !== '' && this.vm.accountList.length === 0) {
      this.ErrorPrompt(this.vm.accountError)
    } else if (this.vm.accountList.length === 0) {
      EmptyState({
        icon: $r('sys.symbol.bookmark'),
        title: this.lm.getString($r('app.string.shelf_account_empty_title'), '账号暂无收藏'),
        message: this.lm.getString($r('app.string.shelf_account_empty_msg'), '在 NoyAcg 网站收藏的漫画会显示在这里')
      })
    } else {
      Refresh({ refreshing: this.refreshing!! }) {
        Grid() {
          LazyForEach(this.vm.accountDataSource, (item: Comic, index: number) => {
            GridItem() {
              ComicCardView({ comic: item, coverHeight: this.coverHeight })
            }
            .onAppear(() => {
              prefetchComicsAround(this.vm.accountList, index, 'shelf_account');
            })
          }, (item: Comic) => item.id)
        }
        .columnsTemplate(this.layout.gridColumnsTemplate)
        .columnsGap(this.layout.gridGapVp)
        .rowsGap(this.layout.gridGapVp)
        .cachedCount(ThemeDims.LIST_CACHED_COUNT)
        .padding({ left: this.layout.pagePaddingVp, right: this.layout.pagePaddingVp, top: 4, bottom: 12 })
        // Phase 15-R2：末尾留白与悬浮栏同源（侧栏形态只留系统避让）
        .contentEndOffset(this.navEndInset())
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .onReachEnd(() => {
          this.vm.loadMoreAccount();
        })
      }
      .onRefreshing(() => {
        this.doRefresh();
      })
      .layoutWeight(1)
      .width('100%')
    }
  }

  @Builder
  LoginPrompt() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.lock'))
        .fontSize(34)
        .fontColor([ThemeColors.TEXT_MUTED])
      Text($r('app.string.shelf_account_login_prompt'))
        .fontSize(ThemeFonts.BODY)
        .fontColor(ThemeColors.TEXT_SECONDARY)
      Text($r('app.string.common_go_login'))
        .fontSize(ThemeFonts.BODY_SMALL)
        .fontColor(ThemeColors.PRIMARY)
        .padding({ left: 16, right: 16, top: 6, bottom: 6 })
        .borderWidth(1)
        .borderColor(ThemeColors.PRIMARY)
        .borderRadius(14)
        .onClick(() => {
          this.pageStack.pushPathByName('LoginPage', null);
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ErrorPrompt(message: string) {
    Column({ space: 10 }) {
      Text(message)
        .fontSize(ThemeFonts.BODY_SMALL)
        .fontColor(ThemeColors.ERROR)
        .textAlign(TextAlign.Center)
        .maxLines(3)
      Text($r('app.string.common_retry'))
        .fontSize(ThemeFonts.BODY_SMALL)
        .fontColor(ThemeColors.PRIMARY)
        .padding({ left: 16, right: 16, top: 6, bottom: 6 })
        .borderWidth(1)
        .borderColor(ThemeColors.PRIMARY)
        .borderRadius(14)
        .onClick(() => {
          this.vm.loadAccount(true);
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding(24)
  }

  // ==================== 本地收藏 ====================

  @Builder
  LocalContent() {
    if (this.vm.isLoading && this.vm.favoriteList.length === 0) {
      LoadingState()
    } else if (this.vm.favoriteList.length === 0) {
      EmptyState({
        icon: $r('sys.symbol.bookshelf'),
        title: this.lm.getString($r('app.string.shelf_local_empty_title'), '本地暂无收藏'),
        message: this.lm.getString($r('app.string.shelf_local_empty_msg'), '在详情页点亮星标，即可加入本地收藏')
      })
    } else {
      Grid() {
        LazyForEach(this.vm.shelfDataSource, (item: Comic, index: number) => {
          GridItem() {
            ComicCardView({ comic: item, coverHeight: this.coverHeight })
          }
          .onAppear(() => {
            prefetchComicsAround(this.vm.favoriteList, index, 'shelf_local');
          })
        }, (item: Comic) => item.id)
      }
      .columnsTemplate(this.layout.gridColumnsTemplate)
      .columnsGap(this.layout.gridGapVp)
      .rowsGap(this.layout.gridGapVp)
      .cachedCount(ThemeDims.LIST_CACHED_COUNT)
      .padding({ left: this.layout.pagePaddingVp, right: this.layout.pagePaddingVp, top: 4, bottom: 12 })
      // Phase 15-R2：末尾留白与悬浮栏同源（侧栏形态只留系统避让）
      .contentEndOffset(this.navEndInset())
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
  }
}
