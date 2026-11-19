/**
 * Phase14T.test.ets —— 状态角标误显示 + 内容分级切换不刷新（Phase 14-T）
 *
 * 与 Phase 14-S 的区别：这里不满足于「解析函数返回了什么」，而是走**完整映射链路**，
 * 并模拟真实操作时序（页面已加载 → 不销毁页面 → 切换分级 → 新请求 → 新数据 → 旧响应作废）。
 *
 * 覆盖：
 * 1. 状态角标：服务端数据经 `mapBookListItem / mapSearchItem / parseBookDetailJson` 完整映射后，
 *    `isCompleted` 只有在「Mode=1 且 Status 明确 0/1」时才非 null；其余一律 null（不显示角标）；
 * 2. 关键词角标：只从完整 Ptag 匹配（不截断、不混入 Otag/标题/作者）；
 * 3. allow-adult 头：纯函数 `resolveContentRatingHeader` 证明新请求确实携带当前分级；
 * 4. 分级刷新：页面级 `RatingBridge` 订阅 + VM `refreshForRating`，验证「新请求携带新分级、
 *    数据被新结果替换、旧响应晚到不覆盖、同值不重复刷新、退订后不再刷新」；
 * 5. SearchViewModel / ComicDetailViewModel 的 `activate()` 复活被 `dispose()` 冻结的实例。
 *
 * 说明：全部为宿主侧逻辑/契约测试，不触达线上接口；真机视觉与交互仍 RUNTIME_UNVERIFIED。
 */
import { describe, it, expect } from '@ohos/hypium';
import { Comic, COMIC_MODE_CHAPTERS, COMIC_MODE_SINGLE, COMIC_MODE_UNKNOWN } from '../main/ets/model/Comic';
import {
  mapBookListItem,
  mapSearchItem,
  parseBookDetailJson
} from '../main/ets/source/NoyAcgProtocol';
import { RawBookListItem, RawSearchItem } from '../main/ets/source/NoyAcgProtocol';
import {
  BADGE_KEYWORD_KINKY,
  BADGE_KEYWORD_NTR,
  BADGE_KEYWORD_UNCLE,
  BADGE_STATUS_COMPLETED,
  BADGE_STATUS_ONGOING,
  ComicBadgeSet,
  resolveComicBadgesFromTags
} from '../main/ets/utils/ComicBadges';
import { ContentRatingPolicy } from '../main/ets/utils/ContentRatingPolicy';
import { ContentRating } from '../main/ets/utils/PreferenceManager';
import { RatingBridge } from '../main/ets/utils/RatingBridge';
import { resolveContentRatingHeader } from '../main/ets/api/ApiHeaders';
import { LeaderboardViewModel } from '../main/ets/viewmodel/LeaderboardViewModel';
import { RecommendViewModel } from '../main/ets/viewmodel/RecommendViewModel';
import { SearchViewModel } from '../main/ets/viewmodel/SearchViewModel';
import { LeaderboardPort, RecommendPort } from '../main/ets/source/DiscoverySourcePort';
import { PageInfo } from '../main/ets/model/PageInfo';
import { ComicDetail } from '../main/ets/model/ComicDetail';
import { HomeFeed } from '../main/ets/model/HomeFeed';
import { AdItem } from '../main/ets/model/AdItem';
import { CommentPage } from '../main/ets/model/BookComment';
import { IComicSource } from '../main/ets/source/IComicSource';
import { RANK_KIND_READING, RANK_PERIOD_DAY } from '../main/ets/model/LeaderboardModels';

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

function resetRating(): void {
  ContentRatingPolicy.getInstance().resetForTest();
}

function pageOf(page: number, ids: string[]): PageInfo<Comic> {
  const list: Comic[] = [];
  for (let i = 0; i < ids.length; i++) {
    const c: Comic = new Comic(ids[i], ids[i], '', '');
    list.push(c);
  }
  return new PageInfo<Comic>(page, 1, list, false);
}

// ==================== 分级感知的假端口 ====================

class RatingLeaderboardPort implements LeaderboardPort {
  calls: number = 0;
  lastRating: string = '';

  async fetchLeaderboard(kind: string, page: number, period: string): Promise<PageInfo<Comic>> {
    this.calls++;
    this.lastRating = ContentRatingPolicy.getInstance().resolve();
    return pageOf(page, [`lb_${this.lastRating}`]);
  }
}

/** 可手动延迟解析的端口：用于验证「旧分级响应晚到不覆盖新结果」 */
class DeferredLeaderboardPort implements LeaderboardPort {
  requestRatings: string[] = [];
  resolvers: ((r: PageInfo<Comic>) => void)[] = [];

  async fetchLeaderboard(kind: string, page: number, period: string): Promise<PageInfo<Comic>> {
    this.requestRatings.push(ContentRatingPolicy.getInstance().resolve());
    return new Promise<PageInfo<Comic>>((resolve) => {
      this.resolvers.push(resolve);
    });
  }
}

class RatingRecommendPort implements RecommendPort {
  calls: number = 0;
  lastRating: string = '';

  async fetchRecommend(page: number): Promise<PageInfo<Comic>> {
    this.calls++;
    this.lastRating = ContentRatingPolicy.getInstance().resolve();
    return pageOf(page, [`rec_${this.lastRating}`]);
  }
}

// ==================== 搜索用假源 ====================

class RatingFakeSource implements IComicSource {
  readonly sourceId: string = 'fake';
  readonly sourceName: string = 'fake';
  readonly baseUrl: string = 'https://noymanga.com';
  calls: number = 0;
  lastRating: string = '';

  async search(keyword: string, page: number, mode?: string): Promise<PageInfo<Comic>> {
    this.calls++;
    this.lastRating = ContentRatingPolicy.getInstance().resolve();
    const c: Comic = new Comic(`${keyword}_${this.lastRating}`, `${keyword}_${this.lastRating}`, '', '');
    return new PageInfo<Comic>(page, 1, [c], false);
  }

  async getHomeList(page: number, sort?: string, finished?: string): Promise<PageInfo<Comic>> {
    return new PageInfo<Comic>(page, 1, [], false);
  }

  async getComicDetail(id: string): Promise<ComicDetail> {
    return new ComicDetail(id, 'x', '');
  }

  async getChapterImages(bookId: string, chapterId: string): Promise<string[]> {
    return [];
  }

  async getHomeFeed(adultLevel?: string): Promise<HomeFeed> {
    return new HomeFeed();
  }

  async getAds(adultLevel?: string): Promise<AdItem[]> {
    return [];
  }

  async getBookComments(bookId: string, page: number): Promise<CommentPage> {
    return new CommentPage([], 1, true);
  }
}

export default function phase14tTest() {
  describe('Phase14T_StatusMappingChain', () => {
    it('booklist_mode1_status1_is_completed', 0, () => {
      const raw: RawBookListItem = { Bid: 1, Bookname: 'x', Mode: 1, Status: 1, Ptag: '奇幻' };
      const comic: Comic = mapBookListItem(raw);
      expect(comic.mode).assertEqual(COMIC_MODE_CHAPTERS);
      expect(comic.isCompleted === true).assertTrue();
      const set: ComicBadgeSet = resolveComicBadgesFromTags(comic.isCompleted, comic.ptag);
      expect(set.status !== null).assertTrue();
      expect(set.status!.id).assertEqual(BADGE_STATUS_COMPLETED);
    });

    it('booklist_mode1_status0_is_ongoing', 0, () => {
      const raw: RawBookListItem = { Bid: 2, Mode: 1, Status: 0 };
      const comic: Comic = mapBookListItem(raw);
      expect(comic.isCompleted === false).assertTrue();
      const set: ComicBadgeSet = resolveComicBadgesFromTags(comic.isCompleted, comic.ptag);
      expect(set.status !== null).assertTrue();
      expect(set.status!.id).assertEqual(BADGE_STATUS_ONGOING);
    });

    it('booklist_status_without_mode_is_unknown', 0, () => {
      // 核心缺陷：服务端给了 Status 但没给 Mode —— 不得显示任何状态角标
      const raw: RawBookListItem = { Bid: 3, Status: 1 };
      const comic: Comic = mapBookListItem(raw);
      expect(comic.mode).assertEqual(COMIC_MODE_UNKNOWN);
      expect(comic.isCompleted === null).assertTrue();
      const set: ComicBadgeSet = resolveComicBadgesFromTags(comic.isCompleted, comic.ptag);
      expect(set.status === null).assertTrue();
    });

    it('booklist_mode0_status1_has_no_badge', 0, () => {
      // 单本无章节：即使 Status=1 也不显示「已完结」
      const raw: RawBookListItem = { Bid: 4, Mode: 0, Status: 1 };
      const comic: Comic = mapBookListItem(raw);
      expect(comic.mode).assertEqual(COMIC_MODE_SINGLE);
      expect(comic.isCompleted === null).assertTrue();
      expect(resolveComicBadgesFromTags(comic.isCompleted, comic.ptag).status === null).assertTrue();
    });

    it('booklist_empty_and_unknown_status_are_unknown', 0, () => {
      const empty: RawBookListItem = { Bid: 5, Mode: 1, Status: '' };
      expect(mapBookListItem(empty).isCompleted === null).assertTrue();
      const unknownStr: RawBookListItem = { Bid: 6, Mode: 1, Status: 'ongoing' };
      expect(mapBookListItem(unknownStr).isCompleted === null).assertTrue();
      const unknownNum: RawBookListItem = { Bid: 7, Mode: 1, Status: 2 };
      expect(mapBookListItem(unknownNum).isCompleted === null).assertTrue();
    });

    it('string_numeric_mode_and_status_are_accepted', 0, () => {
      const raw: RawBookListItem = { Bid: 8, Mode: '1', Status: '0' };
      const comic: Comic = mapBookListItem(raw);
      expect(comic.mode).assertEqual(COMIC_MODE_CHAPTERS);
      expect(comic.isCompleted === false).assertTrue();
    });

    it('default_model_produces_no_badge', 0, () => {
      const comic: Comic = new Comic();
      expect(comic.isCompleted === null).assertTrue();
      expect(comic.mode).assertEqual(COMIC_MODE_UNKNOWN);
      expect(resolveComicBadgesFromTags(comic.isCompleted, comic.ptag).isEmpty()).assertTrue();
    });

    it('keyword_badges_use_full_ptag_only', 0, () => {
      // NTR 是第 7 个标签（会被展示摘要截断，但角标必须仍能命中）；Otag 的大叔不得命中
      const raw: RawBookListItem = {
        Bid: 9,
        Bookname: 'x',
        Mode: 1,
        Status: 1,
        Ptag: 'a b c d e f NTR',
        Otag: '大叔'
      };
      const comic: Comic = mapBookListItem(raw);
      expect(comic.ptag.length).assertEqual(7);
      const set: ComicBadgeSet = resolveComicBadgesFromTags(comic.isCompleted, comic.ptag);
      const ids: string[] = [];
      for (let i = 0; i < set.keywords.length; i++) {
        ids.push(set.keywords[i].id);
      }
      expect(ids.indexOf(BADGE_KEYWORD_NTR) >= 0).assertTrue();
      expect(ids.indexOf(BADGE_KEYWORD_UNCLE) < 0).assertTrue();
    });

    it('search_smallcase_mode_status_mapped', 0, () => {
      const raw: RawSearchItem = { id: 1, name: 'x', tags: ['重口味', '大叔'], mode: 1, status: '1' };
      const comic: Comic = mapSearchItem(raw);
      expect(comic.mode).assertEqual(COMIC_MODE_CHAPTERS);
      expect(comic.isCompleted === true).assertTrue();
      const set: ComicBadgeSet = resolveComicBadgesFromTags(comic.isCompleted, comic.ptag);
      const ids: string[] = [];
      for (let i = 0; i < set.keywords.length; i++) {
        ids.push(set.keywords[i].id);
      }
      expect(ids.indexOf(BADGE_KEYWORD_KINKY) >= 0).assertTrue();
      expect(ids.indexOf(BADGE_KEYWORD_UNCLE) >= 0).assertTrue();
    });

    it('search_mode0_status1_has_no_badge', 0, () => {
      const raw: RawSearchItem = { id: 2, name: 'y', mode: 0, status: 1 };
      const comic: Comic = mapSearchItem(raw);
      expect(comic.isCompleted === null).assertTrue();
    });

    it('detail_mode0_status1_has_no_badge', 0, () => {
      const detail: ComicDetail = parseBookDetailJson(
        '{"book":{"info":{"Bid":99,"Bookname":"z","Mode":0,"Status":1}}}', '99');
      expect(detail.mode).assertEqual(COMIC_MODE_SINGLE);
      expect(detail.isCompleted === null).assertTrue();
    });
  });

  describe('Phase14T_RatingHeader', () => {
    it('header_injected_only_for_noy_api', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      const api: Record<string, string> | undefined =
        resolveContentRatingHeader('https://noymanga.com/api/home');
      expect(api !== undefined).assertTrue();
      expect(api!['allow-adult']).assertEqual(ContentRating.ADULT);
      // 图床 / 外部域名不注入
      expect(resolveContentRatingHeader('https://img.noymanga.com/1/m1.webp')).assertEqual(undefined);
      expect(resolveContentRatingHeader('https://example.com/x')).assertEqual(undefined);
      resetRating();
    });

    it('header_reflects_latest_rating', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      expect(resolveContentRatingHeader('https://noymanga.com/api/search')!['allow-adult'])
        .assertEqual(ContentRating.ALL_AGES);
      await ContentRatingPolicy.getInstance().set(ContentRating.BOTH);
      expect(resolveContentRatingHeader('https://noymanga.com/api/search')!['allow-adult'])
        .assertEqual(ContentRating.BOTH);
      resetRating();
    });
  });

  describe('Phase14T_RatingRefreshChain', () => {
    it('leaderboard_refreshes_with_new_rating_and_replaces_data', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const port: RatingLeaderboardPort = new RatingLeaderboardPort();
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      vm.kind = RANK_KIND_READING;
      vm.period = RANK_PERIOD_DAY;
      await vm.load(true);
      expect(port.calls).assertEqual(1);
      expect(port.lastRating).assertEqual(ContentRating.ALL_AGES);
      expect(vm.items[0].title).assertEqual(`lb_${ContentRating.ALL_AGES}`);

      const bridge: RatingBridge = new RatingBridge((): void => {
        vm.refreshForRating();
      });
      bridge.start();
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      await sleep(10); // 等 fetch 完成
      expect(port.calls).assertEqual(2);
      expect(port.lastRating).assertEqual(ContentRating.ADULT);
      expect(vm.items[0].title).assertEqual(`lb_${ContentRating.ADULT}`);
      bridge.stop();
      resetRating();
    });

    it('same_rating_does_not_refetch', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      const port: RatingRecommendPort = new RatingRecommendPort();
      const vm: RecommendViewModel = new RecommendViewModel(port);
      await vm.load(true);
      expect(port.calls).assertEqual(1);
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      await sleep(10);
      expect(port.calls).assertEqual(1);
      resetRating();
    });

    it('stale_response_does_not_override_new_rating', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const port: DeferredLeaderboardPort = new DeferredLeaderboardPort();
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      vm.kind = RANK_KIND_READING;
      vm.period = RANK_PERIOD_DAY;

      // 第 1 次请求（分级 A）在途，未返回
      const first: Promise<void> = vm.load(true);
      expect(port.requestRatings.length).assertEqual(1);
      expect(port.requestRatings[0]).assertEqual(ContentRating.ALL_AGES);

      // 切换分级 B → 广播 → 第 2 次请求（分级 B）
      const bridge: RatingBridge = new RatingBridge((): void => {
        vm.refreshForRating();
      });
      bridge.start();
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      await sleep(5);
      expect(port.requestRatings.length).assertEqual(2);
      expect(port.requestRatings[1]).assertEqual(ContentRating.ADULT);

      // 旧请求（A）晚到 → 必须被代际守卫丢弃
      port.resolvers[0](pageOf(1, ['stale_A']));
      // 新请求（B）返回 → 落地为新数据
      port.resolvers[1](pageOf(1, ['fresh_B']));
      await first;
      await sleep(10);
      expect(vm.items.length).assertEqual(1);
      expect(vm.items[0].id).assertEqual('fresh_B');

      bridge.stop();
      resetRating();
    });

    it('bridge_unsubscribe_stops_refresh', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const port: RatingLeaderboardPort = new RatingLeaderboardPort();
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      vm.kind = RANK_KIND_READING;
      vm.period = RANK_PERIOD_DAY;
      await vm.load(true);
      expect(port.calls).assertEqual(1);

      const bridge: RatingBridge = new RatingBridge((): void => {
        vm.refreshForRating();
      });
      bridge.start();
      bridge.stop();
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      await sleep(10);
      expect(port.calls).assertEqual(1);
      resetRating();
    });

    it('search_refreshes_with_new_rating_after_switch', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const src: RatingFakeSource = new RatingFakeSource();
      const vm: SearchViewModel = new SearchViewModel(src);
      vm.keyword = '海贼王';
      await vm.search(true);
      expect(src.calls).assertEqual(1);
      expect(src.lastRating).assertEqual(ContentRating.ALL_AGES);

      const bridge: RatingBridge = new RatingBridge((): void => {
        vm.refreshForRating();
      });
      bridge.start();
      await ContentRatingPolicy.getInstance().set(ContentRating.BOTH);
      await sleep(10);
      expect(src.calls).assertEqual(2);
      expect(src.lastRating).assertEqual(ContentRating.BOTH);
      expect(vm.searchDataSource.get(0).id).assertEqual(`海贼王_${ContentRating.BOTH}`);
      bridge.stop();
      resetRating();
    });

    it('search_activate_revives_disposed_instance', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const src: RatingFakeSource = new RatingFakeSource();
      const vm: SearchViewModel = new SearchViewModel(src);
      vm.keyword = '火影';
      await vm.search(true);
      expect(src.calls).assertEqual(1);

      vm.dispose();
      await vm.search(true, true);
      expect(src.calls).assertEqual(1); // 已销毁：不再发请求

      vm.activate();
      await vm.search(true, true);
      expect(src.calls).assertEqual(2); // 复活后可再次搜索
      resetRating();
    });
  });
}
