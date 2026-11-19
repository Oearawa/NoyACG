/**
 * ReaderSessionController.ets —— 阅读器核心会话状态机（独立原生 ArkTS @ObservedV2）
 *
 * 职责：
 * - 管理三种阅读模式（VERTICAL_STRIP / PAGE_LTR / PAGE_RTL）及切换；
 * - 管理沉浸式 HUD、章节目录抽屉与设置浮层显隐；
 * - 统一处理点击热区（上一页 / 呼出菜单 / 下一页）与页码边界钳制；
 * - 管理章节列表上下文与上一话/下一话边界提示。
 */
import { clampPageIndex, resolveTapZoneAction } from './ReaderLayout';
import { ReaderChapterItem, ReaderMode, TapZoneAction } from './ReaderTypes';

@ObservedV2
export class ReaderSessionController {
  @Trace mode: ReaderMode = ReaderMode.PAGE_LTR;
  @Trace isHudVisible: boolean = false;
  @Trace isDrawerVisible: boolean = false;
  @Trace isSettingsVisible: boolean = false;
  /** 0-based 当前页下标 */
  @Trace currentPageIndex: number = 0;
  /** 当前章节总页数 */
  @Trace totalPages: number = 0;
  /** 当前章节列表（用于阅读器内目录抽屉与上一话/下一话） */
  @Trace chapters: ReaderChapterItem[] = [];
  /** 当前章节在 chapters 中的下标；-1 表示未知或单本 */
  @Trace currentChapterIndex: number = -1;
  /** 章节边界提示（如「已是第一章」「已是最后一章」） */
  @Trace boundaryNotice: string = '';

  get currentPageNumber(): number {
    return this.currentPageIndex + 1;
  }

  setMode(nextMode: ReaderMode): void {
    this.mode = nextMode;
  }

  /** 在三种阅读模式间循环切换：条漫 -> 左到右 -> 右到左 -> 条漫 */
  cycleMode(): ReaderMode {
    if (this.mode === ReaderMode.VERTICAL_STRIP) {
      this.mode = ReaderMode.PAGE_LTR;
    } else if (this.mode === ReaderMode.PAGE_LTR) {
      this.mode = ReaderMode.PAGE_RTL;
    } else {
      this.mode = ReaderMode.VERTICAL_STRIP;
    }
    return this.mode;
  }

  toggleHud(): void {
    this.isHudVisible = !this.isHudVisible;
    if (!this.isHudVisible) {
      this.isSettingsVisible = false;
      this.isDrawerVisible = false;
    }
  }

  showHud(): void {
    this.isHudVisible = true;
  }

  hideHud(): void {
    this.isHudVisible = false;
    this.isSettingsVisible = false;
    this.isDrawerVisible = false;
  }

  openDrawer(): void {
    this.isSettingsVisible = false;
    this.isDrawerVisible = true;
    this.isHudVisible = true;
  }

  closeDrawer(): void {
    this.isDrawerVisible = false;
  }

  openSettings(): void {
    this.isDrawerVisible = false;
    this.isSettingsVisible = true;
    this.isHudVisible = true;
  }

  closeSettings(): void {
    this.isSettingsVisible = false;
  }

  /** 同步章节总页数并钳制当前页 */
  syncPages(totalPages: number, startPageNumber: number = 1): void {
    this.totalPages = Math.max(0, Math.floor(totalPages));
    const targetIndex: number = Math.max(0, Math.floor(startPageNumber) - 1);
    this.currentPageIndex = clampPageIndex(targetIndex, this.totalPages);
  }

  /** 跳转到指定 0-based 页码（自动钳制在 [0, totalPages - 1]） */
  goToPage(pageIndex: number): number {
    const clamped: number = clampPageIndex(pageIndex, this.totalPages);
    this.currentPageIndex = clamped;
    return clamped;
  }

  /** 跳转到指定 1-based 页码 */
  goToPageNumber(pageNumber: number): number {
    return this.goToPage(Math.floor(pageNumber) - 1);
  }

  nextPage(): boolean {
    if (this.totalPages <= 0 || this.currentPageIndex >= this.totalPages - 1) {
      return false;
    }
    this.currentPageIndex = this.currentPageIndex + 1;
    return true;
  }

  prevPage(): boolean {
    if (this.totalPages <= 0 || this.currentPageIndex <= 0) {
      return false;
    }
    this.currentPageIndex = this.currentPageIndex - 1;
    return true;
  }

  /** 处理屏幕归一化点击坐标 (0..1, 0..1)，返回并执行对应动作 */
  handleTap(
    normalizedX: number,
    normalizedY: number,
    doubleTapZoomEnabled: boolean = false
  ): TapZoneAction {
    const action: TapZoneAction = resolveTapZoneAction(
      normalizedX, normalizedY, this.mode, doubleTapZoomEnabled
    );
    if (action === TapZoneAction.TOGGLE_HUD) {
      this.toggleHud();
    } else if (action === TapZoneAction.NEXT_PAGE) {
      this.nextPage();
    } else if (action === TapZoneAction.PREV_PAGE) {
      this.prevPage();
    }
    return action;
  }

  /** 初始化章节列表与当前章节下标 */
  setChapters(chapters: ReaderChapterItem[], currentChapterId: string): void {
    this.chapters = chapters.slice();
    this.updateCurrentChapterId(currentChapterId);
  }

  updateCurrentChapterId(chapterId: string): void {
    this.boundaryNotice = '';
    for (let i = 0; i < this.chapters.length; i++) {
      if (this.chapters[i].id === chapterId) {
        this.currentChapterIndex = i;
        return;
      }
    }
    this.currentChapterIndex = -1;
  }

  hasPrevChapter(): boolean {
    return this.currentChapterIndex > 0;
  }

  hasNextChapter(): boolean {
    return this.currentChapterIndex >= 0 && this.currentChapterIndex < this.chapters.length - 1;
  }

  prevChapter(): ReaderChapterItem | null {
    if (!this.hasPrevChapter()) {
      this.boundaryNotice = '已是第一章';
      return null;
    }
    this.boundaryNotice = '';
    this.currentChapterIndex = this.currentChapterIndex - 1;
    return this.chapters[this.currentChapterIndex];
  }

  nextChapter(): ReaderChapterItem | null {
    if (!this.hasNextChapter()) {
      this.boundaryNotice = '已是最后一章';
      return null;
    }
    this.boundaryNotice = '';
    this.currentChapterIndex = this.currentChapterIndex + 1;
    return this.chapters[this.currentChapterIndex];
  }

  selectChapter(chapterId: string): ReaderChapterItem | null {
    for (let i = 0; i < this.chapters.length; i++) {
      if (this.chapters[i].id === chapterId) {
        this.boundaryNotice = '';
        this.currentChapterIndex = i;
        return this.chapters[i];
      }
    }
    return null;
  }
}
