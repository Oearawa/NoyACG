/**
 * DownloadManager.test.ets —— Phase 12 调度器 / 持久化 / ViewModel 测试
 *
 * 全部使用内存端口（SharedMemoryFs / MemoryImageFetcher / MemoryDownloadRepository /
 * StubPlanProvider）；URL 是 stub.local 派生样例，不是真实章节响应。
 * Mock 只验证业务逻辑，不宣称验证了真机沙盒、SQLite 或 RCP 下载。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import {
  DownloadStatus,
  DownloadTask,
  canTransit,
  downloadTaskKey
} from '../main/ets/model/DownloadTask';
import { DownloadError, DownloadRecoveryReport, DownloadToken } from '../main/ets/download/DownloadPorts';
import { DownloadStorage } from '../main/ets/download/DownloadStorage';
import { DownloadManager } from '../main/ets/download/DownloadManager';
import { DownloadRepository } from '../main/ets/download/DownloadRepository';
import { DB_SCHEMA_VERSION, DOWNLOAD_TASK_DDL } from '../main/ets/utils/DatabaseManager';
import { DownloadViewModel } from '../main/ets/viewmodel/DownloadViewModel';
import {
  MemoryDownloadRepository,
  MemoryImageFetcher,
  SharedMemoryFs,
  StubDownloadControl,
  StubPlanProvider,
  delay,
  derivedImageUrls,
  waitForIdle
} from './DownloadStubs';

const ROOT: string = '/virtual/files/Downloads';

interface Harness {
  fs: SharedMemoryFs;
  storage: DownloadStorage;
  repo: MemoryDownloadRepository;
  fetcher: MemoryImageFetcher;
  plan: StubPlanProvider;
  manager: DownloadManager;
  repository: DownloadRepository;
}

function makeHarness(concurrency: number = 3): Harness {
  const fs: SharedMemoryFs = new SharedMemoryFs();
  const storage: DownloadStorage = new DownloadStorage(fs, ROOT);
  const repo: MemoryDownloadRepository = new MemoryDownloadRepository();
  const fetcher: MemoryImageFetcher = new MemoryImageFetcher(fs);
  const plan: StubPlanProvider = new StubPlanProvider();
  const manager: DownloadManager = new DownloadManager(plan, fetcher, storage,
    repo, {}, concurrency);
  const repository: DownloadRepository = new DownloadRepository(repo, storage);
  return { fs, storage, repo, fetcher, plan, manager, repository };
}

/** 完成一次成功下载并返回最终任务 */
async function downloadAll(h: Harness, bookId: string, chapterId: string,
  count: number): Promise<DownloadTask | null> {
  h.plan.urls = derivedImageUrls(bookId, chapterId, count);
  await h.manager.enqueue(bookId, chapterId, `书-${bookId}`, `章节-${chapterId}`);
  await waitForIdle(h.manager);
  return await h.repo.get(bookId, chapterId);
}

export default function downloadManagerTest() {
  describe('DownloadManager', () => {
    let h: Harness = makeHarness();

    beforeEach(() => {
      h = makeHarness();
    });

    // ==================== 入队与去重 ====================

    it('addTaskDownloadsAllImagesAndCompletes', 0, async () => {
      const task: DownloadTask | null = await downloadAll(h, 'b1', 'c1', 4);
      expect(task !== null).assertTrue();
      if (task !== null) {
        expect(task.status).assertEqual(DownloadStatus.COMPLETED);
        expect(task.totalImages).assertEqual(4);
        expect(task.completedImages).assertEqual(4);
        expect(task.failedImages).assertEqual(0);
        expect(task.progressPercent).assertEqual(100);
        expect(task.isComplete).assertTrue();
      }
      expect(h.fetcher.calls.length).assertEqual(4);
    });

    it('duplicateWhileRunningReturnsExistingTask', 0, async () => {
      h.plan.urls = derivedImageUrls('b1', 'c1', 3);
      h.fetcher.delayMs = 5;
      await h.manager.enqueue('b1', 'c1', '书', '章节');
      const second = await h.manager.enqueue('b1', 'c1', '书', '章节');
      expect(second.created).assertFalse();
      await waitForIdle(h.manager);
      expect(h.plan.calls.length).assertEqual(1);
      expect(h.fetcher.calls.length).assertEqual(3);
    });

    it('duplicateCompletedReturnsAlreadyDownloaded', 0, async () => {
      await downloadAll(h, 'b1', 'c1', 2);
      const again = await h.manager.enqueue('b1', 'c1', '书', '章节');
      expect(again.created).assertFalse();
      expect(again.reason.indexOf('已下载') >= 0).assertTrue();
      expect(h.fetcher.calls.length).assertEqual(2); // 不重复下载
    });

    it('duplicatePausedResumesExistingTask', 0, async () => {
      h.plan.urls = derivedImageUrls('b1', 'c1', 3);
      h.fetcher.delayMs = 20;
      await h.manager.enqueue('b1', 'c1', '书', '章节');
      await delay(3);
      h.manager.pause('b1', 'c1');
      await waitForIdle(h.manager);
      const paused: DownloadTask | null = await h.repo.get('b1', 'c1');
      expect(paused !== null && paused.status === DownloadStatus.PAUSED).assertTrue();

      const again = await h.manager.enqueue('b1', 'c1', '书', '章节');
      expect(again.created).assertFalse();
      expect(again.reason.indexOf('恢复') >= 0).assertTrue();
      await waitForIdle(h.manager);
    });

    it('duplicateFailedAllowsRequeue', 0, async () => {
      h.plan.urls = derivedImageUrls('b1', 'c1', 2);
      h.fetcher.failUrls.add(h.plan.urls[0]);
      await h.manager.enqueue('b1', 'c1', '书', '章节');
      await waitForIdle(h.manager);
      const failed: DownloadTask | null = await h.repo.get('b1', 'c1');
      expect(failed !== null && failed.status === DownloadStatus.FAILED).assertTrue();

      h.fetcher.failUrls.clear();
      const again = await h.manager.enqueue('b1', 'c1', '书', '章节');
      expect(again.created).assertTrue();
      await waitForIdle(h.manager);
      const done: DownloadTask | null = await h.repo.get('b1', 'c1');
      expect(done !== null && done.status === DownloadStatus.COMPLETED).assertTrue();
    });

    it('duplicateCanceledAllowsRecreate', 0, async () => {
      await downloadAll(h, 'b1', 'c1', 1);
      // 手动把状态置为 CANCELED 模拟用户取消记录
      const finished: DownloadTask | null = await h.repo.get('b1', 'c1');
      if (finished !== null) {
        finished.status = DownloadStatus.CANCELED;
        await h.repo.upsert(finished);
      }
      const again = await h.manager.enqueue('b1', 'c1', '书', '章节');
      expect(again.created).assertTrue();
      await waitForIdle(h.manager);
    });

    it('differentBookSameChapterIdStoredSeparately', 0, async () => {
      await downloadAll(h, 'book-A', 'same-id', 1);
      await downloadAll(h, 'book-B', 'same-id', 1);
      expect(h.repo.rows.size).assertEqual(2);
      const a: DownloadTask | null = await h.repo.get('book-A', 'same-id');
      const b: DownloadTask | null = await h.repo.get('book-B', 'same-id');
      expect(a !== null && b !== null).assertTrue();
      expect(downloadTaskKey('book-A', 'same-id') === downloadTaskKey('book-B', 'same-id'))
        .assertFalse();
    });

    // ==================== 并发调度 ====================

    it('globalConcurrencyLimitIsRespected', 0, async () => {
      h.manager.setConcurrency(2);
      h.fetcher.delayMs = 8;
      await downloadAll(h, 'b1', 'c1', 10);
      expect(h.manager.getConcurrency()).assertEqual(2);
      expect(h.fetcher.maxInFlight <= 2).assertTrue();
      expect(h.fetcher.maxInFlight > 0).assertTrue();
    });

    it('multipleChaptersShareOneBoundedQueue', 0, async () => {
      h.manager.setConcurrency(3);
      h.fetcher.delayMs = 5;
      h.plan.urls = derivedImageUrls('b1', 'c1', 4);
      await h.manager.enqueue('b1', 'c1', '书', '第 1 章');
      await h.manager.enqueue('b1', 'c2', '书', '第 2 章');
      await waitForIdle(h.manager);
      expect(h.fetcher.maxInFlight <= 3).assertTrue();
      expect(h.repo.rows.size).assertEqual(2);
    });

    it('concurrencyIsClampedToSafeRange', 0, () => {
      h.manager.setConcurrency(99);
      expect(h.manager.getConcurrency()).assertEqual(6);
      h.manager.setConcurrency(0);
      expect(h.manager.getConcurrency()).assertEqual(1);
    });

    // ==================== 暂停 / 恢复 / 取消 / 重试 ====================

    it('pauseCancelsInFlightRequests', 0, async () => {
      h.plan.urls = derivedImageUrls('b1', 'c1', 6);
      h.fetcher.delayMs = 40;
      await h.manager.enqueue('b1', 'c1', '书', '章节');
      await delay(5); // 让请求处于在途状态
      expect(h.manager.pause('b1', 'c1')).assertTrue();
      await waitForIdle(h.manager);
      expect(h.fetcher.canceledUrls.length > 0).assertTrue(); // 真正触发了取消动作
      const task: DownloadTask | null = await h.repo.get('b1', 'c1');
      expect(task !== null && task.status === DownloadStatus.PAUSED).assertTrue();
    });

    it('resumeSkipsAlreadySavedImages', 0, async () => {
      const urls: string[] = derivedImageUrls('b1', 'c1', 4);
      // 确定性构造：前 2 张已在磁盘上（模拟上次下载已完成的图片）
      for (let i = 0; i < 2; i++) {
        await h.storage.saveImage(urls[i], 'b1', 'c1', i,
          h.fetcher, new DownloadToken(`seed${i}`), {});
      }
      const seedCalls: number = h.fetcher.calls.length;
      h.plan.urls = urls;
      await h.manager.enqueue('b1', 'c1', '书', '章节');
      await waitForIdle(h.manager);
      // 只请求缺失的 2 张，绝不重复下载已完整保存的图片
      expect(h.fetcher.calls.length - seedCalls).assertEqual(2);
      const task: DownloadTask | null = await h.repo.get('b1', 'c1');
      expect(task !== null && task.status === DownloadStatus.COMPLETED).assertTrue();
      if (task !== null) {
        expect(task.completedImages).assertEqual(4);
      }
    });

    it('pauseThenResumeReachesCompleted', 0, async () => {
      h.plan.urls = derivedImageUrls('b1', 'c1', 3);
      h.fetcher.delayMs = 20;
      await h.manager.enqueue('b1', 'c1', '书', '章节');
      await delay(5);
      h.manager.pause('b1', 'c1');
      await waitForIdle(h.manager);
      const paused: DownloadTask | null = await h.repo.get('b1', 'c1');
      expect(paused !== null && paused.status === DownloadStatus.PAUSED).assertTrue();

      h.fetcher.delayMs = 0;
      expect(await h.manager.resume('b1', 'c1')).assertTrue();
      await waitForIdle(h.manager);
      const done: DownloadTask | null = await h.repo.get('b1', 'c1');
      expect(done !== null && done.status === DownloadStatus.COMPLETED).assertTrue();
    });

    it('cancelPreservesAlreadyDownloadedFiles', 0, async () => {
      h.plan.urls = derivedImageUrls('b1', 'c1', 5);
      h.fetcher.delayMs = 20;
      await h.manager.enqueue('b1', 'c1', '书', '章节');
      await delay(25);
      h.manager.cancel('b1', 'c1');
      await waitForIdle(h.manager);
      const task: DownloadTask | null = await h.repo.get('b1', 'c1');
      expect(task !== null && task.status === DownloadStatus.CANCELED).assertTrue();
      const entries = await h.storage.listChapterImages('b1', 'c1');
      expect(entries.length > 0).assertTrue(); // 已完成图片保留
    });

    it('cancelAllPendingStopsEveryTask', 0, async () => {
      h.plan.urls = derivedImageUrls('b1', 'c1', 5);
      h.fetcher.delayMs = 20;
      await h.manager.enqueue('b1', 'c1', '书', '章节1');
      await h.manager.enqueue('b1', 'c2', '书', '章节2');
      const count: number = h.manager.cancelAllPending();
      expect(count).assertEqual(2);
      await waitForIdle(h.manager);
      const a: DownloadTask | null = await h.repo.get('b1', 'c1');
      const b: DownloadTask | null = await h.repo.get('b1', 'c2');
      expect(a !== null && a.status === DownloadStatus.CANCELED).assertTrue();
      expect(b !== null && b.status === DownloadStatus.CANCELED).assertTrue();
    });

    it('retryRecoversFailedTask', 0, async () => {
      h.plan.urls = derivedImageUrls('b1', 'c1', 2);
      h.fetcher.failUrls.add(h.plan.urls[1]);
      await h.manager.enqueue('b1', 'c1', '书', '章节');
      await waitForIdle(h.manager);
      h.fetcher.failUrls.clear();
      expect(await h.manager.retry('b1', 'c1')).assertTrue();
      await waitForIdle(h.manager);
      const task: DownloadTask | null = await h.repo.get('b1', 'c1');
      expect(task !== null && task.status === DownloadStatus.COMPLETED).assertTrue();
    });

    // ==================== 失败隔离 ====================

    it('partialImageFailureMarksTaskFailedWithCounts', 0, async () => {
      h.plan.urls = derivedImageUrls('b1', 'c1', 4);
      h.fetcher.failUrls.add(h.plan.urls[2]);
      await h.manager.enqueue('b1', 'c1', '书', '章节');
      await waitForIdle(h.manager);
      const task: DownloadTask | null = await h.repo.get('b1', 'c1');
      expect(task !== null && task.status === DownloadStatus.FAILED).assertTrue();
      if (task !== null) {
        expect(task.completedImages).assertEqual(3);
        expect(task.failedImages).assertEqual(1);
        expect(task.lastError !== '').assertTrue();
      }
    });

    it('allImagesFailMarksTaskFailed', 0, async () => {
      h.plan.urls = derivedImageUrls('b1', 'c1', 3);
      for (let i = 0; i < 3; i++) {
        h.fetcher.failUrls.add(h.plan.urls[i]);
      }
      await h.manager.enqueue('b1', 'c1', '书', '章节');
      await waitForIdle(h.manager);
      const task: DownloadTask | null = await h.repo.get('b1', 'c1');
      expect(task !== null && task.status === DownloadStatus.FAILED).assertTrue();
      if (task !== null) {
        expect(task.completedImages).assertEqual(0);
      }
    });

    it('singleChapterFailureDoesNotCorruptOtherChapter', 0, async () => {
      h.plan.urls = derivedImageUrls('b1', 'ok', 2);
      await h.manager.enqueue('b1', 'ok', '书', '正常章节');
      await waitForIdle(h.manager);
      h.plan.urls = derivedImageUrls('b1', 'bad', 2);
      h.fetcher.failUrls.add(h.plan.urls[0]);
      h.fetcher.failUrls.add(h.plan.urls[1]);
      await h.manager.enqueue('b1', 'bad', '书', '失败章节');
      await waitForIdle(h.manager);
      const ok: DownloadTask | null = await h.repo.get('b1', 'ok');
      const bad: DownloadTask | null = await h.repo.get('b1', 'bad');
      expect(ok !== null && ok.status === DownloadStatus.COMPLETED).assertTrue();
      expect(bad !== null && bad.status === DownloadStatus.FAILED).assertTrue();
    });

    it('planProviderErrorMarksTaskFailed', 0, async () => {
      // 桩抛出的不是真实线上响应，只验证异常分支
      h.plan.urls = [];
      await h.manager.enqueue('b1', 'c1', '书', '章节');
      await waitForIdle(h.manager);
      const task: DownloadTask | null = await h.repo.get('b1', 'c1');
      expect(task !== null && task.status === DownloadStatus.FAILED).assertTrue();
      if (task !== null) {
        expect(task.lastError.indexOf('清单') >= 0).assertTrue();
      }
    });

    // ==================== 生命周期与持久化失败 ====================

    it('enqueueAfterDisposeIsRejected', 0, async () => {
      h.manager.dispose();
      let threw: boolean = false;
      try {
        await h.manager.enqueue('b1', 'c1', '书', '章节');
      } catch (e) {
        threw = e instanceof DownloadError;
      }
      expect(threw).assertTrue();
    });

    it('disposeKeepsInterruptedTaskRecoverableNotFinalized', 0, async () => {
      // 模拟应用异常退出：任务正在下载，dispose 后 in-flight 作业陆续结束。
      // 修复前：runJob 的 finally 会走 maybeFinalize 把任务误判为 FAILED（甚至 COMPLETED），
      // 违背「保留 DOWNLOADING 交 recover 归位 INCOMPLETE」的承诺。
      h.plan.urls = derivedImageUrls('b1', 'c1', 3);
      h.fetcher.delayMs = 60;
      await h.manager.enqueue('b1', 'c1', '书', '章节');
      await delay(10); // 让 prepare 完成、3 个图片作业进入在途
      h.manager.dispose();
      await delay(120); // 等待所有在途作业真正结束（抛 DownloadInterrupted）

      const task: DownloadTask | null = await h.repo.get('b1', 'c1');
      expect(task !== null).assertTrue();
      if (task !== null) {
        // 必须保持活跃/可恢复状态，绝不误判成 FAILED 或 COMPLETED
        expect(task.status === DownloadStatus.DOWNLOADING
          || task.status === DownloadStatus.PREPARING
          || task.status === DownloadStatus.QUEUED).assertTrue();
      }

      // 重启恢复应把异常终止任务归位为 INCOMPLETE（可继续）
      const report: DownloadRecoveryReport = await h.repository.recover();
      expect(report.interrupted >= 1).assertTrue();
      const recovered: DownloadTask | null = await h.repo.get('b1', 'c1');
      expect(recovered !== null && recovered.status === DownloadStatus.INCOMPLETE)
        .assertTrue();
    });

    it('persistFailureIsRecordedNotFaked', 0, async () => {
      h.repo.failOnUpsert = true;
      await downloadAll(h, 'b1', 'c1', 1);
      expect(h.manager.lastPersistError !== '').assertTrue();
    });

    it('taskKeyUsesBothIds', 0, () => {
      expect(downloadTaskKey('b', 'c')).assertEqual('b/c');
      expect(downloadTaskKey('b1', 'c') === downloadTaskKey('b2', 'c')).assertFalse();
    });

    it('statusTransitionRulesAreEnforced', 0, () => {
      expect(canTransit(DownloadStatus.QUEUED, DownloadStatus.PREPARING)).assertTrue();
      expect(canTransit(DownloadStatus.DOWNLOADING, DownloadStatus.COMPLETED)).assertTrue();
      expect(canTransit(DownloadStatus.COMPLETED, DownloadStatus.DOWNLOADING)).assertFalse();
      expect(canTransit(DownloadStatus.PAUSED, DownloadStatus.QUEUED)).assertTrue();
      expect(canTransit(DownloadStatus.QUEUED, DownloadStatus.COMPLETED)).assertFalse();
      expect(canTransit(DownloadStatus.COMPLETED, DownloadStatus.COMPLETED)).assertFalse();
    });
  });

  describe('DownloadRepository', () => {
    let fs: SharedMemoryFs = new SharedMemoryFs();
    let storage: DownloadStorage = new DownloadStorage(fs, ROOT);
    let repo: MemoryDownloadRepository = new MemoryDownloadRepository();
    let repository: DownloadRepository = new DownloadRepository(repo, storage);

    beforeEach(() => {
      fs = new SharedMemoryFs();
      storage = new DownloadStorage(fs, ROOT);
      repo = new MemoryDownloadRepository();
      repository = new DownloadRepository(repo, storage);
    });

    it('insertUpdateDeleteAndQueryTask', 0, async () => {
      const task: DownloadTask = new DownloadTask('b', 'c', '书', '章节');
      task.status = DownloadStatus.QUEUED;
      await repository.upsert(task);
      const found: DownloadTask | null = await repository.get('b', 'c');
      expect(found !== null).assertTrue();
      if (found !== null) {
        found.status = DownloadStatus.DOWNLOADING;
        found.completedImages = 2;
        await repository.upsert(found);
      }
      const updated: DownloadTask | null = await repository.get('b', 'c');
      expect(updated !== null && updated.completedImages === 2).assertTrue();
      await repository.removeRecord('b', 'c');
      expect(await repository.get('b', 'c') === null).assertTrue();
    });

    it('taskUniquenessUsesCompositeKey', 0, async () => {
      for (const bookId of ['b1', 'b2']) {
        const task: DownloadTask = new DownloadTask(bookId, 'same', '书', '章节');
        await repository.upsert(task);
        await repository.upsert(task); // 同键重复写入
      }
      expect(repo.rows.size).assertEqual(2);
    });

    it('clearFinishedRemovesOnlyRecords', 0, async () => {
      for (const status of [DownloadStatus.COMPLETED, DownloadStatus.CANCELED,
        DownloadStatus.FAILED]) {
        const task: DownloadTask = new DownloadTask('b', `c-${status}`, '书', '章节');
        task.status = status;
        await repository.upsert(task);
      }
      expect(await repository.clearFinishedRecords()).assertEqual(2);
      expect((await repository.list()).length).assertEqual(1);
    });

    it('recoveryConvertsInterruptedTasksToIncomplete', 0, async () => {
      const task: DownloadTask = new DownloadTask('b', 'c', '书', '章节');
      task.status = DownloadStatus.DOWNLOADING;
      task.totalImages = 2;
      task.completedImages = 1;
      repo.seed(task);
      const report: DownloadRecoveryReport = await repository.recover();
      expect(report.interrupted).assertEqual(1);
      expect(report.resumable >= 1).assertTrue();
      const recovered: DownloadTask | null = await repository.get('b', 'c');
      expect(recovered !== null && recovered.status === DownloadStatus.INCOMPLETE).assertTrue();
    });

    it('recoveryRecountsCompletedImagesFromFiles', 0, async () => {
      for (let i = 0; i < 2; i++) {
        fs.seedFile(storage.imagePath('b', 'c', i, 'https://stub.local/x.webp'), 10);
      }
      const task: DownloadTask = new DownloadTask('b', 'c', '书', '章节');
      task.status = DownloadStatus.DOWNLOADING;
      task.totalImages = 3;
      task.completedImages = 1; // 内存中的旧计数不可信
      repo.seed(task);
      await repository.recover();
      const recovered: DownloadTask | null = await repository.get('b', 'c');
      expect(recovered !== null && recovered.completedImages === 2).assertTrue();
    });

    it('recoveryDowngradesCompletedWithMissingFiles', 0, async () => {
      const task: DownloadTask = new DownloadTask('b', 'c', '书', '章节');
      task.status = DownloadStatus.COMPLETED;
      task.totalImages = 2;
      task.completedImages = 2;
      repo.seed(task); // 磁盘上一个文件都没有
      const report: DownloadRecoveryReport = await repository.recover();
      expect(report.incomplete >= 1).assertTrue();
      const recovered: DownloadTask | null = await repository.get('b', 'c');
      expect(recovered !== null && recovered.status === DownloadStatus.INCOMPLETE).assertTrue();
    });

    it('recoveryKeepsValidCompletedChapter', 0, async () => {
      for (let i = 0; i < 2; i++) {
        fs.seedFile(storage.imagePath('b', 'c', i, 'https://stub.local/x.webp'), 10);
      }
      const task: DownloadTask = new DownloadTask('b', 'c', '书', '章节');
      task.status = DownloadStatus.COMPLETED;
      task.totalImages = 2;
      task.completedImages = 2;
      repo.seed(task);
      const report: DownloadRecoveryReport = await repository.recover();
      expect(report.completedVerified).assertEqual(1);
      const recovered: DownloadTask | null = await repository.get('b', 'c');
      expect(recovered !== null && recovered.status === DownloadStatus.COMPLETED).assertTrue();
    });

    it('migrationDdlIsIdempotentAndNonDestructive', 0, () => {
      expect(DOWNLOAD_TASK_DDL.indexOf('IF NOT EXISTS') >= 0).assertTrue();
      expect(DOWNLOAD_TASK_DDL.indexOf('PRIMARY KEY (book_id, chapter_id)') >= 0).assertTrue();
      expect(DOWNLOAD_TASK_DDL.indexOf('DROP') >= 0).assertFalse();
      expect(DOWNLOAD_TASK_DDL.indexOf('ALTER') >= 0).assertFalse();
      expect(DB_SCHEMA_VERSION >= 3).assertTrue();
    });
  });

  describe('DownloadViewModel', () => {
    let control: StubDownloadControl = new StubDownloadControl();
    let vm: DownloadViewModel = new DownloadViewModel(control, undefined);

    beforeEach(() => {
      control = new StubDownloadControl();
      vm = new DownloadViewModel(control, undefined);
    });

    it('groupsTasksByStatus', 0, async () => {
      for (const status of [DownloadStatus.QUEUED, DownloadStatus.PAUSED,
        DownloadStatus.FAILED, DownloadStatus.COMPLETED, DownloadStatus.INCOMPLETE]) {
        const task: DownloadTask = new DownloadTask('b', `c-${status}`, '书', '章节');
        task.status = status;
        control.tasks.push(task);
      }
      control.size = 1234;
      await vm.initialize();
      expect(vm.queuedTasks.length).assertEqual(1);
      expect(vm.pausedTasks.length).assertEqual(1);
      expect(vm.failedTasks.length).assertEqual(1);
      expect(vm.completedTasks.length).assertEqual(1);
      expect(vm.incompleteTasks.length).assertEqual(1);
      expect(vm.downloadSizeBytes).assertEqual(1234);
      expect(vm.isRecovered).assertTrue();
    });

    it('disposeStopsStateUpdates', 0, async () => {
      vm.dispose();
      control.tasks.push(new DownloadTask('b', 'c', '书', '章节'));
      await vm.refresh();
      expect(vm.tasks.length).assertEqual(0);
      expect(control.listeners.length).assertEqual(0);
    });

    it('refreshFailureSurfacesError', 0, async () => {
      control.listShouldThrow = true;
      await vm.refresh();
      expect(vm.errorMessage.indexOf('读取下载任务失败') >= 0).assertTrue();
    });

    it('deleteDistinguishesFilesFromRecords', 0, async () => {
      const task: DownloadTask = new DownloadTask('b', 'c', '书', '章节');
      await vm.deleteChapter(task, false);
      expect(control.deleteWithFiles).assertFalse();
      await vm.deleteChapter(task, true);
      expect(control.deleteWithFiles).assertTrue();
      expect(control.deleted.length).assertEqual(2);
    });

    it('downloadSizeIsIndependentFromCacheSize', 0, async () => {
      control.size = 4096;
      await vm.initialize();
      expect(vm.downloadSizeBytes).assertEqual(4096);
      expect(vm.formattedDownloadSize().indexOf('4.0') >= 0
        || vm.formattedDownloadSize().indexOf('4096') >= 0).assertTrue();
    });
  });
}
