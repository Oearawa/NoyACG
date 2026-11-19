/**
 * OfflineDownload.test.ets —— P2 下载队列并发、魔数原子落盘、缺图修复、空间阈值与全链路离线阅读回归测试
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { DownloadStatus, DownloadTask } from '../main/ets/model/DownloadTask';
import {
  ChapterImagePlanProvider,
  DownloadImagePort,
  DownloadToken,
  MIN_FREE_SPACE_BYTES
} from '../main/ets/download/DownloadPorts';
import { DownloadStorage } from '../main/ets/download/DownloadStorage';
import { DownloadManager } from '../main/ets/download/DownloadManager';
import { OfflineChapterSource } from '../main/ets/download/OfflineChapterSource';
import {
  CompositeChapterImageProvider,
  OnlineChapterImageProvider
} from '../main/ets/download/ChapterImageProvider';
import { ComicDetailViewModel, DetailState } from '../main/ets/viewmodel/ComicDetailViewModel';
import { ComicReaderViewModel } from '../main/ets/viewmodel/ComicReaderViewModel';
import { BOOK_MODE_SINGLE } from '../main/ets/model/ComicDetail';
import { CacheCleaner } from '../main/ets/utils/CacheCleaner';
import { HttpError } from '../main/ets/api/HttpManager';
import {
  MemoryDownloadRepository,
  SharedMemoryFs,
  StubDownloadControl,
  delay,
  derivedImageUrls
} from './DownloadStubs';
import { InMemoryReadingStore, StubAccountFavPort, StubDetailSource } from './DetailStubs';

/** 合法 PNG 魔数头（89 50 4E 47 0D 0A 1A 0A + payload） */
function validPngBytes(): Uint8Array {
  return new Uint8Array([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D]);
}

/** 伪装成 HTTP 200 的 HTML 错误页 */
function htmlErrorBytes(): Uint8Array {
  return new Uint8Array([0x3C, 0x68, 0x74, 0x6D, 0x6C, 0x3E, 0x34, 0x30, 0x33, 0x3C, 0x2F, 0x68]);
}

class LocalPlanProvider implements ChapterImagePlanProvider {
  urlsByKey: Record<string, string[]> = {};

  async getImageUrls(bookId: string, chapterId: string): Promise<string[]> {
    const key: string = `${bookId}/${chapterId}`;
    return this.urlsByKey[key] ?? [];
  }
}

class ValidatingMemoryFs extends SharedMemoryFs {
  mockFreeBytes: number = MIN_FREE_SPACE_BYTES * 4;

  async readHeader(path: string, maxBytes: number): Promise<Uint8Array | null> {
    const data: Uint8Array | undefined = this.files.get(path);
    if (data === undefined || data.length === 0) {
      return null;
    }
    const len: number = Math.min(data.length, maxBytes);
    return data.slice(0, len);
  }

  async availableBytes(_dirPath: string): Promise<number> {
    return this.mockFreeBytes;
  }
}

class CustomPayloadFetcher implements DownloadImagePort {
  fs: SharedMemoryFs;
  payloadByUrl: Map<string, Uint8Array> = new Map<string, Uint8Array>();
  fetchedUrls: string[] = [];
  activeCount: number = 0;
  maxObservedActive: number = 0;
  delayMs: number = 0;
  hangUrls: Set<string> = new Set<string>();
  canceledKeys: string[] = [];

  constructor(fs: SharedMemoryFs) {
    this.fs = fs;
  }

  async fetch(url: string, tempPath: string, _headers: Record<string, string>,
    token: DownloadToken): Promise<number> {
    this.fetchedUrls.push(url);
    this.activeCount++;
    if (this.activeCount > this.maxObservedActive) {
      this.maxObservedActive = this.activeCount;
    }
    try {
      if (this.hangUrls.has(url)) {
        while (!token.isCanceled) {
          await delay(10);
        }
        this.canceledKeys.push(token.key);
        throw new Error('canceled');
      }
      if (this.delayMs > 0) {
        await delay(this.delayMs);
      }
      const data: Uint8Array = this.payloadByUrl.get(url) ?? validPngBytes();
      const buf: ArrayBuffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
      return await this.fs.appendChunk(tempPath, buf);
    } finally {
      this.activeCount--;
    }
  }
}

export default function offlineDownloadTest() {
  describe('OfflineDownloadEngineP2', () => {
    let fs: ValidatingMemoryFs = new ValidatingMemoryFs();
    let storage: DownloadStorage = new DownloadStorage(fs, '/downloads');
    let repo: MemoryDownloadRepository = new MemoryDownloadRepository();
    let plan: LocalPlanProvider = new LocalPlanProvider();
    let fetcher: CustomPayloadFetcher = new CustomPayloadFetcher(fs);

    beforeEach(() => {
      fs = new ValidatingMemoryFs();
      storage = new DownloadStorage(fs, '/downloads');
      repo = new MemoryDownloadRepository();
      plan = new LocalPlanProvider();
      fetcher = new CustomPayloadFetcher(fs);
    });

    it('enforcesDualLayerConcurrencyAndFifoQueue', 0, async () => {
      fetcher.delayMs = 15;
      plan.urlsByKey['b1/c1'] = derivedImageUrls('b1', 'c1', 4);
      plan.urlsByKey['b1/c2'] = derivedImageUrls('b1', 'c2', 4);
      plan.urlsByKey['b1/c3'] = derivedImageUrls('b1', 'c3', 4);

      const manager: DownloadManager = new DownloadManager(plan, fetcher, storage, repo, {}, 3, 2);
      await manager.enqueue('b1', 'c1', 'Book', 'Ch1');
      await manager.enqueue('b1', 'c2', 'Book', 'Ch2');
      await manager.enqueue('b1', 'c3', 'Book', 'Ch3');

      // 3rd chapter must remain QUEUED while first 2 chapters are active
      const initial: DownloadTask[] = await manager.listTasks();
      const ch3Initial = initial.find((t: DownloadTask): boolean => t.chapterId === 'c3');
      expect(ch3Initial !== undefined && ch3Initial.status === DownloadStatus.QUEUED).assertTrue();

      for (let i = 0; i < 40; i++) {
        await delay(20);
        const list: DownloadTask[] = await manager.listTasks();
        if (list.every((t: DownloadTask): boolean => t.status === DownloadStatus.COMPLETED)) {
          break;
        }
      }

      expect(fetcher.maxObservedActive <= 3).assertTrue();
      const finalTasks: DownloadTask[] = await manager.listTasks();
      expect(finalTasks.every((t: DownloadTask): boolean => t.status === DownloadStatus.COMPLETED)).assertTrue();
      manager.dispose();
    });

    it('rejectsHtmlOrEmptyPayloadViaMagicBytesValidation', 0, async () => {
      const urls: string[] = derivedImageUrls('b1', 'c1', 2);
      plan.urlsByKey['b1/c1'] = urls;
      fetcher.payloadByUrl.set(urls[0], validPngBytes());
      fetcher.payloadByUrl.set(urls[1], htmlErrorBytes());

      const manager: DownloadManager = new DownloadManager(plan, fetcher, storage, repo, {}, 2, 2);
      await manager.enqueue('b1', 'c1', 'Book', 'Ch1');
      await delay(60);

      const task: DownloadTask | null = await repo.get('b1', 'c1');
      expect(task !== null).assertTrue();
      expect(task?.status).assertEqual(DownloadStatus.FAILED);
      expect(task?.completedImages).assertEqual(1);
      expect(await storage.hasImage('b1', 'c1', 1)).assertFalse();
      manager.dispose();
    });

    it('repairChapterDownloadsOnlyMissingAndCorruptedPages', 0, async () => {
      const urls: string[] = derivedImageUrls('b2', 'c1', 10);
      plan.urlsByKey['b2/c1'] = urls;

      const manager: DownloadManager = new DownloadManager(plan, fetcher, storage, repo, {}, 3, 2);
      await manager.enqueue('b2', 'c1', 'Book2', 'Ch1');
      await delay(80);
      expect((await repo.get('b2', 'c1'))?.status).assertEqual(DownloadStatus.COMPLETED);

      // Corrupt page 3 (index 2) with HTML and delete page 7 (index 6)
      const p3Path: string = storage.imagePath('b2', 'c1', 2, urls[2]);
      const p7Path: string = storage.imagePath('b2', 'c1', 6, urls[6]);
      fs.files.set(p3Path, htmlErrorBytes());
      fs.files.delete(p7Path);

      fetcher.fetchedUrls = [];
      const repaired: boolean = await manager.repairChapter('b2', 'c1');
      expect(repaired).assertTrue();
      await delay(80);

      expect(fetcher.fetchedUrls.length).assertEqual(2);
      expect(fetcher.fetchedUrls.indexOf(urls[2]) >= 0).assertTrue();
      expect(fetcher.fetchedUrls.indexOf(urls[6]) >= 0).assertTrue();
      expect((await repo.get('b2', 'c1'))?.status).assertEqual(DownloadStatus.COMPLETED);
      manager.dispose();
    });

    it('blocksOnInsufficientDiskSpaceAndCascadesDeleteBook', 0, async () => {
      plan.urlsByKey['b3/c1'] = derivedImageUrls('b3', 'c1', 2);
      const manager: DownloadManager = new DownloadManager(plan, fetcher, storage, repo, {}, 2, 2);

      fs.mockFreeBytes = MIN_FREE_SPACE_BYTES - 1024;
      let blocked: boolean = false;
      try {
        await manager.enqueue('b3', 'c1', 'Book3', 'Ch1');
      } catch (_e) {
        blocked = true;
      }
      expect(blocked).assertTrue();

      fs.mockFreeBytes = MIN_FREE_SPACE_BYTES * 2;
      await manager.enqueue('b3', 'c1', 'Book3', 'Ch1');
      await delay(50);
      expect((await manager.getBookSize('b3')) > 0).assertTrue();

      const removedCount: number = await manager.deleteBook('b3');
      expect(removedCount).assertEqual(1);
      expect(await manager.getBookSize('b3')).assertEqual(0);
      expect(await repo.get('b3', 'c1') === null).assertTrue();
      manager.dispose();
    });

    it('pauseAndCancelAbortInFlightTokens', 0, async () => {
      const urls: string[] = derivedImageUrls('b4', 'c1', 2);
      plan.urlsByKey['b4/c1'] = urls;
      fetcher.hangUrls.add(urls[0]);

      const manager: DownloadManager = new DownloadManager(plan, fetcher, storage, repo, {}, 2, 2);
      await manager.enqueue('b4', 'c1', 'Book4', 'Ch1');
      await delay(25);

      expect(manager.pause('b4', 'c1')).assertTrue();
      await delay(25);
      expect((await repo.get('b4', 'c1'))?.status).assertEqual(DownloadStatus.PAUSED);
      expect(fetcher.canceledKeys.length).assertEqual(1);
      manager.dispose();
    });
  });

  describe('OfflineReadingEndToEndLoop', () => {
    it('detailDegradesToOfflineChaptersAndReaderLoadsLocalFiles', 0, async () => {
      const fs: ValidatingMemoryFs = new ValidatingMemoryFs();
      const storage: DownloadStorage = new DownloadStorage(fs, '/downloads');
      const repo: MemoryDownloadRepository = new MemoryDownloadRepository();
      const plan: LocalPlanProvider = new LocalPlanProvider();
      const fetcher: CustomPayloadFetcher = new CustomPayloadFetcher(fs);
      plan.urlsByKey['999/10'] = derivedImageUrls('999', '10', 3);

      const manager: DownloadManager = new DownloadManager(plan, fetcher, storage, repo, {}, 2, 2);
      await manager.enqueue('999', '10', 'OfflineBook', 'Chapter 10');
      await delay(60);

      const controlStub: StubDownloadControl = new StubDownloadControl();
      controlStub.tasks = await manager.listTasks();

      const detailSource: StubDetailSource = new StubDetailSource();
      detailSource.error = new HttpError(503, 'offline');
      const store: InMemoryReadingStore = new InMemoryReadingStore();
      const detailVm: ComicDetailViewModel = new ComicDetailViewModel(
        detailSource, store, controlStub, new StubAccountFavPort()
      );

      await detailVm.loadDetail('999');
      expect(detailVm.state).assertEqual(DetailState.SUCCESS);
      expect(detailVm.isOfflineFallback).assertTrue();
      expect(detailVm.detail !== null && detailVm.detail.chapters.length === 1).assertTrue();
      expect(detailVm.isChapterDownloaded('10')).assertTrue();

      const offlineSource: OfflineChapterSource = new OfflineChapterSource(storage, repo);
      const composite: CompositeChapterImageProvider = new CompositeChapterImageProvider(
        offlineSource, new OnlineChapterImageProvider(detailSource)
      );
      const readerVm: ComicReaderViewModel = new ComicReaderViewModel(detailSource, store, composite);
      await readerVm.loadChapter('999', '10', 1);
      expect(readerVm.isOffline).assertTrue();
      expect(readerVm.totalCount).assertEqual(3);
      expect((readerVm.imageDataSource.getData(0) as string).indexOf('file://') === 0).assertTrue();

      // 跨页面阅读进度同步：模拟阅读器写入第 2 页进度后返回详情页重同步
      await store.saveHistory({
        comicId: '999',
        chapterId: '10',
        chapterTitle: 'Chapter 10',
        pageIndex: 2,
        totalPages: 3,
        updateTime: Date.now()
      });
      await detailVm.resyncProgressAndDownloadsOnReentry();
      expect(detailVm.historyPageIndex).assertEqual(2);
      expect(detailVm.isChapterDownloaded('10')).assertTrue();

      // 在线缓存清理隔离：清理 32 位 MD5 缓存文件不得删除离线下载章节文件
      await fs.ensureDir('/cache');
      const cacheMd5Path: string = '/cache/d41d8cd98f00b204e9800998ecf8427e.webp';
      fs.files.set(cacheMd5Path, validPngBytes());
      const cleaner: CacheCleaner = new CacheCleaner(
        fs,
        (name: string): boolean => /^[0-9a-f]{32}\./i.test(name),
        (_name: string): boolean => false,
        (_msg: string): void => {}
      );
      await cleaner.clear('/cache');
      await cleaner.clear('/downloads');
      expect(fs.files.has(cacheMd5Path)).assertFalse();
      expect(await storage.hasImage('999', '10', 0)).assertTrue();
      manager.dispose();
    });

    it('singleBookZeroCidOfflineFallbackRestoresSingleMode', 0, async () => {
      const fs: ValidatingMemoryFs = new ValidatingMemoryFs();
      const storage: DownloadStorage = new DownloadStorage(fs, '/downloads');
      const repo: MemoryDownloadRepository = new MemoryDownloadRepository();
      const plan: LocalPlanProvider = new LocalPlanProvider();
      const fetcher: CustomPayloadFetcher = new CustomPayloadFetcher(fs);
      plan.urlsByKey['888/0'] = derivedImageUrls('888', '0', 2);

      const manager: DownloadManager = new DownloadManager(plan, fetcher, storage, repo, {}, 2, 2);
      await manager.enqueue('888', '0', 'SingleDoujin', '');
      await delay(60);

      const controlStub: StubDownloadControl = new StubDownloadControl();
      controlStub.tasks = await manager.listTasks();
      const detailSource: StubDetailSource = new StubDetailSource();
      detailSource.error = new HttpError(503, 'offline');
      const detailVm: ComicDetailViewModel = new ComicDetailViewModel(
        detailSource, new InMemoryReadingStore(), controlStub, new StubAccountFavPort()
      );

      await detailVm.loadDetail('888');
      expect(detailVm.state).assertEqual(DetailState.SUCCESS);
      expect(detailVm.isOfflineFallback).assertTrue();
      expect(detailVm.detail !== null && detailVm.detail.mode === BOOK_MODE_SINGLE).assertTrue();
      expect(detailVm.displayChapterCount).assertEqual(1);
      expect(detailVm.isChapterDownloaded('0')).assertTrue();
      manager.dispose();
    });
  });
}
