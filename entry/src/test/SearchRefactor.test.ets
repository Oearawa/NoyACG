import { describe, expect, it } from '@ohos/hypium';
import { Comic } from '../main/ets/model/Comic';
import { AdItem } from '../main/ets/model/AdItem';
import { CommentPage } from '../main/ets/model/BookComment';
import { ComicDetail } from '../main/ets/model/ComicDetail';
import { HomeFeed } from '../main/ets/model/HomeFeed';
import { PageInfo } from '../main/ets/model/PageInfo';
import { HttpError } from '../main/ets/api/HttpManager';
import { IComicSource } from '../main/ets/source/IComicSource';
import { SEARCH_SORT_RATING, SEARCH_TYPE_BOOK } from '../main/ets/source/NoyAcgSource';
import {
  DEFAULT_HOT_SEARCH_TAGS,
  formatSearchResultSummary,
  hasActiveSearchFilters,
  isSearchInlineHeader,
  mergeHotSearchTags,
  searchResultBottomInsetVp,
  shouldShowInlineSearchFilters,
  shouldShowStackedSearchFilters
} from '../main/ets/utils/SearchLayoutHelper';
import { paginationFloatingInsetVp } from '../main/ets/utils/Pagination';
import { SearchViewModel } from '../main/ets/viewmodel/SearchViewModel';

class StubSearchSource implements IComicSource {
  readonly sourceId: string = 'stub';
  readonly sourceName: string = 'Stub';
  readonly baseUrl: string = 'https://stub.local';

  async getHomeList(page: number, _sort?: string, _finished?: string): Promise<PageInfo<Comic>> {
    return new PageInfo<Comic>(page, 1, [], false);
  }

  async getComicDetail(_id: string): Promise<ComicDetail> {
    throw new HttpError(-1, 'stub');
  }

  async getChapterImages(_bookId: string, _chapterId: string): Promise<string[]> {
    return [];
  }

  async getHomeFeed(_adultLevel?: string): Promise<HomeFeed> {
    return new HomeFeed();
  }

  async getAds(_adultLevel?: string): Promise<AdItem[]> {
    return [];
  }

  async getBookComments(_bookId: string, page: number): Promise<CommentPage> {
    return new CommentPage([], page, true);
  }

  async search(keyword: string, page: number, _mode?: string,
    _sort?: string, _type?: string, _finished?: string): Promise<PageInfo<Comic>> {
    const c = new Comic();
    c.id = `${keyword}_${page}`;
    c.title = `${keyword} 第${page}页`;
    return new PageInfo<Comic>(page, 3, [c], page < 3, 45);
  }
}

export default function searchRefactorTest(): void {
  describe('SearchRefactorTest', () => {
    it('landscapeShowsInlineFiltersAndPortraitShowsStackedFilters', 0, () => {
      // 横屏 844x390 / 1080x720：启用单行内联顶栏 + 右侧紧凑筛选胶囊
      expect(isSearchInlineHeader(844, 390)).assertTrue();
      expect(isSearchInlineHeader(1080, 720)).assertTrue();
      expect(shouldShowInlineSearchFilters(844, 390, true)).assertTrue();
      expect(shouldShowStackedSearchFilters(844, 390, true)).assertFalse();
      expect(shouldShowInlineSearchFilters(844, 390, false)).assertFalse();

      // 竖屏 390x844：独立搜索行 + 下方筛选胶囊栏
      expect(isSearchInlineHeader(390, 844)).assertFalse();
      expect(shouldShowInlineSearchFilters(390, 844, true)).assertFalse();
      expect(shouldShowStackedSearchFilters(390, 844, true)).assertTrue();
    });

    it('mergesHotTagsWithoutDuplicatesAndBuildsSummaries', 0, () => {
      const merged: string[] = mergeHotSearchTags(['  百合 ', '', '新标签', '奇幻'], DEFAULT_HOT_SEARCH_TAGS, 10);
      expect(merged.length).assertEqual(10);
      expect(merged[0]).assertEqual('百合');
      expect(merged[1]).assertEqual('新标签');
      expect(merged[2]).assertEqual('奇幻');

      expect(hasActiveSearchFilters('', '', '')).assertFalse();
      expect(hasActiveSearchFilters(SEARCH_SORT_RATING, '', '')).assertTrue();
      expect(formatSearchResultSummary(45, 20, '默认排序', '全部类型', '全部进度', false))
        .assertEqual('共 45 部相关作品');
      expect(formatSearchResultSummary(45, 20, '最高评分', '漫画', '全部进度', true))
        .assertEqual('共 45 部相关作品 · 最高评分 / 漫画 / 全部进度');

      expect(searchResultBottomInsetVp(1, 24)).assertEqual(paginationFloatingInsetVp(false, 24));
      expect(searchResultBottomInsetVp(3, 24)).assertEqual(paginationFloatingInsetVp(true, 24));
    });

    it('clearKeywordAndGoToPageAndResetFiltersUpdateVmState', 0, async () => {
      const vm = new SearchViewModel(new StubSearchSource());
      vm.activate();
      vm.keyword = '百合';
      vm.submit();
      await new Promise<void>((resolve: () => void): void => {
        setTimeout((): void => resolve(), 20);
      });

      expect(vm.hasSearched).assertTrue();
      expect(vm.currentPage).assertEqual(1);
      expect(vm.totalPages).assertEqual(3);
      expect(vm.totalCount).assertEqual(45);

      vm.goToPage(2);
      await new Promise<void>((resolve: () => void): void => {
        setTimeout((): void => resolve(), 20);
      });
      expect(vm.currentPage).assertEqual(2);

      vm.onFilterChanged('type', SEARCH_TYPE_BOOK);
      await new Promise<void>((resolve: () => void): void => {
        setTimeout((): void => resolve(), 20);
      });
      expect(vm.type).assertEqual(SEARCH_TYPE_BOOK);
      expect(vm.currentPage).assertEqual(1);

      vm.resetFilters();
      await new Promise<void>((resolve: () => void): void => {
        setTimeout((): void => resolve(), 20);
      });
      expect(vm.type).assertEqual('');

      vm.clearKeyword();
      expect(vm.keyword).assertEqual('');
      expect(vm.hasSearched).assertFalse();
      expect(vm.totalPages).assertEqual(0);
    });
  });
}
