import { describe, it, expect } from '@ohos/hypium';
import { compactTopEntries, CompactTopEntry } from '../main/ets/components/HomeNavigationEntries';
import { resolveHdsLightButtonTextColor } from '../main/ets/components/HdsLightButton';
import { resolveRankInitialKind, resolveRankInitialPeriod, RankRoutePayload } from '../main/ets/pages/RankPage';
import { ROUTE_CATEGORY, ROUTE_PERSONALIZED, ROUTE_RANK, ROUTE_SEARCH } from '../main/ets/model/DiscoveryRoutes';
import {
  HOME_SECTION_FAV_DAY,
  HOME_SECTION_READ_DAY,
  RANK_KIND_FAVORITE,
  RANK_KIND_READING,
  homeSectionRankKind
} from '../main/ets/model/LeaderboardModels';
import { RankPageParam } from '../main/ets/model/NavParams';
import { ThemeManager } from '../main/ets/utils/ThemeManager';

export default function homeEntriesAndButtonContrastTest() {
  describe('HomeEntriesAndButtonContrastTest', () => {
    it('compact_top_entries_only_contains_category_and_search', 0, () => {
      const entries: CompactTopEntry[] = compactTopEntries();
      expect(entries.length).assertEqual(2);
      expect(entries[0].route).assertEqual(ROUTE_CATEGORY);
      expect(entries[1].route).assertEqual(ROUTE_SEARCH);
      for (let i = 0; i < entries.length; i++) {
        expect(entries[i].route !== ROUTE_RANK).assertTrue();
        expect(entries[i].route !== ROUTE_PERSONALIZED).assertTrue();
      }
    });

    it('rank_route_param_selects_favorite_and_reading_accurately', 0, () => {
      const favParam: RankPageParam = new RankPageParam(
        homeSectionRankKind(HOME_SECTION_FAV_DAY),
        'day'
      );
      expect(resolveRankInitialKind(favParam)).assertEqual(RANK_KIND_FAVORITE);
      expect(resolveRankInitialPeriod(favParam)).assertEqual('day');

      const readParam: RankPageParam = new RankPageParam(
        homeSectionRankKind(HOME_SECTION_READ_DAY),
        'day'
      );
      expect(resolveRankInitialKind(readParam)).assertEqual(RANK_KIND_READING);

      const likePayload: RankRoutePayload = { rankType: 'like', period: 'day' };
      expect(resolveRankInitialKind(likePayload)).assertEqual(RANK_KIND_FAVORITE);
      expect(resolveRankInitialPeriod(likePayload)).assertEqual('day');
    });

    it('hds_light_button_uses_high_contrast_text_primary_when_enabled', 0, () => {
      const tm: ThemeManager = ThemeManager.getInstance();
      tm.applyMode('light');
      expect(resolveHdsLightButtonTextColor('neutral', true, tm)).assertEqual('#1E293B');
      expect(resolveHdsLightButtonTextColor('neutral', false, tm)).assertEqual(tm.textSecondary);

      tm.applyMode('dark');
      expect(resolveHdsLightButtonTextColor('neutral', true, tm)).assertEqual('#F1F5F9');
      expect(resolveHdsLightButtonTextColor('neutral', false, tm)).assertEqual(tm.textSecondary);
    });
  });
}
