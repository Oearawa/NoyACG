/**
 * Phase14N1.test.ets —— Phase 14-N 数据准确性小范围修正回归（Phase 14-N1）
 *
 * 覆盖：
 * 1. 分页统计口径（serverTotal / localLoaded / unknown）与本地页数、边界、跳页；
 * 2. 排行榜语义（readDay / proportion 数据映射、未验证排序、禁用周月榜、代际守卫）；
 * 3. 12 个分类的静态搜索参数映射与真实验证状态（全部 API_UNVERIFIED）；
 * 4. 原功能回归：不删除、不弱化 Phase 14-N 及更早阶段的断言。
 *
 * 说明：本文件全部为宿主侧纯逻辑测试，使用真实协议结构的固定样例，
 * 不依赖实时 NoyAcg 服务器，也不把 Mock 成功结果当作线上接口已验证。
 */
import { describe, it, expect } from '@ohos/hypium';
import { Comic } from '../main/ets/model/Comic';
import { HomeFeed } from '../main/ets/model/HomeFeed';
import {
  SEARCH_MODE_TAG,
  SEARCH_MODE_DEFAULT,
  buildTagSearchParam
} from '../main/ets/model/NavParams';
import {
  RANK_TYPE_READING,
  RANK_TYPE_HIGH_QUALITY,
  RANK_PERIOD_DAY,
  RANK_PERIOD_WEEK,
  RANK_PERIOD_MONTH,
  CATEGORY_DEFINITIONS,
  CategoryDefinition,
  CategoryItem,
  rankFeedField,
  isRankPeriodSupported,
  rankNumber,
  categoryDefinitionByKey,
  buildCategorySearchParam
} from '../main/ets/model/DiscoveryModels';
import { DISCOVERY_ROUTES } from '../main/ets/model/DiscoveryRoutes';
import {
  computeTotalPages,
  computeLocalPages,
  normalizePage,
  computePaginationWindow,
  parseJumpPage,
  canChangePage,
  COUNT_MODE_SERVER_TOTAL,
  COUNT_MODE_LOCAL_LOADED,
  COUNT_MODE_UNKNOWN,
  COUNT_MODE_VALUES,
  STAT_LABEL_TOTAL,
  STAT_LABEL_LOADED,
  STAT_LABEL_UNKNOWN,
  STAT_LABEL_PAGES,
  STAT_LABEL_LOCAL_PAGES,
  STAT_LABEL_NONE,
  PaginationStats,
  normalizeCountMode,
  resolvePaginationStats
} from '../main/ets/utils/Pagination';
import { HomeFeedPort } from '../main/ets/api/DiscoveryRepository';
import {
  RankViewModel,
  RANK_ORDER_STATUS_UNVERIFIED,
  rankOrderStatus,
  officialRankBadgeVisible,
  displayRankNumber,
  rankSemanticsNoticeRequired
} from '../main/ets/viewmodel/RankViewModel';
import {
  CategoryViewModel,
  CategoryTextPort,
  CategorySearchVerification,
  CATEGORY_STATUS_VERIFIED,
  CATEGORY_STATUS_API_UNVERIFIED,
  CATEGORY_REQUEST_NOT_RUN,
  CATEGORY_RETURN_COUNT_UNKNOWN,
  verifyCategorySearchParam,
  verifyAllCategorySearchParams,
  categoryMappingsAreUniqueAndDefined,
  realVerifiedCategoryCount
} from '../main/ets/viewmodel/CategoryViewModel';

class FakeHomeFeedPort implements HomeFeedPort {
  feed: HomeFeed = new HomeFeed();
  calls: number = 0;
  fail: boolean = false;
  delayMs: number = 0;

  async getHomeFeed(): Promise<HomeFeed> {
    this.calls++;
    if (this.delayMs > 0) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, this.delayMs);
      });
    }
    if (this.fail) {
      throw new Error('network');
    }
    return this.feed;
  }
}

class SequencedHomeFeedPort implements HomeFeedPort {
  feeds: HomeFeed[] = [];
  delays: number[] = [];
  private index: number = 0;

  async getHomeFeed(): Promise<HomeFeed> {
    const i: number = this.index;
    this.index++;
    const delay: number = i < this.delays.length ? this.delays[i] : 0;
    if (delay > 0) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, delay);
      });
    }
    const last: number = this.feeds.length - 1;
    return last < 0 ? new HomeFeed() : this.feeds[Math.min(i, last)];
  }
}

/** 视觉参考的 12 个繁体标签（与 gen-i18n.mjs 的 category_tag_* 逐项一致）。 */
const REFERENCE_KEYS: string[] = [
  'fantasy', 'romance', 'daily', 'comedy', 'hotblood', 'action',
  'mystery', 'healing', 'school', 'music', 'four_panel', 'yuri'
];
const REFERENCE_TAGS: string[] = [
  '奇幻', '戀愛', '日常', '搞笑', '熱血', '動作',
  '懸疑', '治癒', '校園', '音樂', '四格', '百合'
];

/** 固定样例文本端口：返回真实资源中的繁体标签，不访问运行时资源系统。 */
class ReferenceCategoryTextPort implements CategoryTextPort {
  getName(def: CategoryDefinition): string {
    return `${def.key}_name`;
  }

  getTag(def: CategoryDefinition): string {
    const i: number = REFERENCE_KEYS.indexOf(def.key);
    return i >= 0 ? REFERENCE_TAGS[i] : '';
  }
}

class EmptyTagTextPort implements CategoryTextPort {
  getName(def: CategoryDefinition): string {
    return `${def.key}_name`;
  }

  getTag(def: CategoryDefinition): string {
    return '';
  }
}

function makeComic(id: string, categories: string = '', cover: string = ''): Comic {
  return new Comic(id, `title_${id}`, cover, '', categories);
}

function makeComics(count: number, prefix: string): Comic[] {
  const result: Comic[] = [];
  for (let i = 0; i < count; i++) {
    result.push(makeComic(`${prefix}_${i}`, '', `cover_${prefix}_${i}`));
  }
  return result;
}

function makeFeed(readCount: number, proportionCount: number): HomeFeed {
  const feed: HomeFeed = new HomeFeed();
  feed.readDay = makeComics(readCount, 'r');
  feed.proportion = makeComics(proportionCount, 'p');
  return feed;
}

async function settle(): Promise<void> {
  await new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, 0);
  });
}

async function loadCatalog(text?: CategoryTextPort): Promise<CategoryViewModel> {
  const port: FakeHomeFeedPort = new FakeHomeFeedPort();
  port.feed = makeFeed(1, 1);
  const vm: CategoryViewModel = new CategoryViewModel(port, text ?? new ReferenceCategoryTextPort());
  await vm.load();
  return vm;
}

export default function phase14n1Test() {
  describe('Phase14N1_PaginationStats', () => {
    it('showsRealServerTotalOnlyInServerTotalMode', 0, () => {
      const s: PaginationStats = resolvePaginationStats(COUNT_MODE_SERVER_TOTAL, 45889, 2295);
      expect(s.mode).assertEqual(COUNT_MODE_SERVER_TOTAL);
      expect(s.showCountNumber).assertTrue();
      expect(s.countLabel).assertEqual(STAT_LABEL_TOTAL);
      expect(s.count).assertEqual(45889);
      expect(s.showPages).assertTrue();
      expect(s.pagesLabel).assertEqual(STAT_LABEL_PAGES);
      expect(s.pages).assertEqual(2295);
    });

    it('showsLocallyLoadedCountAndLocalPagesInLocalMode', 0, () => {
      const s: PaginationStats = resolvePaginationStats(COUNT_MODE_LOCAL_LOADED, 42, 3);
      expect(s.showCountNumber).assertTrue();
      expect(s.countLabel).assertEqual(STAT_LABEL_LOADED);
      expect(s.count).assertEqual(42);
      expect(s.showPages).assertTrue();
      expect(s.pagesLabel).assertEqual(STAT_LABEL_LOCAL_PAGES);
      expect(s.pages).assertEqual(3);
      // 本地模式绝不能显示服务端总量/服务端页数文案
      expect(s.countLabel === STAT_LABEL_TOTAL).assertFalse();
      expect(s.pagesLabel === STAT_LABEL_PAGES).assertFalse();
    });

    it('neverShowsFabricatedNumbersWhenTotalIsUnknown', 0, () => {
      const s: PaginationStats = resolvePaginationStats(COUNT_MODE_UNKNOWN, 42, 3);
      expect(s.showCountNumber).assertFalse();
      expect(s.showPages).assertFalse();
      expect(s.count).assertEqual(0);
      expect(s.pages).assertEqual(0);
      expect(s.countLabel).assertEqual(STAT_LABEL_UNKNOWN);
      expect(s.pagesLabel).assertEqual(STAT_LABEL_NONE);
      // 非法/不存在的口径也不能回退成「服务端总量」
      const bad: PaginationStats = resolvePaginationStats('server_total_guess', 999, 50);
      expect(bad.mode).assertEqual(COUNT_MODE_UNKNOWN);
      expect(bad.showCountNumber).assertFalse();
      expect(bad.countLabel === STAT_LABEL_TOTAL).assertFalse();
    });

    it('hidesNumbersForNegativeOrNonFiniteCounts', 0, () => {
      const negative: PaginationStats = resolvePaginationStats(COUNT_MODE_SERVER_TOTAL, -1, 3);
      expect(negative.showCountNumber).assertFalse();
      expect(negative.showPages).assertFalse();
      const notFinite: PaginationStats = resolvePaginationStats(COUNT_MODE_LOCAL_LOADED, Number.NaN, 3);
      expect(notFinite.showCountNumber).assertFalse();
      expect(notFinite.countLabel).assertEqual(STAT_LABEL_UNKNOWN);
    });

    it('computesLocalPagesFromLoadedCountOnly', 0, () => {
      expect(computeLocalPages(42, 20)).assertEqual(3);
      expect(computeLocalPages(0, 20)).assertEqual(0);
      expect(computeLocalPages(1, 20)).assertEqual(1);
      expect(computeLocalPages(20, 20)).assertEqual(1);
      expect(computeLocalPages(-5, 20)).assertEqual(0);
      // 与既有 computeTotalPages 数值一致，但语义是本地页数
      expect(computeLocalPages(42, 20)).assertEqual(computeTotalPages(42, 20));
    });

    it('hidesPageStatButKeepsPageCountAtZero', 0, () => {
      const s: PaginationStats = resolvePaginationStats(COUNT_MODE_LOCAL_LOADED, 0, 0);
      expect(s.showCountNumber).assertTrue();
      expect(s.count).assertEqual(0);
      expect(s.showPages).assertFalse();
      expect(s.pagesLabel).assertEqual(STAT_LABEL_NONE);
      expect(s.pages).assertEqual(0);
    });

    it('keepsQuickJumpWorkingInBothKnownModes', 0, () => {
      for (let i = 0; i < 2; i++) {
        const mode: string = i === 0 ? COUNT_MODE_SERVER_TOTAL : COUNT_MODE_LOCAL_LOADED;
        const s: PaginationStats = resolvePaginationStats(mode, 42, 3);
        expect(s.showPages).assertTrue();
        expect(parseJumpPage('2', s.pages)).assertEqual(2);
        expect(parseJumpPage('', s.pages)).assertEqual(0);
        expect(parseJumpPage('4', s.pages)).assertEqual(0);
        expect(canChangePage(false, 1, s.pages, 2)).assertTrue();
        expect(canChangePage(true, 1, s.pages, 2)).assertFalse();
      }
    });

    it('keepsFirstAndLastPageBoundaries', 0, () => {
      const first = computePaginationWindow(1, 3, 5);
      expect(first.canPrev).assertFalse();
      expect(first.canNext).assertTrue();
      const last = computePaginationWindow(3, 3, 5);
      expect(last.canPrev).assertTrue();
      expect(last.canNext).assertFalse();
      expect(normalizePage(9, 3)).assertEqual(3);
      expect(normalizePage(0, 3)).assertEqual(1);
    });

    it('normalizesCountModesSafely', 0, () => {
      expect(normalizeCountMode(COUNT_MODE_SERVER_TOTAL)).assertEqual(COUNT_MODE_SERVER_TOTAL);
      expect(normalizeCountMode(COUNT_MODE_LOCAL_LOADED)).assertEqual(COUNT_MODE_LOCAL_LOADED);
      expect(normalizeCountMode('anything')).assertEqual(COUNT_MODE_UNKNOWN);
      expect(COUNT_MODE_VALUES.length).assertEqual(3);
    });
  });

  describe('Phase14N1_RankSemantics', () => {
    it('keepsReadDayAndProportionFieldMapping', 0, () => {
      expect(rankFeedField(RANK_TYPE_READING)).assertEqual('readDay');
      expect(rankFeedField(RANK_TYPE_HIGH_QUALITY)).assertEqual('proportion');
    });

    it('marksRankOrderUnverifiedAndRequiresNotice', 0, () => {
      expect(rankOrderStatus()).assertEqual(RANK_ORDER_STATUS_UNVERIFIED);
      expect(rankSemanticsNoticeRequired(RANK_TYPE_READING)).assertTrue();
      expect(rankSemanticsNoticeRequired(RANK_TYPE_HIGH_QUALITY)).assertTrue();
      expect(rankSemanticsNoticeRequired('unknown_type')).assertFalse();
    });

    it('doesNotPresentArrayIndexAsOfficialRankBadge', 0, () => {
      expect(officialRankBadgeVisible()).assertFalse();
      // 未验证时任何序号都不渲染排名 Badge（0 = ComicListItem 不显示）
      expect(displayRankNumber(1)).assertEqual(0);
      expect(displayRankNumber(3)).assertEqual(0);
      expect(displayRankNumber(21)).assertEqual(0);
      // 但底层列表序号仍保持分页连续性，供未来真实排名能力使用
      expect(rankNumber(1, 20, 0)).assertEqual(1);
      expect(rankNumber(2, 20, 0)).assertEqual(21);
    });

    it('usesLocalLoadedCountModeForHomeFeedData', 0, async () => {
      const port: FakeHomeFeedPort = new FakeHomeFeedPort();
      port.feed = makeFeed(42, 3);
      const vm: RankViewModel = new RankViewModel(port);
      await vm.load(true);
      expect(vm.countMode).assertEqual(COUNT_MODE_LOCAL_LOADED);
      expect(vm.totalCount).assertEqual(42);
      expect(vm.totalPages).assertEqual(3);
      const s: PaginationStats = resolvePaginationStats(vm.countMode, vm.totalCount, vm.totalPages);
      expect(s.countLabel).assertEqual(STAT_LABEL_LOADED);
      expect(s.pagesLabel).assertEqual(STAT_LABEL_LOCAL_PAGES);
      // 页面展示的数字是本次已获取条数，不能冒充服务端总量
      expect(s.count).assertEqual(vm.totalCount);
    });

    it('keepsWeekAndMonthDisabledWithoutNewRequests', 0, async () => {
      expect(isRankPeriodSupported(RANK_PERIOD_DAY)).assertTrue();
      expect(isRankPeriodSupported(RANK_PERIOD_WEEK)).assertFalse();
      expect(isRankPeriodSupported(RANK_PERIOD_MONTH)).assertFalse();
      const port: FakeHomeFeedPort = new FakeHomeFeedPort();
      port.feed = makeFeed(5, 2);
      const vm: RankViewModel = new RankViewModel(port);
      await vm.load(true);
      const before: number = port.calls;
      vm.setPeriod(RANK_PERIOD_WEEK);
      vm.setPeriod(RANK_PERIOD_MONTH);
      expect(port.calls).assertEqual(before);
      expect(vm.period).assertEqual(RANK_PERIOD_DAY);
      expect(vm.totalCount).assertEqual(5);
    });

    it('resetsToFirstPageOnRankTypeSwitch', 0, async () => {
      const port: FakeHomeFeedPort = new FakeHomeFeedPort();
      port.feed = makeFeed(42, 3);
      const vm: RankViewModel = new RankViewModel(port);
      await vm.load(true);
      vm.goToPage(2);
      expect(vm.currentPage).assertEqual(2);
      expect(vm.items[0].rank).assertEqual(21);
      vm.setRankType(RANK_TYPE_HIGH_QUALITY);
      await settle();
      expect(vm.currentPage).assertEqual(1);
      expect(vm.rankType).assertEqual(RANK_TYPE_HIGH_QUALITY);
      expect(vm.totalCount).assertEqual(3);
      expect(vm.totalPages).assertEqual(1);
    });

    it('keepsGenerationGuardAgainstStaleResponses', 0, async () => {
      const port: SequencedHomeFeedPort = new SequencedHomeFeedPort();
      port.feeds = [makeFeed(1, 0), makeFeed(2, 0)];
      port.delays = [10, 0];
      const vm: RankViewModel = new RankViewModel(port);
      const p1: Promise<void> = vm.load(true);
      const p2: Promise<void> = vm.load(true);
      await p1;
      await p2;
      expect(vm.totalCount).assertEqual(2);
      expect(vm.items.length).assertEqual(2);
    });

    it('keepsEmptyAndErrorStatesWithoutFakeCounts', 0, async () => {
      const emptyPort: FakeHomeFeedPort = new FakeHomeFeedPort();
      const vm: RankViewModel = new RankViewModel(emptyPort);
      await vm.load(true);
      expect(vm.totalCount).assertEqual(0);
      expect(vm.totalPages).assertEqual(0);
      expect(resolvePaginationStats(vm.countMode, vm.totalCount, vm.totalPages).showPages).assertFalse();

      const errorPort: FakeHomeFeedPort = new FakeHomeFeedPort();
      errorPort.fail = true;
      const errorVm: RankViewModel = new RankViewModel(errorPort);
      await errorVm.load(true);
      expect(errorVm.errorMessage).assertEqual('network');
      expect(errorVm.totalCount).assertEqual(0);
      expect(errorVm.isLoading).assertFalse();
    });
  });

  describe('Phase14N1_CategorySearchMapping', () => {
    it('hasTwelveUniqueDefinedMappings', 0, async () => {
      const vm: CategoryViewModel = await loadCatalog();
      expect(vm.items.length).assertEqual(12);
      expect(REFERENCE_KEYS.length).assertEqual(12);
      expect(REFERENCE_TAGS.length).assertEqual(12);
      expect(CATEGORY_DEFINITIONS.length).assertEqual(12);
      expect(categoryMappingsAreUniqueAndDefined(vm.items)).assertTrue();
    });

    it('verifiesEveryTraditionalKeywordAndTagMode', 0, async () => {
      const vm: CategoryViewModel = await loadCatalog();
      const rows: CategorySearchVerification[] = verifyAllCategorySearchParams(vm.items);
      expect(rows.length).assertEqual(12);
      for (let i = 0; i < rows.length; i++) {
        expect(rows[i].key).assertEqual(REFERENCE_KEYS[i]);
        expect(rows[i].keyword).assertEqual(REFERENCE_TAGS[i]);
        expect(rows[i].mode).assertEqual(SEARCH_MODE_TAG);
        expect(rows[i].paramValid).assertTrue();
        expect(rows[i].doubleEncoded).assertFalse();
        expect(rows[i].autoSearch).assertTrue();
      }
    });

    it('mapsNamesToSearchParamsWithoutDoubleEncoding', 0, () => {
      for (let i = 0; i < REFERENCE_TAGS.length; i++) {
        const param = buildCategorySearchParam(REFERENCE_TAGS[i]);
        expect(param.keyword).assertEqual(REFERENCE_TAGS[i]);
        expect(param.mode).assertEqual(SEARCH_MODE_TAG);
        expect(param.keyword.indexOf('%') < 0).assertTrue();
      }
      // 前后空白只 trim 一次，不做 URL 编码
      const padded = buildTagSearchParam('  百合  ');
      expect(padded.keyword).assertEqual('百合');
      expect(padded.mode).assertEqual(SEARCH_MODE_TAG);
    });

    it('keepsIndependentParamsWhenSwitchingCategories', 0, async () => {
      const vm: CategoryViewModel = await loadCatalog();
      const first = vm.searchParamFor(vm.items[0]);
      const second = vm.searchParamFor(vm.items[1]);
      expect(first.keyword).assertEqual('奇幻');
      expect(second.keyword).assertEqual('戀愛');
      first.keyword = 'changed';
      expect(second.keyword).assertEqual('戀愛');
      const again = vm.searchParamFor(vm.items[0]);
      expect(again.keyword).assertEqual('奇幻');
    });

    it('rejectsUnknownOrDuplicateCategoryMappings', 0, async () => {
      const vm: CategoryViewModel = await loadCatalog();
      const withUnknown: CategoryItem[] = vm.items.concat(
        [new CategoryItem('unknown_key', 'unknown', '未知')]);
      expect(categoryMappingsAreUniqueAndDefined(withUnknown)).assertFalse();
      const short: CategoryItem[] = vm.items.slice(0, 11);
      expect(categoryMappingsAreUniqueAndDefined(short)).assertFalse();
      const duplicated: CategoryItem[] = vm.items.slice();
      duplicated[1] = new CategoryItem('fantasy', 'dup', '奇幻');
      expect(categoryMappingsAreUniqueAndDefined(duplicated)).assertFalse();
      expect(categoryDefinitionByKey('missing') === null).assertTrue();
    });

    it('marksAllTwelveAsApiUnverifiedWithoutFakeResults', 0, async () => {
      const vm: CategoryViewModel = await loadCatalog();
      const rows: CategorySearchVerification[] = verifyAllCategorySearchParams(vm.items);
      for (let i = 0; i < rows.length; i++) {
        expect(rows[i].status).assertEqual(CATEGORY_STATUS_API_UNVERIFIED);
        expect(rows[i].status === CATEGORY_STATUS_VERIFIED).assertFalse();
        expect(rows[i].requestResult).assertEqual(CATEGORY_REQUEST_NOT_RUN);
        expect(rows[i].returnCount).assertEqual(CATEGORY_RETURN_COUNT_UNKNOWN);
      }
      expect(realVerifiedCategoryCount(rows)).assertEqual(0);
    });

    it('handlesMissingCategoryDataWithoutFakeMappings', 0, async () => {
      const vm: CategoryViewModel = await loadCatalog(new EmptyTagTextPort());
      expect(vm.items.length).assertEqual(12);
      const rows: CategorySearchVerification[] = verifyAllCategorySearchParams(vm.items);
      for (let i = 0; i < rows.length; i++) {
        expect(rows[i].keyword).assertEqual('');
        expect(rows[i].paramValid).assertFalse();
        expect(rows[i].autoSearch).assertFalse();
      }
      expect(categoryMappingsAreUniqueAndDefined(vm.items)).assertFalse();
      const single: CategorySearchVerification = verifyCategorySearchParam(
        new CategoryItem('fantasy', '奇幻', '  '));
      expect(single.paramValid).assertFalse();
      expect(single.autoSearch).assertFalse();
    });

    it('keepsCatalogGenerationGuardOnRepeatedLoad', 0, async () => {
      const port: SequencedHomeFeedPort = new SequencedHomeFeedPort();
      port.feeds = [makeFeed(1, 0), makeFeed(2, 0)];
      port.delays = [10, 0];
      const vm: CategoryViewModel = new CategoryViewModel(port, new ReferenceCategoryTextPort());
      const p1: Promise<void> = vm.load();
      const p2: Promise<void> = vm.load();
      await p1;
      await p2;
      expect(vm.items.length).assertEqual(12);
      expect(vm.errorMessage).assertEqual('');
      expect(categoryMappingsAreUniqueAndDefined(vm.items)).assertTrue();
    });

    it('reportsLoadErrorWithoutFakeItems', 0, async () => {
      const port: FakeHomeFeedPort = new FakeHomeFeedPort();
      port.fail = true;
      const vm: CategoryViewModel = new CategoryViewModel(port, new ReferenceCategoryTextPort());
      await vm.load();
      expect(vm.errorMessage).assertEqual('network');
      expect(vm.items.length).assertEqual(0);
      expect(verifyAllCategorySearchParams(vm.items).length).assertEqual(0);
      expect(realVerifiedCategoryCount([])).assertEqual(0);
    });
  });

  describe('Phase14N1_Regression', () => {
    it('keepsPhase14NPaginationAndTagSearchBehavior', 0, () => {
      expect(computeTotalPages(42, 20)).assertEqual(3);
      expect(computeTotalPages(0, 20)).assertEqual(0);
      expect(parseJumpPage('2', 3)).assertEqual(2);
      expect(canChangePage(false, 1, 3, 2)).assertTrue();
      const param = buildTagSearchParam('百合');
      expect(param.keyword).assertEqual('百合');
      expect(param.mode).assertEqual(SEARCH_MODE_TAG);
      const fallback = buildTagSearchParam('奇幻');
      expect(fallback.mode).assertEqual(SEARCH_MODE_TAG);
      expect(SEARCH_MODE_DEFAULT).assertEqual('default');
    });

    it('keepsDiscoveryRoutesAndRankNumberContinuity', 0, () => {
      expect(DISCOVERY_ROUTES.length).assertEqual(3);
      expect(rankNumber(3, 20, 4)).assertEqual(45);
      expect(rankNumber(0, 20, 0)).assertEqual(0);
      expect(isRankPeriodSupported(RANK_PERIOD_DAY)).assertTrue();
    });

    it('keepsLocalModeNumbersHonestUnderLargeSample', 0, () => {
      // 固定样例：一次 /api/home 返回 42 条，本地每页 20 条 → 3 页
      const loaded: number = 42;
      const pages: number = computeLocalPages(loaded, 20);
      const s: PaginationStats = resolvePaginationStats(COUNT_MODE_LOCAL_LOADED, loaded, pages);
      expect(s.count).assertEqual(42);
      expect(s.pages).assertEqual(3);
      expect(s.countLabel).assertEqual(STAT_LABEL_LOADED);
      expect(s.pagesLabel).assertEqual(STAT_LABEL_LOCAL_PAGES);
      expect(normalizePage(3, s.pages)).assertEqual(3);
      expect(computePaginationWindow(3, s.pages, 5).canNext).assertFalse();
    });
  });
}
