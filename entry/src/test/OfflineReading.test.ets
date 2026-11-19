/**
 * OfflineReading.test.ets —— Phase 12 本地数据源与阅读器离线集成测试
 *
 * 覆盖：完整离线章节 / 不存在章节 / 不完整章节 / 图片顺序 / 删除后读取 /
 * 不同漫画同章节 ID 隔离 / 来源切换 / 在线回归 / 阅读进度恢复 / 本地 URI 不触网。
 *
 * 本地 `file://` URI 采用工程自 Phase 7 起已构建验证的 ArkUI Image 用法；
 * 本测试用内存 FS 桩验证业务逻辑，**不宣称验证了真机图片解码**。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { DownloadStatus, DownloadTask } from '../main/ets/model/DownloadTask';
import { DownloadStorage } from '../main/ets/download/DownloadStorage';
import { OfflineChapterSource } from '../main/ets/download/OfflineChapterSource';
import {
  CompositeChapterImageProvider,
  OnlineChapterImageProvider
} from '../main/ets/download/ChapterImageProvider';
import { ChapterImageSet, DownloadToken } from '../main/ets/download/DownloadPorts';
import { ComicReaderViewModel } from '../main/ets/viewmodel/ComicReaderViewModel';
import { ImageCacheManager } from '../main/ets/utils/ImageCacheManager';
import { AuthRequiredError } from '../main/ets/api/ApiErrors';
import { HttpError } from '../main/ets/api/HttpManager';
import {
  MemoryDownloadRepository,
  MemoryImageFetcher,
  SharedMemoryFs,
  StubChapterImageProvider,
  derivedImageUrls
} from './DownloadStubs';
import { StubReaderImageSource, InMemoryReadingStore } from './DetailStubs';

const ROOT: string = '/virtual/files/Downloads';

interface OfflineHarness {
  fs: SharedMemoryFs;
  storage: DownloadStorage;
  repo: MemoryDownloadRepository;
  fetcher: MemoryImageFetcher;
  offline: OfflineChapterSource;
  online: StubReaderImageSource;
  composite: CompositeChapterImageProvider;
}

function makeOfflineHarness(): OfflineHarness {
  const fs: SharedMemoryFs = new SharedMemoryFs();
  const storage: DownloadStorage = new DownloadStorage(fs, ROOT);
  const repo: MemoryDownloadRepository = new MemoryDownloadRepository();
  const fetcher: MemoryImageFetcher = new MemoryImageFetcher(fs);
  const offline: OfflineChapterSource = new OfflineChapterSource(storage, repo);
  const online: StubReaderImageSource = new StubReaderImageSource();
  const composite: CompositeChapterImageProvider = new CompositeChapterImageProvider(
    offline, new OnlineChapterImageProvider(online));
  return { fs, storage, repo, fetcher, offline, online, composite };
}

/** 在内存 FS 中构造一个「已完成」的本地章节 */
async function seedCompleteChapter(h: OfflineHarness, bookId: string,
  chapterId: string, count: number): Promise<void> {
  const urls: string[] = derivedImageUrls(bookId, chapterId, count);
  for (let i = 0; i < count; i++) {
    await h.storage.saveImage(urls[i], bookId, chapterId, i,
      h.fetcher, new DownloadToken(`t${i}`), {});
  }
  const task: DownloadTask = new DownloadTask(bookId, chapterId, `书-${bookId}`, `章节-${chapterId}`);
  task.status = DownloadStatus.COMPLETED;
  task.totalImages = count;
  task.completedImages = count;
  h.repo.seed(task);
}

export default function offlineReadingTest() {
  describe('OfflineReading', () => {
    let h: OfflineHarness = makeOfflineHarness();

    beforeEach(() => {
      h = makeOfflineHarness();
    });

    it('compositeUsesLocalCompleteChapterWithoutNetwork', 0, async () => {
      await seedCompleteChapter(h, 'b1', 'c1', 3);
      h.online.images = derivedImageUrls('b1', 'c1', 3);
      const set: ChapterImageSet = await h.composite.getChapterImages('b1', 'c1');
      expect(set.offline).assertTrue();
      expect(set.complete).assertTrue();
      expect(set.images.length).assertEqual(3);
      expect(h.online.calls.length).assertEqual(0); // 离线模式绝不触发在线请求
    });

    it('compositeFallsBackToOnlineWhenNoLocalChapter', 0, async () => {
      h.online.images = derivedImageUrls('b1', 'c1', 2);
      const set: ChapterImageSet = await h.composite.getChapterImages('b1', 'c1');
      expect(set.offline).assertFalse();
      expect(set.images.length).assertEqual(2);
      expect(h.online.calls.length).assertEqual(1);
    });

    it('incompleteLocalChapterDoesNotSilentlyFallback', 0, async () => {
      await seedCompleteChapter(h, 'b1', 'c1', 3);
      await h.storage.deleteChapter('b1', 'c1'); // 文件全被删
      h.online.images = derivedImageUrls('b1', 'c1', 3);
      const set: ChapterImageSet = await h.composite.getChapterImages('b1', 'c1');
      expect(set.offline).assertTrue();
      expect(set.complete).assertFalse();
      expect(set.images.length).assertEqual(0);   // 不返回残缺/失效路径
      expect(set.message.indexOf('不完整') >= 0).assertTrue();
      expect(h.online.calls.length).assertEqual(0); // 不用在线掩盖问题
    });

    it('localImageOrderMatchesDownloadOrder', 0, async () => {
      await seedCompleteChapter(h, 'b1', 'c1', 12);
      const uris: string[] = await h.offline.getLocalImageUris('b1', 'c1');
      expect(uris.length).assertEqual(12);
      expect(uris[0].indexOf('000001.webp') >= 0).assertTrue();
      expect(uris[9].indexOf('000010.webp') >= 0).assertTrue();
      expect(uris[11].indexOf('000012.webp') >= 0).assertTrue();
    });

    it('deletedFileIsNotReturnedToReader', 0, async () => {
      await seedCompleteChapter(h, 'b1', 'c1', 2);
      const before = await h.offline.lookup('b1', 'c1');
      expect(before.complete).assertTrue();
      const path: string = h.storage.imagePath('b1', 'c1', 1, 'https://stub.local/x.webp');
      await h.fs.remove(path);
      const after = await h.offline.lookup('b1', 'c1');
      expect(after.complete).assertFalse();
      expect(after.images.length).assertEqual(0);
    });

    it('sameChapterIdDifferentBooksAreIsolated', 0, async () => {
      await seedCompleteChapter(h, 'book-A', 'same', 2);
      await seedCompleteChapter(h, 'book-B', 'same', 2);
      await h.storage.deleteChapter('book-A', 'same');
      const a = await h.offline.lookup('book-A', 'same');
      const b = await h.offline.lookup('book-B', 'same');
      expect(a.complete).assertFalse();
      expect(b.complete).assertTrue();
      expect(b.images[0].indexOf('/book-B/') >= 0).assertTrue();
    });

    it('localUriDoesNotTriggerNetworkDownload', 0, async () => {
      // ImageCacheManager 对 file:// 直接短路，离线阅读不会误触发 rcp 下载
      const uri: string = 'file:///virtual/files/Downloads/b/c/000001.webp';
      const resolved: string = await ImageCacheManager.getInstance().getImage(uri);
      expect(resolved).assertEqual(uri);
    });

    // ==================== 阅读器 VM 集成 ====================

    it('readerLoadsOfflineChapter', 0, async () => {
      await seedCompleteChapter(h, 'b1', 'c1', 3);
      const vm: ComicReaderViewModel = new ComicReaderViewModel(undefined,
        new InMemoryReadingStore(), h.composite);
      await vm.loadChapter('b1', 'c1');
      expect(vm.isOffline).assertTrue();
      expect(vm.imageDataSource.totalCount()).assertEqual(3);
      expect(vm.totalCount).assertEqual(3);
      expect(vm.errorMessage).assertEqual('');
      expect(h.online.calls.length).assertEqual(0);
    });

    it('readerShowsExplicitIncompleteState', 0, async () => {
      await seedCompleteChapter(h, 'b1', 'c1', 2);
      await h.storage.deleteChapter('b1', 'c1');
      const vm: ComicReaderViewModel = new ComicReaderViewModel(undefined,
        new InMemoryReadingStore(), h.composite);
      await vm.loadChapter('b1', 'c1');
      expect(vm.incompleteMessage !== '').assertTrue();
      expect(vm.imageDataSource.totalCount()).assertEqual(0);
      expect(vm.needsLogin).assertFalse();
    });

    it('readerOnlineRegressionViaStubProvider', 0, async () => {
      const provider: StubChapterImageProvider = new StubChapterImageProvider();
      provider.result = ChapterImageSet.online(derivedImageUrls('b1', 'c1', 4));
      const vm: ComicReaderViewModel = new ComicReaderViewModel(undefined,
        new InMemoryReadingStore(), provider);
      await vm.loadChapter('b1', 'c1');
      expect(vm.isOffline).assertFalse();
      expect(vm.imageDataSource.totalCount()).assertEqual(4);
      expect(provider.calls[0]).assertEqual('b1/c1');
    });

    it('readerKeepsAuthRequiredSemanticsFromOnlineSource', 0, async () => {
      const provider: StubChapterImageProvider = new StubChapterImageProvider();
      provider.error = new AuthRequiredError();
      const vm: ComicReaderViewModel = new ComicReaderViewModel(undefined,
        new InMemoryReadingStore(), provider);
      await vm.loadChapter('b1', 'c1');
      expect(vm.needsLogin).assertTrue();
      expect(vm.imageDataSource.totalCount()).assertEqual(0);
    });

    it('readerChapterSwitchDoesNotReusePreviousPage', 0, async () => {
      await seedCompleteChapter(h, 'b1', 'c1', 3);
      await seedCompleteChapter(h, 'b1', 'c2', 3);
      const vm: ComicReaderViewModel = new ComicReaderViewModel(undefined,
        new InMemoryReadingStore(), h.composite);
      await vm.loadChapter('b1', 'c1', 3);
      expect(vm.currentPage).assertEqual(3);
      await vm.loadChapter('b1', 'c2', 1);
      expect(vm.currentPage).assertEqual(1);
    });

    it('readerProgressIsKeyedByBookAndChapter', 0, async () => {
      const store: InMemoryReadingStore = new InMemoryReadingStore();
      const provider: StubChapterImageProvider = new StubChapterImageProvider();
      provider.result = ChapterImageSet.local(['file:///a/1.webp', 'file:///a/2.webp']);
      const vm: ComicReaderViewModel = new ComicReaderViewModel(undefined, store, provider);
      await vm.loadChapter('b1', 'c1', 2);
      expect(await vm.saveProgress('b1', 'c1', '第 1 章')).assertTrue();
      const vm2: ComicReaderViewModel = new ComicReaderViewModel(undefined, store, provider);
      await vm2.loadChapter('b1', 'c2', 1);
      await vm2.saveProgress('b1', 'c2', '第 2 章');
      expect(store.size()).assertEqual(2);
      const first = await store.getHistoryForChapter('b1', 'c1');
      const second = await store.getHistoryForChapter('b1', 'c2');
      expect(first !== null && first.pageIndex === 2).assertTrue();
      expect(second !== null && second.pageIndex === 1).assertTrue();
    });

    it('readerEmptyOfflineImageListIsHandled', 0, async () => {
      const provider: StubChapterImageProvider = new StubChapterImageProvider();
      provider.result = ChapterImageSet.local([]);
      const vm: ComicReaderViewModel = new ComicReaderViewModel(undefined,
        new InMemoryReadingStore(), provider);
      await vm.loadChapter('b1', 'c1');
      expect(vm.imageDataSource.totalCount()).assertEqual(0);
      expect(vm.currentPage).assertEqual(1);
      expect(vm.errorMessage).assertEqual('');
    });

    it('readerDistinguishesNetworkErrorFromIncomplete', 0, async () => {
      const provider: StubChapterImageProvider = new StubChapterImageProvider();
      provider.error = new HttpError(504, '网关超时');
      const vm: ComicReaderViewModel = new ComicReaderViewModel(undefined,
        new InMemoryReadingStore(), provider);
      await vm.loadChapter('b1', 'c1');
      expect(vm.needsLogin).assertFalse();
      expect(vm.incompleteMessage).assertEqual('');
      expect(vm.errorMessage.indexOf('网关超时') >= 0).assertTrue();
    });
  });
}
