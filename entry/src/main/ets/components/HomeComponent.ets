/**
 * HomeComponent.ets —— 主页（分区推荐流 · Phase 14-H 重构 / Phase 14-I 聚合数据 / Phase 14-J2 精简 / Phase 14-J3 交互）
 *
 * 首页内容层级（自上而下）：
 *   标题栏（搜索入口） → 关键词 Chips → 今日阅读榜 readDay
 *   → 今日收藏榜 favDay → 推荐位 fs → 高质量推荐 proportion → 最新推荐书单
 *
 * Phase 14-J2：首页不渲染「动画(stream)」栏目，也不再请求广告接口。
 * Phase 14-J3：四个聚合区块接入可点击「更多」→ SectionListPage（复用 /api/home 已返回的数组，
 *   不新增接口、不伪造分页）；关键词 Chips 可点击 → SearchPage（mode='tag'）。
 * Phase 14-K（广告文案清理）：**首页不再渲染服务端公告条**。
 *   `/api/home` 的 `bulletin.text` 线上内容实为运营广告语（截图为「點擊廣告，救救Noy！」），
 *   渲染在标题下方形成「广告副标题」。现只删除首页渲染节点，`HomeFeed.bulletin` 的模型与解析保留，
 *   接口契约不变，其它模块仍可读取。
 *
 * 说明：本组件树中**不存在任何广告展示节点、广告文案或广告隐藏动画**；
 * `/api/v3/ads` 接口、AdItem 模型与解析器仍完整保留在 source/protocol 层，供其它模块按需调用。
 *
 * MVVM：本组件只做「渲染 + 事件转发」，数据与分页状态在 HomeViewModel。
 * 性能：横向 List + LazyForEach（书单）/ ForEach（聚合榜单，条数有限）+ BasicDataSource。
 */
import { Comic } from '../model/Comic';
import { RankPageParam } from '../model/NavParams';
import {
  HOME_SECTION_READ_DAY,
  HOME_SECTION_FAV_DAY,
  HOME_SECTION_PROPORTION,
  HOME_SECTION_FS,
  homeSectionRankKind,
  homeSectionRankPeriod,
  homeSectionRoute,
  HOME_ROUTE_PERSONALIZED
} from '../model/LeaderboardModels';
import { ROUTE_RANK, ROUTE_PERSONALIZED } from '../model/DiscoveryRoutes';
import { LocalizationManager } from '../utils/LocalizationManager';
import { HomeViewModel } from '../viewmodel/HomeViewModel';
import { ComicPosterCard } from './ComicPosterCard';
import { HomeNavigationEntries } from './HomeNavigationEntries';
import { HomeRankSectionComponent } from './HomeRankSectionComponent';
import { SectionHeader } from './SectionHeader';


import { ErrorState, LoadingState } from './StatusViews';

import { ViewportState } from '../utils/ViewportState';
import { mainTabBottomClearanceVp } from '../utils/BottomInset';
import { compactTopBarTotalHeightVp } from '../utils/TopBarViewport';
import { shouldShowHomeTopEntries, sideRailContentLeftPaddingVp } from '../utils/SideGroupLayout';
import { ThemeColors, ThemeDims } from '../utils/Theme';
import { Logger } from '../utils/Logger';
import { prefetchComicsAround, cancelPrefetch } from '../utils/ImagePrefetch';
import { ContentRatingPolicy } from '../utils/ContentRatingPolicy';

const TAG: string = 'HomeComponent';
const HOME_POSTER_WIDTH_PORTRAIT: number = 132;
export const HOME_FEED_SECTION_ORDER: string[] = ['read_day', 'fav_day', 'quality', 'recommend', 'latest'];
const HOME_POSTER_HEIGHT_PORTRAIT: number = 176;
const HOME_POSTER_WIDTH_LANDSCAPE: number = 144;
const HOME_POSTER_HEIGHT_LANDSCAPE: number = 192;

@ComponentV2
export struct HomeComponent {
  /** 全局路由栈：跳详情 / 搜索 */
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  /** 视图模型 */
  @Local vm: HomeViewModel = new HomeViewModel();
  /** 离散横竖屏状态（旋转全程最多翻转一次，避免连续像素重排） */
  @Local isLandscape: boolean = ViewportState.getInstance().isLandscape();
  /** 离散紧凑顶栏宽度档位（< 380vp） */
  @Local isCompactTopBar: boolean = ViewportState.getInstance().widthVp > 0
    && ViewportState.getInstance().widthVp < 380;
  /** Shared with the root HDS navigation; horizontal lists keep their own controllers. */
  @Param homeScroller: Scroller = new Scroller();
  /** 顶部净空（横屏模式使用；竖屏模式由文档流首项 HomeNavigationEntries 自身避让 topSafeInset） */
  @Param homeTopInset: number = 54;
  /** 是否竖屏底栏形态（true = 在滚动流首部渲染 HomeNavigationEntries；false = 横屏 SIDE 模式） */
  @Param isBottomNav: boolean = true;
  /** 系统顶部状态栏安全区高度（vp） */
  @Param topSafeInset: number = 0;
  /** 当前窗口高度（vp）：用于横屏高度 < 640vp 时将快捷入口收纳到主页首部 */
  @Param windowHeightVp: number = ViewportState.getInstance().heightVp;

  /** 「更多 >」切到最新 Tab（由 Index 注入回调） */
  @Event onMoreLatest: () => void = () => {};
  /**
   * 首页纵向滚动偏移（vp，累计）逐帧上报 Index（p1 Task 1）。
   * 唯一入口：Scroll.onScroll 回调；禁止 onAreaChange 反推。
   */
  @Event onHomeScroll: (yOffset: number) => void = (): void => {};
  /**
   * 本 Tab 是否为当前活动 Tab（由 Index 按 currentTabIndex 注入，Phase 14-T2）。
   * 非活动 Tab 停止分级订阅，避免被 Tabs 保留的隐藏 Tab 继续监听广播并发起请求；
   * 切回活动时恢复订阅并检查 revision。
   */
  @Param active: boolean = true;
  /** 当前根页是否处于 Navigation 栈顶（由 Index 注入） */
  @Param isTopRoute: boolean = true;
  @Local private ratingPolicy: ContentRatingPolicy = ContentRatingPolicy.getInstance();
  private lm: LocalizationManager = LocalizationManager.getInstance();

  /**
   * 内容末尾留白：底栏悬浮高度 64vp + 20vp + 系统避让；侧栏形态下只有系统避让。
   * 公式唯一来源 utils/BottomInset.mainTabBottomClearanceVp。
   */
  private navEndInset(): number {
    const vp: ViewportState = ViewportState.getInstance();
    return mainTabBottomClearanceVp(ThemeDims.BOTTOM_BAR_HEIGHT, vp.isBottomNav(), vp.bottomVp);
  }

  /** 当首页处于前台可见态（active && isTopRoute）且分级版本号落后时，自动静默全量重载 */
  @Monitor('active', 'isTopRoute', 'ratingPolicy.revision')
  onVisibilityOrRatingChanged(): void {
    if (this.active && this.isTopRoute &&
      this.vm.committedRatingRevision !== this.ratingPolicy.revision) {
      this.vm.reloadAllSections('SILENT_SYNC', true);
    }
  }

  private readonly syncViewport = (): void => {
    const vp: ViewportState = ViewportState.getInstance();
    const nextLandscape: boolean = vp.isLandscape();
    if (nextLandscape !== this.isLandscape) {
      this.isLandscape = nextLandscape;
    }
    const nextCompact: boolean = vp.widthVp > 0 && vp.widthVp < 380;
    if (vp.isBottomNav() && nextCompact !== this.isCompactTopBar) {
      this.isCompactTopBar = nextCompact;
    }
  };

  aboutToAppear(): void {
    ViewportState.getInstance().addListener(this.syncViewport);
    this.syncViewport();
    this.vm.reloadAllSections('INITIAL', true);
  }

  aboutToDisappear(): void {
    ViewportState.getInstance().removeListener(this.syncViewport);
    cancelPrefetch('home_latest');
  }

  /** 海报卡宽度：锁定竖屏/横屏两档固定整数宽度 */
  private posterWidth(): number {
    return this.isLandscape ? HOME_POSTER_WIDTH_LANDSCAPE : HOME_POSTER_WIDTH_PORTRAIT;
  }

  /** 海报卡高度（3:4 固定整数高度） */
  private posterHeight(): number {
    return this.isLandscape ? HOME_POSTER_HEIGHT_LANDSCAPE : HOME_POSTER_HEIGHT_PORTRAIT;
  }

  /** 横屏左侧安全偏移：使标题与首张海报避让左侧悬浮 SideRail，而横向滑动卡片可向左滚入 SideRail 下方触发玻璃光感折射 */
  private sideRailStartInsetVp(): number {
    return sideRailContentLeftPaddingVp(this.isBottomNav);
  }

  /**
   * 关键词点击 → 搜索页。
   * 关键词**原样整体传入**（仅去首尾空白），不按空格拆分：复合中文标签被拆开后会变成
   * 两个无意义的搜索词。搜索范围使用协议值 mode='tag'（首方前端 tag 卡片同样用 mode=tag）。
   */
  /**
   * 区块「更多」→ 对应独立页面（Phase 14-Q）。
   * 映射集中在 LeaderboardModels.homeSectionRoute / homeSectionRankKind，
   * 保证「读榜→阅读榜、收藏榜→收藏榜、高质榜→高质量榜、收藏推荐→个人化精选」单一来源。
   */
  private openSection(section: string): void {
    const route: string = homeSectionRoute(section);
    if (route === HOME_ROUTE_PERSONALIZED) {
      Logger.info(TAG, `打开个人化精选（${section}）`);
      this.pageStack.pushPathByName(ROUTE_PERSONALIZED, null);
      return;
    }
    const kind: string = homeSectionRankKind(section);
    if (route === '' || kind === '') {
      return;
    }
    const period: string = homeSectionRankPeriod(section);
    Logger.info(TAG, `打开榜单: section=${section} kind=${kind} period=${period}`);
    this.pageStack.pushPathByName(ROUTE_RANK, new RankPageParam(kind, period));
  }

  build() {
    Column() {
      Refresh({ refreshing: this.vm.isManualRefreshing!! }) {
        if (this.vm.isEmpty && this.vm.errorMessage !== '') {
          ErrorState({
            message: this.vm.errorMessage,
            retry: (): void => {
              this.vm.loadData(true);
              this.vm.loadHome();
            },
            showSecondary: this.vm.needsLogin,
            secondaryText: LocalizationManager.getInstance().getString($r('app.string.common_go_login'), '去登录'),
            secondary: (): void => {
              this.pageStack.pushPathByName('LoginPage', null);
            }
          })
        } else {
          this.SectionedContent()
        }
      }
      .onRefreshing(() => {
        this.vm.onPullToRefresh(true);
      })
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(ThemeColors.BG)
  }

  /** 分区内容：固定头部槽位 + 今日阅读榜 / 今日收藏榜 / 推荐位 / 高质量推荐 + 最新推荐书单（旋转零销毁重建） */
  @Builder
  SectionedContent() {
    Scroll(this.homeScroller) {
      Column() {
        // 单一固定顶部槽位：竖屏底栏或紧凑高度横屏（<640vp）显示 HomeNavigationEntries，否则仅保留安全区留白
        Column() {
          HomeNavigationEntries({
            topSafeInset: this.topSafeInset,
            containerWidth: this.isCompactTopBar ? 360 : 390,
            leadingPaddingVp: 12 + this.sideRailStartInsetVp()
          })
            .visibility(shouldShowHomeTopEntries(this.isBottomNav, this.windowHeightVp)
              ? Visibility.Visible : Visibility.None)
        }
        .width('100%')
        .height(shouldShowHomeTopEntries(this.isBottomNav, this.windowHeightVp)
          ? compactTopBarTotalHeightVp(this.topSafeInset) : this.homeTopInset)
        .clip(true)

        HomeRankSectionComponent({
          title: this.lm.getString($r('app.string.home_section_read_rank'), ''),
          dataSource: this.vm.readDaySource,
          itemCount: this.vm.readDayCount,
          cardWidth: this.posterWidth(),
          cardHeight: this.posterHeight(),
          leadingPaddingVp: ThemeDims.PAGE_PADDING + this.sideRailStartInsetVp(),
          isLoading: this.vm.isInitialLoading || this.vm.homeLoading,
          ratingRevision: this.vm.committedRatingRevision,
          feedRevision: this.vm.homeFeedRevision,
          onMore: (): void => this.openSection(HOME_SECTION_READ_DAY)
        })
        HomeRankSectionComponent({
          title: this.lm.getString($r('app.string.home_section_fav_rank'), ''),
          dataSource: this.vm.favDaySource,
          itemCount: this.vm.favDayCount,
          cardWidth: this.posterWidth(),
          cardHeight: this.posterHeight(),
          leadingPaddingVp: ThemeDims.PAGE_PADDING + this.sideRailStartInsetVp(),
          isLoading: this.vm.isInitialLoading || this.vm.homeLoading,
          ratingRevision: this.vm.committedRatingRevision,
          feedRevision: this.vm.homeFeedRevision,
          onMore: (): void => this.openSection(HOME_SECTION_FAV_DAY)
        })
        HomeRankSectionComponent({
          title: this.lm.getString($r('app.string.home_section_quality'), ''),
          dataSource: this.vm.qualitySource,
          itemCount: this.vm.qualityCount,
          cardWidth: this.posterWidth(),
          cardHeight: this.posterHeight(),
          leadingPaddingVp: ThemeDims.PAGE_PADDING + this.sideRailStartInsetVp(),
          isLoading: this.vm.isInitialLoading || this.vm.homeLoading,
          ratingRevision: this.vm.committedRatingRevision,
          feedRevision: this.vm.homeFeedRevision,
          onMore: (): void => this.openSection(HOME_SECTION_PROPORTION)
        })
        HomeRankSectionComponent({
          title: this.lm.getString($r('app.string.home_section_recommend'), ''),
          dataSource: this.vm.collectionSource,
          itemCount: this.vm.collectionCount,
          cardWidth: this.posterWidth(),
          cardHeight: this.posterHeight(),
          leadingPaddingVp: ThemeDims.PAGE_PADDING + this.sideRailStartInsetVp(),
          isLoading: this.vm.isInitialLoading || this.vm.homeLoading,
          ratingRevision: this.vm.committedRatingRevision,
          feedRevision: this.vm.homeFeedRevision,
          onMore: (): void => this.openSection(HOME_SECTION_FS)
        })

        if (this.vm.homeFeed === null && this.vm.isEmpty && (this.vm.isInitialLoading || this.vm.homeLoading)) {
          SectionHeader({
            title: $r('app.string.home_recommended'),
            showMore: true,
            leadingPaddingVp: ThemeDims.PAGE_PADDING + this.sideRailStartInsetVp(),
            onMore: (): void => this.onMoreLatest()
          })
          Row({ space: ThemeDims.GRID_GAP }) {
            ForEach([0, 1, 2], (idx: number) => {
              Column()
                .width(this.posterWidth())
                .height(this.posterHeight())
                .borderRadius(ThemeDims.RADIUS_CARD)
                .backgroundColor(ThemeColors.SURFACE)
            }, (idx: number) => `${idx}`)
          }
          .width('100%')
          .height(this.posterHeight())
          .padding({
            left: ThemeDims.PAGE_PADDING + this.sideRailStartInsetVp(),
            right: ThemeDims.PAGE_PADDING
          })
          .clip(true)
        } else {
          SectionHeader({
            title: $r('app.string.home_recommended'),
            showMore: true,
            leadingPaddingVp: ThemeDims.PAGE_PADDING + this.sideRailStartInsetVp(),
            onMore: (): void => this.onMoreLatest()
          })
          this.HorizontalPosterRow()
        }

        // 底部留白：与底栏悬浮高度同源（侧栏形态下只留系统导航避让，不再预留底栏空间）
        Column()
          .width('100%')
          .height(this.navEndInset())
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .clipContent(ContentClipMode.SAFE_AREA)
    // p1 Task 1：滚动偏移唯一来源，喂给 Index 的顶栏收起状态机
    .onScroll((xOffset: number, yOffset: number): void => {
      this.onHomeScroll(yOffset);
    })
  }

  /** 横向海报行（懒加载，右侧自然露出半张）—— 最新推荐书单 */
  @Builder
  HorizontalPosterRow() {
    List({ space: ThemeDims.GRID_GAP }) {
      LazyForEach(this.vm.comicDataSource, (item: Comic, index: number) => {
        ListItem() {
          ComicPosterCard({
            comic: item,
            cardWidth: this.posterWidth(),
            cardHeight: this.posterHeight()
          })
        }
        .width(this.posterWidth())
        .height(this.posterHeight())
        .onAppear(() => {
          prefetchComicsAround(this.vm.comicDataSource.getDataArray(), index, 'home_latest');
        })
      }, (item: Comic): string => `${item.id}_${this.vm.committedRatingRevision}_${this.vm.homeFeedRevision}`)
    }
    .listDirection(Axis.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .cachedCount(2)
    .padding({
      left: ThemeDims.PAGE_PADDING + this.sideRailStartInsetVp(),
      right: ThemeDims.PAGE_PADDING
    })
    .width('100%')
    .height(this.posterHeight())
  }
}
