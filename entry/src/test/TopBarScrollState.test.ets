/**
 * TopBarScrollState.test.ets —— 顶栏滚动收起状态机单测（p1-native-material-shell Task 1）
 *
 * 覆盖状态机契约：
 *   1. 初始态展开 / accum 0 / 偏移 0；
 *   2. 防抖：|delta| < 0.5 完全忽略（不推进任何字段）；= 0.5 不忽略；
 *   3. 向下累计 >= 24vp 收起（边界 24 与 23.9）；
 *   4. 向上累计 >= 8vp 恢复（边界 8 与 7.9）；
 *   5. 方向翻转重置累计；
 *   6. lastOffsetVp 单调推进（忽略步除外）；
 *   7. 非法 delta（NaN）整步忽略。
 */
import { describe, it, expect } from '@ohos/hypium';
import { TopBarScrollConfig, DEFAULT_TOP_BAR_SCROLL_CONFIG,
  initialTopBarState, nextTopBarState } from '../main/ets/utils/TopBarScrollState';

const CFG: TopBarScrollConfig = DEFAULT_TOP_BAR_SCROLL_CONFIG;

export default function topBarScrollStateTest(): void {
  describe('TopBarScrollState', () => {

    it('initialStateIsExpanded', 0, () => {
      const s = initialTopBarState();
      expect(s.collapsed).assertFalse();
      expect(s.accumVp).assertEqual(0);
      expect(s.lastOffsetVp).assertEqual(0);
    });

    it('debounceIgnoresDeltaBelowHalfVp', 0, () => {
      let s = initialTopBarState();
      s = nextTopBarState(s, 0.4, CFG);
      expect(s.collapsed).assertFalse();
      expect(s.accumVp).assertEqual(0);
      expect(s.lastOffsetVp).assertEqual(0);
    });

    it('debounceBoundaryHalfVpIsConsumed', 0, () => {
      let s = initialTopBarState();
      s = nextTopBarState(s, 0.5, CFG);
      expect(s.accumVp).assertEqual(0.5);
      expect(s.lastOffsetVp).assertEqual(0.5);
    });

    it('collapsesAtExact24Vp', 0, () => {
      let s = initialTopBarState();
      s = nextTopBarState(s, 10, CFG);
      expect(s.collapsed).assertFalse();
      s = nextTopBarState(s, 14, CFG);
      expect(s.collapsed).assertTrue();
      expect(s.accumVp).assertEqual(24);
    });

    it('staysExpandedBelow24Vp', 0, () => {
      let s = initialTopBarState();
      s = nextTopBarState(s, 10, CFG);
      s = nextTopBarState(s, 13.9, CFG);
      expect(s.collapsed).assertFalse();
    });

    it('restoresAtExact8VpOfUpScroll', 0, () => {
      let s = initialTopBarState();
      s = nextTopBarState(s, 30, CFG);
      expect(s.collapsed).assertTrue();
      s = nextTopBarState(s, -8, CFG);
      expect(s.collapsed).assertFalse();
      expect(s.accumVp).assertEqual(-8);
    });

    it('staysCollapsedBelow8VpOfUpScroll', 0, () => {
      let s = initialTopBarState();
      s = nextTopBarState(s, 30, CFG);
      expect(s.collapsed).assertTrue();
      s = nextTopBarState(s, -7.9, CFG);
      expect(s.collapsed).assertTrue();
      expect(s.accumVp).assertEqual(-7.9);
    });

    it('directionFlipResetsAccumulation', 0, () => {
      let s = initialTopBarState();
      s = nextTopBarState(s, 10, CFG);
      s = nextTopBarState(s, 10, CFG);
      expect(s.accumVp).assertEqual(20);
      // 方向翻转：累计重置为本次 delta（-5），不再延续 +20
      s = nextTopBarState(s, -5, CFG);
      expect(s.accumVp).assertEqual(-5);
      expect(s.collapsed).assertFalse();
      // 继续向上累计到 -8 才恢复（此前已展开，无形态变化）
      s = nextTopBarState(s, -3, CFG);
      expect(s.accumVp).assertEqual(-8);
      expect(s.collapsed).assertFalse();
    });

    it('sameDirectionKeepsAccumulating', 0, () => {
      let s = initialTopBarState();
      s = nextTopBarState(s, 10, CFG);
      s = nextTopBarState(s, 10, CFG);
      s = nextTopBarState(s, 10, CFG);
      expect(s.collapsed).assertTrue();
      expect(s.accumVp).assertEqual(30);
    });

    it('tracksLastOffsetMonotonically', 0, () => {
      let s = initialTopBarState();
      s = nextTopBarState(s, 10, CFG);
      s = nextTopBarState(s, 14, CFG);
      expect(s.lastOffsetVp).assertEqual(24);
      // 忽略步不推进 lastOffset
      s = nextTopBarState(s, 0.4, CFG);
      expect(s.lastOffsetVp).assertEqual(24);
      s = nextTopBarState(s, 0.5, CFG);
      expect(s.lastOffsetVp).assertEqual(24.5);
    });

    it('nanDeltaIsIgnoredEntirely', 0, () => {
      let s = initialTopBarState();
      s = nextTopBarState(s, 30, CFG);
      const before = s;
      s = nextTopBarState(s, Number.NaN, CFG);
      expect(s.collapsed).assertTrue();
      expect(s.accumVp).assertEqual(before.accumVp);
      expect(s.lastOffsetVp).assertEqual(before.lastOffsetVp);
    });

    it('afterRestoreWithRemainderDownwardReachievesCollapse', 0, () => {
      let s = initialTopBarState();
      s = nextTopBarState(s, 30, CFG);   // collapsed
      s = nextTopBarState(s, -10, CFG);  // restored（accum -10）
      expect(s.collapsed).assertFalse();
      // 方向翻转后向下累计 24 再次收起
      s = nextTopBarState(s, 24, CFG);
      expect(s.collapsed).assertTrue();
      expect(s.accumVp).assertEqual(24);
    });
  });
}
