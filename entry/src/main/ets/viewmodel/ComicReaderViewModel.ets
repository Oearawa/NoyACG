/**
 * ComicReaderViewModel.ets —— 阅读器视图模型
 *
 * 阶段六新增能力：
 * - loadChapter 支持断点续传起始页（startPage，1 起）；
 * - saveProgress 阅读进度落盘：由页面 onHidden / onDisappear 触发，
 *   写入 History 表（同漫画 UPSERT，只保留最新进度）。
 */
import { BasicDataSource } from '../utils/BasicDataSource';
import { IComicSource } from '../source/IComicSource';
import { noyAcgSource } from '../source/NoyAcgSource';
import { HttpError } from '../api/HttpManager';
import { AuthRequiredError } from '../api/ApiErrors';
import { DatabaseManager, HistoryRecord, ReadingStorePort } from '../utils/DatabaseManager';
import { ComicMetaCache, HistoryMetadata } from '../utils/ComicMetaCache';
import { ChapterImageProvider, ChapterImageSet } from '../download/DownloadPorts';
import { ChapterImageProviders } from '../download/ChapterImageProvider';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../utils/Logger';

const TAG: string = 'ComicReaderViewModel';

@ObservedV2
export class ComicReaderViewModel {
  /** 本章全部图片地址（绑定阅读器 LazyForEach） */
  readonly imageDataSource: BasicDataSource<string> = new BasicDataSource<string>();

  /** 章节加载中 */
  @Trace isLoading: boolean = false;
  /** 最近一次错误信息（空串 = 无错误） */
  @Trace errorMessage: string = '';
  /** 本章总页数 */
  @Trace totalCount: number = 0;
  /** 当前阅读到的页码（1 起；由 List 滚动位置驱动，随进度落盘） */
  @Trace currentPage: number = 1;
  /** 失败是否由「需要登录」引起（UI 据此提供「去登录」入口） */
  @Trace needsLogin: boolean = false;
  /** 当前章节是否来自本地永久下载（Phase 12 离线阅读） */
  @Trace isOffline: boolean = false;
  /** 本地章节不完整时的明确说明（绝不静默跳过缺图） */
  @Trace incompleteMessage: string = '';
  /** 最近一次进度落盘失败原因（空串 = 无错误；失败绝不伪装成成功） */
  @Trace progressSaveError: string = '';
  /** 章节加载会话代次：每次进入或切章递增，用于丢弃过期异步响应并隔离渲染 key */
  @Trace chapterSessionId: number = 0;

  /** 已加载的章节键（bid/cid 组合，防重复加载；不能只用 chapterId） */
  private loadedChapterKey: string = '';
  /** 漫画源（默认全局 NoyAcg 源；单元测试可注入桩实现，验证续读页与章节幂等） */
  private source: IComicSource;
  /** 本地进度存储端口（默认 DatabaseManager；测试可注入桩验证写入失败语义） */
  private local: ReadingStorePort;
  /**
   * 统一图片来源（Phase 12）：本地完整章节优先，否则走已验证的在线来源。
   * 显式注入 IComicSource 时退化成「只用该源」，保证 Phase 11 的 220 项既有测试行为不变。
   */
  private provider: ChapterImageProvider;

  constructor(source?: IComicSource, local?: ReadingStorePort,
    provider?: ChapterImageProvider) {
    this.source = source ?? noyAcgSource;
    this.local = local ?? DatabaseManager.getInstance();
    this.provider = provider ?? (source !== undefined
      ? ChapterImageProviders.onlineOnly(this.source)
      : ChapterImageProviders.createDefault());
  }

  /**
   * 切章/首帧准备：立即同步清空旧章节图片并进入加载态，递增会话代次，
   * 防止切章瞬间残留上一话或第 1 话第 1 张画面，也防止首帧闪现「暂无页面」。
   */
  prepareChapter(startPage: number = 1): number {
    const sessionId: number = ++this.chapterSessionId;
    this.imageDataSource.clear();
    this.totalCount = 0;
    this.currentPage = Math.max(1, Math.floor(startPage));
    this.loadedChapterKey = '';
    this.errorMessage = '';
    this.needsLogin = false;
    this.incompleteMessage = '';
    this.isLoading = true;
    return sessionId;
  }

  /**
   * 加载章节图片列表
   * @param bookId    书籍 id（真实接口需要 bid+cid 两个参数）
   * @param chapterId 章节 id（由路由参数传入）
   * @param startPage 断点续传起始页（默认 1 从头阅读）
   */
  async loadChapter(
    bookId: string,
    chapterId: string,
    startPage: number = 1,
    forceReload: boolean = false
  ): Promise<void> {
    // 真实读图接口需要 bid+cid；缺 bookId 时不发无效请求，直接给出可诊断错误
    if (bookId.trim() === '' || chapterId.trim() === '') {
      this.chapterSessionId++;
      this.needsLogin = false;
      this.errorMessage = '缺少漫画 ID 或章节 ID，无法加载章节（请从详情页进入阅读器）';
      this.imageDataSource.clear();
      this.totalCount = 0;
      this.loadedChapterKey = '';
      this.isLoading = false;
      return;
    }
    // 同一书籍下的同一章节且已完成加载才视为重复；切章期间允许覆盖旧在途请求
    const key: string = `${bookId}/${chapterId}`;
    if (!forceReload && this.loadedChapterKey === key && !this.isLoading) {
      return;
    }

    const sessionId: number = ++this.chapterSessionId;
    this.imageDataSource.clear();
    this.totalCount = 0;
    this.currentPage = Math.max(1, Math.floor(startPage));
    this.loadedChapterKey = '';
    this.isLoading = true;
    this.errorMessage = '';
    this.needsLogin = false;
    this.incompleteMessage = '';

    try {
      const result: ChapterImageSet = await this.provider.getChapterImages(bookId, chapterId);
      if (sessionId !== this.chapterSessionId) {
        return;
      }
      if (!result.complete) {
        // 本地存在但不完整：明确报错，绝不返回残缺图片列表、也不静默回退在线下载
        this.incompleteMessage = result.message === ''
          ? '本地章节不完整，请重新下载' : result.message;
        this.errorMessage = this.incompleteMessage;
        this.imageDataSource.clear();
        this.totalCount = 0;
        this.isOffline = result.offline;
        Logger.warn(TAG, `章节不可读 bid=${bookId} cid=${chapterId}: ${this.incompleteMessage}`);
        return;
      }
      this.isOffline = result.offline;
      this.imageDataSource.setDataStable(result.images, (url: string): string => url,
        (url: string): string => url);
      this.totalCount = result.images.length;
      // 起始页夹取到 [1, 总页数] 区间
      this.currentPage = Math.max(1, Math.min(startPage, Math.max(result.images.length, 1)));
      this.loadedChapterKey = key;
      Logger.info(TAG, `章节图片加载完成 bid=${bookId} cid=${chapterId}, ` +
        `来源=${result.offline ? '离线' : '在线'}, 共${result.images.length}张, ` +
        `起始页=${this.currentPage}`);
    } catch (e) {
      if (sessionId !== this.chapterSessionId) {
        return;
      }
      this.needsLogin = e instanceof AuthRequiredError;
      this.errorMessage = e instanceof HttpError ? e.message : '未知错误，请稍后重试';
      Logger.error(TAG, `章节加载失败(needsLogin=${this.needsLogin}): ${this.errorMessage}`);
    } finally {
      if (sessionId === this.chapterSessionId) {
        this.isLoading = false;
      }
    }
  }

  /**
   * 由阅读器 List 的 onScrollIndex 回调驱动，实时同步当前页码
   * @param firstIndex 可视区首个图片的下标（从 0 开始）
   */
  updatePage(firstIndex: number): void {
    // 页码下限恒为 1：章节为空 / 下标异常时不得出现「第 0 页」
    const page: number = Math.max(1, Math.min(firstIndex + 1, Math.max(this.totalCount, 1)));
    if (page !== this.currentPage) {
      this.currentPage = page;
    }
  }

  /**
   * 阅读进度落盘（页面 onHidden / onDisAppear 调用）。
   *
   * Phase 11：写入 HistoryV2（复合主键 comic_id + chapter_id），
   * 记录 `totalPages`；同章节 UPSERT 幂等，不同章节互不覆盖。
   *
   * @returns true = **确实写库成功**；false = 跳过或写库失败。
   *          失败时 `progressSaveError` 带原因，调用方不得显示「已保存」类成功提示。
   */
  async saveProgress(comicId: string, chapterId: string, chapterTitle: string): Promise<boolean> {
    if (comicId === '' || chapterId === '' || this.imageDataSource.isEmpty()) {
      return false; // 空章节 / 无漫画上下文：不写库，也不谎报成功
    }
    try {
      const meta: HistoryMetadata | null = ComicMetaCache.get(comicId);
      const record: HistoryRecord = {
        comicId: comicId,
        chapterId: chapterId,
        chapterTitle: chapterTitle,
        pageIndex: this.currentPage,
        totalPages: this.totalCount,
        updateTime: Date.now(),
        title: meta !== null ? meta.title : undefined,
        coverUrl: meta !== null ? meta.coverUrl : undefined,
        author: meta !== null ? meta.author : undefined,
        tags: meta !== null ? meta.tags : undefined,
        isCompleted: meta !== null ? meta.isCompleted : undefined,
        views: meta !== null ? meta.views : undefined,
        favorites: meta !== null ? meta.favorites : undefined
      };
      await this.local.saveHistory(record);
      this.progressSaveError = '';
      Logger.debug(TAG, `进度已保存: ${chapterTitle} 第${this.currentPage}/${this.totalCount}页`);
      return true;
    } catch (e) {
      // 数据库写入失败：如实记录，绝不静默当作成功
      const reason: string = (e as BusinessError).message ?? '未知数据库错误';
      this.progressSaveError = reason;
      Logger.error(TAG, `进度保存失败: ${reason}`);
      return false;
    }
  }

  /** LazyForEach 稳定 key 前缀：绑定会话代次与章节键，切章强制重建图片节点。 */
  chapterStableKey(): string {
    return `${this.chapterSessionId}_${this.loadedChapterKey === '' ? 'pending' : this.loadedChapterKey}`;
  }

  /** 释放数据源（页面销毁时调用） */
  clear(): void {
    this.imageDataSource.clear();
  }
}
