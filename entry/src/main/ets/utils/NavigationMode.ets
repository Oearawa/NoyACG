/**
 * NavigationMode.ets —— 导航形态的唯一判定器（Phase 15-R2）
 *
 * 设计约束（本阶段任务书 R2-1）：
 *   1. 纯函数，无 ArkUI 依赖、无状态、可单测；
 *   2. 输入只有「根窗口宽度 / 高度（vp）」两个数，绝不接受 onAreaChange 的内容宽度、
 *      滚动位置、手势方向等任何内容侧信号 —— 从结构上消除
 *      「出现侧栏 → 内容变窄 → 重新判定 → 变回侧栏」的反馈环（对应 S1）；
 *   3. 600 / 840vp 的内容断点（WindowClass）只服务卡片列数与留白，不参与导航判定。
 *
 * 阈值（宽高比 ratio = 宽 / 高）：
 *   冷启动            ratio >= 1.20 → 侧栏，否则底栏
 *   当前底栏          ratio >= 1.25 → 侧栏，其余保持底栏
 *   当前侧栏          ratio <= 1.15 → 底栏，其余保持侧栏
 *   1.15 ~ 1.25 为滞回带，窗口在临界附近抖动时形态不来回切换。
 */

/** 导航形态。只有两种，互斥，不存在并存或中间态。 */
export enum NavigationMode {
  /** 沉浸光感底部悬浮导航（竖屏 / 方形窗口 / 折叠外屏与展开竖屏） */
  BOTTOM_IMMERSIVE = 'BOTTOM_IMMERSIVE',
  /** 侧边导航（宽窗口 / 横屏） */
  SIDE = 'SIDE'
}

/** 冷启动首次判定阈值：ratio >= 1.20 视为宽窗口 */
export const INITIAL_SIDE_RATIO: number = 1.20;
/** 底栏 → 侧栏 的进入阈值（滞回上界） */
export const SIDE_ENTER_RATIO: number = 1.25;
/** 侧栏 → 底栏 的进入阈值（滞回下界） */
export const BOTTOM_ENTER_RATIO: number = 1.15;
/** 阈值比较容差：只吸收浮点误差（1e-6），不改变任何一档的语义。 */
const RATIO_EPSILON: number = 1e-6;

/**
 * 根窗口宽高比。非法 / 非有限 / 非正数一律返回 0（视为未知），
 * 调用方据此保持当前形态，绝不猜测设备类型。
 */
export function windowAspectRatio(widthVp: number, heightVp: number): number {
  if (!Number.isFinite(widthVp) || !Number.isFinite(heightVp) || widthVp <= 0 || heightVp <= 0) {
    return 0;
  }
  return widthVp / heightVp;
}

/**
 * 解析导航形态。
 * @param widthVp 根窗口宽度（vp）
 * @param heightVp 根窗口高度（vp）
 * @param current 当前形态；undefined 表示冷启动首次判定
 */
export function resolveNavigationMode(widthVp: number, heightVp: number,
  current?: NavigationMode): NavigationMode {
  const ratio: number = windowAspectRatio(widthVp, heightVp);
  if (ratio <= 0) {
    // 尺寸未知（首帧前 / 折叠中间态）：保持既有形态；
    // 冷启动给底栏这一安全默认，它会在拿到真实尺寸的同一帧被纠正。
    return current === undefined ? NavigationMode.BOTTOM_IMMERSIVE : current;
  }
  if (current === undefined) {
    return ratio + RATIO_EPSILON >= INITIAL_SIDE_RATIO
      ? NavigationMode.SIDE : NavigationMode.BOTTOM_IMMERSIVE;
  }
  if (current === NavigationMode.BOTTOM_IMMERSIVE) {
    return ratio + RATIO_EPSILON >= SIDE_ENTER_RATIO
      ? NavigationMode.SIDE : NavigationMode.BOTTOM_IMMERSIVE;
  }
  return ratio <= BOTTOM_ENTER_RATIO + RATIO_EPSILON
    ? NavigationMode.BOTTOM_IMMERSIVE : NavigationMode.SIDE;
}

/** 单点判断：该形态是否为底部导航（全应用唯一判断口，禁止各页面自写条件） */
export function isBottomNavigation(mode: NavigationMode): boolean {
  return mode === NavigationMode.BOTTOM_IMMERSIVE;
}
