/**
 * ReaderLink.test.ets —— Phase 11 阅读器衔接 + 阅读进度持久化测试
 *
 * ReaderLink：验证 getChapterImages(bookId, chapterId) 双参数链路、
 * 图片顺序、空章节、章节切换、同章节幂等、断点续读、缺失 bid 保护、登录失效引导。
 *
 * ReadingStore：用 InMemoryReadingStore 验证「插入 / 更新 / 同章节幂等 /
 * 不同章节隔离 / 页码恢复 / 写失败不谎报」的**端口契约**；
 * 另对 DatabaseManager 导出的 DDL / 迁移 SQL 做静态回归断言。
 *
 * ⚠ 本地单测的 relationalStore 是桩实现（Phase 8 已确认），
 * 真实 SQLite 建表/迁移/重启恢复仍需真机验证，报告中标为未验证。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { ComicReaderViewModel } from '../main/ets/viewmodel/ComicReaderViewModel';
import { AuthRequiredError, ProtocolError } from '../main/ets/api/ApiErrors';
import { HttpError } from '../main/ets/api/HttpManager';
import { ComicReaderParam } from '../main/ets/model/ReaderParam';
import {
  HISTORY_V2_DDL,
  HISTORY_V2_MIGRATION_SQL,
  HistoryRecord
} from '../main/ets/utils/DatabaseManager';
import { InMemoryReadingStore, StubReaderImageSource } from './DetailStubs';

function record(comicId: string, chapterId: string, page: number,
  total: number, time: number): HistoryRecord {
  return {
    comicId: comicId,
    chapterId: chapterId,
    chapterTitle: `章节 ${chapterId}`,
    pageIndex: page,
    totalPages: total,
    updateTime: time
  };
}

export default function readerLinkTest() {
  describe('ReaderLink', () => {
    let source: StubReaderImageSource = new StubReaderImageSource();
    let store: InMemoryReadingStore = new InMemoryReadingStore();
    let vm: ComicReaderViewModel = new ComicReaderViewModel(source, store);

    beforeEach(() => {
      source = new StubReaderImageSource();
      store = new InMemoryReadingStore();
      vm = new ComicReaderViewModel(source, store);
      source.images = ['p1.webp', 'p2.webp', 'p3.webp'];
    });

    it('loadChapterPassesBothIds', 0, async () => {
      await vm.loadChapter('book-1', 'chapter-1');
      expect(source.lastBookId).assertEqual('book-1');
      expect(source.lastChapterId).assertEqual('chapter-1');
      expect(source.calls[0]).assertEqual('book-1/chapter-1');
    });

    it('imagesLoadedInGivenOrder', 0, async () => {
      await vm.loadChapter('book-1', 'chapter-1');
      expect(vm.imageDataSource.totalCount()).assertEqual(3);
      expect(vm.imageDataSource.get(0)).assertEqual('p1.webp');
      expect(vm.imageDataSource.get(2)).assertEqual('p3.webp');
      expect(vm.totalCount).assertEqual(3);
    });

    it('emptyImageListIsHandled', 0, async () => {
      source.images = [];
      await vm.loadChapter('book-1', 'chapter-1');
      expect(vm.imageDataSource.totalCount()).assertEqual(0);
      expect(vm.totalCount).assertEqual(0);
      expect(vm.currentPage).assertEqual(1);
      expect(vm.errorMessage).assertEqual('');
    });

    it('chapterSwitchReloadsAndResetsPage', 0, async () => {
      await vm.loadChapter('book-1', 'chapter-1', 3);
      expect(vm.currentPage).assertEqual(3);
      await vm.loadChapter('book-1', 'chapter-2', 1);
      expect(source.calls.length).assertEqual(2);
      expect(vm.currentPage).assertEqual(1); // 新章节不复用上一章节页码
    });

    it('sameChapterReopenIsIdempotent', 0, async () => {
      await vm.loadChapter('book-1', 'chapter-1', 1);
      await vm.loadChapter('book-1', 'chapter-1', 2);
      expect(source.calls.length).assertEqual(1);
      expect(vm.currentPage).assertEqual(1);
    });

    it('differentBookWithSameChapterIdReloads', 0, async () => {
      await vm.loadChapter('book-1', 'chapter-1');
      await vm.loadChapter('book-2', 'chapter-1');
      expect(source.calls.length).assertEqual(2);
      expect(source.lastBookId).assertEqual('book-2');
    });

    it('resumePageFromStartPage', 0, async () => {
      await vm.loadChapter('book-1', 'chapter-1', 2);
      expect(vm.currentPage).assertEqual(2);
      expect(vm.totalCount).assertEqual(3);
    });

    it('startPageClampedToTotal', 0, async () => {
      await vm.loadChapter('book-1', 'chapter-1', 99);
      expect(vm.currentPage).assertEqual(3);
    });

    it('missingBookIdDoesNotRequest', 0, async () => {
      await vm.loadChapter('', 'chapter-1');
      expect(source.calls.length).assertEqual(0);
      expect(vm.errorMessage.indexOf('缺少漫画 ID') >= 0).assertTrue();
      expect(vm.needsLogin).assertFalse();
    });

    it('authRequiredExposesLoginEntry', 0, async () => {
      source.error = new AuthRequiredError();
      await vm.loadChapter('book-1', 'chapter-1');
      expect(vm.needsLogin).assertTrue();
      expect(vm.imageDataSource.totalCount()).assertEqual(0);
    });

    it('protocolAndNetworkErrorsDoNotExposeLoginEntry', 0, async () => {
      source.error = new ProtocolError('章节响应为空');
      await vm.loadChapter('book-1', 'chapter-1');
      expect(vm.needsLogin).assertFalse();

      const vm2: ComicReaderViewModel = new ComicReaderViewModel(source, store);
      source.error = new HttpError(503, '服务不可用');
      await vm2.loadChapter('book-1', 'chapter-2');
      expect(vm2.needsLogin).assertFalse();
    });

    it('readerParamCarriesBothIdsAndStartPage', 0, () => {
      const param: ComicReaderParam = new ComicReaderParam('book-1', 'chapter-1', '第 1 话', 4);
      expect(param.comicId).assertEqual('book-1');
      expect(param.chapterId).assertEqual('chapter-1');
      expect(param.startPage).assertEqual(4);
    });

    // ==================== 进度写入 ====================

    it('saveProgressStoresTotalPagesAndReturnsTrue', 0, async () => {
      await vm.loadChapter('book-1', 'chapter-1', 2);
      const ok: boolean = await vm.saveProgress('book-1', 'chapter-1', '第 1 话');
      expect(ok).assertTrue();
      expect(vm.progressSaveError).assertEqual('');
      const saved: HistoryRecord | null = await store.getHistoryForChapter('book-1', 'chapter-1');
      expect(saved !== null).assertTrue();
      if (saved !== null) {
        expect(saved.pageIndex).assertEqual(2);
        expect(saved.totalPages).assertEqual(3);
      }
    });

    it('saveProgressFailureReturnsFalseAndRecordsReason', 0, async () => {
      await vm.loadChapter('book-1', 'chapter-1');
      store.failOnSave = true;
      const ok: boolean = await vm.saveProgress('book-1', 'chapter-1', '第 1 话');
      expect(ok).assertFalse();
      expect(vm.progressSaveError.indexOf('模拟数据库写入失败') >= 0).assertTrue();
      expect(store.size()).assertEqual(0);
    });

    it('saveProgressSkipsEmptyChapterWithoutFakeSuccess', 0, async () => {
      const ok: boolean = await vm.saveProgress('book-1', 'chapter-1', '第 1 话');
      expect(ok).assertFalse();
      expect(store.saveCalls).assertEqual(0);
    });

    it('chapterProgressIsIsolatedAcrossVmInstances', 0, async () => {
      const vmA: ComicReaderViewModel = new ComicReaderViewModel(source, store);
      await vmA.loadChapter('book-1', 'chapter-1', 2);
      await vmA.saveProgress('book-1', 'chapter-1', '第 1 话');

      const vmB: ComicReaderViewModel = new ComicReaderViewModel(source, store);
      await vmB.loadChapter('book-1', 'chapter-2', 3);
      await vmB.saveProgress('book-1', 'chapter-2', '第 2 话');

      expect(store.size()).assertEqual(2);
      const a: HistoryRecord | null = await store.getHistoryForChapter('book-1', 'chapter-1');
      const b: HistoryRecord | null = await store.getHistoryForChapter('book-1', 'chapter-2');
      if (a !== null && b !== null) {
        expect(a.pageIndex).assertEqual(2);
        expect(b.pageIndex).assertEqual(3);
      }
    });
  });

  describe('ReadingStore', () => {
    let store: InMemoryReadingStore = new InMemoryReadingStore();

    beforeEach(() => {
      store = new InMemoryReadingStore();
    });

    it('insertThenGetHistory', 0, async () => {
      await store.saveHistory(record('b', 'c1', 3, 20, 1000));
      const found: HistoryRecord | null = await store.getHistoryForChapter('b', 'c1');
      expect(found !== null).assertTrue();
      if (found !== null) {
        expect(found.pageIndex).assertEqual(3);
        expect(found.totalPages).assertEqual(20);
      }
    });

    it('sameChapterUpdateIsIdempotent', 0, async () => {
      await store.saveHistory(record('b', 'c1', 3, 20, 1000));
      await store.saveHistory(record('b', 'c1', 9, 20, 2000));
      expect(store.size()).assertEqual(1);
      const found: HistoryRecord | null = await store.getHistoryForChapter('b', 'c1');
      if (found !== null) {
        expect(found.pageIndex).assertEqual(9);
      }
    });

    it('differentChaptersAreIsolated', 0, async () => {
      await store.saveHistory(record('b', 'c1', 3, 20, 1000));
      await store.saveHistory(record('b', 'c2', 7, 18, 2000));
      expect(store.size()).assertEqual(2);
      const histories: HistoryRecord[] = await store.getHistories('b');
      expect(histories.length).assertEqual(2);
    });

    it('pageRecoveryPerChapter', 0, async () => {
      await store.saveHistory(record('b', 'c1', 3, 20, 1000));
      await store.saveHistory(record('b', 'c2', 7, 18, 2000));
      const c1: HistoryRecord | null = await store.getHistoryForChapter('b', 'c1');
      const c2: HistoryRecord | null = await store.getHistoryForChapter('b', 'c2');
      if (c1 !== null && c2 !== null) {
        expect(c1.pageIndex).assertEqual(3);
        expect(c2.pageIndex).assertEqual(7);
      }
    });

    it('getHistoryReturnsMostRecentChapter', 0, async () => {
      await store.saveHistory(record('b', 'c1', 3, 20, 1000));
      await store.saveHistory(record('b', 'c2', 7, 18, 2000));
      const latest: HistoryRecord | null = await store.getHistory('b');
      expect(latest !== null).assertTrue();
      if (latest !== null) {
        expect(latest.chapterId).assertEqual('c2');
      }
    });

    it('saveHistoryRejectsMissingIds', 0, async () => {
      let threw: boolean = false;
      try {
        await store.saveHistory(record('', 'c1', 1, 1, 1));
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    // ===== 真实 DDL / 迁移 SQL 的静态回归（不依赖真机数据库） =====

    it('historyV2DdlHasCompositePrimaryKey', 0, () => {
      expect(HISTORY_V2_DDL.indexOf('PRIMARY KEY (comic_id, chapter_id)') >= 0).assertTrue();
      expect(HISTORY_V2_DDL.indexOf('total_pages INTEGER') >= 0).assertTrue();
      expect(HISTORY_V2_DDL.indexOf('IF NOT EXISTS') >= 0).assertTrue();
    });

    it('migrationSqlOnlyInsertsMissingRows', 0, () => {
      expect(HISTORY_V2_MIGRATION_SQL.indexOf('WHERE NOT EXISTS') >= 0).assertTrue();
      expect(HISTORY_V2_MIGRATION_SQL.indexOf('FROM History h') >= 0).assertTrue();
      expect(HISTORY_V2_MIGRATION_SQL.indexOf('INSERT INTO HistoryV2') >= 0).assertTrue();
      // 不得用 REPLACE 覆盖迁移后用户产生的新进度
      expect(HISTORY_V2_MIGRATION_SQL.indexOf('INSERT OR REPLACE') >= 0).assertFalse();
    });
  });
}
