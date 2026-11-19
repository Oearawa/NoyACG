/**
 * ReaderTypes.ets —— 阅读器核心类型定义（无 ArkUI 依赖，原生独立实现）
 */

/** 阅读模式 */
export enum ReaderMode {
  /** 连续上下条漫模式（国漫/韩漫长图） */
  VERTICAL_STRIP = 'vertical_strip',
  /** 单页从左到右翻页 */
  PAGE_LTR = 'page_ltr',
  /** 单页从右到左日漫翻页 */
  PAGE_RTL = 'page_rtl'
}

/** 屏幕点击热区动作 */
export enum TapZoneAction {
  PREV_PAGE = 'prev_page',
  TOGGLE_HUD = 'toggle_hud',
  NEXT_PAGE = 'next_page'
}

/** 阅读器章节目录项 */
export class ReaderChapterItem {
  readonly id: string;
  readonly title: string;
  readonly order: number;

  constructor(id: string, title: string, order: number = 0) {
    this.id = id;
    this.title = title;
    this.order = order;
  }
}

/** 阅读进度快照（含阅读模式） */
export class ReadingProgressSnapshot {
  readonly comicId: string;
  readonly chapterId: string;
  readonly chapterTitle: string;
  /** 1-based 页码，兼容 HistoryV2 存储契约 */
  readonly pageIndex: number;
  readonly totalPages: number;
  readonly readingMode: ReaderMode;
  readonly updateTime: number;
  readonly scrollOffsetRatio: number;

  constructor(
    comicId: string,
    chapterId: string,
    chapterTitle: string,
    pageIndex: number,
    totalPages: number,
    readingMode: ReaderMode,
    updateTime: number,
    scrollOffsetRatio: number = 0
  ) {
    this.comicId = comicId;
    this.chapterId = chapterId;
    this.chapterTitle = chapterTitle;
    this.pageIndex = pageIndex;
    this.totalPages = totalPages;
    this.readingMode = readingMode;
    this.updateTime = updateTime;
    this.scrollOffsetRatio = scrollOffsetRatio;
  }
}

/** 阅读器 HUD 安全区避让尺寸（vp） */
export class ReaderHudInsets {
  readonly topVp: number;
  readonly bottomVp: number;

  constructor(topVp: number, bottomVp: number) {
    this.topVp = topVp;
    this.bottomVp = bottomVp;
  }
}
