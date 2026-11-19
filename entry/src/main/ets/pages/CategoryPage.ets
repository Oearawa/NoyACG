import { HdsNavDestination } from '@kit.UIDesignKit';
/**
 * CategoryPage.ets —— 分类网格页（Phase 14-Q 接入官方分类目录 + StandardPageScaffold 迁移）
 *
 * 数据：POST /api/bigtaglist（空表单）→ { status, data: [{tag, search, cover}] }。
 * - `tag`    显示名（原样保留，不做繁简转换）
 * - `search` 搜索标签数组；点击时 `search.join(' ') || tag`
 * - `cover`  代表漫画 Bid，封面经统一 URL 工具生成 `img.noymanga.com/{bid}/m1.webp`
 */
import { BigTagItem } from '../model/LeaderboardModels';
import { ROUTE_LOGIN } from '../model/ProfileMenu';
import { ROUTE_SEARCH } from '../model/DiscoveryRoutes';
import { BigTagViewModel } from '../viewmodel/BigTagViewModel';
import { MangaImage } from '../components/MangaImage';
import { StandardPageScaffold } from '../components/StandardPageScaffold';
import { ViewportState } from '../utils/ViewportState';
import { ResponsiveLayoutMetrics, resolveLayoutPolicy } from '../responsive/LayoutPolicy';
import { LocalizationManager } from '../utils/LocalizationManager';
import { curves } from '@kit.ArkUI';
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import { ThemeManager } from '../utils/ThemeManager';
import { SPATIAL_PRESS_SCALE, resolvePanelMaterialTokens } from '../utils/MaterialPolicy';
import {
  computeColumns,
  buildColumnsTemplate,
  computeTileWidth,
  computeCoverHeight
} from '../utils/ResponsiveGrid';
import { prefetchUrlsAround, cancelPrefetch } from '../utils/ImagePrefetch';
import { ImageCacheManager } from '../utils/ImageCacheManager';
import { RatingBridge } from '../utils/RatingBridge';

const CATEGORY_MIN_COLUMNS: number = 3;
const CATEGORY_MAX_COLUMNS: number = 4;
const CATEGORY_MIN_CARD_WIDTH: number = 100;

@ComponentV2
export struct CategoryPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local vm: BigTagViewModel = new BigTagViewModel();
  @Local containerWidth: number = 0;
  @Local layout: ResponsiveLayoutMetrics = ViewportState.getInstance().getLayoutPolicy();
  @Local columns: number = ViewportState.getInstance().getLayoutPolicy().gridColumns;
  @Local cardHeight: number = ViewportState.getInstance().getLayoutPolicy().coverHeightVp;
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private pressedTag: string = '';
  private lm: LocalizationManager = LocalizationManager.getInstance();
  private readonly syncViewport = (): void => {
    const vp: ViewportState = ViewportState.getInstance();
    const targetW: number = this.containerWidth > 0 ? this.containerWidth : vp.widthVp;
    const metrics: ResponsiveLayoutMetrics = resolveLayoutPolicy(targetW, vp.isLandscape());
    this.layout = metrics;
    if (metrics.gridColumns !== this.columns) {
      this.columns = metrics.gridColumns;
    }
    if (Math.abs(metrics.coverHeightVp - this.cardHeight) >= 0.01) {
      this.cardHeight = metrics.coverHeightVp;
    }
  };

  /** 内容分级变化订阅（Phase 14-T）：分类目录本身随分级变化，广播即重取 */
  private ratingBridge: RatingBridge = new RatingBridge((): void => {
    this.vm.refreshForRating();
  });

  aboutToAppear(): void {
    this.syncViewport();
    ViewportState.getInstance().addListener(this.syncViewport);
    this.ratingBridge.start();
    if (!this.vm.reloadIfRatingChanged()) {
      this.vm.load();
    }
  }

  aboutToDisappear(): void {
    ViewportState.getInstance().removeListener(this.syncViewport);
    this.ratingBridge.stop();
    cancelPrefetch('category');
  }

  /** 页面重新可见（Phase 14-T 兜底）：分级在离开期间变化过则重取目录 */
  private onPageRevealed(): void {
    this.ratingBridge.start();
    this.vm.reloadIfRatingChanged();
  }

  private prefetchCategory(index: number): void {
    const len: number = this.vm.items.length;
    if (index < 0 || index >= len) {
      return;
    }
    const start: number = Math.max(0, index - ThemeDims.PREFETCH_RADIUS);
    const end: number = Math.min(len - 1, index + ThemeDims.PREFETCH_RADIUS);
    const urls: string[] = [];
    for (let i = start; i <= end; i++) {
      const cover: string = this.vm.items[i].cover;
      if (cover !== '' && !cover.startsWith('file://')) {
        urls.push(cover);
      }
    }
    if (urls.length > 0) {
      ImageCacheManager.getInstance().prefetch(urls, 'category', ThemeDims.PREFETCH_MAX_CONCURRENCY);
    }
  }

  private openCategory(item: BigTagItem): void {
    const query: string = this.vm.queryFor(item);
    if (query === '') {
      return; // 无可用搜索值的卡片不跳转，避免打开空白搜索页
    }
    this.pageStack.pushPathByName(ROUTE_SEARCH, this.vm.searchParamFor(item));
  }


  build() {
    HdsNavDestination() {
      StandardPageScaffold({
        title: $r('app.string.category_title'),
        isLoading: this.vm.isLoading,
        hasContent: this.vm.items.length > 0,
        isEmpty: this.vm.items.length === 0,
        errorMessage: this.vm.errorMessage,
        emptyIcon: $r('sys.symbol.doc_plaintext'),
        emptyTitle: $r('app.string.category_empty'),
        emptyMessage: this.lm.getString($r('app.string.category_empty_hint'), ''),
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
          this.CategoryGrid()
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
      cancelPrefetch('category');
    })
  }

  @Builder
  CategoryGrid() {
    Grid() {
      ForEach(this.vm.items, (item: BigTagItem, index: number) => {
        GridItem() {
          this.CategoryCard(item)
        }
        .onAppear(() => {
          this.prefetchCategory(index);
        })
      }, (item: BigTagItem) => `${item.tag}#${item.coverBid}`)
    }
    .columnsTemplate(this.layout.gridColumnsTemplate)
    .columnsGap(this.layout.gridGapVp)
    .rowsGap(this.layout.gridGapVp)
    .cachedCount(6)
    .padding({
      left: this.layout.pagePaddingVp,
      right: this.layout.pagePaddingVp,
      top: 8,
      bottom: ThemeDims.SPACE_L + ViewportState.getInstance().bottomVp
    })
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }


  @Builder
  CategoryCard(item: BigTagItem) {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (item.hasCover) {
        MangaImage({ imageUrl: item.cover, coverFill: true, diagLabel: item.tag })
          .width('100%')
          .height('100%')
      } else {
        Column() {
          Text($r('app.string.category_placeholder'))
            .fontSize(ThemeFonts.CAPTION)
            .fontColor(ThemeColors.TEXT_MUTED)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(ThemeColors.SURFACE)
      }

      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [
            [ThemeColors.SCRIM_FROM, 0.0],
            [ThemeColors.SCRIM_TO, 1.0]
          ]
        })

      Text(item.tag)
        .fontSize(ThemeFonts.BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemeColors.ON_COVER)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 10, right: 10, bottom: 10 })
    }
    .width('100%')
    .aspectRatio(0.75)
    .borderRadius(12)
    .border({
      width: 1,
      color: resolvePanelMaterialTokens(this.theme.isDark).borderColor
    })
    .clip(true)
    .backgroundColor(ThemeColors.SURFACE)
    .scale({
      x: this.pressedTag === item.tag ? SPATIAL_PRESS_SCALE : 1.0,
      y: this.pressedTag === item.tag ? SPATIAL_PRESS_SCALE : 1.0
    })
    .animation({ curve: curves.springMotion(0.24, 0.82) })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressedTag = item.tag;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressedTag = '';
      }
    })
    .onClick(() => {
      this.openCategory(item);
    })
  }
}

/** 系统路由表构建函数：与 route_map.json 的 "CategoryPageBuilder" 对应。 */
@Builder
export function CategoryPageBuilder(name: string, param?: object) {
  CategoryPage()
}
