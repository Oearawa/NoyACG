/**
 * ResponsiveGrid.test.ets —— 响应式列数纯函数单元测试
 *
 * 覆盖任务书要求的全部边界：
 * - 窄宽度（低于两列所需）→ minCols
 * - 440vp 竖屏 → 2 列
 * - N 列 / N+1 列临界点及临界点减 1
 * - 超宽窗口被 maxCols 限制
 * - 0 / 负数 / NaN → minCols（不抛异常）
 * - buildColumnsTemplate 输出格式
 *
 * 参数与 ThemeDims 一致：minCard=160 / gap=6 / hPad=8 / minCols=2 / maxCols=6。
 * 临界点推导：列数 = floor((容器宽 - 2*hPad + gap) / (minCard + gap))
 *            = floor((容器宽 - 10) / 166)
 *   N=2 临界 342；N=3 临界 508；N=4 临界 674；N=5 临界 840；N=6 临界 1006。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  PAGINATION_BAR_COMPACT_HEIGHT_VP,
  PAGINATION_BAR_REGULAR_HEIGHT_VP,
  PAGINATION_CAPSULE_HEIGHT_VP,
  RANK_WIDE_BREAKPOINT_VP,
  isPaginationWideLayout,
  paginationFloatingInsetVp,
  rankBottomInsetVp,
  rankListColumns
} from '../main/ets/utils/Pagination';
import {
  computeColumns,
  buildColumnsTemplate,
  computeTileWidth,
  computeCoverHeight,
} from '../main/ets/utils/ResponsiveGrid';
import {
  Breakpoint,
  resolveBreakpoint,
  resolveDetailColumnSpans
} from '../main/ets/responsive/BreakpointManager';
import {
  COVER_ASPECT_RATIO,
  MAX_GRID_CARD_WIDTH_VP,
  resolveLayoutPolicy
} from '../main/ets/responsive/LayoutPolicy';
import { ViewportState } from '../main/ets/utils/ViewportState';
import { validateImageUrl } from '../main/ets/utils/ImageValidator';
import { shouldReloadImage } from '../main/ets/utils/StableLayout';

const MIN_CARD: number = 160;
const GAP: number = 6;
const H_PAD: number = 8;
const MIN_COLS: number = 2;
const MAX_COLS: number = 6;

export default function responsiveGridTest() {
  describe('ResponsiveGrid', () => {
    it('computeColumns_narrowWidth_returnsMinCols', 0, () => {
      expect(computeColumns(300, MIN_CARD, GAP, H_PAD, MIN_COLS, MAX_COLS)).assertEqual(2);
      expect(computeColumns(100, MIN_CARD, GAP, H_PAD, MIN_COLS, MAX_COLS)).assertEqual(2);
    });

    it('computeColumns_440vpPortrait_returnsTwoColumns', 0, () => {
      expect(computeColumns(440, MIN_CARD, GAP, H_PAD, MIN_COLS, MAX_COLS)).assertEqual(2);
    });

    it('computeColumns_boundaryAndBoundaryMinusOne', 0, () => {
      // N=2 临界 342（341 因 minCols 兜底仍为 2）
      expect(computeColumns(342, MIN_CARD, GAP, H_PAD, MIN_COLS, MAX_COLS)).assertEqual(2);
      expect(computeColumns(341, MIN_CARD, GAP, H_PAD, MIN_COLS, MAX_COLS)).assertEqual(2);
      // N=3 临界 508（507 退回 2）
      expect(computeColumns(508, MIN_CARD, GAP, H_PAD, MIN_COLS, MAX_COLS)).assertEqual(3);
      expect(computeColumns(507, MIN_CARD, GAP, H_PAD, MIN_COLS, MAX_COLS)).assertEqual(2);
      // N=4 临界 674（673 退回 3）
      expect(computeColumns(674, MIN_CARD, GAP, H_PAD, MIN_COLS, MAX_COLS)).assertEqual(4);
      expect(computeColumns(673, MIN_CARD, GAP, H_PAD, MIN_COLS, MAX_COLS)).assertEqual(3);
    });

    it('computeColumns_ultraWide_cappedByMaxCols', 0, () => {
      expect(computeColumns(1006, MIN_CARD, GAP, H_PAD, MIN_COLS, MAX_COLS)).assertEqual(6);
      expect(computeColumns(1280, MIN_CARD, GAP, H_PAD, MIN_COLS, MAX_COLS)).assertEqual(6);
      expect(computeColumns(5000, MIN_CARD, GAP, H_PAD, MIN_COLS, MAX_COLS)).assertEqual(6);
    });

    it('computeColumns_invalidInput_returnsMinCols', 0, () => {
      expect(computeColumns(0, MIN_CARD, GAP, H_PAD, MIN_COLS, MAX_COLS)).assertEqual(2);
      expect(computeColumns(-100, MIN_CARD, GAP, H_PAD, MIN_COLS, MAX_COLS)).assertEqual(2);
      expect(computeColumns(NaN, MIN_CARD, GAP, H_PAD, MIN_COLS, MAX_COLS)).assertEqual(2);
      // 卡片最小宽度非法 → 兜底 minCols
      expect(computeColumns(440, 0, GAP, H_PAD, MIN_COLS, MAX_COLS)).assertEqual(2);
      expect(computeColumns(440, NaN, GAP, H_PAD, MIN_COLS, MAX_COLS)).assertEqual(2);
    });

    it('buildColumnsTemplate_outputFormat', 0, () => {
      expect(buildColumnsTemplate(1)).assertEqual('1fr');
      expect(buildColumnsTemplate(2)).assertEqual('1fr 1fr');
      expect(buildColumnsTemplate(3)).assertEqual('1fr 1fr 1fr');
      expect(buildColumnsTemplate(5)).assertEqual('1fr 1fr 1fr 1fr 1fr');
      // 非法列数 → 单列兜底
      expect(buildColumnsTemplate(0)).assertEqual('1fr');
      expect(buildColumnsTemplate(-1)).assertEqual('1fr');
    });

    it('computeTileWidth_identityAcrossWidths', 0, () => {
      const widths: number[] = [320, 360, 440, 507, 508, 650, 673, 674, 840, 918, 1006, 1280, 2000];
      const COVER: number = 0.714;
      for (let i = 0; i < widths.length; i++) {
        const w: number = widths[i];
        const cols: number = computeColumns(w, MIN_CARD, GAP, H_PAD, MIN_COLS, MAX_COLS);
        const tile: number = computeTileWidth(w, cols, GAP, H_PAD);
        // 恒等式：n×tileW + (n-1)×gap + 2×hPad ≈ containerWidth（容差 0.01）
        const sum: number = cols * tile + (cols - 1) * GAP + 2 * H_PAD;
        expect(Math.abs(sum - w)).assertLess(0.01);
      }
    });

    it('computeTileWidth_referenceValues', 0, () => {
      // 440vp/2列 → 卡片 209、封面 292.7
      const t1: number = computeTileWidth(440, 2, GAP, H_PAD);
      expect(Math.abs(t1 - 209)).assertLess(0.01);
      expect(Math.abs(computeCoverHeight(t1, 0.714) - 292.7)).assertLess(0.1);
      // 650vp/3列 → 卡片 207.3、封面 290.4
      const t2: number = computeTileWidth(650, 3, GAP, H_PAD);
      expect(Math.abs(t2 - 207.3)).assertLess(0.1);
      expect(Math.abs(computeCoverHeight(t2, 0.714) - 290.4)).assertLess(0.1);
      // 918vp/5列 → 卡片 175.6、封面 245.9
      const t3: number = computeTileWidth(918, 5, GAP, H_PAD);
      expect(Math.abs(t3 - 175.6)).assertLess(0.1);
      expect(Math.abs(computeCoverHeight(t3, 0.714) - 245.9)).assertLess(0.1);
    });

    it('computeTileWidth_invalidInput_returnsZero', 0, () => {
      expect(computeTileWidth(0, 2, GAP, H_PAD)).assertEqual(0);
      expect(computeTileWidth(-100, 2, GAP, H_PAD)).assertEqual(0);
      expect(computeTileWidth(NaN, 2, GAP, H_PAD)).assertEqual(0);
      expect(computeTileWidth(440, 0, GAP, H_PAD)).assertEqual(0);
      expect(computeCoverHeight(0, 0.714)).assertEqual(0);
      expect(computeCoverHeight(-1, 0.714)).assertEqual(0);
      expect(computeCoverHeight(NaN, 0.714)).assertEqual(0);
      expect(computeCoverHeight(209, 0)).assertEqual(0);
      expect(computeCoverHeight(209, NaN)).assertEqual(0);
    });

    it('rankListColumns_switchesToTwoColumnsAt600vp', 0, () => {
      expect(rankListColumns(0)).assertEqual(1);
      expect(rankListColumns(360)).assertEqual(1);
      expect(rankListColumns(RANK_WIDE_BREAKPOINT_VP - 1)).assertEqual(1);
      expect(rankListColumns(RANK_WIDE_BREAKPOINT_VP)).assertEqual(2);
      expect(rankListColumns(840)).assertEqual(2);
      expect(rankListColumns(NaN)).assertEqual(1);
    });

    it('rankBottomInsetVp_preventsPaginationOcclusion', 0, () => {
      expect(rankBottomInsetVp(false, false, 24)).assertEqual(24);
      expect(rankBottomInsetVp(false, true, -10)).assertEqual(0);
      expect(rankBottomInsetVp(true, true, 24))
        .assertEqual(PAGINATION_BAR_COMPACT_HEIGHT_VP + 24);
      expect(rankBottomInsetVp(true, false, 24))
        .assertEqual(PAGINATION_BAR_REGULAR_HEIGHT_VP + 24);
      expect(PAGINATION_BAR_COMPACT_HEIGHT_VP < PAGINATION_BAR_REGULAR_HEIGHT_VP).assertTrue();
    });

    it('paginationCapsuleSingleRowAndFloatingInsetAcrossScreenWidths', 0, () => {
      expect(PAGINATION_CAPSULE_HEIGHT_VP).assertEqual(46);
      expect(isPaginationWideLayout(390, false)).assertFalse();
      expect(isPaginationWideLayout(600, false)).assertTrue();
      expect(isPaginationWideLayout(844, false)).assertTrue();
      expect(isPaginationWideLayout(1080, false)).assertTrue();
      expect(paginationFloatingInsetVp(false, 24)).assertEqual(24);
      expect(paginationFloatingInsetVp(true, 24)).assertEqual(66 + 24);
      expect(paginationFloatingInsetVp(true, 0)).assertEqual(66);
    });

    it('breakpointManager_resolvesFourTiersCorrectly', 0, () => {
      expect(resolveBreakpoint(0)).assertEqual(Breakpoint.XS);
      expect(resolveBreakpoint(280)).assertEqual(Breakpoint.XS);
      expect(resolveBreakpoint(319)).assertEqual(Breakpoint.XS);
      expect(resolveBreakpoint(320)).assertEqual(Breakpoint.SM);
      expect(resolveBreakpoint(390)).assertEqual(Breakpoint.SM);
      expect(resolveBreakpoint(599)).assertEqual(Breakpoint.SM);
      expect(resolveBreakpoint(600)).assertEqual(Breakpoint.MD);
      expect(resolveBreakpoint(720)).assertEqual(Breakpoint.MD);
      expect(resolveBreakpoint(839)).assertEqual(Breakpoint.MD);
      expect(resolveBreakpoint(840)).assertEqual(Breakpoint.LG);
      expect(resolveBreakpoint(1024)).assertEqual(Breakpoint.LG);
      expect(resolveBreakpoint(1440)).assertEqual(Breakpoint.LG);
      expect(resolveBreakpoint(NaN)).assertEqual(Breakpoint.SM);
      expect(resolveBreakpoint(-10)).assertEqual(Breakpoint.SM);

      expect(resolveDetailColumnSpans(Breakpoint.XS).leftSpan).assertEqual(12);
      expect(resolveDetailColumnSpans(Breakpoint.SM).rightSpan).assertEqual(12);
      expect(resolveDetailColumnSpans(Breakpoint.MD).leftSpan).assertEqual(5);
      expect(resolveDetailColumnSpans(Breakpoint.MD).rightSpan).assertEqual(7);
      expect(resolveDetailColumnSpans(Breakpoint.LG).leftSpan).assertEqual(4);
      expect(resolveDetailColumnSpans(Breakpoint.LG).rightSpan).assertEqual(8);
    });

    it('layoutPolicy_splitScreenNarrowLandscapeUsesNarrowColumns', 0, () => {
      const metrics = resolveLayoutPolicy(480, true);
      expect(metrics.breakpoint).assertEqual(Breakpoint.SM);
      expect(metrics.gridColumns).assertEqual(2);
      expect(metrics.listLanes).assertEqual(1);
      expect(metrics.pagePaddingVp).assertEqual(12);
    });

    it('layoutPolicy_capsMaxCardWidthAndComputes3By4CoverHeight', 0, () => {
      const widths: number[] = [390, 720, 840, 1280];
      for (let i = 0; i < widths.length; i++) {
        const m = resolveLayoutPolicy(widths[i], widths[i] >= 600);
        expect(m.cardWidthVp <= MAX_GRID_CARD_WIDTH_VP + 0.01).assertTrue();
        expect(Math.abs(m.coverHeightVp - m.cardWidthVp / COVER_ASPECT_RATIO) < 0.01).assertTrue();
      }
      expect(resolveLayoutPolicy(390, false).gridColumns).assertEqual(2);
      expect(resolveLayoutPolicy(720, true).gridColumns).assertEqual(4);
      expect(resolveLayoutPolicy(840, true).gridColumns).assertEqual(4);
      expect(resolveLayoutPolicy(1280, true).gridColumns >= 5).assertTrue();
    });

    it('viewportState_updatesBreakpointAndLayoutPolicyInLockstep', 0, () => {
      const vp: ViewportState = ViewportState.getInstance();
      const prevW: number = vp.widthVp;
      const prevH: number = vp.heightVp;
      const prevTop: number = vp.topVp;
      const prevBottom: number = vp.bottomVp;

      let notified: number = 0;
      const listener = (): void => {
        notified += 1;
      };
      vp.addListener(listener);
      try {
        vp.setGeometry(300, 600, 24, 20);
        expect(vp.breakpoint).assertEqual(Breakpoint.XS);
        expect(vp.getLayoutPolicy().breakpoint).assertEqual(Breakpoint.XS);

        vp.setGeometry(390, 844, 38, 28);
        expect(vp.breakpoint).assertEqual(Breakpoint.SM);
        expect(vp.getLayoutPolicy().gridColumns).assertEqual(2);

        vp.setGeometry(720, 540, 0, 20);
        expect(vp.breakpoint).assertEqual(Breakpoint.MD);
        expect(vp.getLayoutPolicy().listLanes).assertEqual(2);

        vp.setGeometry(960, 600, 0, 20);
        expect(vp.breakpoint).assertEqual(Breakpoint.LG);
        expect(vp.getLayoutPolicy().posterCardWidthVp).assertEqual(156);
        expect(notified).assertLarger(0);
      } finally {
        vp.removeListener(listener);
        vp.setGeometry(prevW, prevH, prevTop, prevBottom);
      }
    });

    it('imageCacheKey_remainsIndependentFromLayoutWidthAndColumns', 0, () => {
      const sampleCoverUrl: string = 'https://img.noymanga.com/12345/m1.webp?v=2';
      const widths: number[] = [300, 390, 600, 840, 1280];
      const normalizedKeys: string[] = [];
      for (let i = 0; i < widths.length; i++) {
        const policy = resolveLayoutPolicy(widths[i], widths[i] >= 600);
        expect(policy.cardWidthVp > 0).assertTrue();
        normalizedKeys.push(validateImageUrl(sampleCoverUrl).normalizedUrl);
        // 布局宽度变化但 URL 未变且已加载成功时，不触发重下载
        expect(shouldReloadImage(sampleCoverUrl, sampleCoverUrl, sampleCoverUrl, false)).assertFalse();
      }
      for (let i = 1; i < normalizedKeys.length; i++) {
        expect(normalizedKeys[i]).assertEqual(normalizedKeys[0]);
      }
    });
  });
}
