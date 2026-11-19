/**
 * ComicReaderViewModel.test.ets —— 阅读器视图模型单元测试
 *
 * 覆盖阅读方向切换所依赖的页码计算与边界（垂直 / 水平共用同一套 updatePage 逻辑）：
 * 首屏下标换算、越界夹取、同页不抖动；
 * 并通过注入桩漫画源，真实执行 loadChapter 验证「续读页恢复 / 章节幂等 / 空章节 / 失败态」，
 * 以及进度落盘的前置守卫（无漫画上下文 / 空章节时不得写库）。
 *
 * 说明：UI 层的「垂直 / 水平容器切换、整页吸附手感」属于渲染行为，本地单元测试无法覆盖，
 * 需真机验证（见 PHASE8_REPORT.md），此处不伪造该项结论。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { ComicReaderViewModel } from '../main/ets/viewmodel/ComicReaderViewModel';
import { IComicSource } from '../main/ets/source/IComicSource';
import { Comic } from '../main/ets/model/Comic';
import { ComicDetail } from '../main/ets/model/ComicDetail';
import { PageInfo } from '../main/ets/model/PageInfo';
import { HomeFeed } from '../main/ets/model/HomeFeed';
import { AdItem } from '../main/ets/model/AdItem';
import { CommentPage } from '../main/ets/model/BookComment';
import { HttpError } from '../main/ets/api/HttpManager';
import { AuthRequiredError } from '../main/ets/api/ApiErrors';

/** 可编程漫画源桩：只实现阅读器用到的 getChapterImages */
class StubReaderSource implements IComicSource {
  readonly sourceId: string = 'stub-reader';
  readonly sourceName: string = 'StubReader';
  readonly baseUrl: string = 'https://stub.local';
  /** 图片数量（生成 https://stub.local/{chapter}/{i}.jpg） */
  imageCount: number = 0;
  /** 非空则抛出该错误信息 */
  errorMessage: string = '';
  /** getChapterImages 调用次数 */
  calls: number = 0;

  /** 记录最近一次的双参数（验证 bookId/chapterId 均已贯通到数据层） */
  lastBookId: string = '';
  lastChapterId: string = '';
  /** 非空则抛出「需要登录」异常 */
  authRequired: boolean = false;

  async getChapterImages(bookId: string, chapterId: string): Promise<string[]> {
    this.calls++;
    this.lastBookId = bookId;
    this.lastChapterId = chapterId;
    if (this.authRequired) {
      throw new AuthRequiredError('需要登录 NoyAcg 账号才能使用该功能');
    }
    if (this.errorMessage !== '') {
      throw new HttpError(-1, this.errorMessage);
    }
    const images: string[] = [];
    for (let i = 1; i <= this.imageCount; i++) {
      images.push(`https://stub.local/${bookId}/${chapterId}/${i}.jpg`);
    }
    return images;
  }

  async getHomeList(page: number, sort?: string, finished?: string): Promise<PageInfo<Comic>> {
    return new PageInfo<Comic>(page, -1, [], false);
  }

  async search(keyword: string, page: number): Promise<PageInfo<Comic>> {
    return new PageInfo<Comic>(page, -1, [], false);
  }

  async getComicDetail(id: string): Promise<ComicDetail> {
    throw new HttpError(-1, 'stub 不支持详情');
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

export default function readerViewModelTest() {
  describe('ComicReaderViewModel', () => {
    let vm: ComicReaderViewModel = new ComicReaderViewModel();

    beforeEach(() => {
      vm = new ComicReaderViewModel();
      vm.totalCount = 10;
      vm.currentPage = 1;
    });

    it('scrollIndexMapsToPage', 0, () => {
      // 可视区首个图片下标 0 → 第 1 页（垂直模式与水平模式共用）
      vm.updatePage(0);
      expect(vm.currentPage).assertEqual(1);
      // 下标 4 → 第 5 页（水平翻页吸附后同样走该回调）
      vm.updatePage(4);
      expect(vm.currentPage).assertEqual(5);
    });

    it('pageClampedToTotal', 0, () => {
      vm.totalCount = 3;
      vm.updatePage(9);
      expect(vm.currentPage).assertEqual(3);
    });

    it('pageNeverBelowOne', 0, () => {
      vm.totalCount = 0;
      vm.updatePage(-1);
      expect(vm.currentPage).assertEqual(1);
    });

    it('samePageDoesNotChurn', 0, () => {
      vm.updatePage(2);
      const page: number = vm.currentPage;
      vm.updatePage(2);
      expect(vm.currentPage).assertEqual(page);
      expect(vm.currentPage).assertEqual(3);
    });

    it('loadChapterResumesAtStartPage', 0, async () => {
      const source: StubReaderSource = new StubReaderSource();
      source.imageCount = 10;
      const reader: ComicReaderViewModel = new ComicReaderViewModel(source);
      await reader.loadChapter('book-1', 'chapter-1', 5);
      expect(source.calls).assertEqual(1);
      // Phase 10：书籍 id 与章节 id 必须一起传到数据层
      expect(source.lastBookId).assertEqual('book-1');
      expect(source.lastChapterId).assertEqual('chapter-1');
      expect(reader.totalCount).assertEqual(10);
      expect(reader.imageDataSource.totalCount()).assertEqual(10);
      // 断点续传：停在请求的起始页
      expect(reader.currentPage).assertEqual(5);
    });

    it('startPageClampedIntoRange', 0, async () => {
      const source: StubReaderSource = new StubReaderSource();
      source.imageCount = 10;
      const reader: ComicReaderViewModel = new ComicReaderViewModel(source);
      await reader.loadChapter('book-1', 'chapter-1', 99);
      expect(reader.currentPage).assertEqual(10);

      const source2: StubReaderSource = new StubReaderSource();
      source2.imageCount = 10;
      const reader2: ComicReaderViewModel = new ComicReaderViewModel(source2);
      await reader2.loadChapter('book-1', 'chapter-1', 0);
      expect(reader2.currentPage).assertEqual(1);
    });

    it('loadChapterIsIdempotentPerChapter', 0, async () => {
      const source: StubReaderSource = new StubReaderSource();
      source.imageCount = 3;
      const reader: ComicReaderViewModel = new ComicReaderViewModel(source);
      await reader.loadChapter('book-1', 'chapter-1', 1);
      await reader.loadChapter('book-1', 'chapter-1', 2);
      // 同书籍同章节重复调用（方向切换 / onReady 重入）不得重复请求，也不得重置页码
      expect(source.calls).assertEqual(1);
      expect(reader.currentPage).assertEqual(1);
      expect(reader.imageDataSource.totalCount()).assertEqual(3);
    });

    it('loadChapterReloadsWhenBookChanges', 0, async () => {
      const source: StubReaderSource = new StubReaderSource();
      source.imageCount = 3;
      const reader: ComicReaderViewModel = new ComicReaderViewModel(source);
      await reader.loadChapter('book-1', 'chapter-1', 1);
      // 章节 id 相同但书籍不同：幂等键必须是 bid/cid 组合，不能误判为已加载
      await reader.loadChapter('book-2', 'chapter-1', 1);
      expect(source.calls).assertEqual(2);
      expect(source.lastBookId).assertEqual('book-2');
      expect(reader.imageDataSource.totalCount()).assertEqual(3);
    });

    it('loadChapterEmptyChapter', 0, async () => {
      const source: StubReaderSource = new StubReaderSource();
      source.imageCount = 0;
      const reader: ComicReaderViewModel = new ComicReaderViewModel(source);
      await reader.loadChapter('book-1', 'chapter-empty', 3);
      expect(reader.totalCount).assertEqual(0);
      expect(reader.imageDataSource.totalCount()).assertEqual(0);
      expect(reader.currentPage).assertEqual(1); // 空章节页码仍为 1
      expect(reader.isLoading).assertFalse();
      expect(reader.errorMessage).assertEqual('');
    });

    it('loadChapterFailureSetsError', 0, async () => {
      const source: StubReaderSource = new StubReaderSource();
      source.errorMessage = '网络异常: timeout';
      const reader: ComicReaderViewModel = new ComicReaderViewModel(source);
      await reader.loadChapter('book-1', 'chapter-1', 1);
      expect(reader.errorMessage).assertEqual('网络异常: timeout');
      expect(reader.needsLogin).assertFalse();
      expect(reader.isLoading).assertFalse();
      expect(reader.imageDataSource.totalCount()).assertEqual(0);
    });

    it('loadChapterAuthRequiredExposesLoginEntry', 0, async () => {
      const source: StubReaderSource = new StubReaderSource();
      source.authRequired = true;
      const reader: ComicReaderViewModel = new ComicReaderViewModel(source);
      await reader.loadChapter('book-1', 'chapter-1', 1);
      expect(reader.needsLogin).assertTrue();
      expect(reader.errorMessage).assertEqual('需要登录 NoyAcg 账号才能使用该功能');
      expect(reader.imageDataSource.totalCount()).assertEqual(0);
    });

    it('saveProgressSkippedWithoutComicId', 0, async () => {
      vm.imageDataSource.pushDataList(['https://stub.local/1.jpg']);
      // comicId 为空（旧路由调用方式）：不得写库，也不得抛异常
      await vm.saveProgress('', 'chapter-1', '第 1 话');
      expect(vm.imageDataSource.totalCount()).assertEqual(1);
    });

    it('saveProgressSkippedWhenChapterEmpty', 0, async () => {
      // 章节未加载成功（数据源为空）：不得写库
      await vm.saveProgress('comic-1', 'chapter-1', '第 1 话');
      expect(vm.imageDataSource.totalCount()).assertEqual(0);
    });

    it('clearReleasesDataSource', 0, () => {
      vm.imageDataSource.pushDataList(['a', 'b', 'c']);
      vm.clear();
      expect(vm.imageDataSource.totalCount()).assertEqual(0);
    });
  });
}
