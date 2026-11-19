/**
 * NavInteraction.ets —— 导航交互的纯策略函数（Phase 15-R2.1）
 *
 * 把「页签下标怎么提交」「返回首页要不要刷新书架」这类判断从 UI 代码里抽出来，
 * 好处有两个：
 *   1. 可以在宿主单测里覆盖，不必依赖真实渲染；
 *   2. 全工程只有一份语义，避免 Index / SideRail / 路由拦截各写一遍条件。
 *
 * 本文件无 ArkUI 依赖，不持有状态。
 */

/**
 * 页签切换是否需要提交。
 * Tabs 在重建、属性变化（如窗口形态切换）时可能回放一次相同下标，
 * 此时不应重复执行切换副作用（书架刷新、用户页刷新计数）。
 */
export function shouldCommitTab(currentIndex: number, incomingIndex: number): boolean {
  return currentIndex !== incomingIndex;
}

/**
 * 提交页签下标：等同则原样返回（不产生新的赋值），否则取新值。
 * 与 Tabs 的 `index` 单向入参配合使用，保证「点击切换」与「程序切换」只有一条写入路径。
 */
export function commitTabIndex(currentIndex: number, incomingIndex: number): number {
  return shouldCommitTab(currentIndex, incomingIndex) ? incomingIndex : currentIndex;
}

/** 页签下标夹取到 [0, count-1]；非法输入回落到 0，避免 index 越界导致 Tabs 空白。 */
export function clampTabIndex(index: number, count: number): number {
  if (!Number.isFinite(index) || count <= 0) {
    return 0;
  }
  if (index < 0) {
    return 0;
  }
  if (index > count - 1) {
    return count - 1;
  }
  return Math.floor(index);
}

/**
 * 路由页面显示时是否需要刷新书架。
 * 只有「POP 返回」且「目标是根页（Tabs）」时才算——页面之间的 POP
 * 不应该改动书架，PUSH 更不应该。
 */
export function shouldRefreshShelfOnPop(isPop: boolean, toIsNavBar: boolean): boolean {
  return isPop && toIsNavBar;
}
