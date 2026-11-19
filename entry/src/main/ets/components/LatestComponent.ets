/**
 * LatestComponent.ets —— 最新页（Tab 内容 · Phase 14-H 新增）
 *
 * 对齐原版 R3 最新页：标题「最新」+ 右上角筛选入口 + 横向可滚动排序页签（选中带下划线）+
 * 单列列表项（ComicListItem）+ 分页加载 + 下拉刷新。
 *
 * 排序 / 筛选只暴露审计已记录的值：
 * - 排序：最新(new) / 最多浏览(views) / 最多收藏(favorites) / 最高评分(rating)；
 *   「最近上传」无对应 sort 值 → 不显示（列入报告缺失）。
 * - 筛选：全部('') / 已完结(true) / 连载中(false)。
 */
import { Comic } from '../model/Comic';
import { HomeViewModel } from '../viewmodel/HomeViewModel';
import { ComicListItem } from './ComicListItem';
import { CapsuleSelect } from './CapsuleSelect';
import { SegmentSelector } from './SegmentSelector';
import { ErrorState, LoadingState } from './StatusViews';
import { SafeAreaManager } from '../utils/SafeAreaManager';
import { ViewportState } from '../utils/ViewportState';
import { ResponsiveLayoutMetrics, resolveLayoutPolicy } from '../responsive/LayoutPolicy';
import { mainTabBottomClearanceVp } from '../utils/BottomInset';
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import { prefetchComicsAround, cancelPrefetch } from '../utils/ImagePrefetch';
import { ContentRatingPolicy } from '../utils/ContentRatingPolicy';
import { LocalizationManager, EffectiveLocale } from '../utils/LocalizationManager';
import {
  BOOKLIST_SORT_NEW,
  BOOKLIST_SORT_VIEWS,
  BOOKLIST_SORT_FAVORITES,
  BOOKLIST_SORT_RATING,
  BOOKLIST_FINISHED_ALL,
  BOOKLIST_FINISHED_COMPLETED,
  BOOKLIST_FINISHED_ONGOING
} from '../source/NoyAcgProtocol';

const TAG: string = 'LatestComponent';

/** 排序选项（label/value 与审计 booklist sort 参数一一对应） */
interface SortOption {
  label: string;
  value: string;
}

const SORT_OPTIONS: SortOption[] = [
  { label: '最新', value: BOOKLIST_SORT_NEW },
  { label: '最多浏览', value: BOOKLIST_SORT_VIEWS },
  { label: '最多收藏', value: BOOKLIST_SORT_FAVORITES },
  { label: '最高评分', value: BOOKLIST_SORT_RATING }
];

/** 完结筛选选项（label/value） */
interface FinishedOption {
  label: string;
  value: string;
}

const FINISHED_OPTIONS: FinishedOption[] = [
  { label: '全部', value: BOOKLIST_FINISHED_ALL },
  { label: '连载中', value: BOOKLIST_FINISHED_ONGOING },
  { label: '已完结', value: BOOKLIST_FINISHED_COMPLETED }
];

export const LATEST_FINISHED_LABELS: string[] = ['全部', '连载中', '已完结'];

export function latestSortLabels(locale: EffectiveLocale): string[] {
  if (locale === 'en-US') {
    return ['Newest', 'Viewed', 'Liked', 'Rated'];
  }
  if (locale === 'zh-TW') {
    return ['最新', '最多瀏覽', '最多收藏', '最高評分'];
  }
  return ['最新', '最多浏览', '最多收藏', '最高评分'];
}

export function latestFinishedLabels(locale: EffectiveLocale): string[] {
  if (locale === 'en-US') {
    return ['All', 'Ongoing', 'Completed'];
  }
  if (locale === 'zh-TW') {
    return ['全部', '連載中', '已完結'];
  }
  return LATEST_FINISHED_LABELS;
}

@ComponentV2
export struct LatestComponent {
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();
  /** 全局路由栈 */
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  /** 各排序栏位独立视图模型（保留各自数据与滚动位置，支持 Swiper 左右滑动切换） */
  @Local tabVms: HomeViewModel[] = [
    new HomeViewModel(),
    new HomeViewModel(),
    new HomeViewModel(),
    new HomeViewModel()
  ];
  /** 状态栏高度 */
  @Local statusBarHeight: number = 36;
  /** 当前排序下标 */
  @Local sortIndex: number = 0;
  /** 当前筛选下标（0=全部 1=已完结 2=连载中） */
  @Local finishedIndex: number = 0;
  /** 容器实测宽度（vp） */
  @Local containerWidth: number = 0;
  /** 统一响应式布局策略 */
  @Local layout: ResponsiveLayoutMetrics = ViewportState.getInstance().getLayoutPolicy();
  /** 横向分段 Swiper 控制器 */
  private readonly swiperController: SwiperController = new SwiperController();
  private readonly syncViewport = (): void => {
    const vp: ViewportState = ViewportState.getInstance();
    const targetW: number = this.containerWidth > 0 ? this.containerWidth : vp.widthVp;
    this.layout = resolveLayoutPolicy(targetW, vp.isLandscape());
  };
  /**
   * 本 Tab 是否为当前活动 Tab（由 Index 注入，Phase 14-T2）。
   * 非活动时停止分级订阅，避免被保留的隐藏 Tab 继续发请求；切回时恢复订阅并检查 revision。
   */
  @Param active: boolean = true;
  /** 当前根页是否处于 Navigation 栈顶（由 Index 注入） */
  @Param isTopRoute: boolean = true;
  @Local private ratingPolicy: ContentRatingPolicy = ContentRatingPolicy.getInstance();

  private activeVm(): HomeViewModel {
    return this.tabVms[this.sortIndex];
  }

  private activateSortTab(index: number): void {
    if (index < 0 || index >= this.tabVms.length) {
      return;
    }
    const vm: HomeViewModel = this.tabVms[index];
    const sortVal: string = SORT_OPTIONS[index].value;
    const finishedVal: string = FINISHED_OPTIONS[this.finishedIndex].value;
    if (vm.committedRatingRevision !== this.ratingPolicy.revision && vm.currentPage > 0) {
      vm.sort = sortVal;
      vm.finished = finishedVal;
      vm.reloadAllSections('SILENT_SYNC', false);
      return;
    }
    vm.ensureLatestTabLoaded(sortVal, finishedVal);
  }

  /** 内容末尾留白（公式唯一来源 utils/BottomInset.mainTabBottomClearanceVp） */
  private navEndInset(): number {
    const vp: ViewportState = ViewportState.getInstance();
    return mainTabBottomClearanceVp(ThemeDims.BOTTOM_BAR_HEIGHT, vp.isBottomNav(), vp.bottomVp);
  }

  /** 当最新页处于前台可见态（active && isTopRoute）且分级版本号落后时，静默重载所有已加载栏位 */
  @Monitor('active', 'isTopRoute', 'ratingPolicy.revision')
  onVisibilityOrRatingChanged(): void {
    if (!this.active || !this.isTopRoute) {
      return;
    }
    for (let i = 0; i < this.tabVms.length; i++) {
      const vm: HomeViewModel = this.tabVms[i];
      if ((i === this.sortIndex || vm.currentPage > 0) &&
        vm.committedRatingRevision !== this.ratingPolicy.revision) {
        vm.reloadAllSections('SILENT_SYNC', false);
      }
    }
  }

  aboutToAppear(): void {
    this.syncViewport();
    ViewportState.getInstance().addListener(this.syncViewport);
    this.activateSortTab(this.sortIndex);
    SafeAreaManager.getStatusBarHeight().then((height: number) => {
      this.statusBarHeight = height;
    });
  }

  aboutToDisappear(): void {
    ViewportState.getInstance().removeListener(this.syncViewport);
    cancelPrefetch('latest');
    for (let i = 0; i < this.tabVms.length; i++) {
      this.tabVms[i].dispose();
    }
  }

  /** 当前筛选文案（用于右上角入口显示） */
  private finishedLabel(): string {
    const labels: string[] = latestFinishedLabels(this.lm.effectiveLocale);
    return labels[this.finishedIndex] ?? labels[0];
  }

  build() {
    Column() {
      this.LatestHeader()
      this.SortTabs()

      Swiper(this.swiperController) {
        ForEach(SORT_OPTIONS, (opt: SortOption, index: number) => {
          this.SortTabPage(this.tabVms[index])
        }, (opt: SortOption) => opt.value)
      }
      .index(this.sortIndex)
      .loop(false)
      .indicator(false)
      .duration(220)
      .curve(Curve.FastOutSlowIn)
      .cachedCount(1)
      .layoutWeight(1)
      .width('100%')
      .onChange((index: number) => {
        if (index !== this.sortIndex) {
          this.sortIndex = index;
          this.activateSortTab(index);
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeColors.BG)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const w: number = Number(newValue.width);
      if (!Number.isFinite(w) || w <= 0 || Math.abs(w - this.containerWidth) < 1) {
        return;
      }
      this.containerWidth = w;
      this.syncViewport();
    })
  }

  @Builder
  SortTabPage(vm: HomeViewModel) {
    Refresh({ refreshing: vm.isManualRefreshing!! }) {
      Stack() {
        this.LatestList(vm)
        if (vm.isEmpty && vm.errorMessage !== '') {
          ErrorState({
            message: vm.errorMessage,
            retry: (): void => {
              vm.loadData(true);
            },
            showSecondary: vm.needsLogin,
            secondaryText: this.lm.getString($r('app.string.common_go_login'), '去登录'),
            secondary: (): void => {
              this.pageStack.pushPathByName('LoginPage', null);
            }
          })
        } else if (vm.isEmpty) {
          LoadingState()
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .onRefreshing(() => {
      vm.onPullToRefresh(false);
    })
    .width('100%')
    .height('100%')
  }

  /** 标题栏：统一 52vp 高 + 16vp 水平边距 + 弹出式胶囊筛选 */
  @Builder
  LatestHeader() {
    Row({ space: ThemeDims.SPACE_M }) {
      Text($r('app.string.latest_title'))
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.TEXT_STRONG)
      Blank()
      CapsuleSelect({
        label: this.finishedLabel(),
        options: latestFinishedLabels(this.lm.effectiveLocale),
        selectedIndex: this.finishedIndex,
        onSelect: (index: number): void => {
          this.finishedIndex = index;
          this.activeVm().setFinished(FINISHED_OPTIONS[index].value);
        }
      })
    }
    .width('100%')
    .height(this.statusBarHeight + 52)
    .alignItems(VerticalAlign.Center)
    .padding({
      left: 16,
      right: 16,
      top: this.statusBarHeight
    })
  }

  private sortLabels(): string[] {
    return latestSortLabels(this.lm.effectiveLocale);
  }

  /** 排序分段胶囊：全仓统一 SegmentSelector 规范 */
  @Builder
  SortTabs() {
    Column() {
      SegmentSelector({
        labels: this.sortLabels(),
        selectedIndex: this.sortIndex,
        onSelect: (index: number): void => {
          if (index === this.sortIndex) {
            return;
          }
          this.sortIndex = index;
          this.swiperController.changeIndex(index, true);
          this.activateSortTab(index);
        }
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 10 })
  }

  /** 单列列表（懒加载 + 触底加载更多 + 底部加载指示） */
  @Builder
  LatestList(vm: HomeViewModel) {
    Column() {
      List({ space: 10 }) {
        LazyForEach(vm.comicDataSource, (item: Comic, index: number) => {
          ListItem() {
            ComicListItem({ comic: item })
          }
          .onAppear(() => {
            prefetchComicsAround(vm.comicDataSource.getDataArray(), index, 'latest');
          })
        }, (item: Comic) => item.id)
      }
      .lanes(this.layout.listLanes, this.layout.listGutterVp)
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .cachedCount(ThemeDims.LIST_CACHED_COUNT)
      .padding({ left: 16, right: 16 })
      // Phase 15-R2：末尾留白 = 悬浮栏高度 + 栏底边距 + 系统避让（侧栏形态只留系统避让）
      .contentEndOffset(this.navEndInset())
      .onReachEnd(() => {
        vm.loadData(false);
      })

      if (vm.isLoading) {
        Row({ space: ThemeDims.SPACE_M }) {
          LoadingProgress()
            .width(20)
            .height(20)
            .color(ThemeColors.PRIMARY)
          Text('加载中...')
            .fontSize(ThemeFonts.BODY_SMALL)
            .fontColor(ThemeColors.TEXT_SECONDARY)
        }
        .width('100%')
        .height(44)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
  }
}
