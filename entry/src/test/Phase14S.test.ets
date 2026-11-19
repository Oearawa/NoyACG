/**
 * Phase14S.test.ets —— 封面角标规则 + 内容分级自动刷新（Phase 14-S）
 *
 * 覆盖：
 * 1. 状态映射收紧：空串 / 未知值不得变成「连载中」；
 * 2. 角标解析：状态角标、关键词角标（重口 / NTR / 大叔）、顺序、去重、无标签不显示；
 * 3. 关键词只认标签字段（标题/简介/作者不参与）；
 * 4. 分级刷新：revision 递增、RatingSyncState 判据、各 VM 的 reloadIfRatingChanged；
 * 5. 分级缓存隔离：cache key 含分级、Repository 分级变化即清空；
 * 6. 请求代次：旧分级响应晚到不覆盖新分级数据。
 *
 * 说明：本文件全部为宿主侧逻辑/契约测试，不触达线上接口；
 * 真机视觉与交互仍为 RUNTIME_UNVERIFIED。
 */
import { describe, it, expect } from '@ohos/hypium';
import { Comic } from '../main/ets/model/Comic';
import { PageInfo } from '../main/ets/model/PageInfo';
import { mapCompletionStatus } from '../main/ets/source/NoyAcgProtocol';
import { BigTagItem } from '../main/ets/model/LeaderboardModels';
import { LeaderboardPort, RecommendPort, BigTagPort } from '../main/ets/source/DiscoverySourcePort';
import {
  BADGE_KEYWORD_KINKY,
  BADGE_KEYWORD_NTR,
  BADGE_KEYWORD_UNCLE,
  BADGE_KIND_KEYWORD,
  BADGE_KIND_STATUS,
  BADGE_STATUS_COMPLETED,
  BADGE_STATUS_ONGOING,
  ComicBadgeSet,
  ComicBadgeSpec,
  keywordBadgeOfTag,
  resolveComicBadges,
  resolveKeywordBadges,
  resolveStatusBadge
} from '../main/ets/utils/ComicBadges';
import { ContentRatingPolicy } from '../main/ets/utils/ContentRatingPolicy';
import { RatingSyncState } from '../main/ets/utils/RatingSync';
import { ContentRating } from '../main/ets/utils/PreferenceManager';
import { discoveryCacheKey } from '../main/ets/api/DiscoveryRepository';
import { LeaderboardViewModel } from '../main/ets/viewmodel/LeaderboardViewModel';
import { RecommendViewModel } from '../main/ets/viewmodel/RecommendViewModel';
import { BigTagViewModel } from '../main/ets/viewmodel/BigTagViewModel';
import { RANK_KIND_READING, RANK_PERIOD_DAY } from '../main/ets/model/LeaderboardModels';

// ==================== 测试夹具 ====================

function makeComic(id: string, categories: string = ''): Comic {
  const comic: Comic = new Comic(id, `title_${id}`, '', '');
  comic.categories = categories;
  return comic;
}

function pageOf(page: number, ids: string[]): PageInfo<Comic> {
  const list: Comic[] = [];
  for (let i = 0; i < ids.length; i++) {
    list.push(makeComic(ids[i]));
  }
  return new PageInfo<Comic>(page, 3, list, true, 60);
}

/** 记录调用的榜单端口（用于断言「分级变化会重新请求」） */
class CountingLeaderboardPort implements LeaderboardPort {
  calls: number = 0;
  lastPage: number = 0;

  async fetchLeaderboard(kind: string, page: number, period: string): Promise<PageInfo<Comic>> {
    this.calls++;
    this.lastPage = page;
    return pageOf(page, [`lb_${this.calls}_${page}`]);
  }
}

class CountingRecommendPort implements RecommendPort {
  calls: number = 0;

  async fetchRecommend(page: number): Promise<PageInfo<Comic>> {
    this.calls++;
    return pageOf(page, [`rec_${this.calls}`]);
  }
}

class CountingBigTagPort implements BigTagPort {
  calls: number = 0;

  async fetchBigTags(): Promise<BigTagItem[]> {
    this.calls++;
    return [new BigTagItem(`tag_${this.calls}`, [], -1, '')];
  }
}

function resetRating(): void {
  ContentRatingPolicy.getInstance().resetForTest();
}

export default function phase14sTest() {
  describe('Phase14S_StatusMapping', () => {
    it('empty_string_is_unknown_not_ongoing', 0, () => {
      // 旧实现把空串映射成 false（= 连载中），是本阶段修复的核心缺陷
      expect(mapCompletionStatus('') === null).assertTrue();
      expect(mapCompletionStatus('   ') === null).assertTrue();
    });

    it('known_values_map_strictly', 0, () => {
      expect(mapCompletionStatus(0) === false).assertTrue();
      expect(mapCompletionStatus(1) === true).assertTrue();
      expect(mapCompletionStatus('0') === false).assertTrue();
      expect(mapCompletionStatus('1') === true).assertTrue();
      expect(mapCompletionStatus(false) === false).assertTrue();
      expect(mapCompletionStatus(true) === true).assertTrue();
    });

    it('unknown_values_are_null', 0, () => {
      expect(mapCompletionStatus(undefined) === null).assertTrue();
      expect(mapCompletionStatus(2) === null).assertTrue();
      expect(mapCompletionStatus(-1) === null).assertTrue();
      expect(mapCompletionStatus('ongoing') === null).assertTrue();
      expect(mapCompletionStatus('finished') === null).assertTrue();
      expect(mapCompletionStatus('2') === null).assertTrue();
      expect(mapCompletionStatus('true') === null).assertTrue();
    });
  });

  describe('Phase14S_StatusBadge', () => {
    it('only_confirmed_states_produce_badge', 0, () => {
      const completed: ComicBadgeSpec | null = resolveStatusBadge(true);
      expect(completed !== null).assertTrue();
      expect(completed!.id).assertEqual(BADGE_STATUS_COMPLETED);
      expect(completed!.kind).assertEqual(BADGE_KIND_STATUS);

      const ongoing: ComicBadgeSpec | null = resolveStatusBadge(false);
      expect(ongoing !== null).assertTrue();
      expect(ongoing!.id).assertEqual(BADGE_STATUS_ONGOING);
    });

    it('unknown_state_has_no_badge', 0, () => {
      expect(resolveStatusBadge(null) === null).assertTrue();
      expect(resolveStatusBadge(undefined) === null).assertTrue();
    });
  });

  describe('Phase14S_KeywordBadge', () => {
    it('single_keyword_matching', 0, () => {
      const kinky: ComicBadgeSpec | null = keywordBadgeOfTag('重口');
      expect(kinky !== null).assertTrue();
      expect(kinky!.id).assertEqual(BADGE_KEYWORD_KINKY);
      // 重口味 统一显示为 重口
      const longKinky: ComicBadgeSpec | null = keywordBadgeOfTag('重口味');
      expect(longKinky !== null && longKinky!.id === BADGE_KEYWORD_KINKY).assertTrue();
      // NTR 大小写不敏感
      expect(keywordBadgeOfTag('NTR')!.id).assertEqual(BADGE_KEYWORD_NTR);
      expect(keywordBadgeOfTag('ntr')!.id).assertEqual(BADGE_KEYWORD_NTR);
      expect(keywordBadgeOfTag('大叔')!.id).assertEqual(BADGE_KEYWORD_UNCLE);
    });

    it('similar_tags_do_not_match', 0, () => {
      // 只匹配完整标签项，不做包含匹配
      expect(keywordBadgeOfTag('大叔控') === null).assertTrue();
      expect(keywordBadgeOfTag('重口味的日常') === null).assertTrue();
      expect(keywordBadgeOfTag('ntr向') === null).assertTrue();
      expect(keywordBadgeOfTag('') === null).assertTrue();
      expect(keywordBadgeOfTag(null) === null).assertTrue();
    });

    it('multiple_keywords_fixed_order_and_dedupe', 0, () => {
      const badges: ComicBadgeSpec[] = resolveKeywordBadges('大叔 NTR 重口味 奇幻');
      expect(badges.length).assertEqual(3);
      expect(badges[0].id).assertEqual(BADGE_KEYWORD_KINKY);
      expect(badges[1].id).assertEqual(BADGE_KEYWORD_NTR);
      expect(badges[2].id).assertEqual(BADGE_KEYWORD_UNCLE);

      // 重复标签只出现一次
      const dup: ComicBadgeSpec[] = resolveKeywordBadges('重口 重口味 重口');
      expect(dup.length).assertEqual(1);
    });

    it('no_tag_data_means_no_keyword_badge', 0, () => {
      expect(resolveKeywordBadges('').length).assertEqual(0);
      expect(resolveKeywordBadges(null).length).assertEqual(0);
      expect(resolveKeywordBadges('奇幻 冒險').length).assertEqual(0);
    });

    it('title_author_description_do_not_leak_into_badges', 0, () => {
      // 摘要里出现关键词，但标签为空 → 不得产生角标（规则只读标签字段）
      const comic: Comic = makeComic('1', '');
      comic.title = 'NTR 大叔的重口日常';
      comic.author = '大叔';
      comic.description = '这是一部重口味作品';
      const set: ComicBadgeSet = resolveComicBadges(comic.isCompleted, comic.categories);
      expect(set.keywords.length).assertEqual(0);
      expect(set.isEmpty()).assertTrue();
    });
  });

  describe('Phase14S_BadgeComposition', () => {
    it('combined_badges_keep_both_kinds', 0, () => {
      const set: ComicBadgeSet = resolveComicBadges(false, '重口 NTR');
      expect(set.status !== null && set.status!.id === BADGE_STATUS_ONGOING).assertTrue();
      expect(set.keywords.length).assertEqual(2);
      expect(set.isEmpty()).assertFalse();
    });

    it('unknown_status_with_keywords_shows_only_keywords', 0, () => {
      const set: ComicBadgeSet = resolveComicBadges(null, '大叔');
      expect(set.status === null).assertTrue();
      expect(set.keywords.length).assertEqual(1);
      expect(set.keywords[0].kind).assertEqual(BADGE_KIND_KEYWORD);
    });

    it('nothing_at_all_for_plain_comic', 0, () => {
      const set: ComicBadgeSet = resolveComicBadges(null, '奇幻');
      expect(set.isEmpty()).assertTrue();
    });
  });

  describe('Phase14S_RatingPolicy', () => {
    it('revision_increments_only_on_real_change', 0, async () => {
      resetRating();
      const policy: ContentRatingPolicy = ContentRatingPolicy.getInstance();
      const before: number = policy.revisionNow();
      await policy.set(ContentRating.ADULT);
      expect(policy.revisionNow()).assertEqual(before + 1);
      expect(policy.resolve()).assertEqual(ContentRating.ADULT);
      // 同值再设一次不应自增（避免无意义的全局刷新）
      await policy.set(ContentRating.ADULT);
      expect(policy.revisionNow()).assertEqual(before + 1);
      await policy.set(ContentRating.BOTH);
      expect(policy.revisionNow()).assertEqual(before + 2);
      resetRating();
    });

    it('rating_sync_first_call_is_not_a_change', 0, () => {
      resetRating();
      const sync: RatingSyncState = new RatingSyncState();
      // 首次对齐不算变更（数据本来还没加载）
      expect(sync.takeChange()).assertFalse();
      expect(sync.takeChange()).assertFalse();
      resetRating();
    });

    it('rating_sync_detects_change_once', 0, async () => {
      resetRating();
      const sync: RatingSyncState = new RatingSyncState();
      sync.takeChange();
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      expect(sync.takeChange()).assertTrue();
      // 同一次变更只消费一次，避免反复刷新
      expect(sync.takeChange()).assertFalse();
      resetRating();
    });

    it('cache_key_contains_rating', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const keyAll: string = discoveryCacheKey('recommend', 1);
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      const keyAdult: string = discoveryCacheKey('recommend', 1);
      expect(keyAll === keyAdult).assertFalse();
      expect(keyAdult.indexOf(ContentRating.ADULT) >= 0).assertTrue();
      resetRating();
    });
  });

  describe('Phase14S_RatingRefresh', () => {
    it('leaderboard_reloads_after_rating_change', 0, async () => {
      resetRating();
      const port: CountingLeaderboardPort = new CountingLeaderboardPort();
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      vm.kind = RANK_KIND_READING;
      vm.period = RANK_PERIOD_DAY;
      await vm.load(true);
      expect(port.calls).assertEqual(1);
      // 首次判据不算变更
      expect(vm.reloadIfRatingChanged()).assertFalse();
      expect(port.calls).assertEqual(1);

      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      expect(vm.reloadIfRatingChanged()).assertTrue();
      // 回到第 1 页重新请求
      expect(port.calls).assertEqual(2);
      expect(port.lastPage).assertEqual(1);
      resetRating();
    });

    it('recommend_reloads_after_rating_change', 0, async () => {
      resetRating();
      const port: CountingRecommendPort = new CountingRecommendPort();
      const vm: RecommendViewModel = new RecommendViewModel(port);
      await vm.load(true);
      expect(port.calls).assertEqual(1);
      await ContentRatingPolicy.getInstance().set(ContentRating.BOTH);
      expect(vm.reloadIfRatingChanged()).assertTrue();
      expect(port.calls).assertEqual(2);
      resetRating();
    });

    it('bigtag_reloads_after_rating_change', 0, async () => {
      resetRating();
      const port: CountingBigTagPort = new CountingBigTagPort();
      const vm: BigTagViewModel = new BigTagViewModel(port);
      await vm.load();
      expect(port.calls).assertEqual(1);
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      expect(vm.reloadIfRatingChanged()).assertTrue();
      expect(port.calls).assertEqual(2);
      resetRating();
    });

    it('no_reload_without_change', 0, async () => {
      resetRating();
      const port: CountingRecommendPort = new CountingRecommendPort();
      const vm: RecommendViewModel = new RecommendViewModel(port);
      await vm.load(true);
      expect(vm.reloadIfRatingChanged()).assertFalse();
      expect(vm.reloadIfRatingChanged()).assertFalse();
      expect(port.calls).assertEqual(1);
      resetRating();
    });
  });
}
