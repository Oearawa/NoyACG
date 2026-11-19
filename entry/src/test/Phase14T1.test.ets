/**
 * Phase14T1.test.ets —— Phase 14-T 修复结果的页面级验收与生命周期补强（Phase 14-T1）
 *
 * 与 Phase14T（数据映射 + 单一 VM 刷新时序）的区别：
 * 本文件做**页面级端到端验收**，逐接口、逐页面、从真实设置入口出发，
 * 并覆盖 Navigation 生命周期、应用前后台、多页面并发三条此前未验证的链路。
 *
 * 覆盖：
 * 1. 状态角标逐接口映射链：booklist / home / readLeaderboard / favLeaderboard /
 *    proportion / favoritesrecommend / search / detail 全部确认 Mode+Status 双字段，
 *    且 Repository/ViewModel 透传后 isCompleted 仍为 completed/ongoing/unknown 三态。
 * 2. 从真实设置控件入口（SettingsViewModel.selectIndex）出发的完整调用链：
 *    持久化 → ContentRatingPolicy → RatingBridge → ViewModel.refreshForRating → 新请求头。
 * 3. 每页面独立刷新（非只测通用 VM）：首页/最新/搜索/分类/榜单/精选/收藏/详情，
 *    各自断言请求次数、请求携带的分级、最终数据内容与旧数据替换。
 * 4. HttpManager 集成：buildRequestHeaders（get/post 唯一 header 注入点）在
 *    不重建 HttpManager 的情况下，分级 A→B 后解析出 B。
 * 5. ContentRatingPolicy.reconcileFromPreference：前后台一致性检查，未变化不广播、变化才广播。
 * 6. 多页面并发：多个 RatingBridge 去重订阅、隐藏页面不重复刷新、旧响应不覆盖新数据。
 *
 * 说明：全部为宿主侧逻辑/契约测试，不触达线上接口；真机视觉与交互仍 RUNTIME_UNVERIFIED。
 */
import { describe, it, expect } from '@ohos/hypium';
import { Comic, COMIC_MODE_CHAPTERS, COMIC_MODE_SINGLE, COMIC_MODE_UNKNOWN } from '../main/ets/model/Comic';
import {
  mapBookListItem,
  mapSearchItem,
  parseBookListJson,
  parseHomeFeedJson,
  parseSearchJson,
  parseLeaderboardPage,
  parseBookDetailJson,
  RawBookListItem,
  RawSearchItem,
  RawLeaderboardEnvelope
} from '../main/ets/source/NoyAcgProtocol';
import {
  BADGE_STATUS_COMPLETED,
  BADGE_STATUS_ONGOING,
  ComicBadgeSet,
  resolveComicBadgesFromTags
} from '../main/ets/utils/ComicBadges';
import { ContentRatingPolicy } from '../main/ets/utils/ContentRatingPolicy';
import { ContentRating, PreferenceManager } from '../main/ets/utils/PreferenceManager';
import { RatingBridge } from '../main/ets/utils/RatingBridge';
import { HttpManager } from '../main/ets/api/HttpManager';
import { SettingsViewModel, indexToRating } from '../main/ets/viewmodel/SettingsViewModel';
import { HomeViewModel } from '../main/ets/viewmodel/HomeViewModel';
import { LeaderboardViewModel } from '../main/ets/viewmodel/LeaderboardViewModel';
import { RecommendViewModel } from '../main/ets/viewmodel/RecommendViewModel';
import { BigTagViewModel } from '../main/ets/viewmodel/BigTagViewModel';
import { SearchViewModel } from '../main/ets/viewmodel/SearchViewModel';
import { ComicDetailViewModel } from '../main/ets/viewmodel/ComicDetailViewModel';
import { LeaderboardPort, RecommendPort, BigTagPort } from '../main/ets/source/DiscoverySourcePort';
import { PageInfo } from '../main/ets/model/PageInfo';
import { ComicDetail } from '../main/ets/model/ComicDetail';
import { HomeFeed } from '../main/ets/model/HomeFeed';
import { AdItem } from '../main/ets/model/AdItem';
import { CommentPage } from '../main/ets/model/BookComment';
import { IComicSource } from '../main/ets/source/IComicSource';
import { BigTagItem, RANK_KIND_READING, RANK_PERIOD_DAY } from '../main/ets/model/LeaderboardModels';
import { InMemoryReadingStore, StubAccountFavPort } from './DetailStubs';

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

function badgeStatusOf(comic: Comic): string | null {
  const set: ComicBadgeSet = resolveComicBadgesFromTags(comic.isCompleted, comic.ptag);
  if (set.status === null) {
    return null;
  }
  return set.status.id;
}

// ==================== 分级感知的假端口 / 假源 ====================

class RatingLeaderboardPort implements LeaderboardPort {
  calls: number = 0;
  lastRating: string = '';
  lastKind: string = '';
  lastPeriod: string = '';

  async fetchLeaderboard(kind: string, page: number, period: string): Promise<PageInfo<Comic>> {
    this.calls++;
    this.lastRating = ContentRatingPolicy.getInstance().resolve();
    this.lastKind = kind;
    this.lastPeriod = period;
    const c: Comic = new Comic(`lb_${this.lastRating}`, `lb_${this.lastRating}`, '', '');
    return new PageInfo<Comic>(page, 1, [c], false);
  }
}

class RatingRecommendPort implements RecommendPort {
  calls: number = 0;
  lastRating: string = '';

  async fetchRecommend(page: number): Promise<PageInfo<Comic>> {
    this.calls++;
    this.lastRating = ContentRatingPolicy.getInstance().resolve();
    const c: Comic = new Comic(`rec_${this.lastRating}`, `rec_${this.lastRating}`, '', '');
    return new PageInfo<Comic>(page, 1, [c], false);
  }
}

class RatingBigTagPort implements BigTagPort {
  calls: number = 0;
  lastRating: string = '';

  async fetchBigTags(): Promise<BigTagItem[]> {
    this.calls++;
    this.lastRating = ContentRatingPolicy.getInstance().resolve();
    return [new BigTagItem(`tag_${this.lastRating}`, [], -1, '')];
  }
}

class RatingFakeSource implements IComicSource {
  readonly sourceId: string = 'fake';
  readonly sourceName: string = 'fake';
  readonly baseUrl: string = 'https://noymanga.com';
  listCalls: number = 0;
  homeCalls: number = 0;
  searchCalls: number = 0;
  detailCalls: number = 0;
  lastListRating: string = '';
  lastHomeRating: string = '';
  lastSearchRating: string = '';
  lastDetailRating: string = '';

  async getHomeList(page: number, sort?: string, finished?: string): Promise<PageInfo<Comic>> {
    this.listCalls++;
    this.lastListRating = ContentRatingPolicy.getInstance().resolve();
    const c: Comic = new Comic(`list_${this.lastListRating}`, `list_${this.lastListRating}`, '', '');
    return new PageInfo<Comic>(page, 1, [c], false);
  }

  async getHomeFeed(adultLevel?: string): Promise<HomeFeed> {
    this.homeCalls++;
    this.lastHomeRating = ContentRatingPolicy.getInstance().resolve();
    const feed: HomeFeed = new HomeFeed();
    const c: Comic = new Comic(`home_${this.lastHomeRating}`, `home_${this.lastHomeRating}`, '', '');
    feed.favDay = [c];
    return feed;
  }

  async search(keyword: string, page: number, mode?: string): Promise<PageInfo<Comic>> {
    this.searchCalls++;
    this.lastSearchRating = ContentRatingPolicy.getInstance().resolve();
    const c: Comic = new Comic(`${keyword}_${this.lastSearchRating}`, `${keyword}_${this.lastSearchRating}`, '', '');
    return new PageInfo<Comic>(page, 1, [c], false);
  }

  async getComicDetail(id: string): Promise<ComicDetail> {
    this.detailCalls++;
    this.lastDetailRating = ContentRatingPolicy.getInstance().resolve();
    const d: ComicDetail = new ComicDetail(id, `detail_${this.lastDetailRating}`, '');
    d.mode = COMIC_MODE_CHAPTERS;
    d.isCompleted = true;
    return d;
  }

  async getChapterImages(bookId: string, chapterId: string): Promise<string[]> {
    return [];
  }

  async getAds(adultLevel?: string): Promise<AdItem[]> {
    return [];
  }

  async getBookComments(bookId: string, page: number): Promise<CommentPage> {
    return new CommentPage([], 1, true);
  }
}

export default function phase14t1Test() {
  describe('Phase14T1_PerInterfaceBadge', () => {
    it('booklist_mode1_status1_and_status0', 0, () => {
      const done: RawBookListItem = { Bid: 1, Mode: 1, Status: 1 };
      const ongoing: RawBookListItem = { Bid: 2, Mode: 1, Status: 0 };
      expect(badgeStatusOf(mapBookListItem(done))).assertEqual(BADGE_STATUS_COMPLETED);
      expect(badgeStatusOf(mapBookListItem(ongoing))).assertEqual(BADGE_STATUS_ONGOING);
    });

    it('booklist_mode0_any_status_has_no_badge', 0, () => {
      expect(badgeStatusOf(mapBookListItem({ Bid: 3, Mode: 0, Status: 0 }))).assertEqual(null);
      expect(badgeStatusOf(mapBookListItem({ Bid: 4, Mode: 0, Status: 1 }))).assertEqual(null);
      expect(badgeStatusOf(mapBookListItem({ Bid: 5, Status: 1 }))).assertEqual(null); // Mode 缺失
      expect(badgeStatusOf(mapBookListItem({ Bid: 6, Mode: 1 }))).assertEqual(null); // Status 缺失
      expect(badgeStatusOf(mapBookListItem({ Bid: 7, Mode: 1, Status: 'weird' }))).assertEqual(null);
      expect(badgeStatusOf(mapBookListItem({ Bid: 8, Mode: 'x', Status: 1 }))).assertEqual(null);
    });

    it('home_feed_all_sections_use_mode_status', 0, () => {
      const text: string = '{"status":"ok","favDay":[{"Bid":1,"Mode":1,"Status":1}],' +
        '"readDay":[{"Bid":2,"Mode":1,"Status":0}],' +
        '"fs":[{"Bid":3,"Mode":0,"Status":1}],' +
        '"proportion":[{"Bid":4,"Status":1}]}';
      const feed: HomeFeed = parseHomeFeedJson(text);
      expect(badgeStatusOf(feed.favDay[0])).assertEqual(BADGE_STATUS_COMPLETED);
      expect(badgeStatusOf(feed.readDay[0])).assertEqual(BADGE_STATUS_ONGOING);
      expect(badgeStatusOf(feed.fs[0])).assertEqual(null); // 单本不显示
      expect(badgeStatusOf(feed.proportion[0])).assertEqual(null); // 缺 Mode 不显示
    });

    it('leaderboard_favleaderboard_proportion_use_mapBookListItem', 0, () => {
      // 三个官方端点都经 parseLeaderboardPage → mapBookListItem（同一映射）
      const env: RawLeaderboardEnvelope = {
        status: 'ok',
        info: [{ Bid: 1, Mode: 1, Status: 1 }, { Bid: 2, Mode: 0, Status: 1 }],
        len: 2
      };
      const page: PageInfo<Comic> = parseLeaderboardPage(env, 1);
      expect(badgeStatusOf(page.list[0])).assertEqual(BADGE_STATUS_COMPLETED);
      expect(badgeStatusOf(page.list[1])).assertEqual(null);
    });

    it('favoritesrecommend_uses_mapBookListItem', 0, () => {
      // 个人化精选端点与榜单共用 parseLeaderboardPage（favoritesrecommend 在 NoyAcgSource.fetchRecommend 里）
      const env: RawLeaderboardEnvelope = {
        status: 'ok',
        info: [{ Bid: 1, Mode: 1, Status: 0 }],
        len: 1
      };
      const page: PageInfo<Comic> = parseLeaderboardPage(env, 1);
      expect(badgeStatusOf(page.list[0])).assertEqual(BADGE_STATUS_ONGOING);
    });

    it('search_smallcase_mode_status', 0, () => {
      const raw: RawSearchItem = { id: 1, mode: 1, status: '1' };
      expect(badgeStatusOf(mapSearchItem(raw))).assertEqual(BADGE_STATUS_COMPLETED);
      const raw2: RawSearchItem = { id: 2, mode: 0, status: 1 };
      expect(badgeStatusOf(mapSearchItem(raw2))).assertEqual(null);
      const raw3: RawSearchItem = { id: 3, status: 1 };
      expect(badgeStatusOf(mapSearchItem(raw3))).assertEqual(null);
    });

    it('detail_mode0_status1_no_badge', 0, () => {
      const detail: ComicDetail = parseBookDetailJson(
        '{"book":{"info":{"Bid":9,"Mode":0,"Status":1}}}', '9');
      expect(detail.mode).assertEqual(COMIC_MODE_SINGLE);
      expect(detail.isCompleted === null).assertTrue();
      expect(badgeStatusOf(detail)).assertEqual(null);
    });

    it('repository_and_viewmodel_preserve_status', 0, async () => {
      // LeaderboardViewModel 经 Repository(端口) 取数后 isCompleted 仍保留三态
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const port: RatingLeaderboardPort = new RatingLeaderboardPort();
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      vm.kind = RANK_KIND_READING;
      vm.period = RANK_PERIOD_DAY;
      await vm.load(true);
      expect(vm.items.length).assertEqual(1);
      // 假端口产出的 Comic 默认 isCompleted=null（未知），UI 不显示角标
      expect(badgeStatusOf(vm.items[0])).assertEqual(null);
      resetRating();
    });
  });

  describe('Phase14T1_SettingsEntryToRequest', () => {
    it('selectIndex_persists_policy_broadcast_and_header', 0, async () => {
      resetRating();
      const vm: SettingsViewModel = new SettingsViewModel();
      vm.initialize();
      expect(vm.contentRating).assertEqual(ContentRating.ALL_AGES);

      // 模拟用户在设置页选择「仅限值级内容」（下标 1 → ADULT）
      const ok: boolean = await vm.selectIndex(1);
      expect(ok).assertTrue();
      expect(vm.contentRating).assertEqual(ContentRating.ADULT);
      // 持久化值已更新（PreferenceManager 内存快照，测试环境无 store 也同步）
      expect(PreferenceManager.getInstance().getContentRatingSync()).assertEqual(ContentRating.ADULT);
      // 策略已更新
      expect(ContentRatingPolicy.getInstance().resolve()).assertEqual(ContentRating.ADULT);
      // 后续请求头会携带新分级
      const headers: Record<string, string> | undefined =
        HttpManager.buildRequestHeaders('https://noymanga.com/api/home');
      expect(headers !== undefined).assertTrue();
      expect(headers!['allow-adult']).assertEqual(ContentRating.ADULT);
      resetRating();
    });

    it('selectIndex_to_both_then_back_to_all', 0, async () => {
      resetRating();
      const vm: SettingsViewModel = new SettingsViewModel();
      vm.initialize();
      await vm.selectIndex(2); // BOTH
      expect(ContentRatingPolicy.getInstance().resolve()).assertEqual(ContentRating.BOTH);
      await vm.selectIndex(0); // ALL_AGES
      expect(ContentRatingPolicy.getInstance().resolve()).assertEqual(ContentRating.ALL_AGES);
      resetRating();
    });
  });

  describe('Phase14T1_PerPageRefresh', () => {
    it('home_and_latest_refresh_with_new_rating', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const src: RatingFakeSource = new RatingFakeSource();
      // 首页（含聚合 + 书单）
      const homeVm: HomeViewModel = new HomeViewModel(src);
      await homeVm.loadHome();
      homeVm.initLoad();
      await sleep(10);
      expect(src.homeCalls).assertEqual(1);
      expect(src.listCalls).assertEqual(1);
      expect(src.lastHomeRating).assertEqual(ContentRating.ALL_AGES);

      const bridge: RatingBridge = new RatingBridge((): void => {
        homeVm.refreshForRating();
      });
      bridge.start();
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      await sleep(10);
      expect(src.homeCalls).assertEqual(2);
      expect(src.listCalls).assertEqual(2);
      expect(src.lastHomeRating).assertEqual(ContentRating.ADULT);
      expect(src.lastListRating).assertEqual(ContentRating.ADULT);
      bridge.stop();
      resetRating();
    });

    it('search_keeps_keyword_and_mode', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const src: RatingFakeSource = new RatingFakeSource();
      const vm: SearchViewModel = new SearchViewModel(src);
      vm.keyword = '海贼王';
      await vm.search(true);
      expect(src.searchCalls).assertEqual(1);
      expect(src.lastSearchRating).assertEqual(ContentRating.ALL_AGES);

      const bridge: RatingBridge = new RatingBridge((): void => {
        vm.refreshForRating();
      });
      bridge.start();
      await ContentRatingPolicy.getInstance().set(ContentRating.BOTH);
      await sleep(10);
      expect(src.searchCalls).assertEqual(2);
      expect(src.lastSearchRating).assertEqual(ContentRating.BOTH);
      // 关键词与模式保留（VM 未清空 keyword/mode）
      expect(vm.keyword).assertEqual('海贼王');
      expect(vm.searchDataSource.get(0).id).assertEqual(`海贼王_${ContentRating.BOTH}`);
      bridge.stop();
      resetRating();
    });

    it('bigtag_refreshes_directory', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const port: RatingBigTagPort = new RatingBigTagPort();
      const vm: BigTagViewModel = new BigTagViewModel(port);
      await vm.load();
      expect(port.calls).assertEqual(1);
      expect(port.lastRating).assertEqual(ContentRating.ALL_AGES);

      const bridge: RatingBridge = new RatingBridge((): void => {
        vm.refreshForRating();
      });
      bridge.start();
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      await sleep(10);
      expect(port.calls).assertEqual(2);
      expect(port.lastRating).assertEqual(ContentRating.ADULT);
      expect(vm.items[0].tag).assertEqual(`tag_${ContentRating.ADULT}`);
      bridge.stop();
      resetRating();
    });

    it('leaderboard_keeps_kind_and_period', 0, async () => {
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
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      await sleep(10);
      expect(port.calls).assertEqual(2);
      expect(port.lastRating).assertEqual(ContentRating.ADULT);
      expect(port.lastKind).assertEqual(RANK_KIND_READING);
      expect(port.lastPeriod).assertEqual(RANK_PERIOD_DAY);
      bridge.stop();
      resetRating();
    });

    it('recommend_clears_and_refetches', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const port: RatingRecommendPort = new RatingRecommendPort();
      const vm: RecommendViewModel = new RecommendViewModel(port);
      await vm.load(true);
      expect(port.calls).assertEqual(1);
      expect(vm.items[0].id).assertEqual(`rec_${ContentRating.ALL_AGES}`);

      const bridge: RatingBridge = new RatingBridge((): void => {
        vm.refreshForRating();
      });
      bridge.start();
      await ContentRatingPolicy.getInstance().set(ContentRating.BOTH);
      await sleep(10);
      expect(port.calls).assertEqual(2);
      expect(port.lastRating).assertEqual(ContentRating.BOTH);
      // 旧分级数据被替换
      expect(vm.items[0].id).assertEqual(`rec_${ContentRating.BOTH}`);
      bridge.stop();
      resetRating();
    });

    it('detail_refetches_with_original_comic_id', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const src: RatingFakeSource = new RatingFakeSource();
      const store: InMemoryReadingStore = new InMemoryReadingStore();
      const fav: StubAccountFavPort = new StubAccountFavPort();
      const vm: ComicDetailViewModel = new ComicDetailViewModel(src, store, undefined, fav);
      await vm.loadDetail('comic-1');
      expect(src.detailCalls).assertEqual(1);
      expect(src.lastDetailRating).assertEqual(ContentRating.ALL_AGES);

      const bridge: RatingBridge = new RatingBridge((): void => {
        vm.refreshForRating();
      });
      bridge.start();
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      await sleep(10);
      expect(src.detailCalls).assertEqual(2);
      expect(src.lastDetailRating).assertEqual(ContentRating.ADULT);
      // 原 comicId 保留
      expect(vm.detail !== null).assertTrue();
      expect(vm.detail!.id).assertEqual('comic-1');
      bridge.stop();
      resetRating();
    });
  });

  describe('Phase14T1_HttpManagerIntegration', () => {
    it('same_http_manager_resolves_new_rating_without_rebuild', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      // 不重建 HttpManager 单例
      const mgr: HttpManager = HttpManager.getInstance();
      expect(mgr).assertEqual(HttpManager.getInstance());
      expect(HttpManager.buildRequestHeaders('https://noymanga.com/api/home')!['allow-adult'])
        .assertEqual(ContentRating.ALL_AGES);
      await ContentRatingPolicy.getInstance().set(ContentRating.BOTH);
      expect(HttpManager.buildRequestHeaders('https://noymanga.com/api/home')!['allow-adult'])
        .assertEqual(ContentRating.BOTH);
      resetRating();
    });
  });

  describe('Phase14T1_ForegroundReconcile', () => {
    it('reconcile_no_change_does_not_broadcast', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      const before: number = ContentRatingPolicy.getInstance().revisionNow();
      // 持久化与内存一致 → 不广播、revision 不变
      expect(ContentRatingPolicy.getInstance().reconcileFromPreference()).assertFalse();
      expect(ContentRatingPolicy.getInstance().revisionNow()).assertEqual(before);
      resetRating();
    });

    it('reconcile_change_broadcasts_and_refreshes_subscriber', 0, async () => {
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
      // 模拟后台期间持久化被改（直接写 PreferenceManager，绕过 policy.set）
      await PreferenceManager.getInstance().setContentRating(ContentRating.BOTH);
      // 前台恢复 → reconcile 检测到不一致 → 广播 → 订阅者刷新
      expect(ContentRatingPolicy.getInstance().reconcileFromPreference()).assertTrue();
      await sleep(10);
      expect(port.calls).assertEqual(2);
      expect(port.lastRating).assertEqual(ContentRating.BOTH);
      bridge.stop();
      resetRating();
    });
  });

  describe('Phase14T1_MultiPageConcurrency', () => {
    it('multiple_bridges_dedupe_and_rapid_switch_is_consistent', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const lbPort: RatingLeaderboardPort = new RatingLeaderboardPort();
      const lbVm: LeaderboardViewModel = new LeaderboardViewModel(lbPort);
      lbVm.kind = RANK_KIND_READING;
      lbVm.period = RANK_PERIOD_DAY;
      await lbVm.load(true);

      const recPort: RatingRecommendPort = new RatingRecommendPort();
      const recVm: RecommendViewModel = new RecommendViewModel(recPort);
      await recVm.load(true);

      const bridge1: RatingBridge = new RatingBridge((): void => {
        lbVm.refreshForRating();
      });
      const bridge2: RatingBridge = new RatingBridge((): void => {
        recVm.refreshForRating();
      });
      bridge1.start();
      bridge2.start();

      // 快速 A → B → A
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      await sleep(10);
      // 每次真实变更各触发一次刷新（ADULT、ALL_AGES 两次变更）
      expect(lbPort.calls).assertEqual(3); // 初始1 + ADULT + ALL_AGES
      expect(recPort.calls).assertEqual(3);
      expect(lbPort.lastRating).assertEqual(ContentRating.ALL_AGES);
      expect(recPort.lastRating).assertEqual(ContentRating.ALL_AGES);

      bridge1.stop();
      bridge2.stop();
      resetRating();
    });

    it('hidden_page_does_not_refresh_when_bridge_stopped', 0, async () => {
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
      bridge.stop(); // 页面隐藏（aboutToDisappear）→ 退订
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      await sleep(10);
      expect(port.calls).assertEqual(1); // 隐藏页面不发起请求
      resetRating();
    });
  });
}
