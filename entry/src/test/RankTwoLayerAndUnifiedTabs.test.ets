import { describe, it, expect } from '@ohos/hypium';
import { RANK_LAYER_COUNT, rankHasPeriodSelector } from '../main/ets/pages/RankPage';
import {
  RANK_KIND_FAVORITE,
  RANK_KIND_QUALITY,
  RANK_KIND_READING
} from '../main/ets/model/LeaderboardModels';
import {
  INLINE_TOP_BAR_HEIGHT_VP,
  SCAFFOLD_TOP_BAR_HEIGHT_VP,
  secondaryHeaderTotalHeightVp
} from '../main/ets/utils/StandardScaffoldLayout';

export default function rankTwoLayerAndUnifiedTabsTest() {
  describe('RankTwoLayerAndUnifiedTabsTest', () => {
    it('rank_page_is_two_layers_with_conditional_header_period_selector', 0, () => {
      expect(RANK_LAYER_COUNT).assertEqual(2);
      expect(rankHasPeriodSelector(RANK_KIND_READING)).assertTrue();
      expect(rankHasPeriodSelector(RANK_KIND_FAVORITE)).assertTrue();
      expect(rankHasPeriodSelector(RANK_KIND_QUALITY)).assertFalse();
    });

    it('unified_top_bar_height_is_52vp_with_zero_jump', 0, () => {
      expect(SCAFFOLD_TOP_BAR_HEIGHT_VP).assertEqual(52);
      expect(INLINE_TOP_BAR_HEIGHT_VP).assertEqual(52);
      expect(secondaryHeaderTotalHeightVp(24, false)).assertEqual(76);
      expect(secondaryHeaderTotalHeightVp(24, true)).assertEqual(76);
    });
  });
}
