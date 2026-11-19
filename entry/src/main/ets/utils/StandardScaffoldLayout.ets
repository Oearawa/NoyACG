/**
 * StandardScaffoldLayout.ets —— 二级页面公共骨架与 FilterBar 纯函数布局契约
 *
 * 零 ArkUI 依赖，供 StandardPageScaffold / SearchPage 与单元测试共用：
 * 1. 统一顶栏高度与返回热区（>= 40vp）；
 * 2. 统一四态状态机解析（loading / error / empty / content）；
 * 3. FilterBar 窄屏（< 520vp，含 360vp 竖屏）水平滚动防错位判据；
 * 4. 宽屏最大内容宽度与底部安全区偏移计算。
 */
import { normalizeAvoid } from './BottomInset';

export const SCAFFOLD_TOP_BAR_HEIGHT_VP: number = 52;
export const INLINE_TOP_BAR_HEIGHT_VP: number = 52;
export const INLINE_HEADER_MIN_WIDTH_VP: number = 600;
export const SCAFFOLD_BACK_TARGET_VP: number = 44;
export const FILTER_BAR_SCROLL_BREAKPOINT_VP: number = 520;

/**
 * 二级页面（排行榜 / 搜索）是否合并为单行紧凑顶栏（纯函数，可单测）：
 * 横屏（widthVp > heightVp）或宽屏（widthVp >= 600vp）时返回 true，将标题与筛选/搜索控件合并为 52vp 单行。
 */
export function shouldUseInlineSecondaryHeader(widthVp: number, heightVp: number): boolean {
  if (Number.isFinite(widthVp) && widthVp >= INLINE_HEADER_MIN_WIDTH_VP) {
    return true;
  }
  if (Number.isFinite(widthVp) && Number.isFinite(heightVp) && widthVp > 0 && heightVp > 0) {
    return widthVp > heightVp;
  }
  return false;
}

export function secondaryHeaderTotalHeightVp(safeAreaTopVp: number, inlineMode: boolean): number {
  return normalizeAvoid(safeAreaTopVp) + (inlineMode ? INLINE_TOP_BAR_HEIGHT_VP : SCAFFOLD_TOP_BAR_HEIGHT_VP);
}

export interface ScaffoldTopBarDecoration {
  transparentHeader: boolean;
  backgroundColor: string;
  bottomBorderWidthVp: number;
  useSystemMaterial: boolean;
}

/**
 * 解析二级页面顶栏装饰配置（纯函数，可单测）：
 * - transparentHeader === true（如漫画详情页 / 首页）：背景完全透明（'#00000000'）、无底部分割线（0vp）、
 *   不挂载顶栏遮罩材质，直接露出页面整体底色；
 * - transparentHeader === false：启用系统材质（或回退至 fallbackSurfaceColor + 1vp 底部分割线）。
 */
export function resolveScaffoldTopBarDecoration(
  transparentHeader: boolean,
  hasSystemMaterial: boolean,
  fallbackSurfaceColor: string
): ScaffoldTopBarDecoration {
  if (transparentHeader) {
    return {
      transparentHeader: true,
      backgroundColor: '#00000000',
      bottomBorderWidthVp: 0,
      useSystemMaterial: false
    };
  }
  return {
    transparentHeader: false,
    backgroundColor: fallbackSurfaceColor,
    bottomBorderWidthVp: 1,
    useSystemMaterial: hasSystemMaterial
  };
}

export type ScaffoldContentState = 'loading' | 'error' | 'empty' | 'content';

/**
 * 统一四态裁决：
 * - 已有数据时（hasContent=true）不切回整页 Loading，避免下拉刷新/翻页闪白；
 * - 无数据且正在加载 → loading；
 * - 有错误消息且无数据 → error；
 * - 无数据且 isEmpty → empty；
 * - 其余 → content。
 */
export function resolveScaffoldState(
  isLoading: boolean,
  hasContent: boolean,
  errorMessage: string,
  isEmpty: boolean
): ScaffoldContentState {
  if (isLoading && !hasContent) {
    return 'loading';
  }
  if (errorMessage.trim() !== '' && !hasContent) {
    return 'error';
  }
  if (isEmpty && !hasContent) {
    return 'empty';
  }
  return 'content';
}

export function scaffoldTopBarTotalHeightVp(safeAreaTopVp: number): number {
  return normalizeAvoid(safeAreaTopVp) + SCAFFOLD_TOP_BAR_HEIGHT_VP;
}

export function scaffoldBottomInsetVp(safeAreaBottomVp: number, extraBottomVp: number = 0): number {
  const safeBottom: number = normalizeAvoid(safeAreaBottomVp);
  const extra: number = Number.isFinite(extraBottomVp) && extraBottomVp > 0 ? extraBottomVp : 0;
  return safeBottom + extra;
}

/** R2 修复：360vp 竖屏及窄屏（< 520vp）下 FilterBar 启用水平滑动容器，避免三枚 Select 溢出/错位 */
export function shouldScrollFilterBar(containerWidthVp: number): boolean {
  if (!Number.isFinite(containerWidthVp) || containerWidthVp <= 0) {
    return true;
  }
  return containerWidthVp < FILTER_BAR_SCROLL_BREAKPOINT_VP;
}

export function scaffoldConstrainedWidthVp(
  containerWidthVp: number,
  maxContentWidthVp: number
): number | undefined {
  if (!Number.isFinite(containerWidthVp) || containerWidthVp <= 0 ||
    !Number.isFinite(maxContentWidthVp) || maxContentWidthVp <= 0) {
    return undefined;
  }
  return containerWidthVp > maxContentWidthVp ? maxContentWidthVp : undefined;
}
