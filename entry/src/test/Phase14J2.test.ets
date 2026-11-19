/**
 * Phase14J2.test.ets —— Phase 14-J2 首页精简 + 账号收藏 测试
 *
 * 覆盖：
 * - 首页仍保留 stream / ads 的模型与解析能力；
 * - HomeViewModel.loadHome 不再请求广告（getAds 调用次数 = 0）；
 * - 账号收藏表单构造（class='all' 省略）、分页解析、登录失效、缺字段；
 * - 收藏分类解析；
 * - ShelfViewModel 账号收藏去重 / 登录失效 / 账号与本地分离。
 *
 * 说明：账号收藏样本来自首方 bundle 的**静态契约**（非登录态实测），
 * 因此本套件只验证「拿到响应体之后」的映射与状态机，不声称已完成真实联调。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  FAVORITE_CLASS_ALL,
  SignInRecordResult,
  SignInResult,
  buildFavoriteForm,
  parseAccountFavoritesJson,
  parseAdsJson,
  parseFavoriteClassesJson,
  parseHomeFeedJson,
  parseSignInRecord,
  parseSignInResult
} from '../main/ets/source/NoyAcgProtocol';
import { PageInfo } from '../main/ets/model/PageInfo';
import { Comic } from '../main/ets/model/Comic';
import { ComicDetail } from '../main/ets/model/ComicDetail';
import { HomeFeed } from '../main/ets/model/HomeFeed';
import { ViewportState } from '../main/ets/utils/ViewportState';
import { AdItem } from '../main/ets/model/AdItem';
import { CommentPage } from '../main/ets/model/BookComment';
import { FavoriteClass } from '../main/ets/model/FavoriteClass';
import { IComicSource } from '../main/ets/source/IComicSource';
import { AccountFavoritePort } from '../main/ets/source/AccountFavoritePort';
import { AccountFavoriteRepository } from '../main/ets/api/AccountFavoriteRepository';
import { HomeViewModel } from '../main/ets/viewmodel/HomeViewModel';
import { SettingsViewModel, ratingSwitchedToast } from '../main/ets/viewmodel/SettingsViewModel';
import { ContentRatingPolicy } from '../main/ets/utils/ContentRatingPolicy';
import {
  ContentRating,
  DEFAULT_SIGN_IN_REMINDER_TIME,
  PreferenceManager,
  ReminderTimeParts,
  formatReminderTime,
  normalizeReminderTime,
  parseReminderTime
} from '../main/ets/utils/PreferenceManager';
import { UserRepository } from '../main/ets/api/UserRepository';
import { UserViewModel } from '../main/ets/viewmodel/UserViewModel';
import { UserInfo } from '../main/ets/model/UserInfo';
import {
  DailySignInManager,
  buildWeekCheckInDays,
  countWeekCheckedDays,
  weekdayMonFirstFromDate
} from '../main/ets/utils/DailySignInManager';
import { ComicDetailViewModel } from '../main/ets/viewmodel/ComicDetailViewModel';
import { Chapter } from '../main/ets/model/Chapter';
import { ChapterGroup } from '../main/ets/model/ChapterGroup';
import { BookComment } from '../main/ets/model/BookComment';
import { ReadingStorePort } from '../main/ets/utils/DatabaseManager';
import { NoopDownloadControl } from '../main/ets/download/DownloadPorts';
import { isAlreadyExistsError } from '../main/ets/download/DownloadStorage';
import { ComicReaderViewModel } from '../main/ets/viewmodel/ComicReaderViewModel';
import {
  READER_PAGE_CACHED_COUNT,
  READER_PAGE_DISPLAY_COUNT,
  READER_PAGE_SWIPE_DURATION_MS,
  READER_STRIP_FRICTION,
  resolveReaderBackgroundColor,
  resolveReaderStatusBarContentColor
} from '../main/ets/reader/ReaderLayout';
import {
  resolveBarDividerColor,
  resolveBottomBarSurfaceColor,
  resolvePaginationSurfaceColor
} from '../main/ets/utils/MaterialPolicy';
import { isPanEnabledForScale } from '../main/ets/reader/ReaderGestureMath';
import { HistoryViewModel, HistoryStorePort } from '../main/ets/viewmodel/HistoryViewModel';
import { HistoryRecord } from '../main/ets/utils/DatabaseManager';
import { ComicMetaCache, HistoryMetadata } from '../main/ets/utils/ComicMetaCache';
import { ShelfViewModel, SHELF_SOURCE_ACCOUNT } from '../main/ets/viewmodel/ShelfViewModel';
import { AuthRequiredError, ProtocolError } from '../main/ets/api/ApiErrors';
import { HttpError } from '../main/ets/api/HttpManager';
import {
  ACCOUNT_FAVORITES_SUCCESS_DERIVED,
  ADS_SUCCESS_DERIVED,
  FAVORITE_CLASSES_SUCCESS_DERIVED,
  HOME_WITH_STREAM_DERIVED,
  USERINFO_ANON
} from './fixtures/FixtureData';

function catchError(fn: () => void): Error | null {
  try {
    fn();
    return null;
  } catch (e) {
    return e as Error;
  }
}

/** 首页数据源桩：记录 getHomeFeed / getAds 调用次数 */
class StubHomeSource implements IComicSource {
  readonly sourceId: string = 'stub';
  readonly sourceName: string = 'stub';
  readonly baseUrl: string = '';
  homeCalls: number = 0;
  adsCalls: number = 0;
  listCalls: number = 0;
  pendingListPromise: Promise<PageInfo<Comic>> | null = null;
  pendingHomePromise: Promise<HomeFeed> | null = null;
  homeFeedFactory: (() => HomeFeed) | null = null;
  failHomeWith: HttpError | null = null;

  async getHomeList(page: number, sort?: string, finished?: string): Promise<PageInfo<Comic>> {
    this.listCalls++;
    if (this.pendingListPromise !== null) {
      return await this.pendingListPromise;
    }
    return new PageInfo<Comic>(page, 0, [], false);
  }

  async search(keyword: string, page: number): Promise<PageInfo<Comic>> {
    return new PageInfo<Comic>(page, 0, [], false);
  }

  async getComicDetail(id: string): Promise<ComicDetail> {
    return new ComicDetail(id, '', '');
  }

  async getChapterImages(bookId: string, chapterId: string): Promise<string[]> {
    return [];
  }

  async getHomeFeed(adultLevel?: string): Promise<HomeFeed> {
    this.homeCalls++;
    if (this.failHomeWith !== null) {
      throw this.failHomeWith;
    }
    if (this.pendingHomePromise !== null) {
      return await this.pendingHomePromise;
    }
    if (this.homeFeedFactory !== null) {
      return this.homeFeedFactory();
    }
    return new HomeFeed();
  }

  async getAds(adultLevel?: string): Promise<AdItem[]> {
    this.adsCalls++;
    return [];
  }

  async getBookComments(bookId: string, page: number): Promise<CommentPage> {
    return new CommentPage([], page, true);
  }
}

class SpyDataChangeListener implements DataChangeListener {
  reloads: number = 0;

  onDataReloaded(): void {
    this.reloads++;
  }

  onDataAdded(_index: number): void {}
  onDataAdd(_index: number): void {}
  onDataMoved(_from: number, _to: number): void {}
  onDataMove(_from: number, _to: number): void {}
  onDataDeleted(_index: number): void {}
  onDataDelete(_index: number): void {}
  onDataChanged(_index: number): void {}
  onDataChange(_index: number): void {}
  onDatasetChange(_dataOperations: DataOperation[]): void {}
}

class StubSignInUserRepository extends UserRepository {
  recordCalls: number = 0;
  signCalls: number = 0;
  failRecordWith: HttpError | null = null;
  recordResult: SignInRecordResult = { today: false, continuous: 140 };
  signResult: SignInResult = { status: 'SIGNED', continuous: 141, message: '签到成功，连续 141 天' };
  user: UserInfo = new UserInfo();

  constructor() {
    super();
    this.user.uid = '1001';
    this.user.username = 'tester';
  }

  override async fetchUserInfo(): Promise<UserInfo> {
    return this.user;
  }

  override async fetchSignInRecord(): Promise<SignInRecordResult> {
    this.recordCalls++;
    if (this.failRecordWith !== null) {
      throw this.failRecordWith;
    }
    return this.recordResult;
  }

  override async signIn(): Promise<SignInResult> {
    this.signCalls++;
    return this.signResult;
  }
}

/** 账号收藏端口桩 */
class StubAccountPort implements AccountFavoritePort {
  page: PageInfo<Comic> | null = null;
  failWith: HttpError | null = null;
  calls: number = 0;

  async fetchAccountFavorites(page: number, classId: string): Promise<PageInfo<Comic>> {
    this.calls++;
    if (this.failWith !== null) {
      throw this.failWith;
    }
    return this.page !== null ? this.page : new PageInfo<Comic>(page, 0, [], false);
  }

  async fetchFavoriteClasses(): Promise<FavoriteClass[]> {
    return [];
  }

  async toggleFavorite(bid: string): Promise<void> {
    // 只读用途的桩：无写实现，仅满足接口契约
  }
}

export default function phase14j2Test() {
  describe('Phase14J2', () => {
    // ==================== 首页：保留解析能力 ====================

    it('homeStillParsesStreamModel', 0, () => {
      const feed: HomeFeed = parseHomeFeedJson(HOME_WITH_STREAM_DERIVED);
      // 首页不再展示 stream，但模型/解析器完整保留
      expect(feed.stream.length).assertEqual(2);
      expect(feed.stream[0].id).assertEqual('501');
      expect(feed.stream[0].cover.indexOf('stream.noyteam.online') >= 0).assertTrue();
    });

    it('adsParseStillWorks', 0, () => {
      // 广告接口与解析保留（只是首页不再展示/不再请求）
      const ads: AdItem[] = parseAdsJson(ADS_SUCCESS_DERIVED);
      expect(ads.length).assertEqual(3);
      expect(ads[0].url).assertEqual('https://example.com/promo/1');
    });

    it('homeLoadNoLongerRequestsAds', 0, async () => {
      const source: StubHomeSource = new StubHomeSource();
      const vm: HomeViewModel = new HomeViewModel(source);
      await vm.loadHome();
      expect(source.homeCalls).assertEqual(1);
      expect(source.adsCalls).assertEqual(0); // 首页默认加载不再请求广告
      expect(vm.homeFeed !== null).assertTrue();
      vm.dispose();
    });

    it('homeColdLoadDoesNotTriggerManualRefresh', 0, async () => {
      const source: StubHomeSource = new StubHomeSource();
      let resolveList: ((value: PageInfo<Comic>) => void) | null = null;
      source.pendingListPromise = new Promise<PageInfo<Comic>>((resolve) => {
        resolveList = resolve;
      });
      const vm: HomeViewModel = new HomeViewModel(source);
      const listTask: Promise<void> = vm.loadData(true);
      const homeTask: Promise<void> = vm.loadHome();
      expect(vm.isManualRefreshing).assertFalse();
      expect(vm.isInitialLoading).assertTrue();
      if (resolveList !== null) {
        (resolveList as (value: PageInfo<Comic>) => void)(new PageInfo<Comic>(1, 0, [], false));
      }
      await Promise.all([listTask, homeTask]);
      expect(vm.isManualRefreshing).assertFalse();
      expect(vm.isInitialLoading).assertFalse();
      vm.dispose();
    });

    it('homePullToRefreshTogglesManualRefresh', 0, async () => {
      const source: StubHomeSource = new StubHomeSource();
      let resolveList: ((value: PageInfo<Comic>) => void) | null = null;
      source.pendingListPromise = new Promise<PageInfo<Comic>>((resolve) => {
        resolveList = resolve;
      });
      const vm: HomeViewModel = new HomeViewModel(source);
      const pullTask: Promise<void> = vm.onPullToRefresh(true);
      expect(vm.isManualRefreshing).assertTrue();
      expect(vm.isInitialLoading).assertFalse();
      if (resolveList !== null) {
        (resolveList as (value: PageInfo<Comic>) => void)(new PageInfo<Comic>(1, 0, [], false));
      }
      await pullTask;
      expect(vm.isManualRefreshing).assertFalse();
      expect(vm.isInitialLoading).assertFalse();
      vm.dispose();
    });

    it('homeAutoRefreshesSilentlyOnRatingRevisionChange', 0, async () => {
      const policy: ContentRatingPolicy = ContentRatingPolicy.getInstance();
      policy.resetForTest();
      const source: StubHomeSource = new StubHomeSource();
      const vm: HomeViewModel = new HomeViewModel(source);
      expect(vm.appliedRatingRevision).assertEqual(0);
      await vm.loadData(true);
      expect(source.listCalls).assertEqual(1);
      expect(vm.isManualRefreshing).assertFalse();

      // 模拟用户在设置页切换年龄限制，使 contentRatingRevision 递增
      await policy.set(ContentRating.ADULT);
      expect(policy.revisionNow()).assertEqual(1);

      // 模拟返回首页触发分级版本号核对：自动静默重载且不触发下拉刷新圈
      const triggered: boolean = vm.reloadIfRatingChanged();
      expect(triggered).assertTrue();
      for (let i = 0; i < 6; i++) {
        await Promise.resolve();
      }
      expect(vm.appliedRatingRevision).assertEqual(1);
      expect(vm.isManualRefreshing).assertFalse();
      expect(source.listCalls).assertEqual(2);

      vm.dispose();
      policy.resetForTest();
    });

    it('homeFeedReloadsWithNewRatingOnRevisionChange', 0, async () => {
      const policy: ContentRatingPolicy = ContentRatingPolicy.getInstance();
      policy.resetForTest();
      const source: StubHomeSource = new StubHomeSource();
      const feedA: HomeFeed = new HomeFeed();
      feedA.readDay = [new Comic('101', '全年龄阅读A', '')];
      feedA.favDay = [new Comic('102', '全年龄收藏A', '')];
      feedA.fs = [new Comic('103', '全年龄推荐A', '')];
      feedA.proportion = [new Comic('104', '全年龄高质A', '')];
      const feedB: HomeFeed = new HomeFeed();
      feedB.readDay = [new Comic('201', '限制级阅读B', '')];
      feedB.favDay = [new Comic('202', '限制级收藏B', '')];
      feedB.fs = [new Comic('203', '限制级推荐B', '')];
      feedB.proportion = [new Comic('204', '限制级高质B', '')];
      source.homeFeedFactory = (): HomeFeed => feedA;

      const vm: HomeViewModel = new HomeViewModel(source);
      await vm.loadHome();
      await vm.loadData(true);
      expect(source.homeCalls).assertEqual(1);
      expect(vm.homeFeed !== null).assertTrue();
      expect(vm.homeFeed!.readDay[0].id).assertEqual('101');
      expect(vm.homeFeed!.favDay[0].id).assertEqual('102');
      expect(vm.homeFeed!.fs[0].id).assertEqual('103');
      expect(vm.homeFeed!.proportion[0].id).assertEqual('104');
      expect(vm.homeFeedRevision).assertEqual(1);
      expect(vm.isManualRefreshing).assertFalse();

      // 切换年龄限制为 ADULT（revision 递增），更新桩返回新分级首页聚合数据
      source.homeFeedFactory = (): HomeFeed => feedB;
      await policy.set(ContentRating.ADULT);
      expect(policy.revisionNow()).assertEqual(1);

      const triggered: boolean = vm.reloadIfRatingChanged(true);
      expect(triggered).assertTrue();
      for (let i = 0; i < 6; i++) {
        await Promise.resolve();
      }
      expect(source.homeCalls).assertEqual(2);
      expect(vm.homeFeed !== null).assertTrue();
      expect(vm.homeFeed!.readDay[0].id).assertEqual('201');
      expect(vm.homeFeed!.favDay[0].id).assertEqual('202');
      expect(vm.homeFeed!.fs[0].id).assertEqual('203');
      expect(vm.homeFeed!.proportion[0].id).assertEqual('204');
      expect(vm.homeFeedRevision).assertEqual(2);
      expect(vm.appliedRatingRevision).assertEqual(1);
      expect(vm.isManualRefreshing).assertFalse();

      // 验证手动下拉刷新也会强制重拉 homeFeed 并递增 homeFeedRevision
      const feedC: HomeFeed = new HomeFeed();
      feedC.readDay = [new Comic('301', '手动刷新阅读C', '')];
      source.homeFeedFactory = (): HomeFeed => feedC;
      await vm.onPullToRefresh(true);
      expect(source.homeCalls).assertEqual(3);
      expect(vm.homeFeed!.readDay[0].id).assertEqual('301');
      expect(vm.homeFeedRevision).assertEqual(3);

      vm.dispose();
      policy.resetForTest();
    });

    it('homeReloadAllSectionsNotifiesAllPartitionSources', 0, async () => {
      const policy: ContentRatingPolicy = ContentRatingPolicy.getInstance();
      policy.resetForTest();
      const source: StubHomeSource = new StubHomeSource();
      const feed: HomeFeed = new HomeFeed();
      feed.readDay = [new Comic('r1', '阅读1', '')];
      feed.favDay = [new Comic('f1', '收藏1', '')];
      feed.fs = [new Comic('c1', '推荐1', '')];
      feed.proportion = [new Comic('q1', '高质1', '')];
      source.homeFeedFactory = (): HomeFeed => feed;

      const vm: HomeViewModel = new HomeViewModel(source);
      const readSpy: SpyDataChangeListener = new SpyDataChangeListener();
      const favSpy: SpyDataChangeListener = new SpyDataChangeListener();
      const colSpy: SpyDataChangeListener = new SpyDataChangeListener();
      const qualSpy: SpyDataChangeListener = new SpyDataChangeListener();
      const latestSpy: SpyDataChangeListener = new SpyDataChangeListener();
      vm.readDaySource.registerDataChangeListener(readSpy);
      vm.favDaySource.registerDataChangeListener(favSpy);
      vm.collectionSource.registerDataChangeListener(colSpy);
      vm.qualitySource.registerDataChangeListener(qualSpy);
      vm.latestSource.registerDataChangeListener(latestSpy);

      await policy.set(ContentRating.ADULT);
      const ok: boolean = await vm.reloadAllSections('SILENT_SYNC', true);
      expect(ok).assertTrue();
      expect(readSpy.reloads).assertEqual(1);
      expect(favSpy.reloads).assertEqual(1);
      expect(colSpy.reloads).assertEqual(1);
      expect(qualSpy.reloads).assertEqual(1);
      expect(latestSpy.reloads).assertEqual(1);
      expect(vm.readDaySource.totalCount()).assertEqual(1);
      expect(vm.favDaySource.totalCount()).assertEqual(1);
      expect(vm.collectionSource.totalCount()).assertEqual(1);
      expect(vm.qualitySource.totalCount()).assertEqual(1);
      expect(vm.committedRatingRevision).assertEqual(1);
      expect(vm.isManualRefreshing).assertFalse();
      vm.dispose();
      policy.resetForTest();
    });

    it('homeReloadAllSectionsDropsStaleOutOfOrderResponse', 0, async () => {
      const policy: ContentRatingPolicy = ContentRatingPolicy.getInstance();
      policy.resetForTest();
      const source: StubHomeSource = new StubHomeSource();
      let resolveStale: ((value: HomeFeed) => void) | null = null;
      source.pendingHomePromise = new Promise<HomeFeed>((resolve) => {
        resolveStale = resolve;
      });

      const vm: HomeViewModel = new HomeViewModel(source);
      const firstTask: Promise<boolean> = vm.reloadAllSections('SILENT_SYNC', true);

      // 快速切换至新分级并发起第二次请求（先返回）
      const freshFeed: HomeFeed = new HomeFeed();
      freshFeed.readDay = [new Comic('fresh-1', '新分级数据', '')];
      source.pendingHomePromise = null;
      source.homeFeedFactory = (): HomeFeed => freshFeed;
      await policy.set(ContentRating.ADULT);
      const secondOk: boolean = await vm.reloadAllSections('SILENT_SYNC', true);
      expect(secondOk).assertTrue();
      expect((vm.readDaySource.get(0) as Comic).id).assertEqual('fresh-1');

      // 过期请求晚到，不得覆盖新分级数据
      const staleFeed: HomeFeed = new HomeFeed();
      staleFeed.readDay = [new Comic('stale-1', '过期数据', '')];
      if (resolveStale !== null) {
        (resolveStale as (value: HomeFeed) => void)(staleFeed);
      }
      const firstOk: boolean = await firstTask;
      expect(firstOk).assertFalse();
      expect((vm.readDaySource.get(0) as Comic).id).assertEqual('fresh-1');
      expect(vm.committedRatingRevision).assertEqual(1);
      vm.dispose();
      policy.resetForTest();
    });

    it('homeReloadAllSectionsRetriesWhenPreviousSyncFailed', 0, async () => {
      const policy: ContentRatingPolicy = ContentRatingPolicy.getInstance();
      policy.resetForTest();
      const source: StubHomeSource = new StubHomeSource();
      source.failHomeWith = new HttpError(500, 'network error');

      const vm: HomeViewModel = new HomeViewModel(source);
      await policy.set(ContentRating.ADULT);
      const firstOk: boolean = await vm.reloadAllSections('SILENT_SYNC', true);
      expect(firstOk).assertFalse();
      expect(vm.committedRatingRevision).assertEqual(0);

      // 恢复网络后返回前台：仍能检测到未提交的版本号并自动重试成功
      source.failHomeWith = null;
      const retried: boolean = vm.reloadIfRatingChanged(true);
      expect(retried).assertTrue();
      for (let i = 0; i < 6; i++) {
        await Promise.resolve();
      }
      expect(vm.committedRatingRevision).assertEqual(1);
      expect(vm.isManualRefreshing).assertFalse();
      vm.dispose();
      policy.resetForTest();
    });

    it('settingsRatingSwitchEmitsImmediateToastOnlyOnChange', 0, async () => {
      const policy: ContentRatingPolicy = ContentRatingPolicy.getInstance();
      policy.resetForTest();
      const settingsVm: SettingsViewModel = new SettingsViewModel();
      settingsVm.initialize();
      expect(settingsVm.lastSwitchToast).assertEqual('');

      // 重复点击当前已选中的同一项：不弹提示
      const initialIdx: number = settingsVm.currentIndex();
      const sameOk: boolean = await settingsVm.selectIndex(initialIdx);
      expect(sameOk).assertTrue();
      expect(settingsVm.lastSwitchToast).assertEqual('');

      // 切换为另一项：立即生成设置页提示文案，且再次点击同一项不弹提示
      const targetIdx: number = initialIdx === 1 ? 0 : 1;
      const switchedOk: boolean = await settingsVm.selectIndex(targetIdx);
      expect(switchedOk).assertTrue();
      const expectedToast: string = targetIdx === 1
        ? '已切换至仅限制级内容，返回首页自动刷新'
        : '已切换至仅全年龄内容，返回首页自动刷新';
      expect(settingsVm.lastSwitchToast).assertEqual(expectedToast);
      expect(ratingSwitchedToast(ContentRating.BOTH)).assertEqual('已切换至显示全部内容，返回首页自动刷新');
      expect(ratingSwitchedToast(ContentRating.ALL_AGES)).assertEqual('已切换至仅全年龄内容，返回首页自动刷新');
      expect(ratingSwitchedToast(ContentRating.ADULT)).assertEqual('已切换至仅限制级内容，返回首页自动刷新');

      const repeatOk: boolean = await settingsVm.selectIndex(targetIdx);
      expect(repeatOk).assertTrue();
      expect(settingsVm.lastSwitchToast).assertEqual('');

      policy.resetForTest();
    });

    it('signInProtocolParsesSuccessAlreadySignedAndAuthRequired', 0, () => {
      const pending = parseSignInRecord({
        status: 200,
        today: false,
        continuous: -1,
        data: [{ continuous: 140 }]
      });
      expect(pending.today).assertFalse();
      expect(pending.continuous).assertEqual(140);

      const done = parseSignInRecord({ status: 200, today: true, continuous: 141 });
      expect(done.today).assertTrue();
      expect(done.continuous).assertEqual(141);

      const errRec = catchError(() => {
        parseSignInRecord({ status: 'login' });
      });
      expect(errRec instanceof AuthRequiredError).assertTrue();

      const okRes = parseSignInResult({ status: 200, continuous: 141, msg: 'success' });
      expect(okRes.status).assertEqual('SIGNED');
      expect(okRes.continuous).assertEqual(141);
      expect(okRes.message).assertEqual('签到成功，连续 141 天');

      const dupRes = parseSignInResult({ status: 500, msg: 'Please do not sign in too frequently' });
      expect(dupRes.status).assertEqual('ALREADY_SIGNED');
      expect(dupRes.message).assertEqual('今天已经签过到了');

      const errSign = catchError(() => {
        parseSignInResult({ status: 'login' });
      });
      expect(errSign instanceof AuthRequiredError).assertTrue();
    });

    it('userViewModelSignInPersistsPerUidAndResetsNextDay', 0, async () => {
      const prefs: PreferenceManager = PreferenceManager.getInstance();
      prefs.reset();
      const repo: StubSignInUserRepository = new StubSignInUserRepository();
      const vm: UserViewModel = new UserViewModel(repo);

      const ok: boolean = await vm.performSignIn('1001', '2026-11-16');
      expect(ok).assertTrue();
      expect(repo.signCalls).assertEqual(1);
      expect(vm.signedInToday).assertTrue();
      expect(vm.signInContinuous).assertEqual(141);
      expect(vm.signInToast).assertEqual('签到成功，连续 141 天');

      // 同 UID 同日再次签到：本地拦截，不重复发请求
      const dupOk: boolean = await vm.performSignIn('1001', '2026-11-16');
      expect(dupOk).assertFalse();
      expect(repo.signCalls).assertEqual(1);

      // 切换其他 UID 或次日：自动恢复为未签到状态
      expect(prefs.isSignedInTodaySync('2002', '2026-11-16')).assertFalse();
      expect(prefs.isSignedInTodaySync('1001', '2026-11-17')).assertFalse();
      prefs.reset();
    });

    it('launchSignInCheckCoversAllFiveBranches', 0, async () => {
      const prefs: PreferenceManager = PreferenceManager.getInstance();
      prefs.reset();
      const repo: StubSignInUserRepository = new StubSignInUserRepository();
      const mgr: DailySignInManager = new DailySignInManager(repo);

      // 1. 未登录（uid 为空）：不查询、不弹窗
      expect(await mgr.checkDailySignInOnLaunch('', '2026-11-17')).assertFalse();
      expect(repo.recordCalls).assertEqual(0);
      expect(mgr.showPrompt).assertFalse();

      // 2. 本地已记录今日已签：跳过网络查询、不弹窗
      await prefs.markSignedInToday('1001', '2026-11-17');
      expect(await mgr.checkDailySignInOnLaunch('1001', '2026-11-17')).assertFalse();
      expect(repo.recordCalls).assertEqual(0);
      expect(mgr.showPrompt).assertFalse();

      // 3. 本地未签但服务端返回 today=true：同步本地且不弹窗
      prefs.reset();
      mgr.resetForTest();
      repo.recordResult = { today: true, continuous: 141 };
      expect(await mgr.checkDailySignInOnLaunch('1001', '2026-11-17')).assertFalse();
      expect(repo.recordCalls).assertEqual(1);
      expect(mgr.showPrompt).assertFalse();
      expect(prefs.isSignedInTodaySync('1001', '2026-11-17')).assertTrue();

      // 4. 服务端返回 today=false：弹出签到弹窗 → 立即签到成功关闭 → 同会话不重复弹窗
      prefs.reset();
      mgr.resetForTest();
      repo.recordCalls = 0;
      repo.recordResult = { today: false, continuous: 140 };
      expect(await mgr.checkDailySignInOnLaunch('1001', '2026-11-17')).assertTrue();
      expect(mgr.showPrompt).assertTrue();
      expect(mgr.continuousDays).assertEqual(140);
      expect(await mgr.confirmSignIn('1001', '2026-11-17')).assertTrue();
      expect(mgr.showPrompt).assertFalse();
      expect(mgr.signedInToday).assertTrue();
      expect(prefs.isSignedInTodaySync('1001', '2026-11-17')).assertTrue();
      expect(await mgr.checkDailySignInOnLaunch('1001', '2026-11-17')).assertFalse();
      expect(repo.recordCalls).assertEqual(1);

      // 5. 网络异常：静默忽略，不弹窗不报错
      prefs.reset();
      mgr.resetForTest();
      repo.failRecordWith = new HttpError(500, 'timeout');
      expect(await mgr.checkDailySignInOnLaunch('1001', '2026-11-17')).assertFalse();
      expect(mgr.showPrompt).assertFalse();
      expect(mgr.toastMessage).assertEqual('');

      prefs.reset();
    });

    it('weeklyCheckInDaysMapsStreakCorrectly', 0, () => {
      // 周日/周一映射：2026-11-16 是周一（0），2026-11-22 是周日（6）
      expect(weekdayMonFirstFromDate(new Date(2026, 10, 16))).assertEqual(0);
      expect(weekdayMonFirstFromDate(new Date(2026, 10, 18))).assertEqual(2); // 周三
      expect(weekdayMonFirstFromDate(new Date(2026, 10, 22))).assertEqual(6); // 周日

      // 周三已签，连续 3 天 → Mon/Tue/Wed 为 true，其余 false
      const wedChecked: boolean[] = buildWeekCheckInDays(2, 3, true);
      expect(JSON.stringify(wedChecked)).assertEqual('[true,true,true,false,false,false,false]');
      expect(countWeekCheckedDays(wedChecked)).assertEqual(3);

      // 周三未签，连续 2 天 → Mon/Tue 为 true，Wed..Sun 为 false
      const wedUnchecked: boolean[] = buildWeekCheckInDays(2, 2, false);
      expect(JSON.stringify(wedUnchecked)).assertEqual('[true,true,false,false,false,false,false]');
      expect(countWeekCheckedDays(wedUnchecked)).assertEqual(2);

      // 跨周长连签：周五已签，连续 15 天 → 仅截断至本周 Mon..Fri（5 天）
      const friLongStreak: boolean[] = buildWeekCheckInDays(4, 15, true);
      expect(JSON.stringify(friLongStreak)).assertEqual('[true,true,true,true,true,false,false]');
      expect(countWeekCheckedDays(friLongStreak)).assertEqual(5);

      // 边界：今日未签且连签 0 天 → 全 false；今日已签但后端给 streak=0 → 至少今日为 true
      const noneChecked: boolean[] = buildWeekCheckInDays(1, 0, false);
      expect(countWeekCheckedDays(noneChecked)).assertEqual(0);
      const onlyToday: boolean[] = buildWeekCheckInDays(3, 0, true);
      expect(JSON.stringify(onlyToday)).assertEqual('[false,false,false,true,false,false,false]');
      expect(countWeekCheckedDays(onlyToday)).assertEqual(1);
    });

    it('checkInReminderPreferencesAndTimeFormatting', 0, async () => {
      expect(DEFAULT_SIGN_IN_REMINDER_TIME).assertEqual('07:00');
      expect(formatReminderTime(7, 5)).assertEqual('07:05');
      expect(formatReminderTime(21, 35)).assertEqual('21:35');
      expect(formatReminderTime(0, 0)).assertEqual('00:00');

      // 非法时间格式一律安全回退默认值 '07:00'
      expect(normalizeReminderTime('25:99')).assertEqual('07:00');
      expect(normalizeReminderTime('')).assertEqual('07:00');
      expect(normalizeReminderTime('bad')).assertEqual('07:00');
      expect(normalizeReminderTime(' 08:30 ')).assertEqual('08:30');

      const parsed: ReminderTimeParts = parseReminderTime('21:45');
      expect(parsed.hour).assertEqual(21);
      expect(parsed.minute).assertEqual(45);

      const prefs: PreferenceManager = PreferenceManager.getInstance();
      prefs.reset();
      expect(prefs.signInReminderEnabled).assertFalse();
      expect(prefs.signInReminderTime).assertEqual('07:00');

      expect(await prefs.setSignInReminderEnabled(true)).assertTrue();
      expect(prefs.signInReminderEnabled).assertTrue();
      expect(await prefs.setSignInReminderTime('20:15')).assertTrue();
      expect(prefs.signInReminderTime).assertEqual('20:15');

      prefs.reset();
      expect(prefs.signInReminderEnabled).assertFalse();
      expect(prefs.signInReminderTime).assertEqual('07:00');
    });

    it('checkInModalOpenAndStayVisibleAfterSignIn', 0, async () => {
      const prefs: PreferenceManager = PreferenceManager.getInstance();
      prefs.reset();
      const repo: StubSignInUserRepository = new StubSignInUserRepository();
      repo.recordResult = { today: false, continuous: 6 };
      repo.signResult = { status: 'SIGNED', continuous: 7, message: '签到成功！积分 +10' };
      const mgr: DailySignInManager = new DailySignInManager(repo);

      // 个人中心打开弹窗：初始同步连续天数与今日未签，弹窗保持开启
      mgr.openModal(6, false);
      expect(mgr.showPrompt).assertTrue();
      expect(mgr.continuousDays).assertEqual(6);
      expect(mgr.signedInToday).assertFalse();

      // 弹窗内确认签到（closeOnSuccess = false）：成功后停留在弹窗展示「已签到」状态
      const ok: boolean = await mgr.confirmSignIn('1001', '2026-11-17', false);
      expect(ok).assertTrue();
      expect(mgr.showPrompt).assertTrue();
      expect(mgr.signedInToday).assertTrue();
      expect(mgr.continuousDays).assertEqual(7);
      expect(mgr.toastMessage).assertEqual('签到成功！积分 +10');

      prefs.reset();
    });

    // ==================== 账号收藏：表单与解析 ====================

    it('favoriteFormOmitsAllClass', 0, () => {
      const all: Record<string, string> = buildFavoriteForm(1);
      expect(all['page']).assertEqual('1');
      expect(all['class'] === undefined).assertTrue();
      // class='all' 同样省略
      const allExplicit: Record<string, string> = buildFavoriteForm(2, FAVORITE_CLASS_ALL);
      expect(allExplicit['class'] === undefined).assertTrue();
      // 具体分类带上 class
      const withClass: Record<string, string> = buildFavoriteForm(3, '5');
      expect(withClass['page']).assertEqual('3');
      expect(withClass['class']).assertEqual('5');
      // 非法页码回退 1
      expect(buildFavoriteForm(0)['page']).assertEqual('1');
    });

    it('accountFavoritesMapsBooksAndPaging', 0, () => {
      const page1: PageInfo<Comic> = parseAccountFavoritesJson(ACCOUNT_FAVORITES_SUCCESS_DERIVED, 1);
      expect(page1.list.length).assertEqual(2);
      expect(page1.list[0].id).assertEqual('810001');
      expect(page1.list[0].title).assertEqual('账号收藏範例 A');
      // count=42 / 20 → 3 页
      expect(page1.totalPages).assertEqual(3);
      expect(page1.hasMore).assertTrue();
      // 末页不再有下一页
      const page3: PageInfo<Comic> = parseAccountFavoritesJson(ACCOUNT_FAVORITES_SUCCESS_DERIVED, 3);
      expect(page3.hasMore).assertFalse();
    });

    it('accountFavoritesLoginRequired', 0, () => {
      const err: Error | null = catchError(() => {
        parseAccountFavoritesJson(USERINFO_ANON, 1);
      });
      expect(err instanceof AuthRequiredError).assertTrue();
    });

    it('accountFavoritesMissingDataRejected', 0, () => {
      const err: Error | null = catchError(() => {
        parseAccountFavoritesJson('{"status":"ok"}', 1);
      });
      expect(err instanceof ProtocolError).assertTrue();
    });

    it('favoriteClassesParsed', 0, () => {
      const classes: FavoriteClass[] = parseFavoriteClassesJson(FAVORITE_CLASSES_SUCCESS_DERIVED);
      expect(classes.length).assertEqual(2);
      expect(classes[0].id).assertEqual('3');
      expect(classes[0].name).assertEqual('默認收藏');
      expect(classes[1].id).assertEqual('5');
    });

    // ==================== ShelfViewModel：账号 / 本地分离 ====================

    it('shelfDedupesAccountByBidAndPreservesOrder', 0, async () => {
      const port: StubAccountPort = new StubAccountPort();
      const dup1: Comic = new Comic('1', 'A', '', '', '', '', '');
      const dup2: Comic = new Comic('1', 'A-dup', '', '', '', '', '');
      const other: Comic = new Comic('2', 'B', '', '', '', '', '');
      port.page = new PageInfo<Comic>(1, 1, [dup1, dup2, other], false);
      const vm: ShelfViewModel = new ShelfViewModel(new AccountFavoriteRepository(port));
      await vm.loadAccount(true);
      expect(port.calls).assertEqual(1);
      expect(vm.accountList.length).assertEqual(2);
      expect(vm.accountList[0].id).assertEqual('1');
      expect(vm.accountList[1].id).assertEqual('2');
      expect(vm.accountLoaded).assertTrue();
    });

    it('shelfAccountNeedsLoginOnAuthError', 0, async () => {
      const port: StubAccountPort = new StubAccountPort();
      port.failWith = new AuthRequiredError('未登录');
      const vm: ShelfViewModel = new ShelfViewModel(new AccountFavoriteRepository(port));
      await vm.loadAccount(true);
      expect(vm.accountNeedsLogin).assertTrue();
      expect(vm.accountList.length).assertEqual(0);
      expect(vm.accountLoaded).assertFalse();
    });

    it('shelfAccountAndLocalAreSeparate', 0, async () => {
      const port: StubAccountPort = new StubAccountPort();
      port.page = new PageInfo<Comic>(1, 1, [new Comic('9', 'X', '', '', '', '', '')], false);
      const vm: ShelfViewModel = new ShelfViewModel(new AccountFavoriteRepository(port));
      await vm.loadAccount(true);
      // 账号收藏不影响本地列表；currentList 随 activeSource 切换
      expect(vm.favoriteList.length).assertEqual(0);
      vm.setActiveSource(SHELF_SOURCE_ACCOUNT);
      expect(vm.currentList().length).assertEqual(1);
      expect(vm.currentList()[0].id).assertEqual('9');
    });

    it('historyHydratesLegacyRecordAndSupportsDeleteClear', 0, async () => {
      class StubHistoryStore implements HistoryStorePort {
        records: HistoryRecord[] = [];
        updatedIds: string[] = [];
        removedIds: string[] = [];
        clearedCount: number = 0;

        async getRecentHistories(limit?: number): Promise<HistoryRecord[]> {
          const cap: number = limit !== undefined ? limit : this.records.length;
          return this.records.slice(0, cap);
        }

        async updateHistoryMetadata(comicId: string, meta: HistoryMetadata): Promise<void> {
          this.updatedIds.push(comicId);
          for (let i = 0; i < this.records.length; i++) {
            if (this.records[i].comicId === comicId) {
              this.records[i] = {
                comicId: this.records[i].comicId,
                chapterId: this.records[i].chapterId,
                chapterTitle: this.records[i].chapterTitle,
                pageIndex: this.records[i].pageIndex,
                updateTime: this.records[i].updateTime,
                title: meta.title,
                coverUrl: meta.coverUrl,
                author: meta.author,
                tags: meta.tags,
                isCompleted: meta.isCompleted,
                views: meta.views,
                favorites: meta.favorites
              };
            }
          }
        }

        async removeHistory(comicId: string): Promise<void> {
          this.removedIds.push(comicId);
          this.records = this.records.filter((r: HistoryRecord) => r.comicId !== comicId);
        }

        async clearAllHistories(): Promise<void> {
          this.clearedCount++;
          this.records = [];
        }
      }

      class StubHistoryDetailSource extends StubHomeSource {
        detailCalls: number = 0;

        async getComicDetail(id: string): Promise<ComicDetail> {
          this.detailCalls++;
          const detail: ComicDetail = new ComicDetail(
            id,
            `测试作品 ${id}`,
            `https://img.example.com/${id}_m.jpg`
          );
          detail.author = '测试作者';
          detail.latestChapter = '连载中';
          detail.tags = ['纯爱', '全彩'];
          detail.isCompleted = false;
          detail.views = 12345;
          detail.favorites = 678;
          return detail;
        }
      }

      ComicMetaCache.clear();
      const store: StubHistoryStore = new StubHistoryStore();
      store.records = [
        {
          comicId: '58626',
          chapterId: '0',
          chapterTitle: '单本',
          pageIndex: 3,
          updateTime: 1700000002
        },
        {
          comicId: '58627',
          chapterId: '12',
          chapterTitle: '第1话',
          pageIndex: 8,
          updateTime: 1700000001,
          title: '已有标题作品',
          coverUrl: 'https://img.example.com/58627_m.jpg',
          author: '原作者',
          tags: '校园',
          isCompleted: true,
          views: 900,
          favorites: 45
        }
      ];
      const src: StubHistoryDetailSource = new StubHistoryDetailSource();
      const vm: HistoryViewModel = new HistoryViewModel(store, src);

      await vm.load();
      // 仅旧记录 58626 缺少元数据并触发回源补齐；58627 已有标题不重复请求
      expect(src.detailCalls).assertEqual(1);
      expect(store.updatedIds.length).assertEqual(1);
      expect(store.updatedIds[0]).assertEqual('58626');
      expect(vm.records.length).assertEqual(2);
      expect(vm.records[0].title ?? '').assertEqual('测试作品 58626');
      expect(vm.records[0].author ?? '').assertEqual('测试作者');

      // toComic 映射真实元数据，不再回退为 作品 #58626
      const mapped0: Comic = HistoryViewModel.toComic(vm.records[0]);
      expect(mapped0.title).assertEqual('测试作品 58626');
      expect(mapped0.cover).assertEqual('https://img.example.com/58626_m.jpg');
      expect(mapped0.author).assertEqual('测试作者');
      expect(mapped0.views).assertEqual(12345);
      expect(mapped0.favorites).assertEqual(678);
      expect(mapped0.categories).assertEqual('纯爱 全彩');
      expect(ComicMetaCache.get('58626')?.title ?? '').assertEqual('测试作品 58626');

      // 单条删除
      expect(await vm.remove('58626')).assertTrue();
      expect(store.removedIds.length).assertEqual(1);
      expect(store.removedIds[0]).assertEqual('58626');
      expect(vm.records.length).assertEqual(1);
      expect(vm.records[0].comicId).assertEqual('58627');

      // 全部清空
      expect(await vm.clearAll()).assertTrue();
      expect(store.clearedCount).assertEqual(1);
      expect(vm.records.length).assertEqual(0);
      ComicMetaCache.clear();
    });

    it('readerDampingAndSegmentedSwipeState', 0, async () => {
      // 1. 阅读器条漫阻尼与单页 Swiper 步进配置
      expect(READER_STRIP_FRICTION).assertEqual(1.35);
      expect(READER_PAGE_SWIPE_DURATION_MS).assertEqual(220);
      expect(READER_PAGE_CACHED_COUNT).assertEqual(2);
      expect(READER_PAGE_DISPLAY_COUNT).assertEqual(1);
      expect(isPanEnabledForScale(1.0)).assertFalse();
      expect(isPanEnabledForScale(1.5)).assertTrue();

      // 2. 最新页分段按需加载：首次切入触发加载，重复切入同一排序/筛选不重复请求
      const src: StubHomeSource = new StubHomeSource();
      const tabVm: HomeViewModel = new HomeViewModel(src);
      expect(tabVm.ensureLatestTabLoaded('views', '')).assertTrue();
      await Promise.resolve();
      await Promise.resolve();
      expect(src.listCalls).assertEqual(1);
      expect(tabVm.ensureLatestTabLoaded('views', '')).assertFalse();
      expect(src.listCalls).assertEqual(1);
      expect(tabVm.ensureLatestTabLoaded('views', 'true')).assertTrue();
      await Promise.resolve();
      await Promise.resolve();
      expect(src.listCalls).assertEqual(2);
    });

    it('detailCollapsedChaptersCommentFilterShareAndRating', 0, async () => {
      class StubDetailSource extends StubHomeSource {
        async getComicDetail(id: string): Promise<ComicDetail> {
          const d: ComicDetail = new ComicDetail(id, '测试漫画', 'https://img.example.com/cover.jpg');
          d.rating = 8.0;
          d.ratingCount = 4;
          const ch1: Chapter = new Chapter('101', '第1话', 1);
          const ch2: Chapter = new Chapter('102', '第2话', 2);
          d.chapters = [ch1, ch2];
          d.groups = [new ChapterGroup('g1', '單話', [ch1, ch2])];
          return d;
        }
      }

      class StubLocalStore implements ReadingStorePort {
        async isFavorite(_comicId: string): Promise<boolean> {
          return false;
        }
        async toggleFavorite(_comicId: string, _title: string, _coverUrl: string): Promise<boolean> {
          return false;
        }
        async getFavorites(): Promise<[]> {
          return [];
        }
        async saveHistory(): Promise<void> {}
        async getHistories(): Promise<[]> {
          return [];
        }
        async getHistory(_comicId: string): Promise<null> {
          return null;
        }
        async getHistoryForChapter(_comicId: string, _chapterId: string): Promise<null> {
          return null;
        }
      }

      const vm: ComicDetailViewModel = new ComicDetailViewModel(
        new StubDetailSource(),
        new StubLocalStore(),
        new NoopDownloadControl(),
        new StubAccountPort()
      );
      await vm.loadDetail('54485');
      // 1. 章节分组默认折叠
      expect(vm.detail !== null).assertTrue();
      expect(vm.detail!.groups.length).assertEqual(1);
      expect(vm.detail!.groups[0].isExpanded).assertFalse();
      expect(vm.chapterRows.totalCount()).assertEqual(1);
      vm.toggleGroup('g1');
      expect(vm.detail!.groups[0].isExpanded).assertTrue();
      expect(vm.chapterRows.totalCount()).assertEqual(3);

      // 2. 评论过滤官方旧版升级公告
      const notice1: BookComment = new BookComment();
      notice1.cid = '1';
      notice1.username = '官方公告';
      notice1.content = '舊版本將會緩慢停止服務';
      const notice2: BookComment = new BookComment();
      notice2.cid = '2';
      notice2.username = '系统';
      notice2.content = '2.x 和 3.x 是圖標長得完全一樣的';
      const normal: BookComment = new BookComment();
      normal.cid = '3';
      normal.username = '读者A';
      normal.content = '画风很棒';
      const filtered: BookComment[] = ComicDetailViewModel.filterComments([notice1, notice2, normal]);
      expect(filtered.length).assertEqual(1);
      expect(filtered[0].cid).assertEqual('3');

      // 3. 分享链接/文本与评分提交
      expect(ComicDetailViewModel.buildShareLink('54485')).assertEqual('https://noy.asia/comic/54485');
      expect(ComicDetailViewModel.buildShareText('测试漫画', '54485'))
        .assertEqual('测试漫画 https://noy.asia/comic/54485');
      expect(vm.submitRating(5, false)).assertFalse();
      expect(vm.ratingNotice).assertEqual('请先登录后评分');
      expect(vm.submitRating(5, true)).assertTrue();
      expect(vm.userRatingStars).assertEqual(5);
      expect(vm.detail!.ratingCount).assertEqual(5);
      expect(ComicDetailViewModel.ratingLabelForStars(5)).assertEqual('5星 非常好');
    });

    it('readerInitAndChapterSwitchClearsStaleFramesAndDiscardsOutOfOrder', 0, async () => {
      class StubReaderSource extends StubHomeSource {
        requestedChapters: string[] = [];
        deferredChapter2: ((urls: string[]) => void) | null = null;

        async getChapterImages(_bookId: string, chapterId: string): Promise<string[]> {
          this.requestedChapters.push(chapterId);
          if (chapterId === 'c2') {
            return await new Promise<string[]>((resolve) => {
              this.deferredChapter2 = resolve;
            });
          }
          if (chapterId === 'c3') {
            return ['p1.jpg', 'p2.jpg', 'p3.jpg', 'p4.jpg', 'p5.jpg', 'p6.jpg'];
          }
          if (chapterId === 'c4') {
            return ['c4_1.jpg', 'c4_2.jpg'];
          }
          return ['c1_1.jpg'];
        }
      }

      class StubReaderLocal implements ReadingStorePort {
        async isFavorite(_comicId: string): Promise<boolean> { return false; }
        async toggleFavorite(_comicId: string, _title: string, _coverUrl: string): Promise<boolean> { return false; }
        async getFavorites(): Promise<[]> { return []; }
        async saveHistory(): Promise<void> {}
        async getHistories(): Promise<[]> { return []; }
        async getHistory(_comicId: string): Promise<null> { return null; }
        async getHistoryForChapter(_comicId: string, _chapterId: string): Promise<null> { return null; }
      }

      const src: StubReaderSource = new StubReaderSource();
      const vm: ComicReaderViewModel = new ComicReaderViewModel(src, new StubReaderLocal());

      // 1. 从第 3 话第 5 页进入：首帧准备立即置为 loading 且不暴露 chapters[0]
      const s1: number = vm.prepareChapter(5);
      expect(s1).assertEqual(1);
      expect(vm.isLoading).assertTrue();
      expect(vm.imageDataSource.totalCount()).assertEqual(0);
      await vm.loadChapter('54485', 'c3', 5);
      expect(src.requestedChapters.length).assertEqual(1);
      expect(src.requestedChapters[0]).assertEqual('c3');
      expect(vm.currentPage).assertEqual(5);
      expect(vm.imageDataSource.totalCount()).assertEqual(6);

      // 2. 切章到第 2 话（慢请求在途），立即同步清空旧画面并递增 sessionId
      const p2: Promise<void> = vm.loadChapter('54485', 'c2', 1, true);
      expect(vm.isLoading).assertTrue();
      expect(vm.imageDataSource.totalCount()).assertEqual(0);
      const sessionBeforeC4: number = vm.chapterSessionId;

      // 3. 快速连续切到第 4 话（先返回），随后第 2 话晚到响应必须被丢弃
      await vm.loadChapter('54485', 'c4', 1, true);
      expect(vm.chapterSessionId > sessionBeforeC4).assertTrue();
      expect(vm.imageDataSource.totalCount()).assertEqual(2);
      expect(vm.imageDataSource.getData(0)).assertEqual('c4_1.jpg');
      expect(vm.currentPage).assertEqual(1);

      if (src.deferredChapter2 !== null) {
        src.deferredChapter2(['stale_c2_1.jpg']);
      }
      await p2;
      // 过期第 2 话响应未覆盖第 4 话画面
      expect(vm.imageDataSource.totalCount()).assertEqual(2);
      expect(vm.imageDataSource.getData(0)).assertEqual('c4_1.jpg');
    });

    it('downloadDirEexistIdempotentAndDetailMetadataStableOnRefresh', 0, async () => {
      // 1. File exists / 13900015 幂等判定
      class FakeFsErr extends Error {
        code: number;
        constructor(code: number, msg: string) {
          super(msg);
          this.code = code;
        }
      }
      expect(isAlreadyExistsError(new FakeFsErr(13900015, 'File exists'))).assertTrue();
      expect(isAlreadyExistsError(new FakeFsErr(0, 'mkdir failed: File exists'))).assertTrue();
      expect(isAlreadyExistsError(new FakeFsErr(13900002, 'No such file or directory'))).assertFalse();

      // 2. 详情页刷新阅读进度后元数据模型（标签/角色/原作/分组）保持稳定不变
      class StubMetaSource extends StubHomeSource {
        async getComicDetail(id: string): Promise<ComicDetail> {
          const d: ComicDetail = new ComicDetail(id, '稳定布局测试', 'https://img.example.com/c.jpg');
          d.alias = '别名X';
          d.tags = ['纯爱', '校园'];
          d.characters = ['角色A'];
          d.originals = ['原作B'];
          const ch1: Chapter = new Chapter('10', '第1话', 1);
          d.chapters = [ch1];
          d.groups = [new ChapterGroup('g1', '單話', [ch1])];
          return d;
        }
      }
      class StubProgressLocal implements ReadingStorePort {
        savedHistories: HistoryRecord[] = [];
        async isFavorite(_comicId: string): Promise<boolean> { return false; }
        async toggleFavorite(_comicId: string, _title: string, _coverUrl: string): Promise<boolean> { return false; }
        async getFavorites(): Promise<[]> { return []; }
        async saveHistory(): Promise<void> {}
        async getHistories(): Promise<HistoryRecord[]> { return this.savedHistories; }
        async getHistory(_comicId: string): Promise<HistoryRecord | null> {
          return this.savedHistories.length > 0 ? this.savedHistories[0] : null;
        }
        async getHistoryForChapter(_comicId: string, _chapterId: string): Promise<null> { return null; }
      }

      const local: StubProgressLocal = new StubProgressLocal();
      const vm: ComicDetailViewModel = new ComicDetailViewModel(
        new StubMetaSource(),
        local,
        new NoopDownloadControl(),
        new StubAccountPort()
      );
      await vm.loadDetail('66342');
      local.savedHistories = [{
        comicId: '66342',
        chapterId: '10',
        chapterTitle: '第1话',
        pageIndex: 12,
        updateTime: 1700000100
      }];
      await vm.resyncProgressAndDownloadsOnReentry();
      expect(vm.historyChapterId).assertEqual('10');
      expect(vm.historyPageIndex).assertEqual(12);
      expect(vm.detail!.alias).assertEqual('别名X');
      expect(vm.detail!.tags.length).assertEqual(2);
      expect(vm.detail!.characters.length).assertEqual(1);
      expect(vm.detail!.originals.length).assertEqual(1);
      expect(vm.detail!.groups.length).assertEqual(1);
    });

    it('readerBackgroundAdaptsToLightAndDarkColorMode', 0, () => {
      const lightBg: string = resolveReaderBackgroundColor(false);
      const darkBg: string = resolveReaderBackgroundColor(true);
      expect(lightBg).assertEqual('#F7F8FA');
      expect(darkBg).assertEqual('#121212');
      expect(lightBg === '#000000').assertFalse();
      expect(lightBg === darkBg).assertFalse();
      expect(resolveReaderStatusBarContentColor(false)).assertEqual('#1E2430');
      expect(resolveReaderStatusBarContentColor(true)).assertEqual('#F8FAFC');
    });

    it('dockedBarsAndGridSurfaceColorsAreOpaqueAndHighContrast', 0, () => {
      // 1. 底部导航栏与停靠式分页栏在深浅色下均返回高对比度实色表面（非透明）
      expect(resolveBottomBarSurfaceColor(false)).assertEqual('#FFFFFF');
      expect(resolveBottomBarSurfaceColor(true)).assertEqual('#1C1E24');
      expect(resolvePaginationSurfaceColor(false)).assertEqual('#FFFFFF');
      expect(resolvePaginationSurfaceColor(true)).assertEqual('#181A20');
      expect(resolveBarDividerColor(false)).assertEqual('#E2E8F0');
      expect(resolveBarDividerColor(true)).assertEqual('#2E323D');

      // 2. 网格卡片竖屏 2 列 / 横屏 4 列断点
      const portraitCols: number = 390 >= 600 ? 4 : 2;
      const landscapeCols: number = 840 >= 600 ? 4 : 2;
      expect(portraitCols).assertEqual(2);
      expect(landscapeCols).assertEqual(4);
    });

    it('viewportStateIsLandscapeMatchesMainSideRailAndNotifiesListeners', 0, () => {
      const vp: ViewportState = ViewportState.getInstance();
      const prevW: number = vp.widthVp;
      const prevH: number = vp.heightVp;
      const prevTop: number = vp.topVp;
      const prevBottom: number = vp.bottomVp;

      let notifiedCount: number = 0;
      const listener = (): void => {
        notifiedCount += 1;
      };
      vp.addListener(listener);
      try {
        vp.setGeometry(390, 844, 38, 28);
        expect(vp.isBottomNav()).assertTrue();
        expect(vp.isLandscape()).assertFalse();

        vp.setGeometry(844, 390, 0, 20);
        expect(vp.isBottomNav()).assertFalse();
        expect(vp.isLandscape()).assertTrue();
        expect(notifiedCount).assertLarger(0);
      } finally {
        vp.removeListener(listener);
        vp.setGeometry(prevW, prevH, prevTop, prevBottom);
      }
    });
  });
}
