/**
 * ReadingProgressStore.ets —— 阅读进度防抖持久化与恢复仓储
 *
 * 职责：
 * 1. 基于 ReadingStorePort（HistoryV2 分章节主键）防抖落盘（默认 350ms），
 *    并在退出阅读器或切换章节时提供 flushSave() 立即刷盘。
 * 2. 记录与恢复最近一次阅读模式（VERTICAL_STRIP / PAGE_LTR / PAGE_RTL）。
 * 3. 写入失败如实记录 lastError，绝不伪装成功。
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { DatabaseManager, HistoryRecord, ReadingStorePort } from '../utils/DatabaseManager';
import { ComicMetaCache, HistoryMetadata } from '../utils/ComicMetaCache';
import { Logger } from '../utils/Logger';
import { ReaderMode, ReadingProgressSnapshot } from './ReaderTypes';

const TAG: string = 'ReadingProgressStore';
export const DEFAULT_PROGRESS_DEBOUNCE_MS: number = 350;

export class ReadingProgressStore {
  private readonly store: ReadingStorePort;
  private readonly debounceMs: number;
  private readonly modeByComic: Map<string, ReaderMode> = new Map<string, ReaderMode>();
  private lastMode: ReaderMode = ReaderMode.PAGE_LTR;
  private pendingSnapshot: ReadingProgressSnapshot | null = null;
  private debounceTimer: number = -1;
  lastError: string = '';

  constructor(store?: ReadingStorePort, debounceMs: number = DEFAULT_PROGRESS_DEBOUNCE_MS) {
    this.store = store ?? DatabaseManager.getInstance();
    this.debounceMs = Math.max(0, debounceMs);
  }

  /** 是否曾显式记录过该漫画的阅读模式 */
  hasSavedMode(comicId: string): boolean {
    return comicId !== '' && this.modeByComic.has(comicId);
  }

  /** 记录当前阅读模式（按漫画 + 全局最近模式记忆） */
  setMode(comicId: string, mode: ReaderMode): void {
    this.lastMode = mode;
    if (comicId !== '') {
      this.modeByComic.set(comicId, mode);
    }
  }

  /** 读取该漫画的阅读模式，未记录则返回最近模式 */
  getMode(comicId: string): ReaderMode {
    if (comicId !== '') {
      const saved: ReaderMode | undefined = this.modeByComic.get(comicId);
      if (saved !== undefined) {
        return saved;
      }
    }
    return this.lastMode;
  }

  /** 调度防抖写入（翻页/滚动时调用，避免高频 SQLite IO） */
  scheduleSave(snapshot: ReadingProgressSnapshot): void {
    if (snapshot.comicId === '' || snapshot.chapterId === '' || snapshot.totalPages <= 0) {
      return;
    }
    this.setMode(snapshot.comicId, snapshot.readingMode);
    this.pendingSnapshot = snapshot;
    this.clearTimer();
    this.debounceTimer = setTimeout((): void => {
      this.debounceTimer = -1;
      void this.flushSave();
    }, this.debounceMs);
  }

  /** 立即将待落盘进度写入存储（退出阅读器 / 切章时调用） */
  async flushSave(): Promise<boolean> {
    this.clearTimer();
    const snap: ReadingProgressSnapshot | null = this.pendingSnapshot;
    if (snap === null) {
      return false;
    }
    this.pendingSnapshot = null;
    return await this.saveNow(snap);
  }

  /** 直接同步写入一次进度 */
  async saveNow(snapshot: ReadingProgressSnapshot): Promise<boolean> {
    if (snapshot.comicId === '' || snapshot.chapterId === '' || snapshot.totalPages <= 0) {
      return false;
    }
    this.setMode(snapshot.comicId, snapshot.readingMode);
    try {
      const meta: HistoryMetadata | null = ComicMetaCache.get(snapshot.comicId);
      const record: HistoryRecord = {
        comicId: snapshot.comicId,
        chapterId: snapshot.chapterId,
        chapterTitle: snapshot.chapterTitle,
        pageIndex: Math.max(1, snapshot.pageIndex),
        totalPages: snapshot.totalPages,
        updateTime: snapshot.updateTime,
        title: meta !== null ? meta.title : undefined,
        coverUrl: meta !== null ? meta.coverUrl : undefined,
        author: meta !== null ? meta.author : undefined,
        tags: meta !== null ? meta.tags : undefined,
        isCompleted: meta !== null ? meta.isCompleted : undefined,
        views: meta !== null ? meta.views : undefined,
        favorites: meta !== null ? meta.favorites : undefined
      };
      await this.store.saveHistory(record);
      this.lastError = '';
      return true;
    } catch (e) {
      const reason: string = (e as BusinessError).message ?? '未知数据库错误';
      this.lastError = reason;
      Logger.error(TAG, `保存阅读进度失败: ${reason}`);
      return false;
    }
  }

  /** 恢复指定章节的上次阅读页码（1-based；无记录或读取失败返回 fallbackPage） */
  async loadChapterPage(comicId: string, chapterId: string, fallbackPage: number = 1): Promise<number> {
    if (comicId === '' || chapterId === '') {
      return Math.max(1, fallbackPage);
    }
    try {
      const record: HistoryRecord | null = await this.store.getHistoryForChapter(comicId, chapterId);
      if (record !== null && record.pageIndex > 0) {
        return record.pageIndex;
      }
    } catch (e) {
      const reason: string = (e as BusinessError).message ?? '读取历史失败';
      Logger.warn(TAG, `读取章节进度失败: ${reason}`);
    }
    return Math.max(1, fallbackPage);
  }

  /** 取消未触发的防抖定时器（组件销毁时清理） */
  cancelPending(): void {
    this.clearTimer();
  }

  hasPendingSave(): boolean {
    return this.pendingSnapshot !== null;
  }

  private clearTimer(): void {
    if (this.debounceTimer >= 0) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
  }
}
