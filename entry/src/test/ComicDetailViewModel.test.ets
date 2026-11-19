/**
 * ComicDetailViewModel.test.ets —— Phase 11 详情视图模型测试
 *
 * 覆盖：首次加载 / 成功 / 失败 / 重试 / 登录失效独立状态 / 快速重复加载 /
 * 旧请求晚到 / 页面销毁 / 同 ID 去重 / 换 ID 重载 / EMPTY 与单本形态 /
 * 分组展开折叠 / 章节选择参数 / 章节级起始页隔离 / 本地读失败容错 / 收藏回滚。
 *
 * 所有响应均为派生 fixture + 可编程桩，不联网、不代表真实登录后接口验证。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import {
  ComicDetailViewModel,
  DetailErrorKind,
  DetailState
} from '../main/ets/viewmodel/ComicDetailViewModel';
import { Chapter } from '../main/ets/model/Chapter';
import { ChapterRow, ChapterRowKind } from '../main/ets/model/ChapterRow';
import { ComicDetail } from '../main/ets/model/ComicDetail';
import { ComicReaderParam } from '../main/ets/model/ReaderParam';
import { parseBookDetailJson } from '../main/ets/source/NoyAcgProtocol';
import { HttpError } from '../main/ets/api/HttpManager';
import { AuthRequiredError, ProtocolError } from '../main/ets/api/ApiErrors';
import { HistoryRecord } from '../main/ets/utils/DatabaseManager';
import { BOOK_DETAIL_FULL_DERIVED, BOOK_DETAIL_MINIMAL_DERIVED,
  BOOK_DETAIL_SINGLE_DERIVED } from './fixtures/FixtureData';
import { InMemoryReadingStore, StubAccountFavPort, StubDetailSource } from './DetailStubs';
import { StubDownloadControl } from './DownloadStubs';

/** 按 id 找章节（ArkTS 不使用可能不稳定的 find） */
function chapterById(vm: ComicDetailViewModel, id: string): Chapter | null {
  const detail: ComicDetail | null = vm.detail;
  if (detail === null) {
    return null;
  }
  for (let i = 0; i < detail.chapters.length; i++) {
    if (detail.chapters[i].id === id) {
      return detail.chapters[i];
    }
  }
  return null;
}

function makeHistory(chapterId: string, page: number, time: number): HistoryRecord {
  return {
    comicId: '900201',
    chapterId: chapterId,
    chapterTitle: `章节 ${chapterId}`,
    pageIndex: page,
    totalPages: 22,
    updateTime: time
  };
}

export default function comicDetailViewModelTest() {
  describe('ComicDetailViewModel', () => {
    let source: StubDetailSource = new StubDetailSource();
    let store: InMemoryReadingStore = new InMemoryReadingStore();
    let favPort: StubAccountFavPort = new StubAccountFavPort();
    let vm: ComicDetailViewModel = new ComicDetailViewModel(source, store);

    beforeEach(() => {
      source = new StubDetailSource();
      store = new InMemoryReadingStore();
      favPort = new StubAccountFavPort();
      vm = new ComicDetailViewModel(source, store, undefined, favPort);
      source.detail = parseBookDetailJson(BOOK_DETAIL_FULL_DERIVED, '900201');
    });

    // ==================== 状态机 ====================

    it('initialStateIsIdle', 0, () => {
      expect(vm.state).assertEqual(DetailState.IDLE);
      expect(vm.detail === null).assertTrue();
      expect(vm.chapterRows.totalCount()).assertEqual(0);
    });

    it('firstLoadTransitionsToSuccess', 0, async () => {
      await vm.loadDetail('900201');
      expect(vm.state).assertEqual(DetailState.SUCCESS);
      expect(vm.detail !== null).assertTrue();
      expect(source.calls.length).assertEqual(1);
      expect(vm.chapterRows.totalCount()).assertEqual(3); // 默认全部折叠：仅 3 分组头
      expect(vm.errorMessage).assertEqual('');
    });

    it('networkFailureSetsDiagnosticError', 0, async () => {
      source.error = new HttpError(504, '网关超时');
      await vm.loadDetail('900201');
      expect(vm.state).assertEqual(DetailState.ERROR);
      expect(vm.errorKind).assertEqual(DetailErrorKind.NETWORK);
      expect(vm.needsLogin).assertFalse();
      expect(vm.errorMessage.indexOf('504') >= 0).assertTrue();
      expect(vm.errorMessage.indexOf('网关超时') >= 0).assertTrue();
    });

    it('protocolFailureUsesProtocolKind', 0, async () => {
      source.error = new ProtocolError('详情响应缺少 book.info');
      await vm.loadDetail('900201');
      expect(vm.state).assertEqual(DetailState.ERROR);
      expect(vm.errorKind).assertEqual(DetailErrorKind.PROTOCOL);
    });

    it('authRequiredUsesDedicatedState', 0, async () => {
      source.error = new AuthRequiredError();
      await vm.loadDetail('900201');
      expect(vm.state).assertEqual(DetailState.AUTH_REQUIRED);
      expect(vm.needsLogin).assertTrue();
      expect(vm.errorKind).assertEqual(DetailErrorKind.AUTH_REQUIRED);
    });

    it('retryAfterFailureSucceeds', 0, async () => {
      source.error = new HttpError(504, '超时');
      await vm.loadDetail('900201');
      expect(vm.state).assertEqual(DetailState.ERROR);
      source.error = null;
      await vm.retry();
      expect(vm.state).assertEqual(DetailState.SUCCESS);
      expect(source.calls.length).assertEqual(2);
      expect(vm.errorMessage).assertEqual('');
    });

    it('sameIdDoesNotReloadAfterSuccess', 0, async () => {
      await vm.loadDetail('900201');
      await vm.loadDetail('900201');
      expect(source.calls.length).assertEqual(1);
    });

    it('differentIdTriggersNewRequest', 0, async () => {
      await vm.loadDetail('900201');
      await vm.loadDetail('900202');
      expect(source.calls.length).assertEqual(2);
      expect(vm.state).assertEqual(DetailState.SUCCESS);
    });

    it('rapidRepeatedLoadTriggersOneRequest', 0, async () => {
      const first: Promise<void> = vm.loadDetail('900201');
      const second: Promise<void> = vm.loadDetail('900201');
      await first;
      await second;
      expect(source.calls.length).assertEqual(1);
    });

    it('staleResponseDoesNotOverrideNewResult', 0, async () => {
      const oldDetail: ComicDetail = parseBookDetailJson(BOOK_DETAIL_FULL_DERIVED, 'A');
      oldDetail.title = '旧详情';
      const newDetail: ComicDetail = parseBookDetailJson(BOOK_DETAIL_FULL_DERIVED, 'B');
      newDetail.title = '新详情';
      source.detailById['A'] = oldDetail;
      source.detailById['B'] = newDetail;
      source.delayById['A'] = 40;
      source.delayById['B'] = 0;

      const first: Promise<void> = vm.loadDetail('A', true);
      const second: Promise<void> = vm.loadDetail('B', true);
      await first;
      await second;
      expect(vm.state).assertEqual(DetailState.SUCCESS);
      expect(vm.detail !== null).assertTrue();
      if (vm.detail !== null) {
        expect(vm.detail.title).assertEqual('新详情');
      }
    });

    it('disposeBlocksNewRequests', 0, async () => {
      vm.dispose();
      await vm.loadDetail('900201');
      expect(source.calls.length).assertEqual(0);
      expect(vm.state).assertEqual(DetailState.IDLE);
    });

    it('disposeIgnoresInFlightResponse', 0, async () => {
      source.delayMs = 20;
      const pending: Promise<void> = vm.loadDetail('900201');
      vm.dispose();
      await pending;
      expect(vm.state === DetailState.SUCCESS).assertFalse();
      expect(vm.detail === null).assertTrue();
    });

    // ==================== EMPTY / 单本 ====================

    it('minimalDetailWithoutModeEntersEmptyState', 0, async () => {
      source.detail = parseBookDetailJson(BOOK_DETAIL_MINIMAL_DERIVED, '900301');
      await vm.loadDetail('900301');
      expect(vm.state).assertEqual(DetailState.EMPTY);
      expect(vm.chapterRows.totalCount()).assertEqual(0);
    });

    it('singleBookModeZeroIsSuccessAndUsesCidZero', 0, async () => {
      source.detail = parseBookDetailJson(BOOK_DETAIL_SINGLE_DERIVED, '900302');
      await vm.loadDetail('900302');
      expect(vm.state).assertEqual(DetailState.SUCCESS);
      const param: ComicReaderParam | null = vm.startReading();
      expect(param !== null).assertTrue();
      if (param !== null) {
        expect(param.comicId).assertEqual('900302');
        expect(param.chapterId).assertEqual('0');
        expect(param.startPage).assertEqual(1);
      }
    });

    // ==================== 目录与章节选择 ====================

    it('chapterRowsContainHeadersAndItemsInGroupOrder', 0, async () => {
      await vm.loadDetail('900201');
      const rows = vm.chapterRows;
      const first: ChapterRow = rows.get(0);
      expect(first.kind).assertEqual(ChapterRowKind.GROUP_HEADER);
      expect(first.groupName).assertEqual('第 1 卷');
      expect(first.groupCount).assertEqual(3);
      vm.toggleGroup(first.groupId);
      expect(rows.get(1).kind).assertEqual(ChapterRowKind.CHAPTER);
    });

    it('toggleGroupCollapsesAndExpandsRows', 0, async () => {
      await vm.loadDetail('900201');
      const collapsed: number = vm.chapterRows.totalCount();
      vm.toggleGroup('5');
      expect(vm.chapterRows.totalCount()).assertEqual(collapsed + 3);
      vm.toggleGroup('5');
      expect(vm.chapterRows.totalCount()).assertEqual(collapsed);
    });

    it('selectChapterCarriesBothIds', 0, async () => {
      await vm.loadDetail('900201');
      const chapter: Chapter | null = chapterById(vm, '90008');
      expect(chapter !== null).assertTrue();
      if (chapter !== null) {
        const param: ComicReaderParam | null = vm.selectChapter(chapter);
        expect(param !== null).assertTrue();
        if (param !== null) {
          expect(param.comicId).assertEqual('900201');
          expect(param.chapterId).assertEqual('90008');
          expect(param.startPage).assertEqual(1);
        }
        expect(vm.selectedChapterId).assertEqual('90008');
      }
    });

    it('startReadingUsesFirstChapter', 0, async () => {
      await vm.loadDetail('900201');
      const param: ComicReaderParam | null = vm.startReading();
      expect(param !== null).assertTrue();
      if (param !== null) {
        expect(param.comicId).assertEqual('900201');
        expect(param.chapterId).assertEqual('90008'); // groups[0] 内 sort 最小的章节
      }
    });

    it('chapterStartPagesAreIsolatedByChapter', 0, async () => {
      store.seed(makeHistory('90008', 7, 100));
      store.seed(makeHistory('90009', 3, 200));
      await vm.loadDetail('900201');
      const c1: Chapter | null = chapterById(vm, '90008');
      const c2: Chapter | null = chapterById(vm, '90009');
      if (c1 !== null && c2 !== null) {
        const p1: ComicReaderParam | null = vm.selectChapter(c1);
        const p2: ComicReaderParam | null = vm.selectChapter(c2);
        if (p1 !== null && p2 !== null) {
          expect(p1.startPage).assertEqual(7);
          expect(p2.startPage).assertEqual(3); // 绝不复用上一章节页码
        }
        expect(vm.isChapterRead('90008')).assertTrue();
        expect(vm.isChapterRead('90099')).assertFalse();
      }
    });

    it('continueReadingRequiresValidHistory', 0, async () => {
      store.seed(makeHistory('999999', 5, 300)); // 章节已不在目录中
      await vm.loadDetail('900201');
      expect(vm.hasValidHistory).assertFalse();
      expect(vm.continueReading() === null).assertTrue();

      const store2: InMemoryReadingStore = new InMemoryReadingStore();
      const vm3: ComicDetailViewModel = new ComicDetailViewModel(source, store2);
      store2.seed(makeHistory('90008', 6, 400));
      await vm3.loadDetail('900201');
      expect(vm3.hasValidHistory).assertTrue();
      const param: ComicReaderParam | null = vm3.continueReading();
      expect(param !== null).assertTrue();
      if (param !== null) {
        expect(param.chapterId).assertEqual('90008');
        expect(param.startPage).assertEqual(6);
      }
    });

    // ==================== 本地容错与收藏 ====================

    it('localReadFailureDoesNotFailDetail', 0, async () => {
      store.failOnRead = true;
      await vm.loadDetail('900201');
      expect(vm.state).assertEqual(DetailState.SUCCESS);
      expect(vm.isFavorite).assertFalse();
      expect(vm.historyChapterId).assertEqual('');
    });

    it('favoriteToggleConstructsBidParam', 0, async () => {
      await vm.loadDetail('900201');
      await vm.toggleFavorite();
      expect(favPort.toggleCalls.length).assertEqual(1);
      expect(favPort.toggleCalls[0]).assertEqual('900201'); // 契约：表单参数名为 bid
    });

    it('favoriteSuccessSyncsFromServer', 0, async () => {
      await vm.loadDetail('900201');
      await vm.toggleFavorite();
      // 成功：乐观取反 + /get 校准（stub 收藏列表不含 900201 → 校准为未收藏）
      expect(favPort.toggleCalls.length).assertEqual(1);
      expect(vm.isFavorite).assertFalse();
      // 服务端已收藏时校准为 true
      const fav2: StubAccountFavPort = new StubAccountFavPort();
      fav2.favoriteIds = ['900201'];
      const vm2: ComicDetailViewModel = new ComicDetailViewModel(source, store, undefined, fav2);
      await vm2.loadDetail('900201');
      await vm2.toggleFavorite();
      expect(vm2.isFavorite).assertTrue();
    });

    it('favoriteNetworkFailureRollsBack', 0, async () => {
      await vm.loadDetail('900201');
      favPort.toggleError = new HttpError(-1, '模拟网络失败');
      await vm.toggleFavorite();
      expect(vm.isFavorite).assertFalse(); // 回滚到操作前（false）
      expect(favPort.toggleCalls.length).assertEqual(1);
    });

    it('favoriteAuthFailureRollsBackAndNotices', 0, async () => {
      await vm.loadDetail('900201');
      favPort.toggleError = new AuthRequiredError('登录已失效');
      await vm.toggleFavorite();
      expect(vm.isFavorite).assertFalse();
      expect(vm.favoriteNotice.indexOf('登录') >= 0).assertTrue();
    });

    it('favoriteRollbackRefetchFailureRestoresPrevious', 0, async () => {
      await vm.loadDetail('900201');
      favPort.favoriteIds = ['900201']; // 服务端已收藏 → 初始显示 true
      await vm.resyncFavoriteOnReentry();
      expect(vm.isFavorite).assertTrue();
      favPort.toggleError = new HttpError(-1, '写失败');
      favPort.getError = new HttpError(-1, '校准也失败');
      await vm.toggleFavorite();
      expect(vm.isFavorite).assertTrue(); // /get 失败 → 回滚到操作前 true
      expect(vm.favoriteNotice.indexOf('失败') >= 0).assertTrue();
    });

    it('favoriteDuplicateClickDebounced', 0, async () => {
      await vm.loadDetail('900201');
      favPort.toggleDelayMs = 50;
      const p1: Promise<void> = vm.toggleFavorite();
      const p2: Promise<void> = vm.toggleFavorite();
      await Promise.all([p1, p2]);
      expect(favPort.toggleCalls.length).assertEqual(1); // 在途期间忽略第二次点击
    });

    it('favoriteSyncOnReentryMatchesServer', 0, async () => {
      await vm.loadDetail('900201');
      // 详情 F=false → 初始 false；服务端此后已收藏 → 重新进入校准为 true
      favPort.favoriteIds = ['900201'];
      await vm.resyncFavoriteOnReentry();
      expect(vm.isFavorite).assertTrue();
    });

    it('favoriteLocalMirrorFailureIsIgnored', 0, async () => {
      store.favorite = true; // 本地库初始已收藏 → 与远端(未收藏)不一致，触发镜像写入
      store.failOnFavorite = true; // 镜像写入失败：不阻断 toggle 成功
      await vm.loadDetail('900201');
      expect(vm.isFavorite).assertFalse(); // 详情 F=false → 星标以服务端为准
      await vm.toggleFavorite();
      expect(vm.isFavorite).assertFalse(); // 远端成功 + /get 校准（stub 无该 id）
      expect(favPort.toggleCalls.length).assertEqual(1);
    });

    // ==================== Phase 12：详情页加入下载队列 ====================

    it('downloadChapterDelegatesBothIds', 0, async () => {
      const control: StubDownloadControl = new StubDownloadControl();
      const withDownload: ComicDetailViewModel =
        new ComicDetailViewModel(source, store, control);
      await withDownload.loadDetail('900201');
      const chapter: Chapter | null = chapterById(withDownload, '90008');
      expect(chapter !== null).assertTrue();
      if (chapter !== null) {
        await withDownload.downloadChapter(chapter);
      }
      expect(control.enqueued.length).assertEqual(1);
      expect(control.enqueued[0]).assertEqual('900201/90008');
      expect(withDownload.downloadNotice.indexOf('下载') >= 0).assertTrue();
    });

    it('downloadChapterWithoutDetailDoesNotEnqueue', 0, async () => {
      const control: StubDownloadControl = new StubDownloadControl();
      const withDownload: ComicDetailViewModel =
        new ComicDetailViewModel(source, store, control);
      await withDownload.downloadChapter(new Chapter('c1', '第 1 话'));
      expect(control.enqueued.length).assertEqual(0);
      expect(withDownload.downloadNotice.indexOf('不完整') >= 0).assertTrue();
    });

    it('downloadChapterAfterDisposeIsIgnored', 0, async () => {
      const control: StubDownloadControl = new StubDownloadControl();
      const withDownload: ComicDetailViewModel =
        new ComicDetailViewModel(source, store, control);
      await withDownload.loadDetail('900201');
      withDownload.dispose();
      const chapter: Chapter | null = chapterById(withDownload, '90008');
      if (chapter !== null) {
        await withDownload.downloadChapter(chapter);
      }
      expect(control.enqueued.length).assertEqual(0);
    });
  });
}
