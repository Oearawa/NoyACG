/**
 * ReaderLayout.ets —— 阅读器纯函数布局、点击热区与页码边界计算（无 ArkUI 依赖）
 */
import { normalizeAvoid } from '../utils/BottomInset';
import { ReaderHudInsets, ReaderMode, TapZoneAction } from './ReaderTypes';

export const READER_WIDE_BREAKPOINT_VP: number = 600;
export const READER_STRIP_MAX_WIDTH_VP: number = 760;
export const READER_HUD_BACK_TARGET_VP: number = 44;
/** 条漫模式滚动摩擦系数（抑制轻划过度惯性飞页） */
export const READER_STRIP_FRICTION: number = 1.35;
/** 垂直滚动模式整屏翻页步进比例（严格 1.0 倍视口高度，不留 15% 上一页残留） */
export const READER_VERTICAL_PAGE_STEP_RATIO: number = 1.0;
/** 翻页模式单页切换动画时长（ms） */
export const READER_PAGE_SWIPE_DURATION_MS: number = 220;
/** 翻页模式 Swiper 缓存与同屏展示页数（前后各预缓存 2 页，消除翻页闪烁） */
export const READER_PAGE_CACHED_COUNT: number = 2;
export const READER_PAGE_DISPLAY_COUNT: number = 1;
/** 阅读器浅/深色自适应画布底色 */
export const READER_LIGHT_BG_COLOR: string = '#F7F8FA';
export const READER_DARK_BG_COLOR: string = '#121212';

export function resolveReaderBackgroundColor(isDark: boolean): string {
  return isDark ? READER_DARK_BG_COLOR : READER_LIGHT_BG_COLOR;
}

export function resolveReaderStatusBarContentColor(isDark: boolean): string {
  return isDark ? '#F8FAFC' : '#1E2430';
}

export class ReaderPageWindow {
  readonly prefetchStart: number;
  readonly prefetchEnd: number;
  readonly retainStart: number;
  readonly retainEnd: number;

  constructor(prefetchStart: number, prefetchEnd: number, retainStart: number, retainEnd: number) {
    this.prefetchStart = prefetchStart;
    this.prefetchEnd = prefetchEnd;
    this.retainStart = retainStart;
    this.retainEnd = retainEnd;
  }
}

/** 计算阅读器滑动窗口：Prefetch [-2, +4]，Retain [-5, +8] */
export function computeReaderPageWindow(currentIndex: number, totalPages: number): ReaderPageWindow {
  if (!Number.isFinite(totalPages) || totalPages <= 0) {
    return new ReaderPageWindow(0, -1, 0, -1);
  }
  const safeTotal: number = Math.floor(totalPages);
  const center: number = clampPageIndex(currentIndex, safeTotal);
  return new ReaderPageWindow(
    Math.max(0, center - 2),
    Math.min(safeTotal - 1, center + 4),
    Math.max(0, center - 5),
    Math.min(safeTotal - 1, center + 8)
  );
}

const TAP_LEFT_RATIO: number = 0.30;
const TAP_RIGHT_RATIO: number = 0.70;
const STRIP_TOP_EDGE_RATIO: number = 0.25;
const STRIP_BOTTOM_EDGE_RATIO: number = 0.75;
const STRIP_DOUBLE_TAP_TOP_RATIO: number = 0.30;
const STRIP_DOUBLE_TAP_BOTTOM_RATIO: number = 0.70;

/**
 * 自适应阅读器点击热区纯函数：
 * - doubleTapZoomEnabled = true：
 *   - PAGE_LTR / PAGE_RTL：中心上下贯穿带 x ∈ [0.30W, 0.70W], y ∈ [0, H] 呼出菜单；左右两侧翻页
 *   - VERTICAL_STRIP：中心左右贯穿带 x ∈ [0, W], y ∈ [0.30H, 0.70H] 呼出菜单；上下两侧翻页/滚屏
 * - doubleTapZoomEnabled = false：
 *   - PAGE_LTR / PAGE_RTL：x ∈ [0.30W, 0.70W] 呼出菜单；左右两侧翻页
 *   - VERTICAL_STRIP：y ∈ [0.25H, 0.75H] 呼出菜单；上下两侧翻页/滚屏
 */
export function resolveReaderTapAction(
  x: number,
  y: number,
  width: number,
  height: number,
  readingMode: ReaderMode,
  doubleTapZoomEnabled: boolean = true
): TapZoneAction {
  const safeW: number = Number.isFinite(width) && width > 0 ? width : 1;
  const safeH: number = Number.isFinite(height) && height > 0 ? height : 1;
  const normX: number = Number.isFinite(x) ? Math.max(0, Math.min(x / safeW, 1)) : 0.5;
  const normY: number = Number.isFinite(y) ? Math.max(0, Math.min(y / safeH, 1)) : 0.5;

  if (readingMode === ReaderMode.VERTICAL_STRIP) {
    const topEdge: number = doubleTapZoomEnabled ? STRIP_DOUBLE_TAP_TOP_RATIO : STRIP_TOP_EDGE_RATIO;
    const bottomEdge: number = doubleTapZoomEnabled ? STRIP_DOUBLE_TAP_BOTTOM_RATIO : STRIP_BOTTOM_EDGE_RATIO;
    if (normY < topEdge) {
      return TapZoneAction.PREV_PAGE;
    }
    if (normY > bottomEdge) {
      return TapZoneAction.NEXT_PAGE;
    }
    return TapZoneAction.TOGGLE_HUD;
  }

  if (normX < TAP_LEFT_RATIO) {
    return readingMode === ReaderMode.PAGE_RTL ? TapZoneAction.NEXT_PAGE : TapZoneAction.PREV_PAGE;
  }
  if (normX > TAP_RIGHT_RATIO) {
    return readingMode === ReaderMode.PAGE_RTL ? TapZoneAction.PREV_PAGE : TapZoneAction.NEXT_PAGE;
  }
  return TapZoneAction.TOGGLE_HUD;
}

/**
 * 屏幕点击热区纯函数判定（归一化坐标版本）：
 * 委托至 resolveReaderTapAction 保持规则完全一致。
 */
export function resolveTapZoneAction(
  normalizedX: number,
  normalizedY: number,
  mode: ReaderMode,
  doubleTapZoomEnabled: boolean = false
): TapZoneAction {
  return resolveReaderTapAction(normalizedX, normalizedY, 1, 1, mode, doubleTapZoomEnabled);
}

/** 0-based 页码下标钳制到 [0, max(totalPages - 1, 0)] */
export function clampPageIndex(pageIndex: number, totalPages: number): number {
  if (!Number.isFinite(totalPages) || totalPages <= 0) {
    return 0;
  }
  const maxIndex: number = Math.floor(totalPages) - 1;
  if (!Number.isFinite(pageIndex)) {
    return 0;
  }
  return Math.max(0, Math.min(Math.floor(pageIndex), maxIndex));
}

/** 1-based 页码钳制到 [1, max(totalPages, 1)] */
export function clampPageNumber(pageNumber: number, totalPages: number): number {
  const safeTotal: number = Number.isFinite(totalPages) && totalPages > 0 ? Math.floor(totalPages) : 1;
  if (!Number.isFinite(pageNumber)) {
    return 1;
  }
  return Math.max(1, Math.min(Math.floor(pageNumber), safeTotal));
}

/** Slider 值（1-based）→ 0-based 页码下标，安全处理 totalPages = 0 / 1 / N */
export function sliderValueToPageIndex(sliderValue: number, totalPages: number): number {
  if (!Number.isFinite(totalPages) || totalPages <= 1) {
    return 0;
  }
  const pageNum: number = clampPageNumber(Math.round(sliderValue), totalPages);
  return clampPageIndex(pageNum - 1, totalPages);
}

/** 0-based 页码下标 → Slider 值（1-based），安全处理 totalPages = 0 / 1 / N */
export function pageIndexToSliderValue(pageIndex: number, totalPages: number): number {
  if (!Number.isFinite(totalPages) || totalPages <= 0) {
    return 1;
  }
  return clampPageIndex(pageIndex, totalPages) + 1;
}

/**
 * 宽屏（>= 600vp）条漫限宽居中计算：
 * - < 600vp：占满视口宽度
 * - >= 600vp：限制在 READER_STRIP_MAX_WIDTH_VP（760vp）以内居中展示
 */
export function computeReaderStripWidthVp(viewportWidthVp: number): number {
  if (!Number.isFinite(viewportWidthVp) || viewportWidthVp <= 0) {
    return 0;
  }
  if (viewportWidthVp >= READER_WIDE_BREAKPOINT_VP) {
    return Math.min(viewportWidthVp, READER_STRIP_MAX_WIDTH_VP);
  }
  return viewportWidthVp;
}

/** 根据阅读模式与视口宽度计算内容列宽度（仅宽屏条漫模式限宽居中 <= 760vp，其余模式占满视口） */
export function computeReaderContentWidthVp(viewportWidthVp: number, readingMode: ReaderMode): number {
  if (!Number.isFinite(viewportWidthVp) || viewportWidthVp <= 0) {
    return 0;
  }
  if (readingMode === ReaderMode.VERTICAL_STRIP && viewportWidthVp >= READER_WIDE_BREAKPOINT_VP) {
    return Math.min(viewportWidthVp, READER_STRIP_MAX_WIDTH_VP);
  }
  return viewportWidthVp;
}

/** 计算 HUD 上下安全区避让偏移 */
export function computeReaderHudInsets(topSafeVp: number, bottomSafeVp: number): ReaderHudInsets {
  return new ReaderHudInsets(normalizeAvoid(topSafeVp), normalizeAvoid(bottomSafeVp));
}

/** 阅读模式显示名称 */
export function readerModeLabel(mode: ReaderMode): string {
  if (mode === ReaderMode.PAGE_LTR) {
    return '由左至右';
  }
  if (mode === ReaderMode.PAGE_RTL) {
    return '由右至左';
  }
  return '垂直滚动';
}

/**
 * 计算垂直滚动模式单次整屏推进距离（vp）：
 * 严格等于 1.0 * viewportHeightVp，消除旧版 0.85 倍率导致的 15% 上一页残留。
 */
export function computeVerticalPageTurnStepVp(viewportHeightVp: number): number {
  if (!Number.isFinite(viewportHeightVp) || viewportHeightVp <= 0) {
    return 0;
  }
  return viewportHeightVp * READER_VERTICAL_PAGE_STEP_RATIO;
}

/** 根据阅读设置「翻页动画」开关解析点击/按键翻页是否启用平滑动画 */
export function resolvePageTurnAnimated(pageTurnAnimationEnabled: boolean): boolean {
  return Boolean(pageTurnAnimationEnabled);
}

export type HorizontalTurnControllerAction = 'none' | 'show_next' | 'show_prev' | 'jump_index';

/**
 * 解析横向翻页模式（PAGE_LTR / PAGE_RTL）下点击/按键翻页应调用的 SwiperController 动作：
 * - 越界时返回 'none'；
 * - 开启「翻页动画」（pageTurnAnimationEnabled = true）时返回 'show_next' / 'show_prev'，
 *   调用 SwiperController.showNext() / showPrevious() 触发原生平滑滑动动画，并由 Swiper.onChange 同步页码；
 * - 关闭「翻页动画」（pageTurnAnimationEnabled = false）时返回 'jump_index'，
 *   调用 SwiperController.changeIndex(targetIndex, false) 无动画瞬切。
 */
export function resolveHorizontalTurnControllerAction(
  currentPageIndex: number,
  totalPages: number,
  delta: number,
  pageTurnAnimationEnabled: boolean
): HorizontalTurnControllerAction {
  if (!Number.isFinite(totalPages) || totalPages <= 0 || !Number.isFinite(delta) || delta === 0) {
    return 'none';
  }
  const safeTotal: number = Math.floor(totalPages);
  const safeCurrent: number = clampPageIndex(currentPageIndex, safeTotal);
  if (delta < 0 && safeCurrent <= 0) {
    return 'none';
  }
  if (delta > 0 && safeCurrent >= safeTotal - 1) {
    return 'none';
  }
  if (resolvePageTurnAnimated(pageTurnAnimationEnabled)) {
    return delta > 0 ? 'show_next' : 'show_prev';
  }
  return 'jump_index';
}
