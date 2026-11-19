/**
 * WindowClass.ets —— 窗口尺寸类别（纯函数，无任何 ArkUI 依赖，便于单测）
 *
 * ★ Phase 15-R2 职责收缩：本文件**只服务内容布局**（网格列数 / 留白 / 海报卡宽度）。
 *   导航形态（底栏 / 侧栏）已改由 utils/NavigationMode.ets 按根窗口宽高比判定，
 *   与这里的 600 / 840vp 断点**完全解耦**——旧实现用 classifyWidth(内容宽度) 决定
 *   vertical/barPosition，导致同一竖屏（939.6vp）被判成 expanded 而出现侧栏（S1）。
 *
 * 阈值来源：HarmonyOS 常见断点约定（sm < 600 / md 600-840 / lg ≥ 840）。
 * 600 / 840 两个边界值按任务书要求单测覆盖。
 *
 * 重要约束：写入状态时只按「类别变化」写一次，不要逐像素回写
 * —— 频繁回写会触发整树重渲染导致图片错位。
 */
export enum WindowSizeClass {
  /** 紧凑（手机竖屏 / 窄窗口）：< 600vp */
  COMPACT = 'compact',
  /** 中等（手机横屏 / 窄平板）：600–840vp */
  MEDIUM = 'medium',
  /** 宽（平板 / 桌面窗口）：≥ 840vp */
  EXPANDED = 'expanded'
}

/** compact 与 medium 的分界宽度（vp） */
export const WIDTH_COMPACT_MAX: number = 600;
/** medium 与 expanded 的分界宽度（vp） */
export const WIDTH_MEDIUM_MAX: number = 840;

/**
 * 按宽度（vp）分类窗口。
 * - < 600 → COMPACT
 * - 600 ≤ w < 840 → MEDIUM
 * - ≥ 840 → EXPANDED
 * NaN / 负数 / 0 → COMPACT（不抛异常，保证旋转或悬浮窗初始 0 宽时布局稳定）。
 */
export function classifyWidth(widthVp: number): WindowSizeClass {
  if (!Number.isFinite(widthVp) || widthVp <= 0) {
    return WindowSizeClass.COMPACT;
  }
  if (widthVp < WIDTH_COMPACT_MAX) {
    return WindowSizeClass.COMPACT;
  }
  if (widthVp < WIDTH_MEDIUM_MAX) {
    return WindowSizeClass.MEDIUM;
  }
  return WindowSizeClass.EXPANDED;
}
