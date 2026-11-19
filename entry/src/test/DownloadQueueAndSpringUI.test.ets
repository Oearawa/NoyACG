import { describe, it, expect } from '@ohos/hypium';
import { DownloadStatus, DownloadTask, downloadTaskKey } from '../main/ets/model/DownloadTask';
import { DownloadStorage } from '../main/ets/download/DownloadStorage';
import { DownloadManager } from '../main/ets/download/DownloadManager';
import {
  MemoryDownloadRepository,
  MemoryImageFetcher,
  SharedMemoryFs,
  StubPlanProvider
} from './DownloadStubs';
import {
  resolveHdsLightButtonBgColor,
  resolveHdsLightButtonTextColor
} from '../main/ets/components/HdsLightButton';
import {
  SPRING_DISABLED_OPACITY,
  SPRING_DOWN_DAMPING,
  SPRING_DOWN_RESPONSE,
  SPRING_PRESS_OPACITY,
  SPRING_PRESS_SCALE,
  SPRING_UP_DAMPING,
  SPRING_UP_RESPONSE,
  springPressOpacity,
  springPressScale
} from '../main/ets/utils/SpringMotion';
import { ThemeManager } from '../main/ets/utils/ThemeManager';

function makeTask(bookId: string, chapterId: string, status: DownloadStatus): DownloadTask {
  const t: DownloadTask = new DownloadTask();
  t.taskId = downloadTaskKey(bookId, chapterId);
  t.bookId = bookId;
  t.chapterId = chapterId;
  t.bookTitle = `Book ${bookId}`;
  t.chapterTitle = `Chapter ${chapterId}`;
  t.status = status;
  return t;
}

export default function downloadQueueAndSpringUITest() {
  describe('DownloadQueueAndSpringUITest', () => {
    it('pauseAllTasks_and_cancelAllPendingTasks_handle_persisted_repo_tasks', 0, async () => {
      const fs: SharedMemoryFs = new SharedMemoryFs();
      const storage: DownloadStorage = new DownloadStorage(fs, '/virtual/files/Downloads');
      const repo: MemoryDownloadRepository = new MemoryDownloadRepository();
      const fetcher: MemoryImageFetcher = new MemoryImageFetcher(fs);
      const plan: StubPlanProvider = new StubPlanProvider();
      const manager: DownloadManager = new DownloadManager(plan, fetcher, storage, repo, {}, 2);

      await repo.upsert(makeTask('b1', 'c1', DownloadStatus.QUEUED));
      await repo.upsert(makeTask('b1', 'c2', DownloadStatus.DOWNLOADING));
      await repo.upsert(makeTask('b1', 'c3', DownloadStatus.PAUSED));
      await repo.upsert(makeTask('b1', 'c4', DownloadStatus.COMPLETED));

      const pausedCount: number = await manager.pauseAllTasks();
      expect(pausedCount).assertEqual(2);
      const c1: DownloadTask | null = await repo.get('b1', 'c1');
      expect(c1 !== null && c1.status === DownloadStatus.PAUSED).assertTrue();

      const singlePausedOk: boolean = await manager.pauseTask('b1', 'c1');
      expect(singlePausedOk).assertFalse();

      const canceledCount: number = await manager.cancelAllPendingTasks();
      expect(canceledCount).assertEqual(3);

      const remaining: DownloadTask[] = await repo.list();
      expect(remaining.length).assertEqual(1);
      expect(remaining[0].chapterId).assertEqual('c4');
      expect(remaining[0].status).assertEqual(DownloadStatus.COMPLETED);
    });

    it('cancelTask_removes_single_persisted_pending_task', 0, async () => {
      const fs: SharedMemoryFs = new SharedMemoryFs();
      const storage: DownloadStorage = new DownloadStorage(fs, '/virtual/files/Downloads');
      const repo: MemoryDownloadRepository = new MemoryDownloadRepository();
      const fetcher: MemoryImageFetcher = new MemoryImageFetcher(fs);
      const plan: StubPlanProvider = new StubPlanProvider();
      const manager: DownloadManager = new DownloadManager(plan, fetcher, storage, repo, {}, 2);

      await repo.upsert(makeTask('b2', 'c1', DownloadStatus.QUEUED));
      const ok: boolean = await manager.cancelTask('b2', 'c1');
      expect(ok).assertTrue();
      const after: DownloadTask | null = await repo.get('b2', 'c1');
      expect(after === null).assertTrue();
    });

    it('hds_light_button_danger_and_neutral_colors_are_high_contrast', 0, () => {
      const tm: ThemeManager = ThemeManager.getInstance();
      tm.applyMode('light');
      expect(resolveHdsLightButtonBgColor('neutral', tm)).assertEqual('#EEF2F6');
      expect(resolveHdsLightButtonTextColor('neutral', true, tm)).assertEqual('#1E293B');
      expect(resolveHdsLightButtonBgColor('danger', tm)).assertEqual('#FEE2E2');
      expect(resolveHdsLightButtonTextColor('danger', true, tm)).assertEqual('#DC2626');

      tm.applyMode('dark');
      expect(resolveHdsLightButtonBgColor('neutral', tm)).assertEqual('#252A36');
      expect(resolveHdsLightButtonTextColor('neutral', true, tm)).assertEqual('#F1F5F9');
      expect(resolveHdsLightButtonBgColor('danger', tm)).assertEqual('#3B1D22');
      expect(resolveHdsLightButtonTextColor('danger', true, tm)).assertEqual('#F87171');
    });

    it('spring_motion_constants_and_helpers_are_valid', 0, () => {
      expect(SPRING_PRESS_SCALE).assertEqual(0.94);
      expect(SPRING_PRESS_OPACITY).assertEqual(0.88);
      expect(SPRING_DISABLED_OPACITY).assertEqual(0.45);
      expect(SPRING_DOWN_RESPONSE).assertEqual(0.26);
      expect(SPRING_DOWN_DAMPING).assertEqual(0.85);
      expect(SPRING_UP_RESPONSE).assertEqual(0.34);
      expect(SPRING_UP_DAMPING).assertEqual(0.70);

      expect(springPressScale(true, true)).assertEqual(0.94);
      expect(springPressScale(false, true)).assertEqual(1.0);
      expect(springPressScale(true, false)).assertEqual(1.0);
      expect(springPressOpacity(true, true)).assertEqual(0.88);
      expect(springPressOpacity(false, true)).assertEqual(1.0);
      expect(springPressOpacity(false, false)).assertEqual(0.45);
    });
  });
}
