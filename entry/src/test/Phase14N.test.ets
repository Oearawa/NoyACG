/**
 * Phase14N.test.ets —— 内容发现功能回归（Phase 14-N）
 *
 * 覆盖：数字分页纯逻辑、RankViewModel 真实聚合数组本地分页与代际守卫、
 * CategoryViewModel 视觉参考目录/真实漫画代表封面/标签搜索参数、
 * PersonalizedViewModel 的 API_UNVERIFIED 能力边界，以及原功能回归。
 */
import { describe, it, expect } from '@ohos/hypium';
import { Comic } from '../main/ets/model/Comic';
import { HomeFeed } from '../main/ets/model/HomeFeed';
import {
  SectionListParam,
  SEARCH_MODE_TAG,
  buildTagSearchParam
} from '../main/ets/model/NavParams';
import {
  DISCOVERY_ROUTES,
  ROUTE_RANK,
  ROUTE_CATEGORY,
  ROUTE_PERSONALIZED
} from '../main/ets/model/DiscoveryRoutes';
import {
  RANK_TYPE_READING,
  RANK_TYPE_HIGH_QUALITY,
  RANK_PERIOD_DAY,
  RANK_PERIOD_WEEK,
  RANK_PERIOD_MONTH,
  CATEGORY_DEFINITIONS,
  CategoryDefinition,
  CategoryItem,
  PERSONALIZED_STATUS_API_UNVERIFIED,
  isRankPeriodSupported,
  rankFeedField,
  localPage,
  rankNumber,
  categoryDefinitionByKey,
  categoryCoverFor,
  buildCategorySearchParam,
  personalizedCanLoad
} from '../main/ets/model/DiscoveryModels';
import {
  computeTotalPages,
  normalizePage,
  computePaginationWindow,
  computeCompactBarWindow,
  parseJumpPage,
  canChangePage,
  paginationButtonCount
} from '../main/ets/utils/Pagination';
import { HomeFeedPort } from '../main/ets/api/DiscoveryRepository';
import { RankViewModel } from '../main/ets/viewmodel/RankViewModel';
import {
  CategoryViewModel,
  CategoryTextPort
} from '../main/ets/viewmodel/CategoryViewModel';
import { PersonalizedViewModel } from '../main/ets/viewmodel/PersonalizedViewModel';

class FakeHomeFeedPort implements HomeFeedPort {
  feed: HomeFeed = new HomeFeed();
  delayMs: number = 0;
  fail: boolean = false;
  calls: number = 0;

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

class FakeCategoryTextPort implements CategoryTextPort {
  getName(def: CategoryDefinition): string {
    return `${def.key}_name`;
  }

  getTag(def: CategoryDefinition): string {
    return def.key;
  }
}

function makeComic(id: string, categories: string = '', cover: string = ''): Comic {
  return new Comic(id, `title_${id}`, cover, '', categories);
}

function makeComics(count: number, prefix: string, categories: string = ''): Comic[] {
  const result: Comic[] = [];
  for (let i = 0; i < count; i++) {
    result.push(makeComic(`${prefix}_${i}`, categories, `cover_${prefix}_${i}`));
  }
  return result;
}

function makeFeed(readCount: number, highQualityCount: number, categories: string = ''): HomeFeed {
  const feed: HomeFeed = new HomeFeed();
  feed.readDay = makeComics(readCount, 'r', categories);
  feed.proportion = makeComics(highQualityCount, 'p', categories);
  return feed;
}

async function settle(): Promise<void> {
  await new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, 0);
  });
}

export default function phase14nTest() {
  describe('Phase14N_PaginationLogic', () => {
    it('computesTotalPagesFromRealCount', 0, () => {
      expect(computeTotalPages(42, 20)).assertEqual(3);
      expect(computeTotalPages(45889, 20)).assertEqual(2295);
    });

    it('returnsZeroPagesForUnknownOrEmptyCounts', 0, () => {
      expect(computeTotalPages(0, 20)).assertEqual(0);
      expect(computeTotalPages(-1, 20)).assertEqual(0);
      expect(computeTotalPages(10, 0)).assertEqual(0);
    });

    it('normalizesPageIntoLegalRange', 0, () => {
      expect(normalizePage(0, 3)).assertEqual(1);
      expect(normalizePage(9, 3)).assertEqual(3);
      expect(normalizePage(2.7, 3)).assertEqual(2);
      expect(normalizePage(1, 0)).assertEqual(1);
    });

    it('showsAllPagesWhenTotalIsSmall', 0, () => {
      const win = computePaginationWindow(1, 3, 5);
      expect(win.pages.length).assertEqual(3);
      expect(win.pages[0]).assertEqual(1);
      expect(win.pages[2]).assertEqual(3);
      expect(win.canPrev).assertFalse();
      expect(win.canNext).assertTrue();
      expect(win.showFirst).assertFalse();
      expect(win.showLast).assertFalse();
    });

    it('disablesNextOnLastPage', 0, () => {
      const win = computePaginationWindow(3, 3, 5);
      expect(win.canPrev).assertTrue();
      expect(win.canNext).assertFalse();
    });

    it('usesDynamicWindowForLargeTotalPages', 0, () => {
      const win = computePaginationWindow(10, 20, 5);
      expect(win.showFirst).assertTrue();
      expect(win.showLast).assertTrue();
      expect(win.pages.indexOf(10) >= 0).assertTrue();
      expect(win.pages.length).assertEqual(5);
    });

    it('handlesFirstAndLastLargePageWindows', 0, () => {
      const first = computePaginationWindow(1, 20, 5);
      expect(first.canPrev).assertFalse();
      expect(first.showFirst).assertFalse();
      expect(first.showLast).assertTrue();
      const last = computePaginationWindow(20, 20, 5);
      expect(last.canNext).assertFalse();
      expect(last.showLast).assertFalse();
    });

    it('returnsEmptyWindowWhenNoPages', 0, () => {
      const win = computePaginationWindow(1, 0, 5);
      expect(win.pages.length).assertEqual(0);
      expect(win.canPrev).assertFalse();
      expect(win.canNext).assertFalse();
    });

    it('computeCompactBarWindowCoversStartMidEnd', 0, () => {
      const first = computeCompactBarWindow(1, 897);
      expect(first.pages.join(',')).assertEqual('1,2,3');
      expect(first.showFirst).assertFalse();
      expect(first.showEndEllipsis).assertTrue();
      expect(first.showLast).assertTrue();

      const midLarge = computeCompactBarWindow(6, 2306);
      expect(midLarge.pages.join(',')).assertEqual('6');
      expect(midLarge.showFirst).assertTrue();
      expect(midLarge.showStartEllipsis).assertTrue();
      expect(midLarge.showEndEllipsis).assertTrue();
      expect(midLarge.showLast).assertTrue();

      const lastLarge = computeCompactBarWindow(2306, 2306);
      expect(lastLarge.pages.join(',')).assertEqual('2304,2305,2306');
      expect(lastLarge.showFirst).assertTrue();
      expect(lastLarge.showStartEllipsis).assertTrue();
      expect(lastLarge.showLast).assertFalse();

      const midMedium = computeCompactBarWindow(6, 50);
      expect(midMedium.pages.join(',')).assertEqual('5,6,7');
      expect(midMedium.showFirst).assertTrue();
      expect(midMedium.showLast).assertTrue();
    });

    it('parsesOnlyPositiveIntegerJumpWithinRange', 0, () => {
      expect(parseJumpPage('2', 3)).assertEqual(2);
      expect(parseJumpPage(' 3 ', 3)).assertEqual(3);
      expect(parseJumpPage('', 3)).assertEqual(0);
      expect(parseJumpPage('0', 3)).assertEqual(0);
      expect(parseJumpPage('abc', 3)).assertEqual(0);
      expect(parseJumpPage('1.5', 3)).assertEqual(0);
      expect(parseJumpPage('4', 3)).assertEqual(0);
    });

    it('preventsDuplicateLoadingAndOutOfRangePageChanges', 0, () => {
      expect(canChangePage(true, 1, 3, 2)).assertFalse();
      expect(canChangePage(false, 1, 3, 1)).assertFalse();
      expect(canChangePage(false, 1, 3, 4)).assertFalse();
      expect(canChangePage(false, 1, 3, 2)).assertTrue();
    });

    it('adaptsButtonCountToScreenWidth', 0, () => {
      expect(paginationButtonCount(360)).assertEqual(5);
      expect(paginationButtonCount(720)).assertEqual(7);
      expect(paginationButtonCount(0)).assertEqual(5);
    });
  });

  describe('Phase14N_RankContract', () => {
    it('mapsRankTypesToRealHomeFeedFields', 0, () => {
      expect(rankFeedField(RANK_TYPE_READING)).assertEqual('readDay');
      expect(rankFeedField(RANK_TYPE_HIGH_QUALITY)).assertEqual('proportion');
      expect(rankFeedField('unknown')).assertEqual('readDay');
    });

    it('supportsOnlyVerifiedDayPeriod', 0, () => {
      expect(isRankPeriodSupported(RANK_PERIOD_DAY)).assertTrue();
      expect(isRankPeriodSupported(RANK_PERIOD_WEEK)).assertFalse();
      expect(isRankPeriodSupported(RANK_PERIOD_MONTH)).assertFalse();
    });

    it('localPageKeepsBoundaryAndRankNumberContinuity', 0, () => {
      const items: number[] = [1, 2, 3, 4, 5];
      const page: number[] = localPage(items, 2, 2);
      expect(page.length).assertEqual(2);
      expect(page[0]).assertEqual(3);
      expect(page[1]).assertEqual(4);
      expect(rankNumber(1, 20, 0)).assertEqual(1);
      expect(rankNumber(2, 20, 0)).assertEqual(21);
      expect(rankNumber(0, 20, 0)).assertEqual(0);
    });

    it('loadsReadingRankWithRealTotalAndLocalPagination', 0, async () => {
      const port: FakeHomeFeedPort = new FakeHomeFeedPort();
      port.feed = makeFeed(25, 3);
      const vm: RankViewModel = new RankViewModel(port);
      await vm.load(true);
      expect(vm.totalCount).assertEqual(25);
      expect(vm.totalPages).assertEqual(2);
      expect(vm.items.length).assertEqual(vm.pageSize);
      expect(vm.items[0].rank).assertEqual(1);
      vm.goToPage(2);
      expect(vm.currentPage).assertEqual(2);
      expect(vm.items.length).assertEqual(5);
      expect(vm.items[0].rank).assertEqual(vm.pageSize + 1);
    });

    it('loadsHighQualityRankFromProportion', 0, async () => {
      const port: FakeHomeFeedPort = new FakeHomeFeedPort();
      port.feed = makeFeed(25, 3);
      const vm: RankViewModel = new RankViewModel(port);
      vm.setRankType(RANK_TYPE_HIGH_QUALITY);
      await settle();
      expect(vm.rankType).assertEqual(RANK_TYPE_HIGH_QUALITY);
      expect(vm.totalCount).assertEqual(3);
      expect(vm.totalPages).assertEqual(1);
      expect(vm.items.length).assertEqual(3);
    });

    it('resetsToFirstPageOnRankTypeSwitch', 0, async () => {
      const port: FakeHomeFeedPort = new FakeHomeFeedPort();
      port.feed = makeFeed(25, 3);
      const vm: RankViewModel = new RankViewModel(port);
      await vm.load(true);
      vm.goToPage(2);
      expect(vm.currentPage).assertEqual(2);
      vm.setRankType(RANK_TYPE_HIGH_QUALITY);
      await settle();
      expect(vm.currentPage).assertEqual(1);
      expect(vm.totalCount).assertEqual(3);
    });

    it('ignoresUnsupportedPeriodWithoutNewRequest', 0, async () => {
      const port: FakeHomeFeedPort = new FakeHomeFeedPort();
      port.feed = makeFeed(5, 2);
      const vm: RankViewModel = new RankViewModel(port);
      await vm.load(true);
      const before: number = port.calls;
      vm.setPeriod(RANK_PERIOD_WEEK);
      expect(vm.period).assertEqual(RANK_PERIOD_DAY);
      expect(port.calls).assertEqual(before);
    });

    it('preservesOptionalMissingFields', 0, async () => {
      const port: FakeHomeFeedPort = new FakeHomeFeedPort();
      const comic: Comic = new Comic('c1', 'title', '', '', '');
      port.feed.readDay = [comic];
      const vm: RankViewModel = new RankViewModel(port);
      await vm.load(true);
      expect(vm.items.length).assertEqual(1);
      expect(vm.items[0].comic.author).assertEqual('');
      expect(vm.items[0].comic.ratingSum).assertEqual(0);
      expect(vm.items[0].comic.views).assertEqual(0);
      expect(vm.items[0].comic.isCompleted === null).assertTrue();
    });

    it('handlesEmptyRankAndNetworkError', 0, async () => {
      const emptyPort: FakeHomeFeedPort = new FakeHomeFeedPort();
      const emptyVm: RankViewModel = new RankViewModel(emptyPort);
      await emptyVm.load(true);
      expect(emptyVm.totalCount).assertEqual(0);
      expect(emptyVm.totalPages).assertEqual(0);
      expect(emptyVm.items.length).assertEqual(0);

      const errorPort: FakeHomeFeedPort = new FakeHomeFeedPort();
      errorPort.fail = true;
      const errorVm: RankViewModel = new RankViewModel(errorPort);
      await errorVm.load(true);
      expect(errorVm.errorMessage).assertEqual('network');
      expect(errorVm.needsLogin).assertFalse();
      expect(errorVm.isLoading).assertFalse();
    });

    it('dropsStaleResponsesWithGenerationGuard', 0, async () => {
      const first: HomeFeed = makeFeed(1, 0);
      const second: HomeFeed = makeFeed(2, 0);
      const port: SequencedHomeFeedPort = new SequencedHomeFeedPort();
      port.feeds = [first, second];
      port.delays = [10, 0];
      const vm: RankViewModel = new RankViewModel(port);
      const p1: Promise<void> = vm.load(true);
      const p2: Promise<void> = vm.load(true);
      await p1;
      await p2;
      expect(vm.totalCount).assertEqual(2);
      expect(vm.items.length).assertEqual(2);
    });
  });

  describe('Phase14N_CategoryContract', () => {
    it('usesTwelveVisualReferenceCategories', 0, () => {
      expect(CATEGORY_DEFINITIONS.length).assertEqual(12);
      const yuri: CategoryDefinition | null = categoryDefinitionByKey('yuri');
      expect(yuri !== null).assertTrue();
      expect(categoryDefinitionByKey('missing') === null).assertTrue();
    });

    it('matchesOnlyRealComicCategoriesForCover', 0, () => {
      const comics: Comic[] = [
        makeComic('c1', '奇幻 百合', 'cover_fantasy'),
        makeComic('c2', '校园', 'cover_school')
      ];
      expect(categoryCoverFor('奇幻', comics)).assertEqual('cover_fantasy');
      expect(categoryCoverFor('动作', comics)).assertEqual('');
      expect(categoryCoverFor('', comics)).assertEqual('');
    });

    it('buildsTagSearchParamForCategory', 0, () => {
      const param = buildCategorySearchParam('奇幻');
      expect(param.keyword).assertEqual('奇幻');
      expect(param.mode).assertEqual(SEARCH_MODE_TAG);
    });

    it('loadsCatalogWithRealRepresentativeCovers', 0, async () => {
      const port: FakeHomeFeedPort = new FakeHomeFeedPort();
      port.feed.readDay = [makeComic('c1', 'fantasy comedy', 'cover_fantasy')];
      const vm: CategoryViewModel = new CategoryViewModel(port, new FakeCategoryTextPort());
      await vm.load();
      expect(vm.items.length).assertEqual(12);
      expect(vm.items[0].name).assertEqual('fantasy_name');
      expect(vm.items[0].tag).assertEqual('fantasy');
      expect(vm.items[0].cover).assertEqual('cover_fantasy');
      expect(vm.items[0].hasCover).assertTrue();
      expect(vm.items[1].hasCover).assertFalse();
      const param = vm.searchParamFor(vm.items[0]);
      expect(param.keyword).assertEqual('fantasy');
      expect(param.mode).assertEqual(SEARCH_MODE_TAG);
    });

    it('keepsCatalogWhenFeedDataIsMissing', 0, async () => {
      const port: FakeHomeFeedPort = new FakeHomeFeedPort();
      const vm: CategoryViewModel = new CategoryViewModel(port, new FakeCategoryTextPort());
      await vm.load();
      expect(vm.items.length).assertEqual(12);
      expect(vm.items[0].hasCover).assertFalse();
    });

    it('reportsCategoryLoadErrorWithoutFakeItems', 0, async () => {
      const port: FakeHomeFeedPort = new FakeHomeFeedPort();
      port.fail = true;
      const vm: CategoryViewModel = new CategoryViewModel(port, new FakeCategoryTextPort());
      await vm.load();
      expect(vm.errorMessage).assertEqual('network');
      expect(vm.items.length).assertEqual(0);
      expect(vm.isLoading).assertFalse();
    });

    it('createsIndependentSearchParamsOnRepeatedClicks', 0, async () => {
      const port: FakeHomeFeedPort = new FakeHomeFeedPort();
      port.feed.readDay = [makeComic('c1', 'fantasy', 'cover_fantasy')];
      const vm: CategoryViewModel = new CategoryViewModel(port, new FakeCategoryTextPort());
      await vm.load();
      const item: CategoryItem = vm.items[0];
      const p1 = vm.searchParamFor(item);
      const p2 = vm.searchParamFor(item);
      p1.keyword = 'changed';
      expect(p2.keyword).assertEqual('fantasy');
      expect(p2.mode).assertEqual(SEARCH_MODE_TAG);
      expect(item.tag).assertEqual('fantasy');
    });
  });

  describe('Phase14N_PersonalizedBoundary', () => {
    it('marksPersonalizedApiUnverified', 0, () => {
      const vm: PersonalizedViewModel = new PersonalizedViewModel();
      expect(vm.status).assertEqual(PERSONALIZED_STATUS_API_UNVERIFIED);
      expect(personalizedCanLoad()).assertFalse();
      expect(vm.canLoad()).assertFalse();
    });

    it('doesNotCreateFakeRecommendationsOrPagination', 0, () => {
      const vm: PersonalizedViewModel = new PersonalizedViewModel();
      vm.load();
      expect(vm.items.length).assertEqual(0);
      expect(vm.isLoading).assertFalse();
      expect(vm.errorMessage).assertEqual('');
      vm.retry();
      expect(vm.items.length).assertEqual(0);
      expect(vm.status).assertEqual(PERSONALIZED_STATUS_API_UNVERIFIED);
    });
  });

  describe('Phase14N_Regression', () => {
    it('keepsExistingTagSearchBehavior', 0, () => {
      const param = buildTagSearchParam('百合');
      expect(param.keyword).assertEqual('百合');
      expect(param.mode).assertEqual(SEARCH_MODE_TAG);
    });

    it('keepsSectionListServerOrder', 0, () => {
      const comics: Comic[] = [makeComic('a'), makeComic('b'), makeComic('c')];
      const param: SectionListParam = new SectionListParam('title', comics);
      expect(param.comics.length).assertEqual(3);
      expect(param.comics[1].id).assertEqual('b');
    });

    it('registersThreeDiscoveryRoutesWithoutChangingTabs', 0, () => {
      expect(DISCOVERY_ROUTES.length).assertEqual(3);
      expect(DISCOVERY_ROUTES.indexOf(ROUTE_RANK) >= 0).assertTrue();
      expect(DISCOVERY_ROUTES.indexOf(ROUTE_CATEGORY) >= 0).assertTrue();
      expect(DISCOVERY_ROUTES.indexOf(ROUTE_PERSONALIZED) >= 0).assertTrue();
    });
  });
}
