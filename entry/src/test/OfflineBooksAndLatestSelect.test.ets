import { describe, it, expect } from '@ohos/hypium';
import { OFFLINE_BOOKS_ENTRY, ROUTE_OFFLINE_BOOKS } from '../main/ets/model/ProfileMenu';
import { DownloadStatus, DownloadTask, downloadTaskKey } from '../main/ets/model/DownloadTask';
import { DownloadStorage } from '../main/ets/download/DownloadStorage';
import { DownloadManager } from '../main/ets/download/DownloadManager';
import { OfflineChapterSource, OfflineChapterLookup } from '../main/ets/download/OfflineChapterSource';
import {
  MemoryDownloadRepository,
  MemoryImageFetcher,
  SharedMemoryFs,
  StubPlanProvider
} from './DownloadStubs';
import {
  DiskOfflineBook,
  OfflineBookGroup,
  aggregateOfflineBooks,
  aggregateOfflineBooksWithDisk,
  deleteAllOfflineResources,
  deleteOfflineBook,
  scanDiskOfflineBooks,
  sumOfflineBooksBytes
} from '../main/ets/utils/OfflineBooksHelper';
import { resolveHdsLightButtonTextColor } from '../main/ets/components/HdsLightButton';
import { LATEST_FINISHED_LABELS } from '../main/ets/components/LatestComponent';
import { formatSettingsCacheButtonLabel } from '../main/ets/pages/SettingsPage';
import {
  THEME_ACCENT_PALETTES,
  themeAccentByIndex,
  themeAccentIndex,
  themeAccentNames
} from '../main/ets/utils/ThemeAccent';
import { ThemeManager } from '../main/ets/utils/ThemeManager';

function makeTask(
  bookId: string,
  chapterId: string,
  status: DownloadStatus,
  updatedAt: number
): DownloadTask {
  const t: DownloadTask = new DownloadTask();
  t.taskId = downloadTaskKey(bookId, chapterId);
  t.bookId = bookId;
  t.chapterId = chapterId;
  t.bookTitle = `漫画_${bookId}`;
  t.chapterTitle = `第 ${chapterId} 话`;
  t.status = status;
  t.updatedAt = updatedAt;
  t.completedImages = 10;
  t.totalImages = 10;
  return t;
}

export default function offlineBooksAndLatestSelectTest() {
  describe('OfflineBooksAndLatestSelectTest', () => {
    it('profile_menu_has_offline_books_entry', 0, () => {
      expect(OFFLINE_BOOKS_ENTRY.route).assertEqual(ROUTE_OFFLINE_BOOKS);
      expect(ROUTE_OFFLINE_BOOKS).assertEqual('OfflineBooksPage');
      expect(OFFLINE_BOOKS_ENTRY.title).assertEqual('离线阅读');
    });

    it('aggregates_only_completed_chapters_by_book_and_sums_bytes', 0, () => {
      const tasks: DownloadTask[] = [
        makeTask('b1', 'c1', DownloadStatus.COMPLETED, 100),
        makeTask('b1', 'c2', DownloadStatus.COMPLETED, 200),
        makeTask('b1', 'c3', DownloadStatus.PAUSED, 300),
        makeTask('b2', 'c1', DownloadStatus.QUEUED, 400)
      ];
      const sizes: Record<string, number> = {
        'b1': 204800,
        'b2': 0
      };
      const groups: OfflineBookGroup[] = aggregateOfflineBooks(tasks, sizes);
      expect(groups.length).assertEqual(1);
      expect(groups[0].bookId).assertEqual('b1');
      expect(groups[0].chapters.length).assertEqual(2);
      expect(groups[0].totalBytes).assertEqual(204800);
      expect(sumOfflineBooksBytes(groups)).assertEqual(204800);
    });

    it('scans_disk_offline_books_even_when_tasks_empty_and_deletes_all', 0, async () => {
      const root: string = '/virtual/files/Downloads';
      const fs: SharedMemoryFs = new SharedMemoryFs();
      const storage: DownloadStorage = new DownloadStorage(fs, root);
      const repo: MemoryDownloadRepository = new MemoryDownloadRepository();
      const fetcher: MemoryImageFetcher = new MemoryImageFetcher(fs);
      const plan: StubPlanProvider = new StubPlanProvider();
      const manager: DownloadManager = new DownloadManager(plan, fetcher, storage, repo, {}, 2);
      const offlineSource: OfflineChapterSource = new OfflineChapterSource(storage, repo);

      // 模拟「清除记录」后数据库无任务，但磁盘上仍有两部漫画的离线图片
      await fs.ensureDir(`${root}/book100/ch1`);
      fs.files.set(`${root}/book100/ch1/000001.webp`, new Uint8Array(512));
      fs.files.set(`${root}/book100/ch1/000002.webp`, new Uint8Array(512));
      await fs.ensureDir(`${root}/book200/ch5`);
      fs.files.set(`${root}/book200/ch5/000001.jpg`, new Uint8Array(1024));

      const diskBooks: DiskOfflineBook[] = await scanDiskOfflineBooks(storage);
      expect(diskBooks.length).assertEqual(2);

      const groups: OfflineBookGroup[] = aggregateOfflineBooksWithDisk([], diskBooks);
      expect(groups.length).assertEqual(2);
      expect(sumOfflineBooksBytes(groups)).assertEqual(2048);

      // 无任务记录时，OfflineChapterSource 仍可离线读取磁盘图片
      const lookup: OfflineChapterLookup = await offlineSource.lookup('book100', 'ch1');
      expect(lookup.complete).assertTrue();
      expect(lookup.images.length).assertEqual(2);

      // 删除单部漫画
      await deleteOfflineBook(manager, 'book100');
      expect(await manager.getDownloadSize()).assertEqual(1024);

      // 一键删除全部离线资源
      const freed: number = await deleteAllOfflineResources(manager);
      expect(freed).assertEqual(1024);
      expect(await manager.getDownloadSize()).assertEqual(0);
      expect((await scanDiskOfflineBooks(storage)).length).assertEqual(0);
    });

    it('settings_neutral_button_uses_high_contrast_text_primary', 0, () => {
      const tm: ThemeManager = ThemeManager.getInstance();
      tm.applyMode('light');
      expect(resolveHdsLightButtonTextColor('neutral', true, tm)).assertEqual('#1E293B');
      tm.applyMode('dark');
      expect(resolveHdsLightButtonTextColor('neutral', true, tm)).assertEqual('#F1F5F9');
    });

    it('latest_finished_labels_omit_filter_prefix', 0, () => {
      expect(LATEST_FINISHED_LABELS.length).assertEqual(3);
      expect(LATEST_FINISHED_LABELS[0]).assertEqual('全部');
      expect(LATEST_FINISHED_LABELS[1]).assertEqual('连载中');
      expect(LATEST_FINISHED_LABELS[2]).assertEqual('已完结');
      for (let i = 0; i < LATEST_FINISHED_LABELS.length; i++) {
        expect(LATEST_FINISHED_LABELS[i].indexOf('筛选')).assertEqual(-1);
      }
    });

    it('settings_cache_label_omits_clear_prefix_and_theme_accent_dropdown_maps_all_6', 0, () => {
      const label: string = formatSettingsCacheButtonLabel(false, false, '3.28 MB');
      expect(label).assertEqual('3.28 MB');
      expect(label.indexOf('清理')).assertEqual(-1);
      expect(formatSettingsCacheButtonLabel(false, true, '3.28 MB')).assertEqual('计算中...');
      expect(formatSettingsCacheButtonLabel(true, false, '3.28 MB')).assertEqual('清理中...');

      const names: string[] = themeAccentNames();
      expect(names.length).assertEqual(6);
      for (let i = 0; i < THEME_ACCENT_PALETTES.length; i++) {
        const id = THEME_ACCENT_PALETTES[i].id;
        expect(themeAccentIndex(id)).assertEqual(i);
        expect(themeAccentByIndex(i)).assertEqual(id);
      }
    });
  });
}
