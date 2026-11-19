import { HdsNavDestination } from '@kit.UIDesignKit';
/**
 * SectionListPage.ets —— 首页区块「更多」完整列表页（Phase 14-J3 + StandardPageScaffold 迁移）
 *
 * 用途：首页 readDay / favDay / fs / proportion 四个区块的「更多」入口。
 */
import { Comic } from '../model/Comic';
import { SectionListParam } from '../model/NavParams';
import { ComicCardView } from '../components/ComicCardView';
import { StandardPageScaffold } from '../components/StandardPageScaffold';
import { ViewportState } from '../utils/ViewportState';
import { ResponsiveLayoutMetrics, resolveLayoutPolicy } from '../responsive/LayoutPolicy';
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import {
  computeColumns,
  buildColumnsTemplate,
  computeTileWidth,
  computeCoverHeight
} from '../utils/ResponsiveGrid';
import { Logger } from '../utils/Logger';
import { STABLE_COVER_FALLBACK_HEIGHT } from '../utils/StableLayout';
import { prefetchComicsAround, cancelPrefetch } from '../utils/ImagePrefetch';

const TAG: string = 'SectionListPage';

@ComponentV2
export struct SectionListPage {
  /** 全局路由栈：与 Index 的 @Provider('pageStack') 配对 */
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  /** 区块标题（由路由参数带入，空串时降级为通用标题） */
  @Param title: string = '';
  /** 区块内容（服务端顺序，原样渲染） */
  @Param comics: Comic[] = [];
  /** 统一响应式布局策略 */
  @Local layout: ResponsiveLayoutMetrics = ViewportState.getInstance().getLayoutPolicy();
  /** 容器实测宽度（vp；0 = 尚未测出） */
  @Local containerWidth: number = 0;
  /** 当前列数 */
  @Local columns: number = ViewportState.getInstance().getLayoutPolicy().gridColumns;
  /** 卡片封面高度 */
  @Local coverHeight: number = ViewportState.getInstance().getLayoutPolicy().coverHeightVp;
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

  aboutToAppear(): void {
    this.syncViewport();
    ViewportState.getInstance().addListener(this.syncViewport);
    Logger.info(TAG, `打开区块列表 title=${this.title} count=${this.comics.length}`);
  }

  aboutToDisappear(): void {
    ViewportState.getInstance().removeListener(this.syncViewport);
    cancelPrefetch('section');
  }

  /** 标题文案：路由参数为空时用通用占位，不臆造榜单名称 */
  private titleText(): string {
    return this.title === '' ? '全部内容' : this.title;
  }

  @Builder
  SectionGrid() {
    Grid() {
      // 条数有限（服务端单次返回的榜单长度），ForEach 足够；无需 LazyForEach
      ForEach(this.comics, (item: Comic, index: number) => {
        GridItem() {
          ComicCardView({ comic: item, coverHeight: this.coverHeight })
        }
        .onAppear(() => {
          prefetchComicsAround(this.comics, index, 'section');
        })
      }, (item: Comic) => item.id)
    }
    .columnsTemplate(this.layout.gridColumnsTemplate)
    .columnsGap(this.layout.gridGapVp)
    .rowsGap(this.layout.gridGapVp)
    .cachedCount(6)
    .padding({
      left: this.layout.pagePaddingVp,
      right: this.layout.pagePaddingVp,
      top: 8,
      bottom: 16 + ViewportState.getInstance().bottomVp
    })
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  build() {
    HdsNavDestination() {
      StandardPageScaffold({
        title: this.titleText(),
        isLoading: false,
        hasContent: this.comics.length > 0,
        isEmpty: this.comics.length === 0,
        emptyIcon: $r('sys.symbol.doc_plaintext'),
        emptyTitle: '该区块暂无内容',
        emptyMessage: '返回首页稍后重试',
        onWidthMeasured: (w: number): void => {
          this.containerWidth = w;
          this.syncViewport();
        },
        content: () => {
          this.SectionGrid()
        }
      })
    }
    .withTheme({ enableThemeColorMode: true })
    .hideTitleBar(true)
    .backgroundColor(ThemeColors.BG)
  }
}

/**
 * 系统路由表构建函数：与 route_map.json 的 "SectionListPageBuilder" 对应。
 * 参数为 SectionListParam；用 instanceof 收窄，脏参数（null / 其它类型）退化为空列表。
 * 说明：@Builder 内只能写 UI 语法，因此取值逻辑放在文件级函数里。
 */
@Builder
export function SectionListPageBuilder(name: string, param?: object) {
  SectionListPage({
    title: sectionTitleOf(param),
    comics: sectionComicsOf(param)
  })
}

/** 从路由参数中安全取出区块标题 */
function sectionTitleOf(param?: object): string {
  if (param !== undefined && param !== null && param instanceof SectionListParam) {
    return param.title;
  }
  return '';
}

/** 从路由参数中安全取出区块内容（保持服务端顺序） */
function sectionComicsOf(param?: object): Comic[] {
  if (param !== undefined && param !== null && param instanceof SectionListParam) {
    return param.comics;
  }
  return [];
}
