/**
 * BreakpointManager.ets —— 官方四档窗口宽度断点与栅格分配器
 *
 * 严格遵循 ArkTS 静态类型约束，纯函数零 UI 依赖，兼容分屏、折叠屏与自由窗口：
 * - xs: [0, 320)
 * - sm: [320, 600)
 * - md: [600, 840)
 * - lg: >= 840
 */

export enum Breakpoint {
  XS = 'xs',
  SM = 'sm',
  MD = 'md',
  LG = 'lg'
}

export const BREAKPOINT_SM_MIN: number = 320;
export const BREAKPOINT_MD_MIN: number = 600;
export const BREAKPOINT_LG_MIN: number = 840;

export interface DetailColumnSpans {
  leftSpan: number;
  rightSpan: number;
}

/**
 * 根据可用窗口宽度（vp）解析四档响应式断点。
 * 非法或负值安全兜底为 SM。
 */
export function resolveBreakpoint(widthVp: number): Breakpoint {
  if (!Number.isFinite(widthVp) || widthVp < 0) {
    return Breakpoint.SM;
  }
  if (widthVp < BREAKPOINT_SM_MIN) {
    return Breakpoint.XS;
  }
  if (widthVp < BREAKPOINT_MD_MIN) {
    return Breakpoint.SM;
  }
  if (widthVp < BREAKPOINT_LG_MIN) {
    return Breakpoint.MD;
  }
  return Breakpoint.LG;
}

/** 是否宽屏断点（md / lg） */
export function isWideBreakpoint(bp: Breakpoint): boolean {
  return bp === Breakpoint.MD || bp === Breakpoint.LG;
}

/** 漫画详情页 12 栅格左右分栏跨度 */
export function resolveDetailColumnSpans(bp: Breakpoint): DetailColumnSpans {
  if (bp === Breakpoint.LG) {
    return { leftSpan: 4, rightSpan: 8 };
  }
  if (bp === Breakpoint.MD) {
    return { leftSpan: 5, rightSpan: 7 };
  }
  return { leftSpan: 12, rightSpan: 12 };
}
