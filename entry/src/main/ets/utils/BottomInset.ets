/**
 * BottomInset.ets —— 导航留白纯函数（Phase 15-R2 · R2-3 / R2-4）
 *
 * 一份公式，三处消费（禁止各算一份）：
 *   1. 底栏悬浮时的 `barBottomMargin`；
 *   2. 滚动容器末尾留白（`contentEndOffset` 或末尾占位项的高度）；
 *   3. 侧栏形态下只保留系统导航避让。
 *
 * 为什么内容留白要 = 栏高 + 栏底边距 + 避让：
 *   barOverlap(true) 后内容会从悬浮栏下方滑过，栏自身不占布局空间；
 *   内容想「滚到底时最后一项完整露出」，末尾就必须让出这一段（对应 S4）。
 *   侧栏不覆盖内容（barOverlap=false），因此只需系统导航避让，不得再预留底栏空间（对应 S3）。
 */

/** 悬浮栏与内容之间的视觉间隙（vp） */
export const FLOATING_BAR_GAP: number = 12;

/** 主 Tab 悬浮底栏视觉高度与安全防遮挡余量（vp） */
export const MAIN_TAB_FLOATING_BAR_HEIGHT_VP: number = 64;
export const MAIN_TAB_EXTRA_CLEARANCE_VP: number = 20;

/** 归一化避让高度：非有限 / 负数 / NaN → 0 */
export function normalizeAvoid(avoidVp: number): number {
  if (!Number.isFinite(avoidVp) || avoidVp < 0) {
    return 0;
  }
  return avoidVp;
}

/** 悬浮栏底部外边距 = 视觉间隙 + 系统底部避让（无手势条时避让为 0） */
export function floatingBarBottomMargin(avoidVp: number): number {
  return FLOATING_BAR_GAP + normalizeAvoid(avoidVp);
}

/**
 * 内容末尾留白。
 * @param barHeightVp 底栏高度（vp）
 * @param bottomBar 是否底部导航形态（由 ViewportState.navMode 单点给出）
 * @param avoidVp 系统底部避让高度（vp）
 */
export function contentEndInset(barHeightVp: number, bottomBar: boolean, avoidVp: number): number {
  const avoid: number = normalizeAvoid(avoidVp);
  if (!bottomBar) {
    // 侧栏形态：内容不被压住，只让开系统导航条
    return avoid;
  }
  return Math.max(0, barHeightVp) + floatingBarBottomMargin(avoid);
}

/**
 * 主 Tab 页（首页 / 最新 / 收藏 / 用户）滚动容器底部安全留白：
 * - 竖屏底栏形态：bottomInsetVp + 悬浮底栏高度 64vp + 20vp（确保最后一行卡片与标签完整露出）；
 * - 横屏侧栏形态：仅保留系统底部导航避让。
 */
export function mainTabBottomClearanceVp(
  barHeightVp: number,
  bottomBar: boolean,
  avoidVp: number
): number {
  const avoid: number = normalizeAvoid(avoidVp);
  if (!bottomBar) {
    return avoid;
  }
  const effectiveBarH: number = Math.max(MAIN_TAB_FLOATING_BAR_HEIGHT_VP, Math.max(0, barHeightVp));
  return avoid + effectiveBarH + MAIN_TAB_EXTRA_CLEARANCE_VP;
}

/**
 * 用户页（ProfileBody）的内容末尾留白。
 *
 * `ProfileBody` 有两个宿主：首页的「用户」页签（有悬浮底栏）与独立路由页（没有导航栏）。
 * 路由形态下如果仍按底栏公式预留，末尾会凭空多出一整条栏高的空白（Phase 15-R2.1 P2-04），
 * 因此这里显式分叉：非 Tab 形态只保留系统导航避让。
 */
export function profileContentEndInset(barHeightVp: number, inTab: boolean,
  bottomBar: boolean, avoidVp: number): number {
  if (!inTab) {
    return normalizeAvoid(avoidVp);
  }
  return contentEndInset(barHeightVp, bottomBar, avoidVp);
}

export function profileTabBottomClearanceVp(
  barHeightVp: number,
  inTab: boolean,
  bottomBar: boolean,
  avoidVp: number
): number {
  if (!inTab) {
    return normalizeAvoid(avoidVp);
  }
  return mainTabBottomClearanceVp(barHeightVp, bottomBar, avoidVp);
}
