/**
 * Geometry.ets —— 窗口几何换算纯函数（Phase 15-R2 · R2-5）
 *
 * 为什么不把密度缓存进静态常量：
 *   折叠屏展开 / 收起、外接显示、投屏、显示大小设置变化时，密度会变；
 *   一旦永久缓存，px→vp 换算会在整段生命周期里用错比例，进而把窗口尺寸算错，
 *   导航形态与内容留白都会跟着错。因此密度**每次采样都重读**，这里只提供纯换算。
 */

/** 兜底密度（取不到系统密度时使用；仅避免除零，不参与形态判定） */
export const FALLBACK_DENSITY: number = 3.0;

/**
 * 归一化屏幕密度：非有限 / <= 0 一律回退 FALLBACK_DENSITY。
 * @param density display.getDefaultDisplaySync().densityPixels 的原始值
 */
export function normalizeDensity(density: number): number {
  if (!Number.isFinite(density) || density <= 0) {
    return FALLBACK_DENSITY;
  }
  return density;
}

/**
 * px → vp。非法输入返回 0，绝不抛异常、绝不返回 NaN。
 * @param px 物理像素
 * @param density 归一化前的密度（内部再归一化）
 */
export function pxToVp(px: number, density: number): number {
  if (!Number.isFinite(px) || px <= 0) {
    return 0;
  }
  return px / normalizeDensity(density);
}
