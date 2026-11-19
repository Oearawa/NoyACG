/**
 * Phase15R2.test.ets —— 导航形态单源 / 密度换算 / 内容留白 纯函数单测（Phase 15-R2）
 *
 * 覆盖：
 * 1. R2-1 形态判定：折叠竖屏 1264×1848、展开竖屏 1624×2296、展开横屏 2296×1624；
 *    1.15 / 1.20 / 1.25 临界与滞回带；非法尺寸保持既有形态。
 * 2. R2-5 密度换算：px→vp 用当次密度，非法密度回退常量，绝不返回 NaN。
 * 3. R2-3 / R2-4 留白：底栏 = 栏高 + 栏底边距 + 避让；侧栏只留系统避让。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  NavigationMode,
  resolveNavigationMode,
  windowAspectRatio,
  isBottomNavigation,
  INITIAL_SIDE_RATIO,
  SIDE_ENTER_RATIO,
  BOTTOM_ENTER_RATIO
} from '../main/ets/utils/NavigationMode';
import { ViewportState } from '../main/ets/utils/ViewportState';
import { pxToVp, normalizeDensity, FALLBACK_DENSITY } from '../main/ets/utils/Geometry';
import { contentEndInset, floatingBarBottomMargin, FLOATING_BAR_GAP } from '../main/ets/utils/BottomInset';
import { ThemeDims } from '../main/ets/utils/Theme';

const BOTTOM: NavigationMode = NavigationMode.BOTTOM_IMMERSIVE;
const SIDE: NavigationMode = NavigationMode.SIDE;

/** 用「宽高比」构造窗口（高度固定 1000vp） */
function atRatio(ratio: number, current?: NavigationMode): NavigationMode {
  return resolveNavigationMode(ratio * 1000, 1000, current);
}

export default function phase15r2Test(): void {
  describe('Phase15R2_ShapeByWindowRatio', () => {

    // ---------- 真实设备尺寸（vp 与 px 同比例，形态判定只看比值） ----------

    it('foldedPortrait1264x1848IsBottom', 0, () => {
      // 1264 / 1848 = 0.684 —— 折叠态竖屏，必须是底栏（旧实现按 939.6vp 内容宽度判成 expanded → 侧栏，S1）
      expect(resolveNavigationMode(1264, 1848, undefined)).assertEqual(BOTTOM);
    });

    it('unfoldedPortrait1624x2296IsBottom', 0, () => {
      // 1624 / 2296 = 0.707 —— 展开竖屏，同样是底栏
      expect(resolveNavigationMode(1624, 2296, undefined)).assertEqual(BOTTOM);
    });

    it('unfoldedLandscape2296x1624IsSide', 0, () => {
      // 2296 / 1624 = 1.413 —— 展开横屏才是侧栏
      expect(resolveNavigationMode(2296, 1624, undefined)).assertEqual(SIDE);
    });

    it('sameGeometryAlwaysSameResult', 0, () => {
      // 同一窗口反复进入，结果必须一致（S1 的另一半：不是「同一尺寸两种导航」）
      for (let i = 0; i < 5; i++) {
        expect(resolveNavigationMode(1264, 1848, undefined)).assertEqual(BOTTOM);
      }
      // 从侧栏形态回到同一竖屏，也必须收敛到底栏
      expect(resolveNavigationMode(1264, 1848, SIDE)).assertEqual(BOTTOM);
    });

    // ---------- 阈值与滞回 ----------

    it('coldStartThreshold', 0, () => {
      expect(atRatio(INITIAL_SIDE_RATIO - 0.0001)).assertEqual(BOTTOM);
      expect(atRatio(INITIAL_SIDE_RATIO)).assertEqual(SIDE);
      expect(atRatio(INITIAL_SIDE_RATIO + 0.1)).assertEqual(SIDE);
    });

    it('bottomToSideRequires125', 0, () => {
      expect(atRatio(SIDE_ENTER_RATIO - 0.0001, BOTTOM)).assertEqual(BOTTOM);
      expect(atRatio(SIDE_ENTER_RATIO, BOTTOM)).assertEqual(SIDE);
    });

    it('sideToBottomRequires115', 0, () => {
      expect(atRatio(BOTTOM_ENTER_RATIO + 0.0001, SIDE)).assertEqual(SIDE);
      expect(atRatio(BOTTOM_ENTER_RATIO, SIDE)).assertEqual(BOTTOM);
    });

    it('hysteresisBandDoesNotFlip', 0, () => {
      let mode: NavigationMode = BOTTOM;
      for (let i = 0; i < 10; i++) {
        mode = atRatio(1.22, mode); // 未达 1.25，保持底栏
        expect(mode).assertEqual(BOTTOM);
        mode = atRatio(1.18, mode); // 未低于 1.15，保持底栏
        expect(mode).assertEqual(BOTTOM);
      }
    });

    it('invalidGeometryKeepsCurrentMode', 0, () => {
      expect(resolveNavigationMode(0, 0, SIDE)).assertEqual(SIDE);
      expect(resolveNavigationMode(-10, 100, SIDE)).assertEqual(SIDE);
      expect(resolveNavigationMode(NaN, NaN, SIDE)).assertEqual(SIDE);
      expect(resolveNavigationMode(Infinity, 100, SIDE)).assertEqual(SIDE);
      // 冷启动非法尺寸 → 安全默认底栏
      expect(resolveNavigationMode(0, 0, undefined)).assertEqual(BOTTOM);
    });

    it('ratioAndPredicate', 0, () => {
      expect(windowAspectRatio(0, 100)).assertEqual(0);
      expect(windowAspectRatio(2000, 1000)).assertEqual(2);
      expect(isBottomNavigation(BOTTOM)).assertTrue();
      expect(isBottomNavigation(SIDE)).assertFalse();
    });
  });

  describe('Phase15R2_ViewportStateSingleSource', () => {

    it('setGeometryRejectsInvalidSamples', 0, () => {
      const state: ViewportState = new ViewportState();
      state.setGeometry(1264, 1848, 0, 24);
      expect(state.navMode).assertEqual(BOTTOM);
      // 非法样本：一个字段都不能改（旧实现会把 0 宽度的中间态冻结成形态）
      state.setGeometry(0, 0, 0, 0);
      expect(state.navMode).assertEqual(BOTTOM);
      expect(state.widthVp).assertEqual(1264);
      state.setGeometry(NaN, 1848, 0, 24);
      expect(state.widthVp).assertEqual(1264);
    });

    it('sideModeThenPortraitReturnsBottom', 0, () => {
      const state: ViewportState = new ViewportState();
      state.setGeometry(2296, 1624, 0, 24);
      expect(state.navMode).assertEqual(SIDE);
      // 折叠回竖屏：一处状态即完成形态切换，不存在第二个「朝向」布尔与之打架
      state.setGeometry(1264, 1848, 0, 24);
      expect(state.navMode).assertEqual(BOTTOM);
      expect(state.isBottomNav()).assertTrue();
    });

    it('bottomVpFeedsContentInset', 0, () => {
      const state: ViewportState = new ViewportState();
      state.setGeometry(1264, 1848, 30, 24);
      expect(state.bottomVp).assertEqual(24);
      expect(contentEndInset(ThemeDims.BOTTOM_BAR_HEIGHT, state.isBottomNav(), state.bottomVp))
        .assertEqual(ThemeDims.BOTTOM_BAR_HEIGHT + FLOATING_BAR_GAP + 24);
    });
  });

  describe('Phase15R2_DensityAndInset', () => {

    it('pxToVpUsesGivenDensity', 0, () => {
      // 同一 px 在不同密度下必须得到不同 vp（密度不得被永久缓存）
      expect(pxToVp(1264, 3.0)).assertEqual(1264 / 3.0);
      expect(pxToVp(1264, 2.0)).assertEqual(1264 / 2.0);
      // 折叠态 1264px@3.0 ≈ 421vp，比值 0.684 → 底栏
      // 用容差比较：两次除法各自有末位舍入，不能直接 assertEqual 浮点结果
      const ratioFromVp: number = pxToVp(1264, 3.0) / pxToVp(1848, 3.0);
      expect(Math.abs(ratioFromVp - 1264 / 1848) < 1e-9).assertTrue();
    });

    it('pxToVpIsSafe', 0, () => {
      expect(pxToVp(0, 3)).assertEqual(0);
      expect(pxToVp(-5, 3)).assertEqual(0);
      expect(pxToVp(NaN, 3)).assertEqual(0);
      expect(Number.isNaN(pxToVp(100, 0))).assertFalse(); // 密度 0 → 回退常量，不产生 NaN
      expect(pxToVp(300, 0)).assertEqual(300 / FALLBACK_DENSITY);
    });

    it('normalizeDensityFallsBack', 0, () => {
      expect(normalizeDensity(3)).assertEqual(3);
      expect(normalizeDensity(0)).assertEqual(FALLBACK_DENSITY);
      expect(normalizeDensity(-1)).assertEqual(FALLBACK_DENSITY);
      expect(normalizeDensity(NaN)).assertEqual(FALLBACK_DENSITY);
    });

    it('contentInsetBottomVersusSide', 0, () => {
      const bar: number = ThemeDims.BOTTOM_BAR_HEIGHT;
      // 底栏：栏高 + 栏底边距 + 避让
      expect(contentEndInset(bar, true, 24)).assertEqual(bar + FLOATING_BAR_GAP + 24);
      expect(contentEndInset(bar, true, 0)).assertEqual(bar + FLOATING_BAR_GAP);
      // 侧栏：不预留底栏空间，只留系统导航避让（S3 的直接断言）
      expect(contentEndInset(bar, false, 24)).assertEqual(24);
      expect(contentEndInset(bar, false, 0)).assertEqual(0);
    });

    it('insetNormalizesIllegalAvoid', 0, () => {
      expect(floatingBarBottomMargin(-10)).assertEqual(FLOATING_BAR_GAP);
      expect(floatingBarBottomMargin(NaN)).assertEqual(FLOATING_BAR_GAP);
      expect(contentEndInset(56, true, -10)).assertEqual(56 + FLOATING_BAR_GAP);
      expect(contentEndInset(-56, true, 0)).assertEqual(FLOATING_BAR_GAP);
    });
  });
}
