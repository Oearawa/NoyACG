/**
 * DownloadStorage.test.ets —— Phase 12 文件存储与缓存隔离测试
 *
 * 全部使用 `SharedMemoryFs`（同时实现 CacheFsPort + DownloadFsPort 的内存桩），
 * **不写真机沙盒**；派生 URL 均为 stub.local，不是真实章节响应。
 * 缓存隔离部分用同一个 FS 实例同时放「临时缓存」与「永久下载」，
 * 真实验证清理一侧不影响另一侧。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { CacheCleaner } from '../main/ets/utils/CacheCleaner';
import { ImageCacheManager } from '../main/ets/utils/ImageCacheManager';
import {
  ChapterVerifyResult,
  DownloadStorage,
  OfflineImageEntry,
  fileUriOf,
  imageExtension,
  pageStem,
  safePathSegment
} from '../main/ets/download/DownloadStorage';
import { DOWNLOAD_TEMP_SUFFIX, DownloadInterrupted, DownloadToken } from '../main/ets/download/DownloadPorts';
import { DownloadStatus, DownloadTask } from '../main/ets/model/DownloadTask';
import { OfflineChapterSource } from '../main/ets/download/OfflineChapterSource';
import {
  MemoryDownloadRepository,
  MemoryImageFetcher,
  SharedMemoryFs,
  derivedImageUrls
} from './DownloadStubs';

const ROOT: string = '/virtual/files/Downloads';
const CACHE: string = '/virtual/cache';

export default function downloadStorageTest() {
  describe('DownloadStorage', () => {
    let fs: SharedMemoryFs = new SharedMemoryFs();
    let storage: DownloadStorage = new DownloadStorage(fs, ROOT);
    let fetcher: MemoryImageFetcher = new MemoryImageFetcher(fs);

    beforeEach(() => {
      fs = new SharedMemoryFs();
      storage = new DownloadStorage(fs, ROOT);
      fetcher = new MemoryImageFetcher(fs);
    });

    // ==================== 路径与命名 ====================

    it('chapterDirUsesBothBookAndChapterIds', 0, () => {
      expect(storage.chapterDir('book-1', 'c1')).assertEqual(`${ROOT}/book-1/c1`);
      expect(storage.chapterDir('book-2', 'c1') === storage.chapterDir('book-1', 'c1'))
        .assertFalse();
    });

    it('safePathSegmentRejectsTraversal', 0, () => {
      expect(safePathSegment('../../etc/passwd')).assertEqual('______etc_passwd');
      expect(safePathSegment('')).assertEqual('unknown');
      expect(safePathSegment('abc-123_XY')).assertEqual('abc-123_XY');
    });

    it('pageStemIsZeroPaddedAndStable', 0, () => {
      expect(pageStem(0)).assertEqual('000001');
      expect(pageStem(9)).assertEqual('000010');
      expect(pageStem(999)).assertEqual('001000');
    });

    it('imagePathKeepsStableOrderMapping', 0, () => {
      const p1: string = storage.imagePath('b', 'c', 0, 'https://stub.local/1.webp');
      const p10: string = storage.imagePath('b', 'c', 9, 'https://stub.local/10.webp');
      expect(p1.indexOf('000001.webp') >= 0).assertTrue();
      expect(p10.indexOf('000010.webp') >= 0).assertTrue();
      expect(imageExtension('https://x/a.JPEG?x=1')).assertEqual('jpg');
      expect(imageExtension('https://x/a')).assertEqual('webp');
    });

    it('fileUriUsesEngineeringFileScheme', 0, () => {
      // 依据工程自 Phase 7 起已构建验证的 Image(file://${沙盒路径}) 用法
      expect(fileUriOf('/data/x.webp')).assertEqual('file:///data/x.webp');
    });

    // ==================== 写入 / 提交 / 失败清理 ====================

    it('saveImageWritesTempThenAtomicallyCommits', 0, async () => {
      const urls: string[] = derivedImageUrls('b', 'c', 1);
      const bytes: number = await storage.saveImage(urls[0], 'b', 'c', 0,
        fetcher, new DownloadToken('t'), {});
      expect(bytes > 0).assertTrue();
      const finalPath: string = storage.imagePath('b', 'c', 0, urls[0]);
      expect(fs.hasFile(finalPath)).assertTrue();
      expect(fs.hasFile(`${finalPath}${DOWNLOAD_TEMP_SUFFIX}`)).assertFalse();
      expect(fetcher.calls.length).assertEqual(1);
    });

    it('saveImageSkipsAlreadyCompleteFile', 0, async () => {
      const urls: string[] = derivedImageUrls('b', 'c', 1);
      await storage.saveImage(urls[0], 'b', 'c', 0, fetcher, new DownloadToken('t'), {});
      const again: number = await storage.saveImage(urls[0], 'b', 'c', 0,
        fetcher, new DownloadToken('t2'), {});
      expect(again).assertEqual(0);
      expect(fetcher.calls.length).assertEqual(1); // 不重复下载
    });

    it('saveImageCleansTempOnFetchFailure', 0, async () => {
      const urls: string[] = derivedImageUrls('b', 'c', 1);
      fetcher.failUrls.add(urls[0]);
      let threw: boolean = false;
      try {
        await storage.saveImage(urls[0], 'b', 'c', 0, fetcher, new DownloadToken('t'), {});
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      const finalPath: string = storage.imagePath('b', 'c', 0, urls[0]);
      expect(fs.hasFile(`${finalPath}${DOWNLOAD_TEMP_SUFFIX}`)).assertFalse();
      expect(fs.hasFile(finalPath)).assertFalse();
    });

    it('saveImageCleansTempOnEmptyResponse', 0, async () => {
      const urls: string[] = derivedImageUrls('b', 'c', 1);
      fetcher.emptyUrls.add(urls[0]);
      let threw: boolean = false;
      try {
        await storage.saveImage(urls[0], 'b', 'c', 0, fetcher, new DownloadToken('t'), {});
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      expect(fs.hasFile(storage.imagePath('b', 'c', 0, urls[0]))).assertFalse();
    });

    it('saveImageCleansTempOnCommitFailure', 0, async () => {
      const urls: string[] = derivedImageUrls('b', 'c', 1);
      fs.commitFails = true;
      let threw: boolean = false;
      try {
        await storage.saveImage(urls[0], 'b', 'c', 0, fetcher, new DownloadToken('t'), {});
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      const finalPath: string = storage.imagePath('b', 'c', 0, urls[0]);
      expect(fs.hasFile(finalPath)).assertFalse();
    });

    it('saveImageThrowsInterruptedWhenTokenCanceled', 0, async () => {
      const urls: string[] = derivedImageUrls('b', 'c', 1);
      const token: DownloadToken = new DownloadToken('t');
      // 模拟在途请求被取消：fetcher 抛 DownloadInterrupted
      fetcher.failUrls.add(urls[0]);
      token.cancel();
      let interrupted: boolean = false;
      try {
        await storage.saveImage(urls[0], 'b', 'c', 0, fetcher, token, {});
      } catch (e) {
        interrupted = e instanceof DownloadInterrupted;
      }
      // token 已取消时存储层必须按中断处理，而不是计入失败图片
      expect(interrupted).assertTrue();
    });

    it('saveImagePreservesPreviouslyCompletedImagesOnFailure', 0, async () => {
      const urls: string[] = derivedImageUrls('b', 'c', 2);
      await storage.saveImage(urls[0], 'b', 'c', 0, fetcher, new DownloadToken('a'), {});
      fetcher.failUrls.add(urls[1]);
      try {
        await storage.saveImage(urls[1], 'b', 'c', 1, fetcher, new DownloadToken('b'), {});
      } catch (e) {
        // 预期失败
      }
      const entries: OfflineImageEntry[] = await storage.listChapterImages('b', 'c');
      expect(entries.length).assertEqual(1);
      expect(entries[0].index).assertEqual(1);
    });

    // ==================== 顺序与完整性 ====================

    it('listChapterImagesSortsByNumericIndex', 0, async () => {
      // 故意乱序写入：10, 2, 1
      for (const index of [9, 1, 0]) {
        const url: string = derivedImageUrls('b', 'c', 10)[index];
        await storage.saveImage(url, 'b', 'c', index, fetcher, new DownloadToken(`t${index}`), {});
      }
      const entries: OfflineImageEntry[] = await storage.listChapterImages('b', 'c');
      expect(entries.length).assertEqual(3);
      expect(entries[0].index).assertEqual(1);
      expect(entries[1].index).assertEqual(2);
      expect(entries[2].index).assertEqual(10);
    });

    it('verifyChapterDetectsMissingIndexes', 0, async () => {
      const urls: string[] = derivedImageUrls('b', 'c', 3);
      await storage.saveImage(urls[0], 'b', 'c', 0, fetcher, new DownloadToken('a'), {});
      await storage.saveImage(urls[2], 'b', 'c', 2, fetcher, new DownloadToken('c'), {});
      const verify: ChapterVerifyResult = await storage.verifyChapter('b', 'c', 3);
      expect(verify.complete).assertFalse();
      expect(verify.missingIndexes.length).assertEqual(1);
      expect(verify.missingIndexes[0]).assertEqual(2);
      expect(verify.message.indexOf('不完整') >= 0).assertTrue();
    });

    it('verifyChapterDetectsCorruptedZeroByteFile', 0, async () => {
      fs.seedFile(`${ROOT}/b/c/000001.webp`, 0);  // 0 字节 = 损坏
      fs.seedFile(`${ROOT}/b/c/000002.webp`, 10); // 正常
      const verify: ChapterVerifyResult = await storage.verifyChapter('b', 'c', 2);
      expect(verify.complete).assertFalse();
      expect(verify.validCount).assertEqual(1);
      expect(verify.missingIndexes[0]).assertEqual(1);
    });

    it('verifyChapterRejectsExtraFiles', 0, async () => {
      const urls: string[] = derivedImageUrls('b', 'c', 2);
      for (let i = 0; i < 2; i++) {
        await storage.saveImage(urls[i], 'b', 'c', i, fetcher, new DownloadToken(`t${i}`), {});
      }
      const verify: ChapterVerifyResult = await storage.verifyChapter('b', 'c', 1);
      expect(verify.complete).assertFalse();
      expect(verify.message.indexOf('多余文件') >= 0).assertTrue();
    });

    it('verifyChapterUnknownTotalIsNotComplete', 0, async () => {
      const verify: ChapterVerifyResult = await storage.verifyChapter('b', 'c', 0);
      expect(verify.complete).assertFalse();
      expect(verify.message.indexOf('未知') >= 0).assertTrue();
    });

    it('deleteChapterRemovesOnlyTargetChapter', 0, async () => {
      await storage.saveImage('https://stub.local/a/1.webp', 'b1', 'c1', 0,
        fetcher, new DownloadToken('a'), {});
      await storage.saveImage('https://stub.local/a/1.webp', 'b2', 'c1', 0,
        fetcher, new DownloadToken('b'), {});
      await storage.deleteChapter('b1', 'c1');
      expect((await storage.listChapterImages('b1', 'c1')).length).assertEqual(0);
      expect((await storage.listChapterImages('b2', 'c1')).length).assertEqual(1);
    });

    it('largeChapterHandlesManyFiles', 0, async () => {
      const urls: string[] = derivedImageUrls('b', 'big', 60);
      for (let i = 0; i < urls.length; i++) {
        await storage.saveImage(urls[i], 'b', 'big', i, fetcher, new DownloadToken(`t${i}`), {});
      }
      const verify: ChapterVerifyResult = await storage.verifyChapter('b', 'big', 60);
      expect(verify.complete).assertTrue();
      expect(verify.entries.length).assertEqual(60);
      expect((await storage.getTotalSize()) > 0).assertTrue();
    });

    // ==================== 缓存严格隔离 ====================

    it('clearImageCacheDoesNotDeleteDownloadFiles', 0, async () => {
      // 同一个虚拟 FS：缓存目录放 MD5 命名的临时文件，下载目录放序号命名的永久文件
      const cacheFile: string = `${CACHE}/aabbccddeeff00112233445566778899.webp`;
      fs.seedFile(cacheFile, 100);
      const downloadUrl: string = derivedImageUrls('b', 'c', 1)[0];
      await storage.saveImage(downloadUrl, 'b', 'c', 0, fetcher, new DownloadToken('t'), {});
      const downloadPath: string = storage.imagePath('b', 'c', 0, downloadUrl);
      expect(fs.hasFile(downloadPath)).assertTrue();

      const cleaner: CacheCleaner = new CacheCleaner(fs,
        (name: string): boolean => ImageCacheManager.isImageCacheFile(name),
        (name: string): boolean => false,
        (msg: string): void => {
        });
      const result = await cleaner.clear(CACHE);
      expect(result.success).assertTrue();
      expect(fs.hasFile(cacheFile)).assertFalse();       // 缓存已清
      expect(fs.hasFile(downloadPath)).assertTrue();     // 下载文件仍在
    });

    it('cacheCleanerIgnoresDownloadNamesEvenIfPathsOverlap', 0, async () => {
      // 异常布局：下载文件恰好位于 cacheDir 之下，也必须因命名规则不被误删
      const downloadName: string = '000001.webp';
      fs.seedFile(`${CACHE}/${downloadName}`, 200);
      const cleaner: CacheCleaner = new CacheCleaner(fs,
        (name: string): boolean => ImageCacheManager.isImageCacheFile(name),
        (name: string): boolean => false,
        (msg: string): void => {
        });
      await cleaner.clear(CACHE);
      expect(fs.hasFile(`${CACHE}/${downloadName}`)).assertTrue();
    });

    it('deleteDownloadChapterDoesNotDeleteCacheFiles', 0, async () => {
      const cacheFile: string = `${CACHE}/aabbccddeeff00112233445566778899.webp`;
      fs.seedFile(cacheFile, 100);
      await storage.saveImage(derivedImageUrls('b', 'c', 1)[0], 'b', 'c', 0,
        fetcher, new DownloadToken('t'), {});
      await storage.deleteChapter('b', 'c');
      expect(fs.hasFile(cacheFile)).assertTrue();
    });

    it('cacheAndDownloadStatisticsAreIndependent', 0, async () => {
      fs.seedFile(`${CACHE}/aabbccddeeff00112233445566778899.webp`, 100);
      await storage.saveImage(derivedImageUrls('b', 'c', 1)[0], 'b', 'c', 0,
        fetcher, new DownloadToken('t'), {});
      const cleaner: CacheCleaner = new CacheCleaner(fs,
        (name: string): boolean => ImageCacheManager.isImageCacheFile(name),
        (name: string): boolean => false,
        (msg: string): void => {
        });
      const cacheSize: number = await cleaner.sum(CACHE);
      const downloadSize: number = await storage.getTotalSize();
      expect(cacheSize).assertEqual(100);
      expect(downloadSize > 0).assertTrue();
      expect(cacheSize === downloadSize).assertFalse();
    });

    // ==================== 离线数据源（存储侧） ====================

    it('offlineLookupReturnsMissingWhenNoRecord', 0, async () => {
      const repo: MemoryDownloadRepository = new MemoryDownloadRepository();
      const offline: OfflineChapterSource = new OfflineChapterSource(storage, repo);
      const found = await offline.lookup('b', 'c');
      expect(found.exists).assertFalse();
      expect(found.complete).assertFalse();
    });

    it('offlineLookupReturnsOrderedFileUrisForCompleteChapter', 0, async () => {
      const urls: string[] = derivedImageUrls('b', 'c', 3);
      for (let i = 0; i < 3; i++) {
        await storage.saveImage(urls[i], 'b', 'c', i, fetcher, new DownloadToken(`t${i}`), {});
      }
      const repo: MemoryDownloadRepository = new MemoryDownloadRepository();
      const task: DownloadTask = new DownloadTask('b', 'c', '书', '章节');
      task.status = DownloadStatus.COMPLETED;
      task.totalImages = 3;
      task.completedImages = 3;
      repo.seed(task);
      const offline: OfflineChapterSource = new OfflineChapterSource(storage, repo);
      const found = await offline.lookup('b', 'c');
      expect(found.complete).assertTrue();
      expect(found.images.length).assertEqual(3);
      expect(found.images[0].startsWith('file://')).assertTrue();
      expect(found.images[0].indexOf('000001.webp') >= 0).assertTrue();
      expect(found.images[2].indexOf('000003.webp') >= 0).assertTrue();
    });

    it('offlineLookupMarksIncompleteWhenFileDeleted', 0, async () => {
      const urls: string[] = derivedImageUrls('b', 'c', 2);
      for (let i = 0; i < 2; i++) {
        await storage.saveImage(urls[i], 'b', 'c', i, fetcher, new DownloadToken(`t${i}`), {});
      }
      const repo: MemoryDownloadRepository = new MemoryDownloadRepository();
      const task: DownloadTask = new DownloadTask('b', 'c', '书', '章节');
      task.status = DownloadStatus.COMPLETED;
      task.totalImages = 2;
      task.completedImages = 2;
      repo.seed(task);
      await storage.deleteChapter('b', 'c'); // 文件被删除
      const offline: OfflineChapterSource = new OfflineChapterSource(storage, repo);
      const found = await offline.lookup('b', 'c');
      expect(found.exists).assertTrue();
      expect(found.complete).assertFalse();
      expect(found.images.length).assertEqual(0); // 不返回失效路径
    });

    it('offlineLookupIsolatesSameChapterIdAcrossBooks', 0, async () => {
      const repo: MemoryDownloadRepository = new MemoryDownloadRepository();
      // 两本漫画的章节 id 相同，各自下载 2 张
      for (const bookId of ['b1', 'b2']) {
        const urls: string[] = derivedImageUrls(bookId, 'same', 2);
        for (let i = 0; i < 2; i++) {
          await storage.saveImage(urls[i], bookId, 'same', i,
            fetcher, new DownloadToken(`${bookId}${i}`), {});
        }
        const task: DownloadTask = new DownloadTask(bookId, 'same', bookId, '章节');
        task.status = DownloadStatus.COMPLETED;
        task.totalImages = 2;
        task.completedImages = 2;
        repo.seed(task);
      }
      const offline: OfflineChapterSource = new OfflineChapterSource(storage, repo);
      const before1 = await offline.lookup('b1', 'same');
      const before2 = await offline.lookup('b2', 'same');
      expect(before1.complete).assertTrue();
      expect(before2.complete).assertTrue();

      // 只删 b1 的目录 → b2 必须仍完整
      await storage.deleteChapter('b1', 'same');
      const after1 = await offline.lookup('b1', 'same');
      const after2 = await offline.lookup('b2', 'same');
      expect(after1.complete).assertFalse();
      expect(after2.complete).assertTrue();
      expect(after2.images.length).assertEqual(2);
    });
  });
}
