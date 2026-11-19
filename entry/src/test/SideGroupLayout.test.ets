/**
 * SideGroupLayout.test.ets —— 横屏侧栏两分组高度分配与紧凑策略单测（p7-landscape-side-rail Task 2）
 *
 * 覆盖（plan Task 3 测试契约 4-5 / brief）：
 *   1. 充足高度：两分组完整显示，不滚动不压缩（quickScrollable=false, compact=false）；
 *   2. 恰好充足（restFull == quickIdealH 边界）：不滚动；
 *   3. 常规不足：快捷组滚动（quickScrollable=true，首选策略），间距不压缩；
 *   4. 进一步不足（常规间距放不下）：压缩间距 NAV_RAIL_ITEM_GAP→SPACE_S（compact=true）+ 滚动；
 *   5. 物理极限：主导航完整可见，快捷滚动区=0，spacingVp 按剩余钳制（F1 修复，守恒成立）；
 *   6. 非法输入（<=0 / NaN / 负避让）：保底两分组可见 + 快捷组可滚；
 *   7. sideRailAvailHeightVp 唯一口径 = heightVp - topVp - bottomVp - 2*NAV_RAIL_MARGIN（非法→0）；
 *   8. sideGroupsForGeometry 集成：真实 ThemeDims / 分屏低高度 / 横竖屏恢复。
 *
 * 低高度横屏（分屏，T1 F-01）：mainNav 4 项永远完整（navH=248 恒定），快捷组可滚/压缩，无裁切。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  SideGroupLayout,
  layoutSideGroups,
  sideRailAvailHeightVp,
  mainNavGroupHeightVp,
  quickGroupIdealHeightVp,
  sideGroupSpacingVp,
  sideGroupInnerGapVp,
  sideGroupsForAvailHeight,
  sideGroupsForGeometry,
  shouldShowQuickEntriesInSideRail,
  shouldShowHomeTopEntries,
  sideRailContentLeftPaddingVp,
  SIDE_QUICK_ENTRIES_MIN_HEIGHT_VP,
  COMPACT_OUTER_PAD_V_VP,
  COMPACT_INNER_GAP_VP,
  SIDE_COMPACT_BREAKPOINT_VP,
  SIDE_EXTREME_TINY_BREAKPOINT_VP,
  SIDE_GROUP_DIVIDER_HEIGHT,
  SIDE_SEARCH_BUTTON_SIZE
} from '../main/ets/utils/SideGroupLayout';
import { ThemeDims } from '../main/ets/utils/Theme';

export default function sideGroupLayoutTest(): void {
  describe('SideGroupLayout', () => {

    it('sufficientHeightFullDisplayNoScroll', 0, () => {
      // 充足高度：两分组完整显示，不滚动不压缩
      const navH: number = mainNavGroupHeightVp();
      const quickH: number = quickGroupIdealHeightVp();
      const availH: number = navH + sideGroupSpacingVp(false) + quickH + 100;
      const r: SideGroupLayout = layoutSideGroups(availH, navH, quickH);
      expect(r.navH).assertEqual(navH);
      expect(r.quickH).assertEqual(quickH);
      expect(r.quickScrollable).assertFalse();
      expect(r.compact).assertFalse();
      // spacingVp 契约：常规档 = sideGroupSpacingVp(false)，守恒 quickH+spacingVp+navH == availH-100
      expect(r.spacingVp).assertEqual(sideGroupSpacingVp(false));
    });

    it('exactFitNoScrollBoundary', 0, () => {
      // 恰好充足（restFull == quickIdealH）：不滚动
      const navH: number = mainNavGroupHeightVp();
      const quickH: number = quickGroupIdealHeightVp();
      const availH: number = navH + sideGroupSpacingVp(false) + quickH;
      const r: SideGroupLayout = layoutSideGroups(availH, navH, quickH);
      expect(r.navH).assertEqual(navH);
      expect(r.quickH).assertEqual(quickH);
      expect(r.quickScrollable).assertFalse();
    });

    it('regularShortageScrollsQuickGroup', 0, () => {
      // 常规不足：快捷组滚动（首选策略），间距不压缩
      const navH: number = mainNavGroupHeightVp();
      const quickH: number = quickGroupIdealHeightVp();
      const restFull: number = quickH - 40;
      const availH: number = navH + sideGroupSpacingVp(false) + restFull;
      const r: SideGroupLayout = layoutSideGroups(availH, navH, quickH);
      expect(r.navH).assertEqual(navH);
      expect(r.quickH).assertEqual(restFull);
      expect(r.quickScrollable).assertTrue();
      expect(r.compact).assertFalse();
      expect(r.spacingVp).assertEqual(sideGroupSpacingVp(false));
    });

    it('severeShortageCompactsThenScrolls', 0, () => {
      // 进一步不足（常规间距放不下）：压缩间距 NAV_RAIL_ITEM_GAP→SPACE_S + 滚动
      const navH: number = mainNavGroupHeightVp();
      const quickH: number = quickGroupIdealHeightVp();
      // 常规间距下 restFull < 0（压缩节省 = spacing(false)-spacing(true) = 8vp，故 restTight 须 < 8），
      // 压缩后 restTight >= 0 → 进入压缩分支
      const restTight: number = 4;
      const availH: number = navH + sideGroupSpacingVp(true) + restTight;
      const r: SideGroupLayout = layoutSideGroups(availH, navH, quickH);
      expect(r.navH).assertEqual(navH);
      expect(r.quickH).assertEqual(restTight);
      expect(r.quickScrollable).assertTrue();
      expect(r.compact).assertTrue();
      expect(r.spacingVp).assertEqual(sideGroupSpacingVp(true));
      // 该 availH 在常规间距下确实不足（验证进入了压缩分支）
      expect(navH + sideGroupSpacingVp(false) + restTight).assertLarger(availH);
    });

    it('physicalLimitClampsSpacingToRemaining', 0, () => {
      const navH: number = mainNavGroupHeightVp();
      const availH: number = navH + 12;
      const r: SideGroupLayout = layoutSideGroups(availH, navH, quickGroupIdealHeightVp());
      expect(r.navH).assertEqual(navH);
      expect(r.quickH).assertEqual(0);
      expect(r.quickScrollable).assertTrue();
      expect(r.compact).assertTrue();
      expect(r.spacingVp).assertEqual(12);
      expect(r.quickH + r.spacingVp + r.navH).assertEqual(availH);
      const minSpacing: number = 2 * COMPACT_OUTER_PAD_V_VP + SIDE_GROUP_DIVIDER_HEIGHT;
      const edge: SideGroupLayout = layoutSideGroups(navH + minSpacing, navH, quickGroupIdealHeightVp());
      expect(edge.spacingVp).assertEqual(minSpacing);
      expect(edge.quickH + edge.spacingVp + edge.navH).assertLessOrEqual(navH + minSpacing + 0.001);
      const unreachable: SideGroupLayout = layoutSideGroups(navH + 4, navH, quickGroupIdealHeightVp());
      expect(unreachable.spacingVp).assertEqual(minSpacing);
      expect(unreachable.navH).assertEqual(navH);
    });

    it('physicalLimitKeepsMainNavIntact', 0, () => {
      const navH: number = mainNavGroupHeightVp();
      const minSpacing: number = 2 * COMPACT_OUTER_PAD_V_VP + SIDE_GROUP_DIVIDER_HEIGHT;
      const r: SideGroupLayout = layoutSideGroups(navH + 0, navH, quickGroupIdealHeightVp());
      expect(r.navH).assertEqual(navH);
      expect(r.quickH).assertEqual(0);
      expect(r.quickScrollable).assertTrue();
      expect(r.compact).assertTrue();
      expect(r.spacingVp).assertEqual(minSpacing);
      expect(r.quickH + r.spacingVp + r.navH).assertLessOrEqual(navH + minSpacing + 0.001);
    });

    it('invalidInputsFallbackSafe', 0, () => {
      // 非法输入：保底两分组可见 + 快捷组可滚（不抛异常、不裁切）
      const navH: number = mainNavGroupHeightVp();
      const quickH: number = quickGroupIdealHeightVp();
      const r1: SideGroupLayout = layoutSideGroups(0, navH, quickH);
      expect(r1.navH).assertEqual(navH);
      expect(r1.quickH).assertEqual(quickH);
      expect(r1.quickScrollable).assertTrue();
      const r2: SideGroupLayout = layoutSideGroups(-10, navH, quickH);
      expect(r2.navH).assertEqual(navH);
      expect(r2.quickScrollable).assertTrue();
      const r3: SideGroupLayout = layoutSideGroups(NaN, navH, quickH);
      expect(r3.quickH).assertEqual(quickH);
      expect(r3.quickScrollable).assertTrue();
      const r4: SideGroupLayout = layoutSideGroups(1000, 0, quickH);
      expect(r4.navH).assertEqual(mainNavGroupHeightVp());
      expect(r4.quickScrollable).assertTrue();
      const r5: SideGroupLayout = layoutSideGroups(1000, navH, -5);
      expect(r5.navH).assertEqual(navH);
      expect(r5.quickScrollable).assertTrue();
    });

    it('availHeightFormulaMatchesContract', 0, () => {
      // 唯一口径：H_avail = heightVp - topVp - bottomVp - 2*NAV_RAIL_MARGIN
      expect(sideRailAvailHeightVp(1624, 0, 24))
        .assertEqual(1624 - 0 - 24 - 2 * ThemeDims.NAV_RAIL_MARGIN);
      expect(sideRailAvailHeightVp(800, 30, 24))
        .assertEqual(800 - 30 - 24 - 2 * ThemeDims.NAV_RAIL_MARGIN);
      // 非法输入（<=0 / 负避让 / NaN）→ 0（保底接管）
      expect(sideRailAvailHeightVp(0, 0, 0)).assertEqual(0);
      expect(sideRailAvailHeightVp(-100, 0, 0)).assertEqual(0);
      expect(sideRailAvailHeightVp(100, 0, -5)).assertEqual(0);
      expect(sideRailAvailHeightVp(NaN, 0, 0)).assertEqual(0);
      // 可用高度必为 2*MARGIN 的净高：过高必然导致整体超屏时由布局兜底
      expect(sideRailAvailHeightVp(200, 0, 0)).assertEqual(200 - 2 * ThemeDims.NAV_RAIL_MARGIN);
    });

    it('geometryHelperRecomputesOnWindowChange', 0, () => {
      const tall: SideGroupLayout = sideGroupsForGeometry(1624, 0, 24);
      expect(tall.quickScrollable).assertFalse();
      expect(tall.compact).assertFalse();
      expect(tall.quickH).assertEqual(quickGroupIdealHeightVp(false));

      // 紧凑横屏（420vp）：启用紧凑密度，8 项入口完整同屏展示且不滚动
      const compactLand: SideGroupLayout = sideGroupsForGeometry(420, 0, 24);
      expect(compactLand.compact).assertTrue();
      expect(compactLand.quickScrollable).assertFalse();
      expect(compactLand.navH).assertEqual(mainNavGroupHeightVp(true));

      const restored: SideGroupLayout = sideGroupsForGeometry(1624, 0, 24);
      expect(restored.quickScrollable).assertFalse();
      expect(restored.compact).assertFalse();
    });

    it('compactLandscapeFitsAllEightItemsWithoutScrolling', 0, () => {
      // 紧凑横屏档：360vp / 400vp / 430vp 可用高度下 8 项总高严格 <= availH 且无需滚动
      const compactHeights: number[] = [360, 400, 430];
      for (let i = 0; i < compactHeights.length; i++) {
        const availH: number = compactHeights[i];
        const r: SideGroupLayout = sideGroupsForAvailHeight(availH);
        expect(r.compact).assertTrue();
        expect(r.quickScrollable).assertFalse();
        expect(r.capsuleH).assertLargerOrEqual(32);
        expect(r.navItemH).assertLargerOrEqual(44);
        expect(r.quickH + r.spacingVp + r.navH).assertLessOrEqual(availH);
      }

      // 标准横屏档（>= 520vp）：600vp / 768vp 使用舒展常规尺寸
      const standardHeights: number[] = [SIDE_COMPACT_BREAKPOINT_VP, 600, 768];
      for (let i = 0; i < standardHeights.length; i++) {
        const availH: number = standardHeights[i];
        const r: SideGroupLayout = sideGroupsForAvailHeight(availH);
        expect(r.compact).assertFalse();
        expect(r.quickScrollable).assertFalse();
        expect(r.navH).assertEqual(mainNavGroupHeightVp(false));
        expect(r.quickH).assertEqual(quickGroupIdealHeightVp(false));
      }

      // 极端分屏/小窗兜底档（< 330vp）：启用 Scroll 滚动兜底不溢出
      const tiny: SideGroupLayout = sideGroupsForAvailHeight(300);
      expect(tiny.compact).assertTrue();
      expect(tiny.quickScrollable).assertTrue();
      expect(SIDE_EXTREME_TINY_BREAKPOINT_VP).assertEqual(330);
      expect(tiny.quickH + tiny.spacingVp + tiny.navH).assertLessOrEqual(300);
    });

    it('spacingContractUsesTokensOnly', 0, () => {
      expect(sideGroupSpacingVp(false))
        .assertEqual(2 * ThemeDims.SPACE_M + 2 * ThemeDims.NAV_RAIL_ITEM_GAP + SIDE_GROUP_DIVIDER_HEIGHT);
      expect(sideGroupSpacingVp(true))
        .assertEqual(2 * COMPACT_OUTER_PAD_V_VP + 2 * COMPACT_INNER_GAP_VP + SIDE_GROUP_DIVIDER_HEIGHT);
      expect(sideGroupSpacingVp(true)).assertLess(sideGroupSpacingVp(false));
      expect(SIDE_SEARCH_BUTTON_SIZE).assertEqual(40);
      expect(sideGroupInnerGapVp(sideGroupSpacingVp(false), ThemeDims.SPACE_M))
        .assertEqual(ThemeDims.NAV_RAIL_ITEM_GAP);
      expect(sideGroupInnerGapVp(sideGroupSpacingVp(true), COMPACT_OUTER_PAD_V_VP))
        .assertEqual(COMPACT_INNER_GAP_VP);
      expect(sideGroupInnerGapVp(0)).assertEqual(0);
      expect(sideGroupInnerGapVp(10)).assertEqual(0);
    });

    it('sideRailOverlayStackPreservesContentLeftPaddingOnlyInLandscape', 0, () => {
      // 根因 B 回归测试：竖屏（isBottomNav=true）左侧内边距为 0；
      // 横屏（isBottomNav=false）悬浮 Stack 下主内容左侧安全内边距 = ThemeDims.NAV_RAIL_TOTAL_WIDTH（92vp）
      expect(sideRailContentLeftPaddingVp(true)).assertEqual(0);
      expect(sideRailContentLeftPaddingVp(false)).assertEqual(ThemeDims.NAV_RAIL_TOTAL_WIDTH);
    });

    it('adaptsSideRailQuickEntriesAcrossPhoneFoldableAndTabletRatios', 0, () => {
      expect(SIDE_QUICK_ENTRIES_MIN_HEIGHT_VP).assertEqual(640);
      // 横屏 SideRail 固定只保留 4 个核心主 Tab，快捷入口统一收敛在 HomeComponent 顶部
      expect(shouldShowQuickEntriesInSideRail(390)).assertFalse();
      expect(shouldShowQuickEntriesInSideRail(720)).assertFalse();
      expect(shouldShowHomeTopEntries(true, 844)).assertTrue();
      expect(shouldShowHomeTopEntries(false, 390)).assertTrue();
      expect(shouldShowHomeTopEntries(true, 800)).assertTrue();
      expect(shouldShowHomeTopEntries(false, 720)).assertTrue();
    });
  });
}