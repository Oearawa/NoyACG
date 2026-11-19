/**
 * LayoutPolicy.ets —— 全仓统一响应式布局策略计算器
 *
 * 所有网格列数、单卡宽度、3:4 封面高度、横向列表栏数与容器边距均由此纯函数派生，
 * 主判定依据为窗口宽度四档断点（兼容分屏窄宽横屏、折叠屏与自由窗口）。
 */
import { Breakpoint, resolveBreakpoint } from './BreakpointManager';
import { buildColumnsTemplate } from '../utils/ResponsiveGrid';

export const COVER_ASPECT_RATIO: number = 0.75;
export const MIN_GRID_CARD_WIDTH_VP: number = 156;
export const MAX_GRID_CARD_WIDTH_VP: number = 220;
const DEFAULT_FALLBACK_WIDTH_VP: number = 390;

export interface ResponsiveLayoutMetrics {
  breakpoint: Breakpoint;
  isLandscape: boolean;
  availableWidthVp: number;
  pagePaddingVp: number;
  gridGapVp: number;
  gridColumns: number;
  gridColumnsTemplate: string;
  cardWidthVp: number;
  coverHeightVp: number;
  listLanes: number;
  listGutterVp: number;
  posterCardWidthVp: number;
}

/** 各断点标准水平外边距（xs/sm: 12vp, md/lg: 16vp） */
export function resolveGridPaddingVp(bp: Breakpoint): number {
  if (bp === Breakpoint.MD || bp === Breakpoint.LG) {
    return 16;
  }
  return 12;
}

/** 各断点网格间距 */
export function resolveGridGapVp(bp: Breakpoint): number {
  if (bp === Breakpoint.XS) {
    return 8;
  }
  if (bp === Breakpoint.SM) {
    return 10;
  }
  return 12;
}

/** 各断点基础网格列数（xs/sm: 2 列，md/lg: 4 列起算） */
export function resolveBaseGridColumns(bp: Breakpoint): number {
  if (bp === Breakpoint.MD || bp === Breakpoint.LG) {
    return 4;
  }
  return 2;
}

/** 各断点横向内容列表栏数（xs/sm: 1 栏，md: 2 栏，lg: 2 或 3 栏） */
export function resolveListLanes(bp: Breakpoint, allowThreeOnLg: boolean = false): number {
  if (bp === Breakpoint.MD) {
    return 2;
  }
  if (bp === Breakpoint.LG) {
    return allowThreeOnLg ? 3 : 2;
  }
  return 1;
}

/** 各断点横向海报行单卡宽度 */
export function resolvePosterCardWidthVp(bp: Breakpoint): number {
  if (bp === Breakpoint.XS) {
    return 116;
  }
  if (bp === Breakpoint.MD) {
    return 144;
  }
  if (bp === Breakpoint.LG) {
    return 156;
  }
  return 128;
}

/**
 * 计算完整响应式布局指标。
 * @param widthVp 当前可用容器或窗口宽度（vp）
 * @param isLandscape 物理/窗口方向标识（仅作附带诊断/导航参考，不覆盖窄宽分屏列数）
 */
export function resolveLayoutPolicy(widthVp: number, isLandscape: boolean = false): ResponsiveLayoutMetrics {
  const effectiveWidth: number = Number.isFinite(widthVp) && widthVp > 0
    ? widthVp
    : DEFAULT_FALLBACK_WIDTH_VP;
  const bp: Breakpoint = resolveBreakpoint(effectiveWidth);
  const pagePaddingVp: number = resolveGridPaddingVp(bp);
  const gridGapVp: number = resolveGridGapVp(bp);
  const availableWidthVp: number = Math.max(0, effectiveWidth - pagePaddingVp * 2);

  let cols: number = resolveBaseGridColumns(bp);
  let rawCardW: number = (availableWidthVp - (cols - 1) * gridGapVp) / cols;
  while (rawCardW > MAX_GRID_CARD_WIDTH_VP && cols < 6) {
    const nextCols: number = cols + 1;
    const nextCardW: number = (availableWidthVp - (nextCols - 1) * gridGapVp) / nextCols;
    if (nextCardW < MIN_GRID_CARD_WIDTH_VP) {
      break;
    }
    cols = nextCols;
    rawCardW = nextCardW;
  }

  const cardWidthVp: number = Math.max(1, rawCardW);
  const coverHeightVp: number = cardWidthVp / COVER_ASPECT_RATIO;
  const listLanes: number = resolveListLanes(bp, false);
  const listGutterVp: number = listLanes >= 2 ? 12 : 0;

  return {
    breakpoint: bp,
    isLandscape: isLandscape,
    availableWidthVp: availableWidthVp,
    pagePaddingVp: pagePaddingVp,
    gridGapVp: gridGapVp,
    gridColumns: cols,
    gridColumnsTemplate: buildColumnsTemplate(cols),
    cardWidthVp: cardWidthVp,
    coverHeightVp: coverHeightVp,
    listLanes: listLanes,
    listGutterVp: listGutterVp,
    posterCardWidthVp: resolvePosterCardWidthVp(bp)
  };
}
