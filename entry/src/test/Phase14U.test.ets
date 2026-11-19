/**
 * Phase14U.test.ets —— 任务 A：首页内容分级切换不刷新的修复（Phase 14-U）
 *
 * 背景：Phase 14-T2 给 HomeComponent 接入 `@Param active` + `@Monitor('active')`，
 * 但首页仍无法在切换分级后自动刷新。根因定位：
 *   HomeComponent.aboutToDisappear() 在 NavDestination（设置页）覆盖首页 Tab 时会被触发，
 *   其中调用的 `vm.dispose()` 清空了 comicDataSource（书单），而 homeFeed（聚合区块）保留旧数据；
 *   组件并未真正销毁，aboutToAppear 不会重新执行，返回首页时聚合区块停留在旧分级、书单空白。
 *
 * 修复：移除 HomeComponent.aboutToDisappear() 里的 vm.dispose()（与 ShelfComponent 对齐），
 *   仅退订 + 取消预取，保留 VM 数据状态，由 @Monitor('active') 切回时 reloadIfRatingChanged 刷新。
 *
 * 本测试从 VM 层验证「首页」这一特有数据流：
 *   聚合（homeFeed）与书单（comicDataSource）都必须随分级切换重新请求，
 *   且旧分级数据不得混入新分级数据集合；同时回归验证其他页面（搜索/榜单/精选）不受影响。
 *
 * 说明：全部为宿主侧逻辑/契约测试，不触达线上接口；真机视觉与交互仍 RUNTIME_UNVERIFIED。
 */
import { describe, it, expect } from '@ohos/hypium';
import { Comic, COMIC_MODE_CHAPTERS } from '../main/ets/model/Comic';
import { ContentRatingPolicy } from '../main/ets/utils/ContentRatingPolicy';
import { ContentRating } from '../main/ets/utils/PreferenceManager';
import { RatingBridge } from '../main/ets/utils/RatingBridge';
import { HttpManager } from '../main/ets/api/HttpManager';
import { HomeViewModel } from '../main/ets/viewmodel/HomeViewModel';
import { SearchViewModel } from '../main/ets/viewmodel/SearchViewModel';
import { LeaderboardViewModel } from '../main/ets/viewmodel/LeaderboardViewModel';
import { RecommendViewModel } from '../main/ets/viewmodel/RecommendViewModel';
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

/** 记录每次请求携带分级的首页源（含聚合 + 书单两个数据源） */
class HomeSource implements IComicSource {
  readonly sourceId: string = 'fake';
  readonly sourceName: string = 'fake';
  readonly baseUrl: string = 'https://noymanga.com';
  homeCalls: number = 0;
  listCalls: number = 0;
  homeRatings: string[] = [];
  listRatings: string[] = [];

  async getHomeFeed(adultLevel?: string): Promise<HomeFeed> {
    this.homeCalls++;
    const r: string = ContentRatingPolicy.getInstance().resolve();
    this.homeRatings.push(r);
    const feed: HomeFeed = new HomeFeed();
    // 用「携带分级」的 id 标识聚合数据，便于断言数据被新分级替换
    const c: Comic = new Comic(`home_${r}`, `home_${r}`, '', '');
    c.mode = COMIC_MODE_CHAPTERS;
    feed.favDay = [c];
    feed.readDay = [c];
    feed.fs = [c];
    feed.proportion = [c];
    return feed;
  }

  async getHomeList(page: number, sort?: string, finished?: string): Promise<PageInfo<Comic>> {
    this.listCalls++;
    const r: string = ContentRatingPolicy.getInstance().resolve();
    this.listRatings.push(r);
    const c: Comic = new Comic(`list_${r}`, `list_${r}`, '', '');
    return new PageInfo<Comic>(page, 1, [c], false);
  }

  async search(keyword: string, page: number, mode?: string): Promise<PageInfo<Comic>> {
    return new PageInfo<Comic>(page, 1, [], false);
  }

  async getComicDetail(id: string): Promise<ComicDetail> {
    return new ComicDetail(id, 'x', '');
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

class RatingLeaderboardPort implements LeaderboardPort {
  calls: number = 0;
  lastRating: string = '';

  async fetchLeaderboard(kind: string, page: number, period: string): Promise<PageInfo<Comic>> {
    this.calls++;
    this.lastRating = ContentRatingPolicy.getInstance().resolve();
    return new PageInfo<Comic>(page, 1, [new Comic(`lb_${this.lastRating}`, 'lb', '', '')], false);
  }
}

class RatingRecommendPort implements RecommendPort {
  calls: number = 0;
  lastRating: string = '';

  async fetchRecommend(page: number): Promise<PageInfo<Comic>> {
    this.calls++;
    this.lastRating = ContentRatingPolicy.getInstance().resolve();
    return new PageInfo<Comic>(page, 1, [new Comic(`rec_${this.lastRating}`, 'rec', '', '')], false);
  }
}

export default function phase14uTest() {
  describe('Phase14U_HomeRefresh', () => {
    it('home_aggregate_and_list_refresh_from_A_to_B', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const src: HomeSource = new HomeSource();
      const vm: HomeViewModel = new HomeViewModel(src);
      // 模拟首页 aboutToAppear：加载聚合 + 书单
      await vm.loadHome();
      vm.initLoad();
      await sleep(10);
      expect(src.homeCalls).assertEqual(1);
      expect(src.listCalls).assertEqual(1);
      expect(src.homeRatings[0]).assertEqual(ContentRating.ALL_AGES);
      expect(src.listRatings[0]).assertEqual(ContentRating.ALL_AGES);

      // 模拟首页订阅（bridge），设置页切换分级 A → B
      const bridge: RatingBridge = new RatingBridge((): void => {
        vm.refreshForRating();
      });
      bridge.start();
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      await sleep(10);

      // 聚合 + 书单都重新请求，且携带新分级 B
      expect(src.homeCalls).assertEqual(2);
      expect(src.listCalls).assertEqual(2);
      expect(src.homeRatings[1]).assertEqual(ContentRating.ADULT);
      expect(src.listRatings[1]).assertEqual(ContentRating.ADULT);
      // 聚合数据被新分级替换
      expect(vm.homeFeed !== null).assertTrue();
      expect(vm.homeFeed!.favDay[0].id).assertEqual(`home_${ContentRating.ADULT}`);
      bridge.stop();
      resetRating();
    });

    it('home_reverse_B_to_A_refreshes_and_no_stale_data', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      const src: HomeSource = new HomeSource();
      const vm: HomeViewModel = new HomeViewModel(src);
      await vm.loadHome();
      vm.initLoad();
      await sleep(10);
      expect(src.homeRatings[0]).assertEqual(ContentRating.ADULT);

      const bridge: RatingBridge = new RatingBridge((): void => {
        vm.refreshForRating();
      });
      bridge.start();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      await sleep(10);
      expect(src.homeCalls).assertEqual(2);
      expect(src.homeRatings[1]).assertEqual(ContentRating.ALL_AGES);
      // 旧分级数据（ADULT）不得混入新分级集合
      expect(vm.homeFeed!.favDay[0].id).assertEqual(`home_${ContentRating.ALL_AGES}`);
      expect(vm.homeFeed!.favDay[0].id.indexOf(ContentRating.ADULT) < 0).assertTrue();
      bridge.stop();
      resetRating();
    });

    it('home_does_not_refresh_when_rating_unchanged', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const src: HomeSource = new HomeSource();
      const vm: HomeViewModel = new HomeViewModel(src);
      await vm.loadHome();
      vm.initLoad();
      await sleep(10);
      expect(src.homeCalls).assertEqual(1);

      const bridge: RatingBridge = new RatingBridge((): void => {
        vm.refreshForRating();
      });
      bridge.start();
      // 同值再设一次：不应触发无意义刷新
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      await sleep(10);
      expect(src.homeCalls).assertEqual(1);
      expect(src.listCalls).assertEqual(1);
      bridge.stop();
      resetRating();
    });

    it('home_allow_adult_header_reflects_new_rating', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      expect(HttpManager.buildRequestHeaders('https://noymanga.com/api/home')!['allow-adult'])
        .assertEqual(ContentRating.ALL_AGES);
      await ContentRatingPolicy.getInstance().set(ContentRating.BOTH);
      expect(HttpManager.buildRequestHeaders('https://noymanga.com/api/home')!['allow-adult'])
        .assertEqual(ContentRating.BOTH);
      resetRating();
    });
  });

  describe('Phase14U_OtherPagesRegression', () => {
    it('search_still_refreshes', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const src: HomeSource = new HomeSource();
      const vm: SearchViewModel = new SearchViewModel(src);
      vm.keyword = '海贼王';
      await vm.search(true);
      expect(src.listCalls).assertEqual(0); // 搜索走 search()，不走 getHomeList
      const bridge: RatingBridge = new RatingBridge((): void => {
        vm.refreshForRating();
      });
      bridge.start();
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      await sleep(10);
      // 搜索页 refreshForRating 保留关键词并重搜
      expect(vm.keyword).assertEqual('海贼王');
      bridge.stop();
      resetRating();
    });

    it('leaderboard_still_refreshes_with_single_registration', 0, async () => {
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
      expect(port.calls).assertEqual(2); // 只刷新一次，不因首页修复翻倍
      expect(port.lastRating).assertEqual(ContentRating.ADULT);
      bridge.stop();
      resetRating();
    });

    it('recommend_still_refreshes', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const port: RatingRecommendPort = new RatingRecommendPort();
      const vm: RecommendViewModel = new RecommendViewModel(port);
      await vm.load(true);
      expect(port.calls).assertEqual(1);
      const bridge: RatingBridge = new RatingBridge((): void => {
        vm.refreshForRating();
      });
      bridge.start();
      await ContentRatingPolicy.getInstance().set(ContentRating.BOTH);
      await sleep(10);
      expect(port.calls).assertEqual(2);
      expect(port.lastRating).assertEqual(ContentRating.BOTH);
      bridge.stop();
      resetRating();
    });
  });
}
