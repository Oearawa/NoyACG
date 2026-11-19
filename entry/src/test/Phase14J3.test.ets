/**
 * Phase14J3.test.ets —— Phase 14-J3 首页交互修复回归测试
 *
 * 覆盖三件事：
 * 1. 路由参数与搜索范围归一化（首页关键词 → SearchPage mode='tag'，关键词不按空格拆分）；
 * 2. SearchViewModel 带参自动搜索 / 搜索范围透传到 source / 改写关键词回退 default；
 * 3. HomeViewModel 首页加载**不再请求广告接口**（/api/v3/ads 保留在 source 层但首页不调用）。
 *
 * 全部断言直接作用于真实实现代码（协议/VM），Stub 仅用于替换网络传输层。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { Comic } from '../main/ets/model/Comic';
import { PageInfo } from '../main/ets/model/PageInfo';
import { ComicDetail } from '../main/ets/model/ComicDetail';
import { HomeFeed } from '../main/ets/model/HomeFeed';
import { AdItem } from '../main/ets/model/AdItem';
import { CommentPage } from '../main/ets/model/BookComment';
import {
  SEARCH_MODE_DEFAULT,
  SEARCH_MODE_TAG,
  SEARCH_MODE_AUTHOR,
  SearchParam,
  SectionListParam,
  buildTagSearchParam,
  normalizeSearchMode
} from '../main/ets/model/NavParams';
import { IComicSource } from '../main/ets/source/IComicSource';
import { SearchViewModel } from '../main/ets/viewmodel/SearchViewModel';
import { HomeViewModel } from '../main/ets/viewmodel/HomeViewModel';
import { HttpError } from '../main/ets/api/HttpManager';

/** 搜索调用记录 */
class SearchCall {
  keyword: string = '';
  page: number = 0;
  mode: string = '';

  constructor(keyword: string, page: number, mode: string) {
    this.keyword = keyword;
    this.page = page;
    this.mode = mode;
  }
}

/** IComicSource 桩：记录搜索调用参数；首页聚合返回固定空 feed；统计广告接口被调用次数 */
class RecordingSource implements IComicSource {
  readonly sourceId: string = 'stub-j3';
  readonly sourceName: string = 'StubJ3';
  readonly baseUrl: string = 'https://stub.local';

  searchCalls: SearchCall[] = [];
  adsCalls: number = 0;
  homeCalls: number = 0;
  resultList: Comic[] = [];
  failSearchWith: string = '';

  async search(keyword: string, page: number, mode?: string): Promise<PageInfo<Comic>> {
    this.searchCalls.push(new SearchCall(keyword, page, mode === undefined ? '' : mode));
    if (this.failSearchWith !== '') {
      throw new HttpError(-1, this.failSearchWith);
    }
    return new PageInfo<Comic>(page, -1, this.resultList, false);
  }

  async getHomeList(page: number, sort?: string, finished?: string): Promise<PageInfo<Comic>> {
    return new PageInfo<Comic>(page, -1, [], false);
  }

  async getComicDetail(id: string): Promise<ComicDetail> {
    throw new HttpError(-1, 'stub 不支持详情');
  }

  async getChapterImages(bookId: string, chapterId: string): Promise<string[]> {
    return [];
  }

  async getHomeFeed(adultLevel?: string): Promise<HomeFeed> {
    this.homeCalls++;
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

/** 让出事件循环，等待 VM 内部 await 链完成 */
function nextTick(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, 0);
  });
}

function comicOf(id: string, title: string): Comic {
  return new Comic(id, title, 'https://img.noymanga.com/c.webp', '作者', '标签');
}

export default function phase14j3Test() {
  describe('Phase14J3_NavParams', () => {
    it('searchParamDefaultsToDefaultMode', 0, () => {
      const p: SearchParam = new SearchParam();
      expect(p.keyword).assertEqual('');
      expect(p.mode).assertEqual(SEARCH_MODE_DEFAULT);
    });

    it('tagSearchParamKeepsWholeKeyword', 0, () => {
      // 复合中文标签带空格：必须整体保留，不能被拆成两个搜索词
      const p: SearchParam = buildTagSearchParam('  科幻 冒险  ');
      expect(p.keyword).assertEqual('科幻 冒险');
      expect(p.mode).assertEqual(SEARCH_MODE_TAG);
    });

    it('tagSearchParamPreservesChineseWithoutSplit', 0, () => {
      const p: SearchParam = buildTagSearchParam('校園戀愛喜劇');
      expect(p.keyword).assertEqual('校園戀愛喜劇');
      expect(p.mode).assertEqual('tag');
    });

    it('normalizeSearchModeFallsBackToDefault', 0, () => {
      expect(normalizeSearchMode('')).assertEqual(SEARCH_MODE_DEFAULT);
      expect(normalizeSearchMode('nsfw')).assertEqual(SEARCH_MODE_DEFAULT);
      expect(normalizeSearchMode('TAG')).assertEqual(SEARCH_MODE_DEFAULT); // 大小写敏感，脏值一律回退
      expect(normalizeSearchMode(SEARCH_MODE_TAG)).assertEqual(SEARCH_MODE_TAG);
      expect(normalizeSearchMode(SEARCH_MODE_AUTHOR)).assertEqual(SEARCH_MODE_AUTHOR);
      expect(normalizeSearchMode(SEARCH_MODE_DEFAULT)).assertEqual(SEARCH_MODE_DEFAULT);
    });

    it('sectionParamKeepsServerOrder', 0, () => {
      const list: Comic[] = [comicOf('3', 'C'), comicOf('1', 'A'), comicOf('2', 'B')];
      const param: SectionListParam = new SectionListParam('今日阅读榜', list);
      expect(param.title).assertEqual('今日阅读榜');
      expect(param.comics.length).assertEqual(3);
      // 顺序必须与服务端一致（不重排、不去重）
      expect(param.comics[0].id).assertEqual('3');
      expect(param.comics[1].id).assertEqual('1');
      expect(param.comics[2].id).assertEqual('2');
    });
  });

  describe('Phase14J3_SearchMode', () => {
    let source: RecordingSource = new RecordingSource();
    let vm: SearchViewModel = new SearchViewModel(source);

    beforeEach(() => {
      source = new RecordingSource();
      vm = new SearchViewModel(source);
    });

    it('applyInitialQuerySendsTagMode', 0, async () => {
      vm.applyInitialQuery('科幻 冒险', SEARCH_MODE_TAG);
      await nextTick();
      await nextTick();
      expect(vm.keyword).assertEqual('科幻 冒险');
      expect(source.searchCalls.length).assertEqual(1);
      expect(source.searchCalls[0].keyword).assertEqual('科幻 冒险');
      expect(source.searchCalls[0].page).assertEqual(1);
      expect(source.searchCalls[0].mode).assertEqual(SEARCH_MODE_TAG);
      expect(vm.hasSearched).assertTrue();
    });

    it('applyInitialQueryIgnoresEmptyKeyword', 0, async () => {
      vm.applyInitialQuery('   ', SEARCH_MODE_TAG);
      await nextTick();
      expect(source.searchCalls.length).assertEqual(0);
      expect(vm.hasSearched).assertFalse();
    });

    it('applyInitialQueryNormalizesIllegalMode', 0, async () => {
      vm.applyInitialQuery('標籤甲', 'whatever');
      await nextTick();
      await nextTick();
      expect(source.searchCalls[0].mode).assertEqual(SEARCH_MODE_DEFAULT);
    });

    it('manualSubmitUsesDefaultMode', 0, async () => {
      vm.keyword = '海賊';
      vm.submit();
      await nextTick();
      await nextTick();
      expect(source.searchCalls[0].mode).assertEqual(SEARCH_MODE_DEFAULT);
    });

    it('editingKeywordAfterTagQueryFallsBackToDefault', 0, async () => {
      vm.applyInitialQuery('標籤甲', SEARCH_MODE_TAG);
      await nextTick();
      await nextTick();
      expect(source.searchCalls.length).assertEqual(1);
      expect(source.searchCalls[0].mode).assertEqual(SEARCH_MODE_TAG);

      // 用户改写关键词 → 搜索范围回退 default（否则会把普通词当标签搜，结果恒空）
      vm.onKeywordInput('海賊王');
      expect(vm.mode).assertEqual(SEARCH_MODE_DEFAULT);
      vm.submit();
      await nextTick();
      await nextTick();
      expect(source.searchCalls.length).assertEqual(2);
      expect(source.searchCalls[1].keyword).assertEqual('海賊王');
      expect(source.searchCalls[1].mode).assertEqual(SEARCH_MODE_DEFAULT);
    });

    it('sameKeywordStillKeepsModeWhileUnchanged', 0, async () => {
      // onChange 用同一关键词回填（Search 组件初始化可能触发一次）：mode 不得被重置
      vm.applyInitialQuery('標籤甲', SEARCH_MODE_TAG);
      await nextTick();
      await nextTick();
      vm.onKeywordInput('標籤甲');
      expect(vm.mode).assertEqual(SEARCH_MODE_TAG);
    });
  });

  describe('Phase14J3_HomeNoAds', () => {
    let source: RecordingSource = new RecordingSource();
    let vm: HomeViewModel = new HomeViewModel(source);

    beforeEach(() => {
      source = new RecordingSource();
      vm = new HomeViewModel(source);
    });

    it('loadHomeDoesNotRequestAds', 0, async () => {
      await vm.loadHome();
      expect(source.homeCalls).assertEqual(1);
      // 首页不再展示广告 → 不得为隐藏广告发起无意义请求
      expect(source.adsCalls).assertEqual(0);
      expect(vm.homeFeed !== null).assertTrue();
      expect(vm.homeError).assertEqual('');
    });

    it('reloadForRatingDoesNotRequestAds', 0, async () => {
      await vm.loadHome();
      vm.reloadForRating();
      await nextTick();
      await nextTick();
      expect(source.adsCalls).assertEqual(0);
      expect(source.homeCalls).assertEqual(2);
    });
  });
}
