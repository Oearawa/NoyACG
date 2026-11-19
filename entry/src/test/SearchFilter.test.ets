/**
 * SearchFilter.test.ets —— I-000003 搜索筛选参数化 测试
 *
 * 覆盖（任务书要求：组合请求参数断言 / 非法值拒发 / 筛选变化刷新 / 分页正确）：
 * - 协议层：buildSearchForm 对 sort×type×finished 合法组合与 FALSY 归一化的请求参数断言；
 *   normalizeSearchFilter 对 '' / undefined / 合法值 / 非法值的归一与拒发判定；
 * - 源层：非法筛选值在发网之前抛 ProtocolError（不触达 HTTP）；
 * - ViewModel：筛选变化 → 立即重查第 1 页（currentPage 重置回 1）；同词 + 新筛选不短路；
 *   筛选变化后 loadMore 仍携带新筛选且页码连续；同值筛选变化不发请求。
 *
 * 契约依据：API_PROTOCOL_AUDIT.md §2.1 :52 —— sort∈{''/views/favorites/rating}、
 * type∈{''/book/stream}、finished∈{''/true/false}、mode∈{''/tag/author}（成功响应 ⛔ 待会话验证）。
 * 全部断言作用于真实实现代码（协议纯函数 / source 前置守卫 / VM 状态机），不联网、不触达真实服务端。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  NoyAcgSource,
  SEARCH_SORT_DEFAULT,
  SEARCH_SORT_VIEWS,
  SEARCH_SORT_FAVORITES,
  SEARCH_SORT_RATING,
  SEARCH_TYPE_DEFAULT,
  SEARCH_TYPE_BOOK,
  SEARCH_TYPE_STREAM,
  SEARCH_FINISHED_ALL,
  SEARCH_FINISHED_COMPLETED,
  SEARCH_FINISHED_ONGOING,
  buildSearchForm,
  normalizeSearchFilter
} from '../main/ets/source/NoyAcgSource';
import { IComicSource } from '../main/ets/source/IComicSource';
import { SearchViewModel } from '../main/ets/viewmodel/SearchViewModel';
import { Comic } from '../main/ets/model/Comic';
import { ComicDetail } from '../main/ets/model/ComicDetail';
import { HomeFeed } from '../main/ets/model/HomeFeed';
import { AdItem } from '../main/ets/model/AdItem';
import { CommentPage } from '../main/ets/model/BookComment';
import { PageInfo } from '../main/ets/model/PageInfo';
import { HttpError } from '../main/ets/api/HttpManager';
import { ProtocolError } from '../main/ets/api/ApiErrors';

/** 记录搜索调用（含全部筛选参数）的可编程源桩 */
class FilterStubSource implements IComicSource {
  readonly sourceId: string = 'stub-filter';
  readonly sourceName: string = 'StubFilter';
  readonly baseUrl: string = 'https://stub.local';
  /** 调用记录: 'keyword#page#mode#sort#type#finished' */
  calls: string[] = [];
  /** 每页返回条数（构造递增 id 漫画） */
  pageSize: number = 3;
  /** hasMore 开关 */
  hasMoreFlag: boolean = true;

  async search(keyword: string, page: number, mode?: string, sort?: string,
    type?: string, finished?: string): Promise<PageInfo<Comic>> {
    this.calls.push(`${keyword}#${page}#${mode ?? ''}#${sort ?? ''}#${type ?? ''}#${finished ?? ''}`);
    const list: Comic[] = [];
    for (let i = 0; i < this.pageSize; i++) {
      list.push(new Comic(`f${page}_${i}`, `筛选漫画${page}_${i}`, 'https://stub.local/c.webp', '', ''));
    }
    return new PageInfo<Comic>(page, 5, list, this.hasMoreFlag);
  }

  async getHomeList(page: number, sort?: string, finished?: string): Promise<PageInfo<Comic>> {
    return new PageInfo<Comic>(page, 0, [], false);
  }

  async getComicDetail(id: string): Promise<ComicDetail> {
    throw new HttpError(-1, '桩不支持详情');
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
    return new CommentPage([], page, true);
  }
}

/** 等待筛选触发的在途请求收敛（桩无延迟，微任务即可完成） */
function settle(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

export default function searchFilterTest() {
  describe('SearchFilter', () => {
    // ==================== 协议层：组合请求参数断言 ====================
    it('formDefaultFalsyCombination', 0, () => {
      const form: Record<string, string> | null =
        buildSearchForm('海贼王', 1, 'default', undefined, undefined, undefined);
      expect(form !== null).assertTrue();
      if (form !== null) {
        expect(form['value']).assertEqual('海贼王');
        expect(form['mode']).assertEqual('default');
        expect(form['sort']).assertEqual('');
        expect(form['type']).assertEqual('');
        expect(form['finished']).assertEqual('');
        expect(form['page']).assertEqual('1');
      }
    });

    it('formExplicitEmptyCombination', 0, () => {
      const form: Record<string, string> | null = buildSearchForm('海贼王', 2, 'default', '', '', '');
      expect(form !== null).assertTrue();
      if (form !== null) {
        expect(form['sort']).assertEqual('');
        expect(form['type']).assertEqual('');
        expect(form['finished']).assertEqual('');
        expect(form['page']).assertEqual('2');
      }
    });

    it('formCombinationViewsBookCompleted', 0, () => {
      const form: Record<string, string> | null = buildSearchForm('海贼王', 1, 'tag',
        SEARCH_SORT_VIEWS, SEARCH_TYPE_BOOK, SEARCH_FINISHED_COMPLETED);
      expect(form !== null).assertTrue();
      if (form !== null) {
        expect(form['sort']).assertEqual('views');
        expect(form['type']).assertEqual('book');
        expect(form['finished']).assertEqual('true');
        expect(form['mode']).assertEqual('tag');
        expect(form['page']).assertEqual('1');
      }
    });

    it('formCombinationFavoritesStreamOngoing', 0, () => {
      const form: Record<string, string> | null = buildSearchForm('海贼王', 3, 'author',
        SEARCH_SORT_FAVORITES, SEARCH_TYPE_STREAM, SEARCH_FINISHED_ONGOING);
      expect(form !== null).assertTrue();
      if (form !== null) {
        expect(form['sort']).assertEqual('favorites');
        expect(form['type']).assertEqual('stream');
        expect(form['finished']).assertEqual('false');
        expect(form['mode']).assertEqual('author');
        expect(form['page']).assertEqual('3');
      }
    });

    it('formCombinationRatingMixed', 0, () => {
      const form: Record<string, string> | null = buildSearchForm('海贼王', 1, 'default',
        SEARCH_SORT_RATING, undefined, SEARCH_FINISHED_COMPLETED);
      expect(form !== null).assertTrue();
      if (form !== null) {
        expect(form['sort']).assertEqual('rating');
        expect(form['type']).assertEqual('');
        expect(form['finished']).assertEqual('true');
      }
    });

    // ==================== 协议层：非法值拒发 ====================
    it('formIllegalSortRejected', 0, () => {
      expect(buildSearchForm('海贼王', 1, 'default', 'hot', undefined, undefined)).assertNull();
    });

    it('formIllegalTypeRejected', 0, () => {
      expect(buildSearchForm('海贼王', 1, 'default', undefined, 'video', undefined)).assertNull();
    });

    it('formIllegalFinishedRejected', 0, () => {
      expect(buildSearchForm('海贼王', 1, 'default', undefined, undefined, 'yes')).assertNull();
    });

    it('normalizeFilterFalsyToEmpty', 0, () => {
      expect(normalizeSearchFilter(undefined, [SEARCH_SORT_VIEWS, SEARCH_SORT_RATING])).assertEqual('');
      expect(normalizeSearchFilter('', [SEARCH_SORT_VIEWS, SEARCH_SORT_RATING])).assertEqual('');
    });

    it('normalizeFilterLegalPassthrough', 0, () => {
      expect(normalizeSearchFilter('views', [SEARCH_SORT_VIEWS, SEARCH_SORT_RATING])).assertEqual('views');
    });

    it('normalizeFilterIllegalReturnsNull', 0, () => {
      expect(normalizeSearchFilter('hot', [SEARCH_SORT_VIEWS, SEARCH_SORT_RATING])).assertNull();
    });

    it('constantsMatchAuditTable', 0, () => {
      // 契约表（API_PROTOCOL_AUDIT.md §2.1 :52）逐值核对，防拼写漂移
      expect(SEARCH_SORT_DEFAULT).assertEqual('');
      expect(SEARCH_SORT_VIEWS).assertEqual('views');
      expect(SEARCH_SORT_FAVORITES).assertEqual('favorites');
      expect(SEARCH_SORT_RATING).assertEqual('rating');
      expect(SEARCH_TYPE_DEFAULT).assertEqual('');
      expect(SEARCH_TYPE_BOOK).assertEqual('book');
      expect(SEARCH_TYPE_STREAM).assertEqual('stream');
      expect(SEARCH_FINISHED_ALL).assertEqual('');
      expect(SEARCH_FINISHED_COMPLETED).assertEqual('true');
      expect(SEARCH_FINISHED_ONGOING).assertEqual('false');
    });

    // ==================== 源层：非法值在发网前拒发 ====================
    it('sourceRefusesIllegalBeforeHttp', 0, async () => {
      const source: NoyAcgSource = new NoyAcgSource();
      let err: Error | null = null;
      try {
        await source.search('海贼王', 1, undefined, 'hot', undefined, undefined);
      } catch (e) {
        err = e as Error;
      }
      // 前置守卫抛 ProtocolError：请求未到达 HttpManager（无会话环境下也不会发网）
      expect(err instanceof ProtocolError).assertTrue();
    });

    // ==================== ViewModel：筛选变化刷新 + 分页正确 ====================
    it('filterChangeRefreshesPageOne', 0, async () => {
      const source: FilterStubSource = new FilterStubSource();
      const vm: SearchViewModel = new SearchViewModel(source);
      vm.keyword = '海贼王';
      await vm.search(true);
      expect(source.calls.length).assertEqual(1);
      expect(source.calls[0]).assertEqual('海贼王#1#default###');
      vm.currentPage = 2; // 模拟已翻页
      vm.onFilterChanged('sort', SEARCH_SORT_VIEWS); // 触发异步重查
      await settle(20); // 等待收敛
      expect(source.calls.length).assertEqual(2);
      // 新组合：sort=views，其余默认 → page 重置回 1
      expect(source.calls[1]).assertEqual('海贼王#1#default#views##');
      expect(vm.currentPage).assertEqual(1);
    });

    it('filterChangeSameValueNoRequest', 0, async () => {
      const source: FilterStubSource = new FilterStubSource();
      const vm: SearchViewModel = new SearchViewModel(source);
      vm.keyword = '海贼王';
      await vm.search(true);
      vm.onFilterChanged('sort', SEARCH_SORT_DEFAULT);
      vm.onFilterChanged('type', SEARCH_TYPE_DEFAULT);
      vm.onFilterChanged('finished', SEARCH_FINISHED_ALL);
      expect(source.calls.length).assertEqual(1);
    });

    it('filterChangeThenLoadMoreKeepsFilter', 0, async () => {
      const source: FilterStubSource = new FilterStubSource();
      const vm: SearchViewModel = new SearchViewModel(source);
      vm.keyword = '海贼王';
      await vm.search(true);
      vm.onFilterChanged('finished', SEARCH_FINISHED_COMPLETED);
      await settle(20); // 等待筛选重查收敛，再翻页
      await vm.loadMore();
      expect(source.calls.length).assertEqual(3);
      expect(source.calls[0]).assertEqual('海贼王#1#default###');
      // 筛选重查：第 1 页 + finished=true
      expect(source.calls[1]).assertEqual('海贼王#1#default###true');
      // 翻页：第 2 页仍携带 finished=true
      expect(source.calls[2]).assertEqual('海贼王#2#default###true');
      expect(vm.currentPage).assertEqual(2);
    });

    it('filterChangeWhileInFlightNotShortCircuited', 0, async () => {
      const source: FilterStubSource = new FilterStubSource();
      const vm: SearchViewModel = new SearchViewModel(source);
      vm.keyword = '海贼王';
      const first: Promise<void> = vm.search(true);
      // 同词在途 + 新筛选：不命中「同词在途短路」，发出第二次请求
      vm.onFilterChanged('sort', SEARCH_SORT_RATING);
      await first;
      await settle(20);
      expect(source.calls.length).assertEqual(2);
      expect(source.calls[1]).assertEqual('海贼王#1#default#rating##');
    });
  });
}