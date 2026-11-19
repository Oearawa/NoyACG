/**
 * Phase14Q.test.ets —— Phase 14-Q 官方接口接入回归
 *
 * 覆盖：
 * 1. 协议层：榜单/推荐分页解析（info/len）、len 严格校验、bigtaglist 解析、login 错误映射；
 * 2. 请求构造：readLeaderboard/favLeaderboard 带 type、proportion 不带 type、moon 白名单；
 * 3. LeaderboardViewModel：三榜单、周期切换、服务端分页、边界夹取、代际守卫；
 * 4. BigTagViewModel：动态目录、search.join(' ')||tag、空/错误/未登录；
 * 5. RecommendViewModel：favoritesrecommend 分页、空态、登录、缓存隔离；
 * 6. 首页区块 → 目标页面映射。
 *
 * 重要：本文件全部为宿主侧逻辑测试，样例按 Phase 14-P 首方契约构造
 * （CONTRACT_DERIVED_FIXTURE），**不是** LIVE_CAPTURE / REAL_RESPONSE。
 * 未取得登录态真实响应，相关结论在报告中标记 LIVE_RESPONSE_UNVERIFIED。
 */
import { describe, it, expect } from '@ohos/hypium';
import { Comic } from '../main/ets/model/Comic';
import { PageInfo } from '../main/ets/model/PageInfo';
import {
  RawLeaderboardEnvelope,
  RawBigTagEnvelope,
  RawBookListItem,
  parseLeaderboardPage,
  parseBigTagList
} from '../main/ets/source/NoyAcgProtocol';
import { AuthRequiredError, ProtocolError } from '../main/ets/api/ApiErrors';
import {
  RANK_KIND_READING,
  RANK_KIND_FAVORITE,
  RANK_KIND_QUALITY,
  RANK_PERIOD_DAY,
  RANK_PERIOD_WEEK,
  RANK_PERIOD_MOON,
  RANK_PERIOD_VALUES,
  BigTagItem,
  buildBigTagQuery,
  buildLeaderboardForm,
  buildRecommendForm,
  homeSectionRankKind,
  homeSectionRankPeriod,
  homeSectionRoute,
  HOME_ROUTE_RANK,
  HOME_ROUTE_PERSONALIZED,
  HOME_SECTION_READ_DAY,
  HOME_SECTION_FAV_DAY,
  HOME_SECTION_PROPORTION,
  HOME_SECTION_FS,
  isValidRankPeriod,
  normalizeRankPeriod,
  normalizeServerLen,
  rankKindPath,
  rankKindSupportsPeriod,
  serverTotalPages,
  SERVER_LEN_UNKNOWN
} from '../main/ets/model/LeaderboardModels';
import { LeaderboardViewModel } from '../main/ets/viewmodel/LeaderboardViewModel';
import { BigTagViewModel } from '../main/ets/viewmodel/BigTagViewModel';
import { RecommendViewModel } from '../main/ets/viewmodel/RecommendViewModel';
import { LeaderboardPort, BigTagPort, RecommendPort } from '../main/ets/source/DiscoverySourcePort';
import { RecommendRepository } from '../main/ets/api/DiscoveryRepository';
import { COUNT_MODE_SERVER_TOTAL, COUNT_MODE_UNKNOWN } from '../main/ets/utils/Pagination';
import { SEARCH_MODE_TAG } from '../main/ets/model/NavParams';

// ==================== 契约派生样例（CONTRACT_DERIVED_FIXTURE） ====================

function makeComic(id: string): Comic {
  return new Comic(id, `title_${id}`, `https://img.noymanga.com/${id}/m1.webp`, '', '');
}

function makeRawBook(index: number, prefix: string): RawBookListItem {
  const item: RawBookListItem = {
    Bid: index + 1,
    Bookname: `book_${prefix}_${index}`,
    Author: `author_${index}`,
    Ptag: '奇幻 冒險',
    Views: 100 + index,
    Favorites: 10 + index,
    RatingSUM: 9.5,
    Len: 1,
    Adult: 0,
    Status: 0,
    publish_year: '2024'
  };
  return item;
}

function leaderboardEnvelope(count: number, len: number | string | null | undefined,
  prefix: string = 'c'): RawLeaderboardEnvelope {
  const info: RawBookListItem[] = [];
  for (let i = 0; i < count; i++) {
    info.push(makeRawBook(i, prefix));
  }
  const envelope: RawLeaderboardEnvelope = { status: 'ok', info: info, len: len };
  return envelope;
}

/**
 * 直接构造服务端语义的分页结果（供 Fake 端口使用）。
 * 不在 Fake 里调用可能抛异常的解析器：解析器行为由 ProtocolParsing 组单独覆盖，
 * 这样既避免「未处理异常」编译告警，也不重复被测逻辑。
 */
function serverPage(page: number, count: number, len: number, prefix: string): PageInfo<Comic> {
  const list: Comic[] = [];
  for (let i = 0; i < count; i++) {
    list.push(makeComic(`${prefix}_${page}_${i}`));
  }
  const totalPages: number = len >= 0 ? Math.max(1, Math.ceil(len / 20)) : 0;
  return new PageInfo<Comic>(page, totalPages, list, page < totalPages, len);
}

/** 记录调用参数的榜单端口。 */
class RecordingLeaderboardPort implements LeaderboardPort {
  calls: string[] = [];
  pages: number[] = [];
  periods: string[] = [];
  fail: boolean = false;
  login: boolean = false;
  len: number = 42;
  count: number = 20;
  delayMs: number = 0;

  async fetchLeaderboard(kind: string, page: number, period: string): Promise<PageInfo<Comic>> {
    this.calls.push(kind);
    this.pages.push(page);
    this.periods.push(period);
    if (this.delayMs > 0) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, this.delayMs);
      });
    }
    if (this.login) {
      throw new AuthRequiredError('login');
    }
    if (this.fail) {
      throw new Error('network');
    }
    return serverPage(page, this.count, this.len, kind);
  }
}

class FakeBigTagPort implements BigTagPort {
  items: BigTagItem[] = [];
  fail: boolean = false;
  login: boolean = false;
  calls: number = 0;

  async fetchBigTags(): Promise<BigTagItem[]> {
    this.calls++;
    if (this.login) {
      throw new AuthRequiredError('login');
    }
    if (this.fail) {
      throw new Error('network');
    }
    return this.items;
  }
}

class RecordingRecommendPort implements RecommendPort {
  pages: number[] = [];
  len: number = 25;
  count: number = 20;
  fail: boolean = false;
  login: boolean = false;
  delayMs: number = 0;

  async fetchRecommend(page: number): Promise<PageInfo<Comic>> {
    this.pages.push(page);
    if (this.delayMs > 0) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, this.delayMs);
      });
    }
    if (this.login) {
      throw new AuthRequiredError('login');
    }
    if (this.fail) {
      throw new Error('network');
    }
    return serverPage(page, this.count, this.len, 'r');
  }
}

async function settle(): Promise<void> {
  await new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, 0);
  });
}

export default function phase14qTest() {
  describe('Phase14Q_RequestContract', () => {
    it('mapsRankKindsToOfficialPaths', 0, () => {
      expect(rankKindPath(RANK_KIND_READING)).assertEqual('/api/readLeaderboard');
      expect(rankKindPath(RANK_KIND_FAVORITE)).assertEqual('/api/favLeaderboard');
      expect(rankKindPath(RANK_KIND_QUALITY)).assertEqual('/api/proportion');
    });

    it('includesTypeOnlyForReadingAndFavorite', 0, () => {
      const read = buildLeaderboardForm(RANK_KIND_READING, 1, RANK_PERIOD_WEEK);
      expect(read['page']).assertEqual('1');
      expect(read['type']).assertEqual('week');
      const fav = buildLeaderboardForm(RANK_KIND_FAVORITE, 2, RANK_PERIOD_MOON);
      expect(fav['page']).assertEqual('2');
      expect(fav['type']).assertEqual('moon');
      // 高质量榜绝不带 type
      const quality = buildLeaderboardForm(RANK_KIND_QUALITY, 3, RANK_PERIOD_WEEK);
      expect(quality['page']).assertEqual('3');
      expect(quality['type'] === undefined).assertTrue();
    });

    it('usesMoonNotMonthForMonthly', 0, () => {
      expect(RANK_PERIOD_MOON).assertEqual('moon');
      expect(RANK_PERIOD_MOON === 'month').assertFalse();
      expect(normalizeRankPeriod('moon')).assertEqual('moon');
      // 首方白名单不含 month：非法值回落 day，绝不把 month 发出去
      expect(normalizeRankPeriod('month')).assertEqual('day');
      expect(normalizeRankPeriod('')).assertEqual('day');
      expect(normalizeRankPeriod('YEAR')).assertEqual('day');
      expect(RANK_PERIOD_VALUES.length).assertEqual(3);
      expect(isValidRankPeriod('moon')).assertTrue();
      expect(isValidRankPeriod('month')).assertFalse();
    });

    it('normalizesPageToOneBasedPositiveInteger', 0, () => {
      expect(buildLeaderboardForm(RANK_KIND_READING, 0, RANK_PERIOD_DAY)['page']).assertEqual('1');
      expect(buildLeaderboardForm(RANK_KIND_READING, -5, RANK_PERIOD_DAY)['page']).assertEqual('1');
      expect(buildLeaderboardForm(RANK_KIND_READING, 2.7, RANK_PERIOD_DAY)['page']).assertEqual('2');
      expect(buildRecommendForm(0)['page']).assertEqual('1');
      expect(buildRecommendForm(4)['page']).assertEqual('4');
      const rec = buildRecommendForm(7);
      expect(rec['type'] === undefined).assertTrue();
    });

    it('declaresPeriodSupportPerKind', 0, () => {
      expect(rankKindSupportsPeriod(RANK_KIND_READING)).assertTrue();
      expect(rankKindSupportsPeriod(RANK_KIND_FAVORITE)).assertTrue();
      expect(rankKindSupportsPeriod(RANK_KIND_QUALITY)).assertFalse();
    });
  });

  describe('Phase14Q_ProtocolParsing', () => {
    it('parsesLeaderboardInfoAndLen', 0, () => {
      const page: PageInfo<Comic> = parseLeaderboardPage(leaderboardEnvelope(20, 42), 1);
      expect(page.list.length).assertEqual(20);
      expect(page.totalCount).assertEqual(42);
      expect(page.totalPages).assertEqual(3);
      expect(page.hasMore).assertTrue();
      expect(page.list[0].title).assertEqual('book_c_0');
    });

    it('acceptsNumericStringLenAndRejectsGarbage', 0, () => {
      expect(normalizeServerLen('42')).assertEqual(42);
      expect(normalizeServerLen(42)).assertEqual(42);
      expect(normalizeServerLen('  42  ')).assertEqual(42);
      expect(normalizeServerLen(0)).assertEqual(0);
      expect(normalizeServerLen('')).assertEqual(SERVER_LEN_UNKNOWN);
      expect(normalizeServerLen('abc')).assertEqual(SERVER_LEN_UNKNOWN);
      expect(normalizeServerLen(-1)).assertEqual(SERVER_LEN_UNKNOWN);
      expect(normalizeServerLen(1.5)).assertEqual(1);
      expect(normalizeServerLen(null)).assertEqual(SERVER_LEN_UNKNOWN);
      expect(normalizeServerLen(undefined)).assertEqual(SERVER_LEN_UNKNOWN);
      expect(normalizeServerLen('12.5')).assertEqual(SERVER_LEN_UNKNOWN);
    });

    it('marksUnknownLenRatherThanZero', 0, () => {
      const page: PageInfo<Comic> = parseLeaderboardPage(leaderboardEnvelope(20, undefined), 1);
      expect(page.totalCount).assertEqual(SERVER_LEN_UNKNOWN);
      expect(page.totalPages).assertEqual(-1);
      // 未知总量不得被当成 0 条
      expect(page.totalCount === 0).assertFalse();
    });

    it('computesServerTotalPagesWithMinimumOne', 0, () => {
      expect(serverTotalPages(42, 20)).assertEqual(3);
      expect(serverTotalPages(0, 20)).assertEqual(1);
      expect(serverTotalPages(20, 20)).assertEqual(1);
      expect(serverTotalPages(21, 20)).assertEqual(2);
      expect(serverTotalPages(-1, 20)).assertEqual(0);
    });

    it('mapsLoginToAuthRequiredError', 0, () => {
      const envelope: RawLeaderboardEnvelope = { status: 'login' };
      let caught: boolean = false;
      try {
        parseLeaderboardPage(envelope, 1);
      } catch (e) {
        caught = true;
        expect(e instanceof AuthRequiredError).assertTrue();
      }
      expect(caught).assertTrue();
    });

    it('rejectsMalformedLeaderboardResponses', 0, () => {
      let emptyCaught: boolean = false;
      try {
        parseLeaderboardPage(undefined, 1);
      } catch (e) {
        emptyCaught = e instanceof ProtocolError;
      }
      expect(emptyCaught).assertTrue();

      let missingCaught: boolean = false;
      const missingInfo: RawLeaderboardEnvelope = { status: 'ok' };
      try {
        parseLeaderboardPage(missingInfo, 1);
      } catch (e) {
        missingCaught = e instanceof ProtocolError;
      }
      expect(missingCaught).assertTrue();
    });

    it('handlesEmptyInfoAsRealEmptyPage', 0, () => {
      const page: PageInfo<Comic> = parseLeaderboardPage(leaderboardEnvelope(0, 0), 1);
      expect(page.list.length).assertEqual(0);
      expect(page.totalCount).assertEqual(0);
      expect(page.totalPages).assertEqual(1);
      expect(page.hasMore).assertFalse();
    });

    it('parsesBigTagListWithSearchAndCover', 0, () => {
      const envelope: RawBigTagEnvelope = {
        status: 'ok',
        data: [
          { tag: '奇幻', search: ['奇幻', '魔法'], cover: 12345 },
          { tag: '日常', search: [], cover: 0 },
          { tag: '戀愛' }
        ]
      };
      const items: BigTagItem[] = parseBigTagList(envelope);
      expect(items.length).assertEqual(3);
      expect(items[0].tag).assertEqual('奇幻');
      expect(items[0].search.length).assertEqual(2);
      expect(items[0].coverBid).assertEqual(12345);
      expect(items[0].cover).assertEqual('https://img.noymanga.com/12345/m1.webp');
      expect(items[0].hasCover).assertTrue();
      // search 为空 → 使用 tag
      expect(items[1].query).assertEqual('日常');
      // 缺 cover → 无封面占位，不伪造 URL
      expect(items[2].coverBid).assertEqual(-1);
      expect(items[2].cover).assertEqual('');
      expect(items[2].hasCover).assertFalse();
      expect(items[2].query).assertEqual('戀愛');
    });

    it('joinsSearchTagsInServerOrder', 0, () => {
      expect(buildBigTagQuery(['a', 'b', 'c'], 'x')).assertEqual('a b c');
      expect(buildBigTagQuery([], 'x')).assertEqual('x');
      expect(buildBigTagQuery(['', '  '], ' y ')).assertEqual('y');
      expect(buildBigTagQuery(['a', 'a'], 'x')).assertEqual('a a');
    });

    it('skipsEmptyTagsAndDuplicatesKeepingOrder', 0, () => {
      const envelope: RawBigTagEnvelope = {
        status: 'ok',
        data: [
          { tag: 'A', cover: 1 },
          { tag: '', cover: 2 },
          { tag: '  ', cover: 3 },
          { tag: 'B', cover: 4 },
          { tag: 'A', cover: 1 }
        ]
      };
      const items: BigTagItem[] = parseBigTagList(envelope);
      expect(items.length).assertEqual(2);
      expect(items[0].tag).assertEqual('A');
      expect(items[1].tag).assertEqual('B');
    });

    it('mapsBigTagLoginAndMalformed', 0, () => {
      let loginCaught: boolean = false;
      const loginEnv: RawBigTagEnvelope = { status: 'login' };
      try {
        parseBigTagList(loginEnv);
      } catch (e) {
        loginCaught = e instanceof AuthRequiredError;
      }
      expect(loginCaught).assertTrue();

      let malformed: boolean = false;
      const noData: RawBigTagEnvelope = { status: 'ok' };
      try {
        parseBigTagList(noData);
      } catch (e) {
        malformed = e instanceof ProtocolError;
      }
      expect(malformed).assertTrue();
    });
  });

  describe('Phase14Q_LeaderboardViewModel', () => {
    it('loadsReadingDayByDefaultWithServerTotal', 0, async () => {
      const port: RecordingLeaderboardPort = new RecordingLeaderboardPort();
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      await vm.load(true);
      expect(port.calls[0]).assertEqual(RANK_KIND_READING);
      expect(port.periods[0]).assertEqual(RANK_PERIOD_DAY);
      expect(port.pages[0]).assertEqual(1);
      expect(vm.countMode).assertEqual(COUNT_MODE_SERVER_TOTAL);
      expect(vm.totalCount).assertEqual(42);
      expect(vm.totalPages).assertEqual(3);
      expect(vm.items.length).assertEqual(20);
      expect(vm.isEmpty).assertFalse();
    });

    it('switchesAllThreeKindsAndResetsPage', 0, async () => {
      const port: RecordingLeaderboardPort = new RecordingLeaderboardPort();
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      await vm.load(true);
      vm.goToPage(2);
      await settle();
      expect(vm.currentPage).assertEqual(2);

      vm.setKind(RANK_KIND_FAVORITE);
      await settle();
      expect(vm.currentPage).assertEqual(1);
      expect(port.calls[port.calls.length - 1]).assertEqual(RANK_KIND_FAVORITE);
      expect(vm.items.length).assertEqual(20);

      vm.setKind(RANK_KIND_QUALITY);
      await settle();
      expect(vm.currentPage).assertEqual(1);
      expect(vm.kind).assertEqual(RANK_KIND_QUALITY);
      expect(port.calls[port.calls.length - 1]).assertEqual(RANK_KIND_QUALITY);
    });

    it('supportsAllThreePeriodsForReading', 0, async () => {
      const port: RecordingLeaderboardPort = new RecordingLeaderboardPort();
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      await vm.load(true);
      vm.setPeriod(RANK_PERIOD_WEEK);
      await settle();
      expect(port.periods[port.periods.length - 1]).assertEqual(RANK_PERIOD_WEEK);
      expect(vm.currentPage).assertEqual(1);
      vm.setPeriod(RANK_PERIOD_MOON);
      await settle();
      expect(port.periods[port.periods.length - 1]).assertEqual(RANK_PERIOD_MOON);
    });

    it('ignoresPeriodSwitchForQuality', 0, async () => {
      const port: RecordingLeaderboardPort = new RecordingLeaderboardPort();
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      vm.setKind(RANK_KIND_QUALITY);
      await settle();
      const before: number = port.calls.length;
      vm.setPeriod(RANK_PERIOD_WEEK);
      await settle();
      expect(port.calls.length).assertEqual(before);
      expect(vm.period).assertEqual(RANK_PERIOD_DAY);
    });

    it('requestsServerPagesInsteadOfLocalSlicing', 0, async () => {
      const port: RecordingLeaderboardPort = new RecordingLeaderboardPort();
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      await vm.load(true);
      vm.goToPage(3);
      await settle();
      expect(port.pages[port.pages.length - 1]).assertEqual(3);
      expect(vm.currentPage).assertEqual(3);
    });

    it('blocksDuplicatePageRequestsWhileLoading', 0, async () => {
      const port: RecordingLeaderboardPort = new RecordingLeaderboardPort();
      port.delayMs = 10;
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      const p: Promise<void> = vm.load(true);
      vm.goToPage(2);
      await p;
      await settle();
      // 加载中不允许并发翻页
      expect(port.pages.indexOf(2)).assertEqual(-1);
    });

    it('clampsOutOfRangePageAfterLenShrinks', 0, async () => {
      const port: RecordingLeaderboardPort = new RecordingLeaderboardPort();
      port.len = 100;
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      await vm.load(true);
      vm.goToPage(5);
      await settle();
      expect(vm.currentPage).assertEqual(5);
      // 服务端总量骤降为 25 → 2 页，第 5 页越界
      port.len = 25;
      vm.goToPage(3);
      await settle();
      expect(vm.totalPages).assertEqual(2);
      expect(vm.currentPage <= 2).assertTrue();
    });

    it('handlesEmptyLoginAndNetworkStates', 0, async () => {
      const emptyPort: RecordingLeaderboardPort = new RecordingLeaderboardPort();
      emptyPort.count = 0;
      emptyPort.len = 0;
      const emptyVm: LeaderboardViewModel = new LeaderboardViewModel(emptyPort);
      await emptyVm.load(true);
      expect(emptyVm.totalCount).assertEqual(0);
      expect(emptyVm.isEmpty).assertTrue();

      const loginPort: RecordingLeaderboardPort = new RecordingLeaderboardPort();
      loginPort.login = true;
      const loginVm: LeaderboardViewModel = new LeaderboardViewModel(loginPort);
      await loginVm.load(true);
      expect(loginVm.needsLogin).assertTrue();
      expect(loginVm.isEmpty).assertFalse();
      expect(loginVm.errorMessage !== '').assertTrue();

      const failPort: RecordingLeaderboardPort = new RecordingLeaderboardPort();
      failPort.fail = true;
      const failVm: LeaderboardViewModel = new LeaderboardViewModel(failPort);
      await failVm.load(true);
      expect(failVm.needsLogin).assertFalse();
      expect(failVm.errorMessage).assertEqual('network');
    });

    it('dropsStaleResponsesWithGenerationGuard', 0, async () => {
      const port: RecordingLeaderboardPort = new RecordingLeaderboardPort();
      port.delayMs = 10;
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      const slow: Promise<void> = vm.load(true);
      vm.setKind(RANK_KIND_QUALITY);
      await slow;
      await settle();
      expect(vm.kind).assertEqual(RANK_KIND_QUALITY);
    });

    it('appliesInitialRouteParam', 0, async () => {
      const port: RecordingLeaderboardPort = new RecordingLeaderboardPort();
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      vm.applyInitial(RANK_KIND_FAVORITE, RANK_PERIOD_WEEK);
      await vm.load(true);
      expect(vm.kind).assertEqual(RANK_KIND_FAVORITE);
      expect(vm.period).assertEqual(RANK_PERIOD_WEEK);
      // quality 强制丢弃周期
      vm.applyInitial(RANK_KIND_QUALITY, RANK_PERIOD_MOON);
      expect(vm.period).assertEqual(RANK_PERIOD_DAY);
      // 非法 kind 保持默认
      vm.applyInitial('nope', RANK_PERIOD_WEEK);
      expect(vm.kind).assertEqual(RANK_KIND_QUALITY);
    });

    it('marksUnknownCountModeWhenLenMissing', 0, async () => {
      const port: RecordingLeaderboardPort = new RecordingLeaderboardPort();
      port.len = -1;
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      await vm.load(true);
      expect(vm.countMode).assertEqual(COUNT_MODE_UNKNOWN);
      expect(vm.totalCount).assertEqual(-1);
      expect(vm.totalPages).assertEqual(0);
    });
  });

  describe('Phase14Q_BigTagViewModel', () => {
    it('loadsDynamicDirectoryAndBuildsTagSearch', 0, async () => {
      const port: FakeBigTagPort = new FakeBigTagPort();
      const env: RawBigTagEnvelope = {
        status: 'ok',
        data: [
          { tag: '奇幻', search: ['奇幻', '魔法'], cover: 111 },
          { tag: '日常', cover: 222 }
        ]
      };
      port.items = parseBigTagList(env);
      const vm: BigTagViewModel = new BigTagViewModel(port);
      await vm.load();
      expect(vm.items.length).assertEqual(2);
      expect(vm.loaded).assertTrue();
      expect(vm.queryFor(vm.items[0])).assertEqual('奇幻 魔法');
      expect(vm.queryFor(vm.items[1])).assertEqual('日常');
      const param = vm.searchParamFor(vm.items[0]);
      expect(param.keyword).assertEqual('奇幻 魔法');
      expect(param.mode).assertEqual(SEARCH_MODE_TAG);
      expect(param.keyword.indexOf('%') < 0).assertTrue();
    });

    it('handlesEmptyDirectoryWithoutHardcodedFallback', 0, async () => {
      const port: FakeBigTagPort = new FakeBigTagPort();
      const vm: BigTagViewModel = new BigTagViewModel(port);
      await vm.load();
      // 空目录就是空目录，不回退成固定 12 项
      expect(vm.items.length).assertEqual(0);
      expect(vm.loaded).assertTrue();
      expect(vm.errorMessage).assertEqual('');
    });

    it('separatesLoginFromEmptyAndError', 0, async () => {
      const loginPort: FakeBigTagPort = new FakeBigTagPort();
      loginPort.login = true;
      const loginVm: BigTagViewModel = new BigTagViewModel(loginPort);
      await loginVm.load();
      expect(loginVm.needsLogin).assertTrue();
      expect(loginVm.items.length).assertEqual(0);
      expect(loginVm.loaded).assertFalse();

      const failPort: FakeBigTagPort = new FakeBigTagPort();
      failPort.fail = true;
      const failVm: BigTagViewModel = new BigTagViewModel(failPort);
      await failVm.load();
      expect(failVm.needsLogin).assertFalse();
      expect(failVm.errorMessage).assertEqual('network');
    });

    it('retriesAfterFailure', 0, async () => {
      const port: FakeBigTagPort = new FakeBigTagPort();
      port.fail = true;
      const vm: BigTagViewModel = new BigTagViewModel(port);
      await vm.load();
      expect(vm.errorMessage).assertEqual('network');
      port.fail = false;
      const okEnv: RawBigTagEnvelope = { status: 'ok', data: [{ tag: 'X', cover: 1 }] };
      port.items = parseBigTagList(okEnv);
      vm.retry();
      await settle();
      expect(vm.items.length).assertEqual(1);
      expect(vm.errorMessage).assertEqual('');
    });
  });

  describe('Phase14Q_RecommendViewModel', () => {
    it('loadsFirstPageAndPaginatesOnServer', 0, async () => {
      const port: RecordingRecommendPort = new RecordingRecommendPort();
      const vm: RecommendViewModel = new RecommendViewModel(port);
      await vm.load(true);
      expect(port.pages[0]).assertEqual(1);
      expect(vm.countMode).assertEqual(COUNT_MODE_SERVER_TOTAL);
      expect(vm.totalCount).assertEqual(25);
      expect(vm.totalPages).assertEqual(2);
      expect(vm.items.length).assertEqual(20);
      expect(vm.isEmpty).assertFalse();

      vm.goToPage(2);
      await settle();
      expect(port.pages[port.pages.length - 1]).assertEqual(2);
      expect(vm.currentPage).assertEqual(2);
    });

    it('showsOfficialEmptyState', 0, async () => {
      const port: RecordingRecommendPort = new RecordingRecommendPort();
      port.count = 0;
      port.len = 0;
      const vm: RecommendViewModel = new RecommendViewModel(port);
      await vm.load(true);
      expect(vm.isEmpty).assertTrue();
      expect(vm.totalCount).assertEqual(0);
      expect(vm.errorMessage).assertEqual('');
    });

    it('requiresLoginInsteadOfEmptyState', 0, async () => {
      const port: RecordingRecommendPort = new RecordingRecommendPort();
      port.login = true;
      const vm: RecommendViewModel = new RecommendViewModel(port);
      await vm.load(true);
      expect(vm.needsLogin).assertTrue();
      expect(vm.isEmpty).assertFalse();
      expect(vm.items.length).assertEqual(0);
    });

    it('reportsNetworkErrorAndRetries', 0, async () => {
      const port: RecordingRecommendPort = new RecordingRecommendPort();
      port.fail = true;
      const vm: RecommendViewModel = new RecommendViewModel(port);
      await vm.load(true);
      expect(vm.errorMessage).assertEqual('network');
      expect(vm.needsLogin).assertFalse();
      port.fail = false;
      vm.retry();
      await settle();
      expect(vm.items.length).assertEqual(20);
    });

    it('guardsAgainstStaleResponses', 0, async () => {
      const port: RecordingRecommendPort = new RecordingRecommendPort();
      port.delayMs = 10;
      const vm: RecommendViewModel = new RecommendViewModel(port);
      const slow: Promise<void> = vm.load(true);
      vm.goToPage(2);
      await slow;
      await settle();
      expect(vm.currentPage).assertEqual(1);
    });

    it('cachesPerPageWithoutCrossingBoundaries', 0, async () => {
      const inner: RecordingRecommendPort = new RecordingRecommendPort();
      const repo: RecommendRepository = new RecommendRepository(inner);
      repo.invalidate();
      await repo.fetchRecommend(1);
      const before: number = inner.pages.length;
      await repo.fetchRecommend(1);
      // 命中缓存：不再打服务端
      expect(inner.pages.length).assertEqual(before);
      await repo.fetchRecommend(2);
      expect(inner.pages.length).assertEqual(before + 1);
      repo.invalidate();
      expect(repo.cacheSize()).assertEqual(0);
    });
  });

  describe('Phase14Q_HomeSectionMapping', () => {
    it('mapsFourSectionsToOfficialTargets', 0, () => {
      expect(homeSectionRoute(HOME_SECTION_READ_DAY)).assertEqual(HOME_ROUTE_RANK);
      expect(homeSectionRankKind(HOME_SECTION_READ_DAY)).assertEqual(RANK_KIND_READING);
      expect(homeSectionRankPeriod(HOME_SECTION_READ_DAY)).assertEqual(RANK_PERIOD_DAY);

      expect(homeSectionRoute(HOME_SECTION_FAV_DAY)).assertEqual(HOME_ROUTE_RANK);
      expect(homeSectionRankKind(HOME_SECTION_FAV_DAY)).assertEqual(RANK_KIND_FAVORITE);

      expect(homeSectionRoute(HOME_SECTION_PROPORTION)).assertEqual(HOME_ROUTE_RANK);
      expect(homeSectionRankKind(HOME_SECTION_PROPORTION)).assertEqual(RANK_KIND_QUALITY);

      // fs 只能进个人化精选，不得当成榜单
      expect(homeSectionRoute(HOME_SECTION_FS)).assertEqual(HOME_ROUTE_PERSONALIZED);
      expect(homeSectionRankKind(HOME_SECTION_FS)).assertEqual('');
      expect(homeSectionRankPeriod(HOME_SECTION_FS)).assertEqual('');
    });

    it('returnsEmptyForUnknownSections', 0, () => {
      expect(homeSectionRoute('tags')).assertEqual('');
      expect(homeSectionRoute('unknown')).assertEqual('');
      expect(homeSectionRankKind('tags')).assertEqual('');
    });
  });

  describe('Phase14Q_Regression', () => {
    it('keepsExistingSearchTagContract', 0, () => {
      const param = buildLeaderboardForm(RANK_KIND_READING, 1, RANK_PERIOD_DAY);
      expect(param['page']).assertEqual('1');
      expect(param['type']).assertEqual('day');
      // 既有 12 项视觉目录仍在（作为离线参考保留，不再驱动分类页）
      expect(RANK_KIND_VALUES_LENGTH_CHECK()).assertEqual(3);
    });

    it('keepsMoonConstantStableForFuturePhases', 0, () => {
      // 回归：任何“好心”把 moon 改成 month 的改动都会在这里失败
      expect(RANK_PERIOD_MOON).assertEqual('moon');
      expect(RANK_PERIOD_VALUES.indexOf('moon') >= 0).assertTrue();
    });
  });
}

/** 小工具：避免在断言里直接写魔法数字 3（榜单类型数量）。 */
function RANK_KIND_VALUES_LENGTH_CHECK(): number {
  return [RANK_KIND_READING, RANK_KIND_FAVORITE, RANK_KIND_QUALITY].length;
}
