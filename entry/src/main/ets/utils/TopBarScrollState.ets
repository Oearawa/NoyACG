/**
 * TopBarScrollState.ets —— 顶栏滚动收起状态机（纯函数，无 UI 依赖，可单测）
 *
 * 契约（p1-native-material-shell / architect）：
 *   interface TopBarScrollState { collapsed; accumVp; lastOffsetVp }
 *   interface TopBarScrollConfig  { collapseThresholdVp=24; expandThresholdVp=8;
 *                                   debounceVp=0.5; animationMs=180; curve='FastOutSlowIn' }
 *   nextTopBarState(prev, deltaVp, cfg): TopBarScrollState —— 纯函数：
 *     - 向下累计 >= collapseThresholdVp(24vp) → collapsed = true（收起）
 *     - 向上累计 <= -expandThresholdVp(8vp)  → collapsed = false（恢复）
 *     - 方向翻转时重置累计（以本次 delta 重新起算）
 *     - |delta| < debounceVp(0.5vp) 完全忽略（不推进任何字段）
 *
 * 本文件只做「状态演算」，不接触 ArkUI：形态翻转时的动画参数（animationMs/curve）
 * 由接线方（pages/Index.ets）按 cfg 应用；四形态滚动偏移的唯一来源是
 * Scroll.onScroll 回调，禁止 onAreaChange 反推。
 */
export interface TopBarScrollState {
  /** 顶栏是否处于收起态 */
  collapsed: boolean;
  /**
   * 带符号累计滚动（vp）：正值 = 向下累计（趋向收起），负值 = 向上累计（趋向恢复）。
   * 方向翻转时重置为本次 delta。
   */
  accumVp: number;
  /** 状态机最近一次消费的滚动偏移（vp）：prev.lastOffsetVp + deltaVp */
  lastOffsetVp: number;
}

export interface TopBarScrollConfig {
  /** 向下累计达到该值（vp）触发收起 */
  collapseThresholdVp: number;
  /** 向上累计达到该值（vp）触发恢复 */
  expandThresholdVp: number;
  /** 单次 |delta|（vp）小于该值则完全忽略 */
  debounceVp: number;
  /** 形态翻转动画时长（ms），接线方应用 */
  animationMs: number;
  /** 形态翻转动画曲线名（'FastOutSlowIn'），接线方映射到 Curve.FastOutSlowIn */
  curve: string;
}

export const DEFAULT_TOP_BAR_SCROLL_CONFIG: TopBarScrollConfig = {
  collapseThresholdVp: 24,
  expandThresholdVp: 8,
  debounceVp: 0.5,
  animationMs: 180,
  curve: 'FastOutSlowIn'
};

/** 初始状态：展开、无累计、偏移 0 */
export function initialTopBarState(): TopBarScrollState {
  return { collapsed: false, accumVp: 0, lastOffsetVp: 0 };
}

/**
 * 单步演算：输入上一状态与本次滚动增量（vp），输出下一状态。
 * 滚动方向约定：deltaVp > 0 = 向下滚动（内容上移 → 趋向收起）；
 * deltaVp < 0 = 向上滚动（内容下移 → 趋向恢复）。
 */
export function nextTopBarState(prev: TopBarScrollState,
  deltaVp: number, cfg: TopBarScrollConfig): TopBarScrollState {
  // 非法 delta（NaN/Infinity）：忽略整步，保持状态与偏移不变，等待下一个合法事件。
  if (!Number.isFinite(deltaVp) || !Number.isFinite(prev.lastOffsetVp)) {
    return prev;
  }
  // 防抖：|delta| < debounceVp 完全忽略（不推进 accumVp / lastOffsetVp）。
  if (Math.abs(deltaVp) < cfg.debounceVp) {
    return prev;
  }
  const nextOffsetVp: number = prev.lastOffsetVp + deltaVp;
  // 方向翻转检测：accumVp 为 0 视为「无方向」，衔接任意方向；否则必须同向才继续累计。
  const continued: boolean = prev.accumVp === 0 ||
    (prev.accumVp > 0 && deltaVp > 0) || (prev.accumVp < 0 && deltaVp < 0);
  const accumulated: number = continued ? prev.accumVp + deltaVp : deltaVp;
  let collapsed: boolean = prev.collapsed;
  if (accumulated >= cfg.collapseThresholdVp) {
    collapsed = true;
  } else if (accumulated <= -cfg.expandThresholdVp) {
    collapsed = false;
  }
  return { collapsed: collapsed, accumVp: accumulated, lastOffsetVp: nextOffsetVp };
}
