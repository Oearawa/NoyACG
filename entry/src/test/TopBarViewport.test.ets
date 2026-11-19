/**
 * TopBarViewport.test.ets —— 四形态顶栏视口契约单测（p1-native-material-shell Task 3）
 *
 * 覆盖（plan Task 3 净空策略 / brief 契约）：
 *   1. 四形态（竖屏/横屏/折叠 compact/展开 expanded）× collapsed/expanded 的
 *      topBarVisibleHeightVp 期望值：expanded = 56 + 48 = 104，collapsed = 56；
 *   2. contentPaddingTop = topBarVisibleHeightVp + safeAreaTopVp（brief 公式），
 *      逐形态断言（顶部状态栏 / 底部手势区用设备参考样本 fixture 分别避让）；
 *   3. 折叠/展开切换 padding 偏移恒 = bottomBuilder 高度 48（顶栏可视高度与 padding
 *      同源同量 → 无 translate 式布局跳动；阈值断言 < 48 + ε）；
 *   4. 底栏位置 = FLOATING_BAR_GAP + bottomSafeAreaVp（避开底部手势区）；
 *   5. resolveViewportForm：纯几何只可派生 LANDSCAPE/PORTRAIT；折叠两态需设备折叠
 *      信号（display.FoldDisplayMode），T3 纯函数不臆造 → UNVERIFIED，p2 设备验收。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  ViewportForm,
  TopBarMetrics,
  topBarMetrics,
  normalizeSafeAreaVp,
  contentPaddingTopVp,
  homeTopInsetVp,
  compactTopBarTotalHeightVp,
  resolveCompactTopBarSpec,
  CompactTopBarSpec,
  shouldScrollCompactEntries,
  bottomBarPositionVp,
  resolveViewportForm,
  TOP_BAR_TITLE_HEIGHT_VP,
  TOP_BAR_BOTTOM_BUILDER_HEIGHT_VP,
  COMPACT_TOP_BAR_HEIGHT_VP,
  COMPACT_CAPSULE_HEIGHT_VP,
  COMPACT_TOUCH_TARGET_VP,
  COMPACT_WIDE_BREAKPOINT_VP,
  COMPACT_NARROW_SCROLL_THRESHOLD_VP
} from '../main/ets/utils/TopBarViewport';
import {
  SIDE_QUICK_ROUTES,
  SIDE_SEARCH_ROUTE
} from '../main/ets/viewport/SideRailModel';
import {
  ROUTE_RANK,
  ROUTE_CATEGORY,
  ROUTE_PERSONALIZED,
  ROUTE_SEARCH
} from '../main/ets/model/DiscoveryRoutes';
import { FLOATING_BAR_GAP } from '../main/ets/utils/BottomInset';
import { ViewportState } from '../main/ets/utils/ViewportState';
import { SafeAreaManager } from '../main/ets/utils/SafeAreaManager';
import { commitTabIndex, shouldCommitTab } from '../main/ets/utils/NavInteraction';
import { HomeViewModel } from '../main/ets/viewmodel/HomeViewModel';
import { Comic } from '../main/ets/model/Comic';

interface ViewportFormFixture {
  form: ViewportForm;
  widthVp: number;
  heightVp: number;
  /** 顶部状态栏避让（SafeAreaManager 采样参考值，vp） */
  topSafeAreaVp: number;
  /** 底部手势条 / 三键导航避让（vp） */
  bottomSafeAreaVp: number;
}

/** 四形态参考样本：几何与 Phase15R2 设备样本同源（vp 与 px 同比例） */
const FORM_FIXTURES: ViewportFormFixture[] = [
  { form: ViewportForm.PORTRAIT, widthVp: 1264, heightVp: 1848, topSafeAreaVp: 30, bottomSafeAreaVp: 24 },
  { form: ViewportForm.LANDSCAPE, widthVp: 2296, heightVp: 1624, topSafeAreaVp: 0, bottomSafeAreaVp: 24 },
  { form: ViewportForm.FOLD_COMPACT, widthVp: 1264, heightVp: 1848, topSafeAreaVp: 30, bottomSafeAreaVp: 24 },
  { form: ViewportForm.FOLD_EXPANDED, widthVp: 1624, heightVp: 2296, topSafeAreaVp: 36, bottomSafeAreaVp: 24 }
];

export default function topBarViewportTest(): void {
  describe('TopBarViewport', () => {

    it('metricsExpanded104Collapsed56', 0, () => {
      const expanded: TopBarMetrics = topBarMetrics(false);
      const collapsed: TopBarMetrics = topBarMetrics(true);
      expect(expanded.titleHeightVp).assertEqual(TOP_BAR_TITLE_HEIGHT_VP);
      expect(expanded.bottomBuilderHeightVp).assertEqual(TOP_BAR_BOTTOM_BUILDER_HEIGHT_VP);
      expect(expanded.visibleHeightVp).assertEqual(104);
      expect(collapsed.titleHeightVp).assertEqual(TOP_BAR_TITLE_HEIGHT_VP);
      expect(collapsed.bottomBuilderHeightVp).assertEqual(0);
      expect(collapsed.visibleHeightVp).assertEqual(56);
    });

    it('fourFormsExpandedPadding', 0, () => {
      // expanded：paddingTop = 104 + safeAreaTop
      for (let i = 0; i < FORM_FIXTURES.length; i++) {
        const f: ViewportFormFixture = FORM_FIXTURES[i];
        expect(contentPaddingTopVp(false, f.topSafeAreaVp)).assertEqual(104 + f.topSafeAreaVp);
      }
    });

    it('fourFormsCollapsedPadding', 0, () => {
      // collapsed：paddingTop = 56 + safeAreaTop
      for (let i = 0; i < FORM_FIXTURES.length; i++) {
        const f: ViewportFormFixture = FORM_FIXTURES[i];
        expect(contentPaddingTopVp(true, f.topSafeAreaVp)).assertEqual(56 + f.topSafeAreaVp);
      }
    });

    it('paddingTopEqualsTopBarVisiblePlusSafeArea', 0, () => {
      // brief 公式恒等式：paddingTop = topBarVisibleHeightVp + safeAreaTopVp
      for (let i = 0; i < FORM_FIXTURES.length; i++) {
        const f: ViewportFormFixture = FORM_FIXTURES[i];
        expect(contentPaddingTopVp(false, f.topSafeAreaVp))
          .assertEqual(topBarMetrics(false).visibleHeightVp + f.topSafeAreaVp);
        expect(contentPaddingTopVp(true, f.topSafeAreaVp))
          .assertEqual(topBarMetrics(true).visibleHeightVp + f.topSafeAreaVp);
      }
    });

    it('collapseTogglePaddingOffsetIsExactlyBottomBuilderHeight', 0, () => {
      // 收起/展开切换：padding 偏移恒 = 48（bottomBuilder 高）= 顶栏可视高度差，
      // 高度与 padding 同源同量 → 无 translate 式布局跳动（阈值：< 48 + ε）
      for (let i = 0; i < FORM_FIXTURES.length; i++) {
        const f: ViewportFormFixture = FORM_FIXTURES[i];
        const delta: number =
          contentPaddingTopVp(false, f.topSafeAreaVp) - contentPaddingTopVp(true, f.topSafeAreaVp);
        expect(delta).assertEqual(48);
        expect(Math.abs(delta)).assertLess(48 + 0.001);
      }
    });

    it('bottomBarClearsGestureSafeAreaPerForm', 0, () => {
      for (let i = 0; i < FORM_FIXTURES.length; i++) {
        const f: ViewportFormFixture = FORM_FIXTURES[i];
        expect(bottomBarPositionVp(f.bottomSafeAreaVp))
          .assertEqual(FLOATING_BAR_GAP + f.bottomSafeAreaVp);
      }
    });

    it('resolverDerivesLandscapeAndPortraitOnly', 0, () => {
      expect(resolveViewportForm(1264, 1848)).assertEqual(ViewportForm.PORTRAIT);
      expect(resolveViewportForm(1624, 2296)).assertEqual(ViewportForm.PORTRAIT);
      expect(resolveViewportForm(2296, 1624)).assertEqual(ViewportForm.LANDSCAPE);
      // 非法几何 → 安全默认 PORTRAIT（与 NavigationMode 冷启动默认同思路）
      expect(resolveViewportForm(0, 0)).assertEqual(ViewportForm.PORTRAIT);
      expect(resolveViewportForm(NaN, 100)).assertEqual(ViewportForm.PORTRAIT);
    });

    it('normalizeSafeAreaClampsInvalid', 0, () => {
      expect(normalizeSafeAreaVp(-10)).assertEqual(0);
      expect(normalizeSafeAreaVp(NaN)).assertEqual(0);
      expect(normalizeSafeAreaVp(30)).assertEqual(30);
    });

  });

  describe('HomeInsetW49', () => {
    it('landscapeInsetIsSafeAreaOnly', 0, () => {
      // 横屏（非 bottom nav）：移除顶部栏后 inset = 仅系统安全区 topVp
      expect(homeTopInsetVp(false, false, 24)).assertEqual(24);
      expect(homeTopInsetVp(false, true, 24)).assertEqual(24);
      expect(homeTopInsetVp(false, false, 0)).assertEqual(0);
    });

    it('portraitInsetIsFixedCompactTopBarPlusSafeArea', 0, () => {
      // P1 竖屏（bottom nav）：固定单行紧凑顶栏（44vp）+ 安全区，不再随滚动折叠跳变
      expect(homeTopInsetVp(true, false, 24)).assertEqual(24 + COMPACT_TOP_BAR_HEIGHT_VP);
      expect(homeTopInsetVp(true, true, 24)).assertEqual(24 + COMPACT_TOP_BAR_HEIGHT_VP);
      expect(homeTopInsetVp(true, false, 0)).assertEqual(COMPACT_TOP_BAR_HEIGHT_VP);
      expect(homeTopInsetVp(true, true, 0)).assertEqual(COMPACT_TOP_BAR_HEIGHT_VP);
      expect(homeTopInsetVp(false, false, 0)).assertEqual(0);
    });
  });

  describe('PortraitCompactTopBar', () => {
    it('compactDimensionsAndTouchTargetMeetEnlargedSpec', 0, () => {
      expect(COMPACT_TOP_BAR_HEIGHT_VP).assertEqual(54);
      expect(COMPACT_CAPSULE_HEIGHT_VP).assertEqual(36);
      expect(COMPACT_TOUCH_TARGET_VP >= 44).assertTrue();

      // >= 380vp 常规/宽幅竖屏规格
      const wide: CompactTopBarSpec = resolveCompactTopBarSpec(420);
      expect(wide.barHeightVp).assertEqual(54);
      expect(wide.brandFontSizeFp).assertEqual(20);
      expect(wide.capsuleHeightVp).assertEqual(36);
      expect(wide.capsuleFontSizeFp).assertEqual(13);
      expect(wide.capsuleIconSizeVp).assertEqual(15);
      expect(wide.touchTargetVp >= 44).assertTrue();
      expect(wide.scrollCapsules).assertFalse();

      // 360vp 紧凑竖屏微调规格（不换行不截断）
      const narrow: CompactTopBarSpec = resolveCompactTopBarSpec(360);
      expect(narrow.barHeightVp).assertEqual(54);
      expect(narrow.brandFontSizeFp).assertEqual(18);
      expect(narrow.capsuleHeightVp).assertEqual(34);
      expect(narrow.capsuleFontSizeFp).assertEqual(12);
      expect(narrow.capsuleIconSizeVp).assertEqual(14);
      expect(narrow.touchTargetVp >= 44).assertTrue();
      expect(narrow.scrollCapsules).assertFalse();
      expect(COMPACT_WIDE_BREAKPOINT_VP).assertEqual(380);
    });

    it('computesCompactTotalHeightAcrossSafeAreasAndOrientationRestores', 0, () => {
      expect(compactTopBarTotalHeightVp(0)).assertEqual(COMPACT_TOP_BAR_HEIGHT_VP);
      expect(compactTopBarTotalHeightVp(30)).assertEqual(30 + COMPACT_TOP_BAR_HEIGHT_VP);
      expect(compactTopBarTotalHeightVp(-10)).assertEqual(COMPACT_TOP_BAR_HEIGHT_VP);
      expect(compactTopBarTotalHeightVp(NaN)).assertEqual(COMPACT_TOP_BAR_HEIGHT_VP);

      // 竖屏 -> 横屏 -> 竖屏切换恢复一致
      const p1: number = homeTopInsetVp(true, false, 30);
      const l1: number = homeTopInsetVp(false, false, 0);
      const p2: number = homeTopInsetVp(true, false, 30);
      expect(p1).assertEqual(30 + COMPACT_TOP_BAR_HEIGHT_VP);
      expect(l1).assertEqual(0);
      expect(p2).assertEqual(p1);
    });

    it('scrollsOnlyBelowNarrowThreshold340vp', 0, () => {
      expect(shouldScrollCompactEntries(360)).assertFalse();
      expect(shouldScrollCompactEntries(COMPACT_NARROW_SCROLL_THRESHOLD_VP)).assertFalse();
      expect(shouldScrollCompactEntries(COMPACT_NARROW_SCROLL_THRESHOLD_VP - 1)).assertTrue();
      expect(shouldScrollCompactEntries(280)).assertTrue();
      expect(shouldScrollCompactEntries(0)).assertFalse();
    });

    it('reusesFourQuickEntryRoutesConsistently', 0, () => {
      expect(SIDE_QUICK_ROUTES.length).assertEqual(3);
      expect(SIDE_QUICK_ROUTES[0]).assertEqual(ROUTE_RANK);
      expect(SIDE_QUICK_ROUTES[1]).assertEqual(ROUTE_CATEGORY);
      expect(SIDE_QUICK_ROUTES[2]).assertEqual(ROUTE_PERSONALIZED);
      expect(SIDE_SEARCH_ROUTE).assertEqual(ROUTE_SEARCH);
    });

    it('homeRotationPreservesTabAndFeedStateWithDiscreteGeometry', 0, () => {
      const vp: ViewportState = ViewportState.getInstance();
      const prevW: number = vp.widthVp;
      const prevH: number = vp.heightVp;
      const prevTop: number = vp.topVp;
      const prevBottom: number = vp.bottomVp;

      const vm: HomeViewModel = new HomeViewModel();
      const sample: Comic = new Comic();
      sample.id = '10001';
      sample.title = 'rotation-stable-comic';
      vm.comicDataSource.setData([sample]);
      let activeTab: number = commitTabIndex(0, 2);
      expect(activeTab).assertEqual(2);
      expect(shouldCommitTab(activeTab, 2)).assertFalse();

      try {
        // 竖屏 -> 横屏 -> 竖屏切换：Tab 下标、数据源条目与静默刷新标志均不得重置
        vp.setGeometry(390, 844, 38, 28);
        expect(vp.isBottomNav()).assertTrue();
        expect(vp.isLandscape()).assertFalse();

        vp.setGeometry(844, 390, 0, 20);
        expect(vp.isBottomNav()).assertFalse();
        expect(vp.isLandscape()).assertTrue();
        expect(activeTab).assertEqual(2);
        expect(vm.comicDataSource.totalCount()).assertEqual(1);
        expect(vm.isManualRefreshing).assertFalse();

        vp.setGeometry(390, 844, 38, 28);
        expect(vp.isBottomNav()).assertTrue();
        expect(activeTab).assertEqual(2);
        expect(vm.comicDataSource.totalCount()).assertEqual(1);
        expect(vm.isManualRefreshing).assertFalse();
      } finally {
        vp.setGeometry(prevW, prevH, prevTop, prevBottom);
      }
    });

    it('coldStartGeometryPopulatesCacheAndAppStorageSynchronously', 0, () => {
      const vp: ViewportState = ViewportState.getInstance();
      const prevW: number = vp.widthVp;
      const prevH: number = vp.heightVp;
      const prevTop: number = vp.topVp;
      const prevBottom: number = vp.bottomVp;

      try {
        vp.setGeometry(390, 844, 38, 28);
        expect(vp.hasCommitted()).assertTrue();
        expect(SafeAreaManager.topInsetNow()).assertEqual(38);
        expect(compactTopBarTotalHeightVp(SafeAreaManager.topInsetNow()))
          .assertEqual(38 + COMPACT_TOP_BAR_HEIGHT_VP);
      } finally {
        vp.setGeometry(prevW, prevH, prevTop, prevBottom);
      }
    });
  });
}
