/**
 * One shared NavPathStack and one HdsTabs content tree.
 * ViewportState alone selects the floating native bottom bar or solid side rail.
 * HDS owns the home title material and vertical-scroll visibility.
 */
import { HomeComponent } from '../components/HomeComponent';
import { SymbolGlyphModifier, curves } from '@kit.ArkUI';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { LatestComponent } from '../components/LatestComponent';
import { CommunityComponent } from '../components/CommunityComponent';
import { ShelfComponent } from '../components/ShelfComponent';
import { ProfileBody } from './ProfilePage';
import { ShelfViewModel } from '../viewmodel/ShelfViewModel';
import {
  resolveGlassCapsuleBorderColor,
  resolveGlassCapsuleShadowColor,
  resolveGlassCapsuleTintColor
} from '../utils/MaterialPolicy';
import { buildBarImmersiveMaterial } from '../utils/ImmersiveMaterial';
import { ThemeColors, ThemeDims } from '../utils/Theme';
import { ThemeManager } from '../utils/ThemeManager';
import { Logger } from '../utils/Logger';
import { SafeAreaManager } from '../utils/SafeAreaManager';
import { ViewportState } from '../utils/ViewportState';
import { NavigationMode as AppNavigationMode } from '../utils/NavigationMode';
import { floatingBarBottomMargin } from '../utils/BottomInset';
import { HdsNavigation, HdsTabs, HdsTabsFloatingStyle, HdsNavigationTitleMode, HideMode } from '@kit.UIDesignKit';
import {
  HDS_SYSTEM_MATERIAL,
  hdsTitleBarStyle,
  reportHdsMaterialSupport,
  resolveHdsSystemMaterial
} from '../utils/HdsMaterialPolicy';
import { BUILD_ID, DEBUG_STAMP_ENABLED } from '../utils/BuildInfo';
import { commitTabIndex, shouldCommitTab, shouldRefreshShelfOnPop } from '../utils/NavInteraction';
import { homeTopInsetVp } from '../utils/TopBarViewport';
import {
  SideGroupLayout,
  sideGroupsForGeometry,
  sideRailContentLeftPaddingVp
} from '../utils/SideGroupLayout';
import { AuthManager } from '../utils/AuthManager';
import { NoyClient } from '../api/NoyClient';
import { DailySignInManager } from '../utils/DailySignInManager';
import { CheckInModal } from '../components/CheckInModal';
import { CommunityImageViewer } from '../components/CommunityImageViewer';
import { BackInterceptRegistry } from '../utils/BackInterceptRegistry';
import { CommunityViewerController } from '../utils/CommunityViewerController';
import {
  NavTabId,
  resolveSafeSelectedTab,
  resolveTabIndexById,
  resolveVisibleNavTabs
} from '../utils/NavTabsPolicy';
import { PreferenceManager } from '../utils/PreferenceManager';

const TAG: string = 'Index';

@Entry
@ComponentV2
struct Index {
  /** 全局共享路由栈：所有子页面通过 @Consumer('pageStack') 接入同一栈实例 */
  @Provider('pageStack') pageStack: NavPathStack = new NavPathStack();
  /** 书架 VM 提升到 Index 持有：刷新时机由本页统一驱动，ShelfComponent 只管渲染 */
  @Local shelfVm: ShelfViewModel = new ShelfViewModel();
  /**
   * 当前选中的 Tab 下标 —— 页签切换的**唯一状态源**（Phase 15-R2.1 P2-01）。
   *
   * Tabs 的 `index` 是单向入参（SDK：组件重建 / 系统资源切换 / 属性变化时都会切回该值），
   * 因此「点击导航项」与「程序内切换」都只写这一个字段即可；
   * 若再叠加 `TabsController.changeIndex`，同一次切换会走两次提交（重复动画 / 重复副作用）。
   */
  @Local currentTabIndex: number = 0;
  @Local currentTabId: NavTabId = 'home';
  @Local theme: ThemeManager = ThemeManager.getInstance();
  @Local private prefs: PreferenceManager = PreferenceManager.getInstance();
  @Local private auth: AuthManager = AuthManager.getInstance();
  @Local private signInMgr: DailySignInManager = DailySignInManager.getInstance();
  @Local private viewerCtrl: CommunityViewerController = CommunityViewerController.getInstance();
  private readonly barMaterial = buildBarImmersiveMaterial();
  private nativeThemeMode: string = '';

  @Monitor('theme.mode')
  onNativeThemeModeChanged(): void {
    this.syncNativeThemeMode();
  }

  @Monitor('auth.status')
  onAuthStatusChanged(): void {
    this.tryCheckSignInOnLaunch();
  }

  @Monitor('prefs.navShowLatest', 'prefs.navShowCommunity', 'prefs.navShowShelf')
  onNavPrefsChanged(): void {
    const tabs: NavTabId[] = this.visibleTabs();
    const safeId: NavTabId = resolveSafeSelectedTab(this.currentTabId, tabs);
    const nextIdx: number = resolveTabIndexById(safeId, tabs);
    this.currentTabId = safeId;
    this.currentTabIndex = nextIdx;
  }

  private visibleTabs(): NavTabId[] {
    return resolveVisibleNavTabs({
      showLatest: this.prefs.navShowLatest,
      showCommunity: this.prefs.navShowCommunity,
      showShelf: this.prefs.navShowShelf
    });
  }

  private tabTitleRes(tabId: NavTabId): Resource {
    if (tabId === 'latest') {
      return $r('app.string.tab_latest');
    }
    if (tabId === 'community') {
      return $r('app.string.tab_community');
    }
    if (tabId === 'shelf') {
      return $r('app.string.tab_shelf');
    }
    if (tabId === 'profile') {
      return $r('app.string.tab_user');
    }
    return $r('app.string.tab_home');
  }

  private tabIconRes(tabId: NavTabId): Resource {
    if (tabId === 'latest') {
      return $r('sys.symbol.clock');
    }
    if (tabId === 'community') {
      return $r('sys.symbol.message');
    }
    if (tabId === 'shelf') {
      return $r('sys.symbol.bookshelf_1');
    }
    if (tabId === 'profile') {
      return $r('sys.symbol.person');
    }
    return $r('sys.symbol.house');
  }

  private tabSelectedIconRes(tabId: NavTabId): Resource {
    if (tabId === 'latest') {
      return $r('sys.symbol.clock_fill');
    }
    if (tabId === 'community') {
      return $r('sys.symbol.message_fill');
    }
    if (tabId === 'shelf') {
      return $r('sys.symbol.bookshelf');
    }
    if (tabId === 'profile') {
      return $r('sys.symbol.person_fill');
    }
    return $r('sys.symbol.house_fill');
  }

  private tryCheckSignInOnLaunch(): void {
    if (this.auth.isAuthenticated && this.auth.user !== null) {
      void this.signInMgr.checkDailySignInOnLaunch(this.auth.user.uid);
    }
  }

  private syncNativeThemeMode(): void {
    if (this.nativeThemeMode === this.theme.mode) {
      return;
    }
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    const mode: ConfigurationConstant.ColorMode = this.theme.mode === 'dark'
      ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
      : this.theme.mode === 'light' ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
        : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    try {
      context.getApplicationContext().setColorMode(mode);
      this.nativeThemeMode = this.theme.mode;
      Logger.info(TAG, `native color mode=${mode} preference=${this.theme.mode}`);
    } catch (e) {
      Logger.warn(TAG, 'Unable to synchronize the native application color mode');
    }
  }
  /**
   * 窗口几何 + 导航形态的**显式订阅**（Phase 15-R3）。
   *
   * 真机实测：`@Local viewport = getInstance()` 读 `viewport.navMode` 的隐式依赖，
   * 在「窗口配置变更」这条路径上没有触发重绘，`@Monitor` 也不回调 —— 采样日志已算出
   * BOTTOM_IMMERSIVE，界面却仍是 SIDE，直到重启（重建组件）才正确。
   * 因此壳层改为：采样提交时回调 syncGeometry()，把值写进下面这几个 @Local 基元，
   * 由基元赋值（V2 最可靠的路径）驱动重绘，不再依赖 @Trace 的跨模块通知时机。
   */
  private readonly viewportSource: ViewportState = ViewportState.getInstance();
  @Local navModeValue: AppNavigationMode = ViewportState.getInstance().navMode;
  @Local widthVpValue: number = ViewportState.getInstance().widthVp;
  @Local heightVpValue: number = ViewportState.getInstance().heightVp;
  @Local topVpValue: number = ViewportState.getInstance().topVp > 0
    ? ViewportState.getInstance().topVp : SafeAreaManager.topInsetNow();
  @Local bottomVpValue: number = ViewportState.getInstance().bottomVp;
  /** p7 Task 2：侧栏两分组高度分配（layoutSideGroups 纯函数驱动，syncGeometry 随时重算） */
  @Local sideLayout: SideGroupLayout = sideGroupsForGeometry(
    ViewportState.getInstance().heightVp,
    ViewportState.getInstance().topVp,
    ViewportState.getInstance().bottomVp
  );
  /**
   * 用户中心刷新信号：每次切到「用户」Tab 自增一次，ProfileBody 通过 @Monitor 感知，
   * 刷新未读计数与登录态。
   */
  @Local profileRefreshTick: number = 0;
  /** 根 NavBar 是否处于栈顶可见态（驱动 Home/Latest 在返回首页时自动核对内容分级版本号） */
  @Local isNavBarTop: boolean = true;


  private readonly homeScroller: Scroller = new Scroller();

  /** 首页滚动回调保留空实现（P1：竖屏改为固定单行紧凑顶栏，取消随滚动隐藏/展开动画） */
  private onHomeScroll = (_yOffset: number): void => {
  };


  private floatingBarStyle(): HdsTabsFloatingStyle {
    const style: HdsTabsFloatingStyle = {
      barWidth: {
        smallWidth: Math.min(348,
          Math.max(0, this.widthVpValue - 24 * 2)),
        mediumWidth: 368,
        largeWidth: 368
      },
      barSideMargin: 24,
      barBottomMargin: floatingBarBottomMargin(this.bottomVpValue),
      systemMaterialEffect: resolveHdsSystemMaterial()
    };
    return style;
  }

  // ==================== 形态派生（全应用唯一判断口） ====================

  /** 是否底部导航。唯一形态值来自 ViewportState.navMode。 */
  private isBottomNav(): boolean {
    return this.navModeValue === AppNavigationMode.BOTTOM_IMMERSIVE;
  }



  /** 内容末尾留白由各滚动容器用同一个 BottomInset 公式自行计算（见 navEndInset） */

  // ==================== 生命周期 ====================

  aboutToAppear(): void {
    this.syncNativeThemeMode();
    reportHdsMaterialSupport();
    this.tryCheckSignInOnLaunch();
    NoyClient.getInstance().setOnSessionExpired((): void => {
      const names: string[] = this.pageStack.getAllPathName();
      if (names.length === 0 || names[names.length - 1] !== 'LoginPage') {
        this.pageStack.pushPathByName('LoginPage', null);
      }
    });
    // 首次按登录态选择默认收藏数据源（登录→账号，游客→本地）
    this.shelfVm.initDefaultSource();
    // 兜底采样：若 EntryAbility 侧尚未绑定窗口，这里再触发一次（内部幂等且异常安全）
    SafeAreaManager.sampleWindowGeometry();
    // 先订阅再同步，避免两次采样之间的空档丢失变更
    this.viewportSource.addListener(this.syncGeometry);
    this.syncGeometry();
    Logger.info(TAG, `BUILD_ID=${BUILD_ID} navMode=${this.navModeValue} ` +
      `${this.widthVpValue.toFixed(1)}x${this.heightVpValue.toFixed(1)}vp ` +
      `viewportId=${this.viewportSource.instanceId}`);
    // 路由拦截（P2-03）：书架刷新放到转场**完成之后**（didShow），不再与原生动画争用同一时段。
    // 只认「POP 且目标是根页」：NavBar 的字面量就是 'navBar'，页面之间的 POP 不改书架。
    this.pageStack.setInterception({
      didShow: (from: NavDestinationContext | NavBar,
        to: NavDestinationContext | NavBar,
        operation: NavigationOperation, isAnimated: boolean): void => {
        const isPop: boolean = operation === NavigationOperation.POP;
        const toIsNavBar: boolean = to === 'navBar';
        this.isNavBarTop = toIsNavBar;
        if (!shouldRefreshShelfOnPop(isPop, toIsNavBar)) {
          return;
        }
        Logger.debug(TAG, '返回首页转场完成，刷新书架');
        this.shelfVm.loadFavorites();
      }
    });
  }

  /**
   * 采样提交后的同步回调：离散防抖写入 @Local 基元，仅在关键态实际变化时触发单次更新。
   */
  private syncGeometry = (): void => {
    const vp: ViewportState = this.viewportSource;
    const modeChanged: boolean = this.navModeValue !== vp.navMode;
    if (modeChanged) {
      this.navModeValue = vp.navMode;
    }
    if (Math.abs(vp.topVp - this.topVpValue) >= 0.5) {
      this.topVpValue = vp.topVp;
    }
    if (Math.abs(vp.bottomVp - this.bottomVpValue) >= 0.5) {
      this.bottomVpValue = vp.bottomVp;
    }
    if (Math.abs(vp.widthVp - this.widthVpValue) >= 0.5 || modeChanged) {
      this.widthVpValue = vp.widthVp;
    }
    if (Math.abs(vp.heightVp - this.heightVpValue) >= 0.5 || modeChanged) {
      this.heightVpValue = vp.heightVp;
    }
    // 仅横屏侧栏可见或模式切入横屏时重算侧栏几何
    if (!vp.isBottomNav() || modeChanged) {
      const nextSide: SideGroupLayout = sideGroupsForGeometry(vp.heightVp, vp.topVp, vp.bottomVp);
      if (nextSide.navH !== this.sideLayout.navH
        || nextSide.quickH !== this.sideLayout.quickH
        || nextSide.quickScrollable !== this.sideLayout.quickScrollable
        || nextSide.compact !== this.sideLayout.compact
        || nextSide.spacingVp !== this.sideLayout.spacingVp) {
        this.sideLayout = nextSide;
      }
    }
    if (modeChanged) {
      Logger.info(TAG, `navMode -> ${vp.navMode} ` +
        `${vp.widthVp.toFixed(1)}x${vp.heightVp.toFixed(1)}vp`);
    }
  };

  aboutToDisappear(): void {
    this.viewportSource.removeListener(this.syncGeometry);
  }

  onBackPress(): boolean {
    if (this.viewerCtrl.closeIfOpen()) {
      return true;
    }
    if (BackInterceptRegistry.getInstance().dispatchBack()) {
      return true;
    }
    if (this.signInMgr.showPrompt) {
      if (!this.signInMgr.signingIn) {
        this.signInMgr.dismissPrompt();
      }
      return true;
    }
    if (this.pageStack.size() > 0) {
      this.pageStack.pop();
      return true;
    }
    return false;
  }

  // ==================== UI ====================

  build() {
    WithTheme({ colorMode: this.theme.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT }) {
      Stack({ alignContent: Alignment.TopStart }) {
        HdsNavigation(this.pageStack) {
          // 悬浮式层叠（Stack）+ 单树零重建：
          // 底层全屏 HdsTabs（横屏设左侧安全内边距 sideRailContentLeftPaddingVp，背景与横向光影延伸至屏幕左缘）
          // 顶层左侧悬浮 SideRail（系统光感材质着色器直接折射底层画布，呈现与竖屏底栏一致的通透玻璃与边缘高光）
          Stack({ alignContent: Alignment.TopStart }) {
            // 全应用唯一的 Tabs 实例：竖屏启用官方 HDS 悬浮胶囊光感玻璃底栏，横屏隐藏内置底栏由左侧 SideRail 接管（旋转零重建）
            HdsTabs({
              index: this.currentTabIndex,
              barPosition: BarPosition.End
            }) {
              ForEach(this.visibleTabs(), (tabId: NavTabId) => {
                if (tabId === 'home') {
                  TabContent() {
                    HomeComponent({
                      active: this.currentTabId === 'home',
                      isTopRoute: this.isNavBarTop,
                      homeScroller: this.homeScroller,
                      homeTopInset: homeTopInsetVp(this.isBottomNav(), false, this.topVpValue),
                      isBottomNav: this.isBottomNav(),
                      topSafeInset: this.topVpValue,
                      windowHeightVp: this.heightVpValue,
                      onMoreLatest: (): void => this.switchToTabId('latest'),
                      onHomeScroll: this.onHomeScroll
                    })
                  }
                  .tabBar(this.BottomItem(this.tabTitleRes('home'),
                    this.tabIconRes('home'), this.tabSelectedIconRes('home')))
                } else if (tabId === 'latest') {
                  TabContent() {
                    Column() {
                      LatestComponent({
                        active: this.currentTabId === 'latest',
                        isTopRoute: this.isNavBarTop
                      })
                    }
                    .width('100%')
                    .height('100%')
                    .padding({ left: sideRailContentLeftPaddingVp(this.isBottomNav()) })
                  }
                  .tabBar(this.BottomItem(this.tabTitleRes('latest'),
                    this.tabIconRes('latest'), this.tabSelectedIconRes('latest')))
                } else if (tabId === 'community') {
                  TabContent() {
                    Column() {
                      CommunityComponent({
                        active: this.currentTabId === 'community',
                        isTopRoute: this.isNavBarTop
                      })
                    }
                    .width('100%')
                    .height('100%')
                    .padding({ left: sideRailContentLeftPaddingVp(this.isBottomNav()) })
                  }
                  .tabBar(this.BottomItem(this.tabTitleRes('community'),
                    this.tabIconRes('community'), this.tabSelectedIconRes('community')))
                } else if (tabId === 'shelf') {
                  TabContent() {
                    Column() {
                      ShelfComponent({ vm: this.shelfVm, active: this.currentTabId === 'shelf' })
                    }
                    .width('100%')
                    .height('100%')
                    .padding({ left: sideRailContentLeftPaddingVp(this.isBottomNav()) })
                  }
                  .tabBar(this.BottomItem(this.tabTitleRes('shelf'),
                    this.tabIconRes('shelf'), this.tabSelectedIconRes('shelf')))
                } else {
                  TabContent() {
                    Column() {
                      ProfileBody({ inTab: true, refreshTick: this.profileRefreshTick })
                    }
                    .width('100%')
                    .height('100%')
                    .padding({ left: sideRailContentLeftPaddingVp(this.isBottomNav()) })
                  }
                  .tabBar(this.BottomItem(this.tabTitleRes('profile'),
                    this.tabIconRes('profile'), this.tabSelectedIconRes('profile')))
                }
              }, (tabId: NavTabId): string => tabId)
            }
            .barMode(BarMode.Fixed)
            .vertical(false)
            .barPosition(BarPosition.End)
            .barWidth(this.isBottomNav() ? ThemeDims.BOTTOM_BAR_WIDTH : 0)
            .barHeight(this.isBottomNav() ? ThemeDims.BOTTOM_BAR_HEIGHT : 0)
            .barOverlap(this.isBottomNav())
            .barFloatingStyle(this.isBottomNav() ? this.floatingBarStyle() : undefined)
            .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
            // Tabs 会消费纵向拖动，与页面 List/Scroll 的纵向滚动直接冲突。
            .scrollable(false)
            .backgroundColor(Color.Transparent)
            .width('100%')
            .height('100%')
            .onChange((index: number) => {
              this.applyTabSelection(index);
            })

            // 固定左侧悬浮侧栏槽位：仅控制显隐，保证 HdsTabs 与 SideRail 节点在旋转时 100% 原地存活
            Column() {
              this.SideRail()
            }
            .width(ThemeDims.NAV_RAIL_TOTAL_WIDTH)
            .height('100%')
            .visibility(this.isBottomNav() ? Visibility.None : Visibility.Visible)
          }
          .width('100%')
          .height('100%')
        }
        .withTheme({ enableThemeColorMode: true })
        .mode(NavigationMode.Stack) // 手机端固定 Stack 模式（推入子页全覆盖）
        .hideBackButton(true)
        .hideTitleBar(true)
        .bindToScrollable([])
        .hideToolBar(true)
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
        .width('100%')
        .height('100%')
        .backgroundColor(ThemeColors.BG)

        // 调试戳：让每张截图自带版本与几何（发布前置 false）
        if (DEBUG_STAMP_ENABLED) {
          this.DebugStamp()
        }

        if (this.signInMgr.showPrompt) {
          CheckInModal()
        }

        if (this.viewerCtrl.imageUrl !== '') {
          CommunityImageViewer({
            imageUrl: this.viewerCtrl.imageUrl,
            onClose: (): void => {
              this.viewerCtrl.close();
            }
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemeColors.BG)
    }
  }

  private BottomItem(title: Resource, icon: Resource, selected: Resource): BottomTabBarStyle {
    const unselectedColor: string = this.theme.isDark ? '#CBD5E1' : '#333A48';
    const selectedColor: string = this.theme.accent;
    return new BottomTabBarStyle({
      normal: new SymbolGlyphModifier(icon).fontColor([unselectedColor]),
      selected: new SymbolGlyphModifier(selected).fontColor([selectedColor])
    }, title).labelStyle({
      selectedColor: selectedColor,
      unselectedColor: unselectedColor
    });
  }

  /** Side rail and docked bottom bar write the same selected tab idempotently by NavTabId. */
  private applyTabSelection(index: number): void {
    const tabs: NavTabId[] = this.visibleTabs();
    const safeIdx: number = index >= 0 && index < tabs.length ? index : 0;
    const tabId: NavTabId = tabs[safeIdx];
    if (!shouldCommitTab(this.currentTabIndex, safeIdx) && this.currentTabId === tabId) {
      return;
    }
    this.currentTabIndex = commitTabIndex(this.currentTabIndex, safeIdx);
    this.currentTabId = tabId;
    if (tabId === 'shelf') {
      this.shelfVm.onTabSelected();
    } else if (tabId === 'profile') {
      this.profileRefreshTick = this.profileRefreshTick + 1;
    }
  }

  private switchTo(index: number): void {
    this.applyTabSelection(index);
  }

  private switchToTabId(tabId: NavTabId): void {
    const tabs: NavTabId[] = this.visibleTabs();
    const idx: number = tabs.indexOf(tabId);
    if (idx >= 0) {
      this.applyTabSelection(idx);
    }
  }

  /** 侧栏：垂直居中悬浮的紧凑动态光感玻璃胶囊（64vp 宽，32vp 全圆角，三层光学玻璃结构） */
  @Builder
  SideRail() {
    Column() {
      Column({ space: this.sideLayout.navGap }) {
        ForEach(this.visibleTabs(), (tabId: NavTabId, idx: number) => {
          Column() {
            this.NavItem(this.tabTitleRes(tabId), this.tabIconRes(tabId), this.tabSelectedIconRes(tabId), idx)
          }
          .width('100%')
          .onClick((): void => this.switchTo(idx))
        }, (tabId: NavTabId): string => tabId)
      }
      .width(ThemeDims.NAV_RAIL_WIDTH)
      .padding({
        left: 6,
        right: 6,
        top: 10,
        bottom: 10
      })
      .backgroundColor(resolveGlassCapsuleTintColor(this.theme.isDark))
      .border({
        width: 1,
        color: resolveGlassCapsuleBorderColor(this.theme.isDark)
      })
      .shadow({
        radius: 24,
        color: resolveGlassCapsuleShadowColor(this.theme.isDark),
        offsetX: 0,
        offsetY: 6
      })
      .systemMaterial(this.barMaterial)
      .borderRadius(ThemeDims.NAV_RAIL_RADIUS)
    }
    .width(ThemeDims.NAV_RAIL_TOTAL_WIDTH)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({
      left: ThemeDims.NAV_RAIL_MARGIN,
      right: ThemeDims.NAV_RAIL_MARGIN,
      top: ThemeDims.NAV_RAIL_MARGIN + this.topVpValue,
      bottom: ThemeDims.NAV_RAIL_MARGIN + this.bottomVpValue
    })
  }

  /**
   * 导航入口（底栏与侧栏共用同一个 Builder）。
   * 图标用系统符号资源（SymbolGlyph），选中/未选中用 fontColor 区分（→ S5）。
   */
  @Builder
  NavItem(title: Resource, icon: Resource, iconSelected: Resource, index: number) {
    Column({ space: this.sideLayout.compact && !this.isBottomNav() ? 1 : 2 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(this.currentTabIndex === index ? iconSelected : icon)
          .fontSize(this.isBottomNav() ? ThemeDims.NAV_ICON_SIZE : (this.sideLayout.compact ? 18 : 20))
          .fontColor([
            this.currentTabIndex === index
              ? this.theme.accent
              : (this.theme.isDark ? '#CBD5E1' : '#333A48')
          ])
      }
      .width(this.isBottomNav() ? 52 : 48)
      .height(this.isBottomNav() ? 28 : (this.sideLayout.compact ? 22 : 28))
      .borderRadius(14)
      .backgroundColor(this.currentTabIndex === index
        ? this.theme.accentSoft
        : Color.Transparent)
      .border(this.currentTabIndex === index
        ? { width: 1, color: this.theme.accentBorder }
        : { width: 0, color: Color.Transparent })
      .scale({
        x: this.currentTabIndex === index ? 1.0 : 0.94,
        y: this.currentTabIndex === index ? 1.0 : 0.94
      })
      .animation({ curve: curves.springMotion(0.28, 0.80) })

      Text(title)
        .fontSize(this.isBottomNav() ? 10 : (this.sideLayout.compact ? this.sideLayout.navFontSize : 11))
        .fontWeight(this.currentTabIndex === index ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(
          this.currentTabIndex === index
            ? (this.theme.isDark ? '#F8FAFC' : '#1E2430')
            : (this.theme.isDark ? '#94A3B8' : '#5A6270')
        )
        .maxLines(1)
    }
    .width('100%')
    .height(this.isBottomNav() ? ThemeDims.BOTTOM_BAR_HEIGHT : this.sideLayout.navItemH)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(Color.Transparent)
  }

  /** 调试戳：BUILD_ID | navMode | 宽x高(vp) | 宽高比；不拦截触摸 */
  @Builder
  DebugStamp() {
    Text(`${BUILD_ID} | ${this.navModeValue} | ` +
      `${this.widthVpValue.toFixed(0)}x${this.heightVpValue.toFixed(0)}vp | ` +
      `r=${(this.heightVpValue > 0
        ? this.widthVpValue / this.heightVpValue : 0).toFixed(3)}`)
      .fontSize(9)
      .fontColor(ThemeColors.TEXT_MUTED)
      .opacity(0.7)
      .maxLines(1)
      .hitTestBehavior(HitTestMode.None)
      .position({ x: 6, y: this.topVpValue + 2 })
  }
}
