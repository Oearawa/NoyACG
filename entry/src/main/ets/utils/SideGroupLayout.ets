/**
 * SideGroupLayout.ets —— 横屏侧栏两分组高度分配与多档垂直密度布局（纯函数 · 零 ArkUI 依赖）
 *
 * 三档高度自适应策略：
 * 1. 标准/高屏横屏档（availH >= 520vp）：保持舒展常规尺寸（capsuleH=48, navItemH=56, total=497vp）；
 * 2. 紧凑横屏档（330vp <= availH < 520vp，覆盖手机/宽矮横屏 360~430vp）：
 *    压缩快捷胶囊（32vp, gap 4vp, icon 14vp）与主导航（44vp, gap 2vp, icon 18vp）及容器内边距（4vp），
 *    总高度 140 + 15 + 182 = 337vp <= 360vp，确保 8 项入口无需滚动完整同屏展示；
 * 3. 极端分屏/小窗兜底档（availH < 330vp）：保留快捷组 Scroll 滚动兜底，防止溢出。
 */
import { ThemeDims } from '../utils/Theme';

export const SIDE_COMPACT_BREAKPOINT_VP: number = 520;
export const SIDE_EXTREME_TINY_BREAKPOINT_VP: number = 330;
export const SIDE_QUICK_ENTRIES_MIN_HEIGHT_VP: number = 640;
export const SIDE_GROUP_DIVIDER_HEIGHT: number = 1;
export const SIDE_SEARCH_BUTTON_SIZE: number = 40;

export const COMPACT_CAPSULE_HEIGHT_VP: number = 32;
export const COMPACT_QUICK_GAP_VP: number = 4;
export const COMPACT_QUICK_ICON_VP: number = 14;
export const COMPACT_QUICK_FONT_FP: number = 11;
export const COMPACT_NAV_ITEM_HEIGHT_VP: number = 44;
export const COMPACT_NAV_GAP_VP: number = 2;
export const COMPACT_NAV_ICON_VP: number = 18;
export const COMPACT_NAV_FONT_FP: number = 10;
export const COMPACT_OUTER_PAD_V_VP: number = 4;
export const COMPACT_INNER_GAP_VP: number = 3;

export interface SideGroupLayout {
  quickH: number;
  navH: number;
  quickScrollable: boolean;
  compact: boolean;
  spacingVp: number;
  capsuleH: number;
  quickGap: number;
  quickIconSize: number;
  quickFontSize: number;
  navItemH: number;
  navGap: number;
  navIconSize: number;
  navFontSize: number;
  outerPadV: number;
}

export function sideGroupSpacingVp(compact: boolean): number {
  if (compact) {
    return 2 * COMPACT_OUTER_PAD_V_VP + 2 * COMPACT_INNER_GAP_VP + SIDE_GROUP_DIVIDER_HEIGHT;
  }
  return 2 * ThemeDims.SPACE_M + 2 * ThemeDims.NAV_RAIL_ITEM_GAP + SIDE_GROUP_DIVIDER_HEIGHT;
}

export function sideGroupInnerGapVp(spacingVp: number, outerPadV: number = ThemeDims.SPACE_M): number {
  const gap: number = (spacingVp - 2 * outerPadV - SIDE_GROUP_DIVIDER_HEIGHT) / 2;
  return gap >= 0 ? gap : 0;
}

export function mainNavGroupHeightVp(compact: boolean = false): number {
  if (compact) {
    return 4 * COMPACT_NAV_ITEM_HEIGHT_VP + 3 * COMPACT_NAV_GAP_VP;
  }
  return 4 * ThemeDims.NAV_RAIL_ITEM_HEIGHT + 3 * ThemeDims.NAV_RAIL_ITEM_GAP;
}

export function quickGroupIdealHeightVp(compact: boolean = false): number {
  if (compact) {
    return 4 * COMPACT_CAPSULE_HEIGHT_VP + 3 * COMPACT_QUICK_GAP_VP;
  }
  const capsuleH: number = ThemeDims.NAV_RAIL_ITEM_HEIGHT - ThemeDims.SPACE_M;
  return 4 * capsuleH + 3 * ThemeDims.SPACE_M;
}

export function sideRailAvailHeightVp(heightVp: number, topVp: number, bottomVp: number): number {
  if (!Number.isFinite(heightVp) || !Number.isFinite(topVp) || !Number.isFinite(bottomVp)
    || heightVp <= 0 || topVp < 0 || bottomVp < 0) {
    return 0;
  }
  return heightVp - topVp - bottomVp - 2 * ThemeDims.NAV_RAIL_MARGIN;
}

function buildMetricsLayout(
  quickH: number,
  navH: number,
  quickScrollable: boolean,
  compact: boolean,
  spacingVp: number
): SideGroupLayout {
  if (compact) {
    return {
      quickH: quickH,
      navH: navH,
      quickScrollable: quickScrollable,
      compact: true,
      spacingVp: spacingVp,
      capsuleH: COMPACT_CAPSULE_HEIGHT_VP,
      quickGap: COMPACT_QUICK_GAP_VP,
      quickIconSize: COMPACT_QUICK_ICON_VP,
      quickFontSize: COMPACT_QUICK_FONT_FP,
      navItemH: COMPACT_NAV_ITEM_HEIGHT_VP,
      navGap: COMPACT_NAV_GAP_VP,
      navIconSize: COMPACT_NAV_ICON_VP,
      navFontSize: COMPACT_NAV_FONT_FP,
      outerPadV: COMPACT_OUTER_PAD_V_VP
    };
  }
  return {
    quickH: quickH,
    navH: navH,
    quickScrollable: quickScrollable,
    compact: false,
    spacingVp: spacingVp,
    capsuleH: ThemeDims.NAV_RAIL_ITEM_HEIGHT - ThemeDims.SPACE_M,
    quickGap: ThemeDims.SPACE_M,
    quickIconSize: ThemeDims.ICON_SIZE,
    quickFontSize: 12,
    navItemH: ThemeDims.NAV_RAIL_ITEM_HEIGHT,
    navGap: ThemeDims.NAV_RAIL_ITEM_GAP,
    navIconSize: ThemeDims.ICON_SIZE + 2,
    navFontSize: 11,
    outerPadV: ThemeDims.SPACE_M
  };
}

/** 兼容旧版调用签名（基于给定 navH / quickIdealH 分配高度） */
export function layoutSideGroups(availH: number, navH: number, quickIdealH: number): SideGroupLayout {
  if (!Number.isFinite(availH) || !Number.isFinite(navH) || !Number.isFinite(quickIdealH)
    || availH <= 0 || navH <= 0 || quickIdealH <= 0) {
    const safeNav: number = navH > 0 ? navH : mainNavGroupHeightVp(false);
    const safeQuick: number = quickIdealH > 0 ? quickIdealH : quickGroupIdealHeightVp(false);
    return buildMetricsLayout(safeQuick, safeNav, true, false, sideGroupSpacingVp(false));
  }

  const navHFinal: number = navH;
  const restFull: number = availH - navHFinal - sideGroupSpacingVp(false);
  if (restFull >= quickIdealH) {
    return buildMetricsLayout(quickIdealH, navHFinal, false, false, sideGroupSpacingVp(false));
  }
  if (restFull >= 0) {
    return buildMetricsLayout(restFull, navHFinal, true, false, sideGroupSpacingVp(false));
  }

  const restTight: number = availH - navHFinal - sideGroupSpacingVp(true);
  if (restTight >= 0) {
    return buildMetricsLayout(restTight, navHFinal, true, true, sideGroupSpacingVp(true));
  }

  const minSpacing: number = 2 * COMPACT_OUTER_PAD_V_VP + SIDE_GROUP_DIVIDER_HEIGHT;
  const remainingSpacing: number = Math.min(Math.max(availH - navHFinal, minSpacing), sideGroupSpacingVp(true));
  return buildMetricsLayout(0, navHFinal, true, true, remainingSpacing);
}

/** 三档响应式垂直密度入口：根据可用高度自动选择紧凑/标准/极端兜底布局 */
export function sideGroupsForAvailHeight(availH: number): SideGroupLayout {
  if (!Number.isFinite(availH) || availH <= 0) {
    return buildMetricsLayout(
      quickGroupIdealHeightVp(false),
      mainNavGroupHeightVp(false),
      true,
      false,
      sideGroupSpacingVp(false)
    );
  }

  if (availH >= SIDE_COMPACT_BREAKPOINT_VP) {
    const navH: number = mainNavGroupHeightVp(false);
    const quickH: number = quickGroupIdealHeightVp(false);
    const spacingVp: number = sideGroupSpacingVp(false);
    return buildMetricsLayout(quickH, navH, false, false, spacingVp);
  }

  // 紧凑档（330 <= availH < 520）及极端小窗档（< 330）
  const navH: number = mainNavGroupHeightVp(true);
  const quickIdealH: number = quickGroupIdealHeightVp(true);
  const spacingVp: number = sideGroupSpacingVp(true);
  const rest: number = availH - navH - spacingVp;

  if (availH >= SIDE_EXTREME_TINY_BREAKPOINT_VP && rest >= quickIdealH) {
    return buildMetricsLayout(quickIdealH, navH, false, true, spacingVp);
  }
  if (rest >= 0) {
    return buildMetricsLayout(rest, navH, true, true, spacingVp);
  }
  const minSpacing: number = 2 * COMPACT_OUTER_PAD_V_VP + SIDE_GROUP_DIVIDER_HEIGHT;
  const remainingSpacing: number = Math.min(Math.max(availH - navH, minSpacing), spacingVp);
  return buildMetricsLayout(0, navH, true, true, remainingSpacing);
}

/** 便捷入口：由窗口几何直接求出两分组分配 */
export function sideGroupsForGeometry(heightVp: number, topVp: number, bottomVp: number): SideGroupLayout {
  return sideGroupsForAvailHeight(sideRailAvailHeightVp(heightVp, topVp, bottomVp));
}

/**
 * 主内容区（HdsTabs）在横竖屏下的左侧安全内边距（根因 B 修复）：
 * - 竖屏底栏形态（isBottomNav=true）：0vp；
 * - 横屏侧栏形态（isBottomNav=false）：ThemeDims.NAV_RAIL_TOTAL_WIDTH（92vp），
 *   使主内容区在全屏宽 Stack 中不被左侧悬浮 SideRail 遮挡初始正文，同时允许全屏背景与横向列表光影自然延伸至左缘，
 *   触发 SideRail 的官方沉浸光感玻璃折射与高光描边。
 */
export function sideRailContentLeftPaddingVp(isBottomNav: boolean): number {
  return isBottomNav ? 0 : ThemeDims.NAV_RAIL_TOTAL_WIDTH;
}

/**
 * 横屏 SideRail 快捷入口显隐策略（纯函数，可单测）：
 * 左侧 SideRail 固定只展示 4 个核心主 Tab（主页 / 最新 / 收藏 / 用户），
 * 4 个主页专属频道入口（排行榜 / 分类 / 精选 / 搜索）统一收敛在 HomeComponent 顶部。
 */
export function shouldShowQuickEntriesInSideRail(_heightVp: number): boolean {
  return false;
}

/**
 * 主页首部快捷入口条（HomeNavigationEntries）显隐策略：
 * 竖屏与横屏统一在 HomeComponent 顶部与 NoyAcg 品牌同行展示。
 */
export function shouldShowHomeTopEntries(_isBottomNav: boolean, _heightVp: number): boolean {
  return true;
}
