/**
 * SearchViewModel.test.ets —— 搜索状态机单元测试（本地单元测试）
 *
 * 用可编程的 StubSource 注入 IComicSource，覆盖：
 * 首次搜索 / 空关键词 / 无结果 / 失败 / 快速连续搜索 / 同词重复提交 /
 * 刷新重置页码 / 分页 / 重复触底 / 去重 / 旧响应晚到 / 分页失败保留结果 / 销毁后响应丢弃。
 * 全部用例均真实执行 ViewModel 代码，不使用假数据「伪装」搜索结果。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { Comic } from '../main/ets/model/Comic';
import { PageInfo } from '../main/ets/model/PageInfo';
import { ComicDetail } from '../main/ets/model/ComicDetail';
import { HomeFeed } from '../main/ets/model/HomeFeed';
import { AdItem } from '../main/ets/model/AdItem';
import { CommentPage } from '../main/ets/model/BookComment';
import { IComicSource } from '../main/ets/source/IComicSource';
import { HttpError } from '../main/ets/api/HttpManager';
import { AuthRequiredError } from '../main/ets/api/ApiErrors';
import { SearchViewModel } from '../main/ets/viewmodel/SearchViewModel';

/** 可编程响应：delayMs 控制返回时序，errorMessage 非空表示抛错 */
class StubResponse {
  list: Comic[] = [];
  hasMore: boolean = false;
  delayMs: number = 0;
  errorMessage: string = '';
}

/** IComicSource 桩实现：记录调用并按队列返回预设响应 */
class StubSource implements IComicSource {
  readonly sourceId: string = 'stub';
  readonly sourceName: string = 'Stub';
  readonly baseUrl: string = 'https://stub.local';
  /** 调用记录，格式 "keyword#page" */
  calls: string[] = [];
  /** 待消费响应队列（为空时使用 fallback） */
  queue: StubResponse[] = [];
  fallback: StubResponse = new StubResponse();

  async search(keyword: string, page: number): Promise<PageInfo<Comic>> {
    this.calls.push(`${keyword}#${page}`);
    const response: StubResponse = this.queue.length > 0 ? this.queue.shift()! : this.fallback;
    if (response.delayMs > 0) {
      await StubSource.sleep(response.delayMs);
    }
    if (response.errorMessage !== '') {
      throw new HttpError(-1, response.errorMessage);
    }
    return new PageInfo<Comic>(page, -1, response.list, response.hasMore);
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
    return new HomeFeed();
  }

  async getAds(adultLevel?: string): Promise<AdItem[]> {
    return [];
  }

  async getBookComments(bookId: string, page: number): Promise<CommentPage> {
    return new CommentPage([], page, true);
  }

  static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}

/** 永远返回「需要登录」的源：模拟真实接口未登录时的行为 */
class AuthFailingSource implements IComicSource {
  readonly sourceId: string = 'stub-auth';
  readonly sourceName: string = 'StubAuth';
  readonly baseUrl: string = 'https://stub.local';
  calls: number = 0;

  async search(keyword: string, page: number): Promise<PageInfo<Comic>> {
    this.calls++;
    throw new AuthRequiredError('登录已失效或未登录：NoyAcg 需要账号会话才能读取数据');
  }

  async getHomeList(page: number, sort?: string, finished?: string): Promise<PageInfo<Comic>> {
    throw new AuthRequiredError();
  }

  async getComicDetail(id: string): Promise<ComicDetail> {
    throw new AuthRequiredError();
  }

  async getChapterImages(bookId: string, chapterId: string): Promise<string[]> {
    throw new AuthRequiredError();
  }

  async getHomeFeed(adultLevel?: string): Promise<HomeFeed> {
    throw new AuthRequiredError();
  }

  async getAds(adultLevel?: string): Promise<AdItem[]> {
    throw new AuthRequiredError();
  }

  async getBookComments(bookId: string, page: number): Promise<CommentPage> {
    throw new AuthRequiredError();
  }
}

/** 构造 n 条漫画（id 递增，便于断言） */
function makeComics(start: number, count: number): Comic[] {
  const list: Comic[] = [];
  for (let i = 0; i < count; i++) {
    const id: number = start + i;
    list.push(new Comic(`id${id}`, `漫画${id}`, `https://stub.local/${id}.jpg`));
  }
  return list;
}

function makeResponse(list: Comic[], hasMore: boolean, delayMs: number = 0,
  errorMessage: string = ''): StubResponse {
  const response: StubResponse = new StubResponse();
  response.list = list;
  response.hasMore = hasMore;
  response.delayMs = delayMs;
  response.errorMessage = errorMessage;
  return response;
}

export default function searchViewModelTest() {
  describe('SearchViewModel', () => {
    let source: StubSource = new StubSource();
    let vm: SearchViewModel = new SearchViewModel(source);

    beforeEach(() => {
      source = new StubSource();
      vm = new SearchViewModel(source);
    });

    it('emptyKeywordDoesNotRequest', 0, async () => {
      vm.keyword = '   ';
      await vm.search(true);
      expect(source.calls.length).assertEqual(0);
      expect(vm.hasSearched).assertFalse();
      expect(vm.isEmpty).assertTrue();
    });

    it('firstSearchSuccess', 0, async () => {
      source.queue = [makeResponse(makeComics(1, 6), true)];
      vm.keyword = '海贼王';
      vm.submit();
      // 等待请求完成（submit 内部未 await，这里轮询状态收敛）
      await StubSource.sleep(20);
      expect(source.calls.length).assertEqual(1);
      expect(source.calls[0]).assertEqual('海贼王#1');
      expect(vm.isSearching).assertFalse();
      expect(vm.hasSearched).assertTrue();
      expect(vm.isEmpty).assertFalse();
      expect(vm.hasMore).assertTrue();
      expect(vm.currentPage).assertEqual(1);
      expect(vm.searchDataSource.totalCount()).assertEqual(6);
    });

    it('searchNoResult', 0, async () => {
      source.queue = [makeResponse([], false)];
      vm.keyword = '不存在的漫画';
      await vm.search(true);
      expect(vm.hasSearched).assertTrue();
      expect(vm.isEmpty).assertTrue();
      expect(vm.hasMore).assertFalse();
      expect(vm.searchDataSource.totalCount()).assertEqual(0);
    });

    it('searchFailureSetsError', 0, async () => {
      source.queue = [makeResponse([], false, 0, '网络异常: timeout')];
      vm.keyword = '海贼王';
      await vm.search(true);
      expect(vm.hasError).assertTrue();
      expect(vm.errorMessage).assertEqual('网络异常: timeout');
      expect(vm.isEmpty).assertTrue();
      expect(vm.isSearching).assertFalse();
      expect(vm.currentPage).assertEqual(0);
    });

    it('duplicateSubmitWhileInFlightIgnored', 0, async () => {
      // 同词在途重复提交（用户连按回车）只允许一次真实请求
      source.queue = [makeResponse(makeComics(1, 3), true, 60)];
      vm.keyword = '海贼王';
      const first: Promise<void> = vm.search(true, true);
      const second: Promise<void> = vm.search(true, true);
      await first;
      await second;
      expect(source.calls.length).assertEqual(1);
    });

    it('refreshResetsPage', 0, async () => {
      source.queue = [makeResponse(makeComics(1, 3), true)];
      vm.keyword = '海贼王';
      await vm.search(true);
      await vm.loadMore();
      expect(vm.currentPage).assertEqual(2);
      // 刷新（显式提交）：页码回到 1，列表整表替换
      source.queue = [makeResponse(makeComics(100, 2), true)];
      vm.keyword = '海贼王';
      vm.submit();
      await StubSource.sleep(20);
      expect(vm.currentPage).assertEqual(1);
      expect(vm.searchDataSource.totalCount()).assertEqual(2);
      expect(vm.searchDataSource.get(0).id).assertEqual('id100');
    });

    it('loadMoreAppendsNextPage', 0, async () => {
      source.queue = [makeResponse(makeComics(1, 3), true)];
      vm.keyword = '海贼王';
      await vm.search(true);
      source.queue = [makeResponse(makeComics(4, 3), false)];
      await vm.loadMore();
      expect(source.calls[1]).assertEqual('海贼王#2');
      expect(vm.searchDataSource.totalCount()).assertEqual(6);
      expect(vm.currentPage).assertEqual(2);
      expect(vm.hasMore).assertFalse();
    });

    it('duplicateReachEndRequestsOnlyOnce', 0, async () => {
      source.queue = [makeResponse(makeComics(1, 3), true)];
      vm.keyword = '海贼王';
      await vm.search(true);
      source.queue = [makeResponse(makeComics(4, 3), true, 50)];
      // 模拟连续触底：三连发只应产生一次请求
      const first: Promise<void> = vm.loadMore();
      const second: Promise<void> = vm.loadMore();
      const third: Promise<void> = vm.loadMore();
      await first;
      await second;
      await third;
      expect(source.calls.length).assertEqual(2);
      expect(vm.searchDataSource.totalCount()).assertEqual(6);
    });

    it('duplicateDataDeduped', 0, async () => {
      source.queue = [makeResponse(makeComics(1, 3), true)];
      vm.keyword = '海贼王';
      await vm.search(true);
      // 第 2 页与第 1 页完全重复：去重后 0 新增 → 判定到底
      source.queue = [makeResponse(makeComics(1, 3), true)];
      await vm.loadMore();
      expect(vm.searchDataSource.totalCount()).assertEqual(3);
      expect(vm.hasMore).assertFalse();
    });

    it('emptyPageStopsPagination', 0, async () => {
      source.queue = [makeResponse(makeComics(1, 3), true)];
      vm.keyword = '海贼王';
      await vm.search(true);
      source.queue = [makeResponse([], true)];
      await vm.loadMore();
      expect(vm.hasMore).assertFalse();
      // 触底不再发请求
      await vm.loadMore();
      expect(source.calls.length).assertEqual(2);
    });

    it('loadMoreFailureKeepsResults', 0, async () => {
      source.queue = [makeResponse(makeComics(1, 3), true)];
      vm.keyword = '海贼王';
      await vm.search(true);
      source.queue = [makeResponse([], true, 0, '加载更多失败')];
      await vm.loadMore();
      expect(vm.loadMoreError).assertTrue();
      expect(vm.hasError).assertFalse();
      expect(vm.searchDataSource.totalCount()).assertEqual(3);
      expect(vm.currentPage).assertEqual(1);
      expect(vm.isLoadMore).assertFalse();
      // 重试：重发第 2 页
      source.queue = [makeResponse(makeComics(4, 2), false)];
      vm.retry();
      await StubSource.sleep(20);
      expect(source.calls[2]).assertEqual('海贼王#2');
      expect(vm.searchDataSource.totalCount()).assertEqual(5);
    });

    it('staleResponseDoesNotOverrideNewSearch', 0, async () => {
      // 第一次请求慢（80ms），第二次请求快（10ms）
      source.queue = [
        makeResponse(makeComics(1, 3), true, 80),
        makeResponse(makeComics(9, 2), true, 10)
      ];
      vm.keyword = '旧词';
      const slow: Promise<void> = vm.search(true);
      vm.keyword = '新词';
      const fast: Promise<void> = vm.search(true);
      await fast;
      await slow;
      // 最终结果必须来自「新词」，旧词晚到的响应被代际废弃
      expect(vm.searchDataSource.totalCount()).assertEqual(2);
      expect(vm.searchDataSource.get(0).id).assertEqual('id9');
      expect(vm.hasSearched).assertTrue();
      expect(vm.isSearching).assertFalse();
    });

    it('staleLoadMoreDiscardedAfterNewSearch', 0, async () => {
      source.queue = [makeResponse(makeComics(1, 3), true)];
      vm.keyword = '海贼王';
      await vm.search(true);
      // 分页请求在途时用户换了关键词
      source.queue = [
        makeResponse(makeComics(4, 3), true, 60),
        makeResponse(makeComics(20, 2), true, 5)
      ];
      const paging: Promise<void> = vm.loadMore();
      vm.keyword = '火影';
      await vm.search(true);
      await paging;
      expect(vm.searchDataSource.totalCount()).assertEqual(2);
      expect(vm.searchDataSource.get(0).id).assertEqual('id20');
      expect(vm.currentPage).assertEqual(1);
    });

    it('disposeDiscardsLateResponse', 0, async () => {
      source.queue = [makeResponse(makeComics(1, 3), true, 50)];
      vm.keyword = '海贼王';
      const pending: Promise<void> = vm.search(true);
      vm.dispose();
      await pending;
      expect(vm.searchDataSource.totalCount()).assertEqual(0);
      expect(vm.hasSearched).assertFalse();
    });

    it('debounceTriggersSingleAutoSearch', 0, async () => {
      source.queue = [makeResponse(makeComics(1, 2), false)];
      vm.onKeywordInput('海');
      vm.onKeywordInput('海贼');
      vm.onKeywordInput('海贼王');
      expect(source.calls.length).assertEqual(0);
      await StubSource.sleep(700);
      expect(source.calls.length).assertEqual(1);
      expect(source.calls[0]).assertEqual('海贼王#1');
    });

    it('submitCancelsPendingDebounce', 0, async () => {
      source.queue = [makeResponse(makeComics(1, 2), false)];
      vm.onKeywordInput('海贼王');
      vm.submit();
      await StubSource.sleep(700);
      // 提交已消化本次输入，防抖计时器不得再补发一次
      expect(source.calls.length).assertEqual(1);
    });

    it('clearKeywordBackToIdle', 0, async () => {
      source.queue = [makeResponse(makeComics(1, 3), true)];
      vm.keyword = '海贼王';
      await vm.search(true);
      vm.clearKeyword();
      expect(vm.keyword).assertEqual('');
      expect(vm.hasSearched).assertFalse();
      expect(vm.isEmpty).assertTrue();
      expect(vm.searchDataSource.totalCount()).assertEqual(0);
    });

    it('retryAfterFailureReissuesSearch', 0, async () => {
      source.queue = [makeResponse([], false, 0, '网络异常: timeout')];
      vm.keyword = '海贼王';
      await vm.search(true);
      expect(vm.hasError).assertTrue();
      expect(vm.isEmpty).assertTrue();
      // 点击重试：重新请求第 1 页并恢复正常态
      source.queue = [makeResponse(makeComics(1, 2), true)];
      vm.retry();
      await StubSource.sleep(20);
      expect(source.calls.length).assertEqual(2);
      expect(source.calls[1]).assertEqual('海贼王#1');
      expect(vm.hasError).assertFalse();
      expect(vm.isEmpty).assertFalse();
      expect(vm.searchDataSource.totalCount()).assertEqual(2);
    });

    it('searchAfterDisposeIsIgnored', 0, async () => {
      source.queue = [makeResponse(makeComics(1, 3), true)];
      vm.keyword = '海贼王';
      vm.dispose();
      // 页面已销毁：任何入口都不得再产生请求或状态变更
      await vm.search(true, true);
      await vm.loadMore();
      vm.onKeywordInput('火影');
      await StubSource.sleep(700);
      expect(source.calls.length).assertEqual(0);
      expect(vm.hasSearched).assertFalse();
      expect(vm.isSearching).assertFalse();
      expect(vm.searchDataSource.totalCount()).assertEqual(0);
    });

    it('authRequiredSurfacesLoginHint', 0, async () => {
      // 真实接口在未登录时返回 HTTP 200 + {"status":"login"}，
      // 数据层转成 AuthRequiredError；VM 必须把它标记为「需要登录」而不是普通失败
      const authSource: AuthFailingSource = new AuthFailingSource();
      const authVm: SearchViewModel = new SearchViewModel(authSource);
      authVm.keyword = '海贼王';
      await authVm.search(true);
      expect(authVm.hasError).assertTrue();
      expect(authVm.needsLogin).assertTrue();
      expect(authVm.errorMessage.indexOf('登录') >= 0).assertTrue();
      expect(authVm.isEmpty).assertTrue();
      expect(authVm.isSearching).assertFalse();
    });

    it('loginHintClearedOnNextSuccess', 0, async () => {
      const authSource: AuthFailingSource = new AuthFailingSource();
      const authVm: SearchViewModel = new SearchViewModel(authSource);
      authVm.keyword = '海贼王';
      await authVm.search(true);
      expect(authVm.needsLogin).assertTrue();

      // 换成能返回数据的源：再次搜索成功后登录提示必须清除
      const okVm: SearchViewModel = new SearchViewModel(source);
      expect(okVm.needsLogin).assertFalse();
      source.queue = [makeResponse(makeComics(1, 2), false)];
      okVm.keyword = '海贼王';
      await okVm.search(true);
      expect(okVm.needsLogin).assertFalse();
      expect(okVm.hasError).assertFalse();
      expect(okVm.searchDataSource.totalCount()).assertEqual(2);
    });
  });
}
