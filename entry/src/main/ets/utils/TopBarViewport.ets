/**
 * TopBarViewport.ets —— 四形态顶栏视口净空纯函数（p1-native-material-shell Task 3）
 *
 * 契约（plan Task 3 净空策略 / brief）：
 *   1. 顶栏可视高度由 TopBarScrollState.collapsed 同一状态驱动：
 *        expanded  = TOP_BAR_HEIGHT(56) + bottomBuilder(48) = 104vp
 *        collapsed = TOP_BAR_HEIGHT(56)  （bottomBuilder 随 HDS dynamicHideTitleBar 隐藏）
 *   2. content paddingTop = topBarVisibleHeightVp + safeAreaTopVp（唯一公式，禁止各算一份）；
 *   3. 收起/展开只改变「顶栏可视高度」与内容 paddingTop，二者同源同量 → 无 translate 位移，
 *      切换偏移恒 = bottomBuilder 高度 48，内容中线无跳变；
 *   4. 底栏位置 = FLOATING_BAR_GAP + 底部系统避让（避开手势区/三键导航）。
 *
 * 本文件只做数值演算，不接触 ArkUI：四形态判定唯一来源仍是 ViewportState.navMode
 * （SafeAreaManager 采样 windowRect → NavigationMode）。这里只补顶栏视口期望值，
 * 供 TopBarViewport.test.ets 断言与 Index.ets 接线消费。
 */
import { ThemeDims } from './Theme';
import { normalizeAvoid, floatingBarBottomMargin } from './BottomInset';

/** 顶栏底部 builder（药丸 + 圆形搜索行）高度（vp）：历史 HDS bottomBuilder 高度常量（保留供纯函数回归） */
export const TOP_BAR_BOTTOM_BUILDER_HEIGHT_VP: number = 48;

/** 顶栏标题区高度（vp）：与 ThemeDims.TOP_BAR_HEIGHT 同源（56） */
export const TOP_BAR_TITLE_HEIGHT_VP: number = ThemeDims.TOP_BAR_HEIGHT;

/** P1 竖屏单行顶栏内容区高度（vp，放大后 54vp） */
export const COMPACT_TOP_BAR_HEIGHT_VP: number = 54;
/** P1 竖屏常规宽度（>= 380vp）胶囊视觉高度（vp） */
export const COMPACT_CAPSULE_HEIGHT_VP: number = 36;
/** P1 竖屏胶囊最小触控热区高度（vp，>= 44vp） */
export const COMPACT_TOUCH_TARGET_VP: number = 44;
/** P1 宽幅/常规竖屏断点（vp） */
export const COMPACT_WIDE_BREAKPOINT_VP: number = 380;
/** P1 超窄竖屏（分屏/小窗 < 340vp）触发水平滚动兜底的宽度阈值（vp） */
export const COMPACT_NARROW_SCROLL_THRESHOLD_VP: number = 340;

export interface CompactTopBarSpec {
  barHeightVp: number;
  brandFontSizeFp: number;
  capsuleHeightVp: number;
  capsuleFontSizeFp: number;
  capsuleIconSizeVp: number;
  capsuleHPaddingVp: number;
  capsuleGapVp: number;
  touchTargetVp: number;
  scrollCapsules: boolean;
}

/**
 * 按容器宽度解析竖屏顶栏响应式视觉规格（纯函数，可单测）：
 * - >= 380vp：常规/宽幅放大规格（54vp 顶栏 / 20fp 品牌 / 36vp 胶囊 / 13fp 字号 / 15vp 图标 / 9vp 内边距 / 6vp 间距）；
 * - 340..379vp（如 360vp 紧凑竖屏）：微调比例确保 4 胶囊单行完整展示不换行不截断；
 * - < 340vp（分屏/小窗）：启用水平无滚动条滑动兜底。
 */
export function resolveCompactTopBarSpec(widthVp: number): CompactTopBarSpec {
  const scroll: boolean = shouldScrollCompactEntries(widthVp);
  const isCompactWidth: boolean = Number.isFinite(widthVp) && widthVp > 0 && widthVp < COMPACT_WIDE_BREAKPOINT_VP;
  if (isCompactWidth) {
    return {
      barHeightVp: COMPACT_TOP_BAR_HEIGHT_VP,
      brandFontSizeFp: 18,
      capsuleHeightVp: 34,
      capsuleFontSizeFp: 12,
      capsuleIconSizeVp: 14,
      capsuleHPaddingVp: 7,
      capsuleGapVp: 4,
      touchTargetVp: COMPACT_TOUCH_TARGET_VP,
      scrollCapsules: scroll
    };
  }
  return {
    barHeightVp: COMPACT_TOP_BAR_HEIGHT_VP,
    brandFontSizeFp: 20,
    capsuleHeightVp: COMPACT_CAPSULE_HEIGHT_VP,
    capsuleFontSizeFp: 13,
    capsuleIconSizeVp: 15,
    capsuleHPaddingVp: 9,
    capsuleGapVp: 6,
    touchTargetVp: COMPACT_TOUCH_TARGET_VP,
    scrollCapsules: scroll
  };
}

/** 顶栏可视高度（vp） */
export interface TopBarMetrics {
  /** 标题区高度（vp），收起/展开不变量 */
  titleHeightVp: number;
  /** bottomBuilder 可视高度（vp）：展开 48，收起 0（随 HDS dynamicHideTitleBar 隐藏） */
  bottomBuilderHeightVp: number;
  /** 顶栏总可视高度（vp）= titleHeightVp + bottomBuilderHeightVp */
  visibleHeightVp: number;
}

/** 按收起状态计算顶栏可视高度期望（每态一个值） */
export function topBarMetrics(collapsed: boolean): TopBarMetrics {
  const titleHeightVp: number = TOP_BAR_TITLE_HEIGHT_VP;
  const bottomBuilderHeightVp: number = collapsed ? 0 : TOP_BAR_BOTTOM_BUILDER_HEIGHT_VP;
  return {
    titleHeightVp: titleHeightVp,
    bottomBuilderHeightVp: bottomBuilderHeightVp,
    visibleHeightVp: titleHeightVp + bottomBuilderHeightVp
  };
}

/** 归一化避让高度：委托 BottomInset.normalizeAvoid（I-000010 收敛，「一份公式」单源） */
export function normalizeSafeAreaVp(avoidVp: number): number {
  return normalizeAvoid(avoidVp);
}

/**
 * 内容顶部净空（paddingTop）唯一公式：
 *   paddingTop = topBarVisibleHeightVp + safeAreaTopVp
 * 由 TopBarScrollState.collapsed 同一状态驱动；禁止 translate 位移造成内容跳动。
 */
export function contentPaddingTopVp(collapsed: boolean, safeAreaTopVp: number): number {
  return topBarMetrics(collapsed).visibleHeightVp + normalizeSafeAreaVp(safeAreaTopVp);
}

/** 底栏位置（距底边，vp）= 视觉间隙 + 底部系统避让（单源委托 BottomInset.floatingBarBottomMargin，I-000010 收敛） */
export function bottomBarPositionVp(bottomSafeAreaVp: number): number {
  return floatingBarBottomMargin(bottomSafeAreaVp);
}

/**
 * 四形态（设备展示形态）：
 *   PORTRAIT / LANDSCAPE 由窗口几何纯函数派生（与 NavigationMode 同断点 1.2）；
 *   FOLD_COMPACT / FOLD_EXPANDED 需要设备折叠信号（display.FoldDisplayMode），
 *   T3 纯函数不臆造该状态 —— UNVERIFIED，留 p2 设备验收（见报告）。
 */
export enum ViewportForm {
  PORTRAIT = 'PORTRAIT',
  LANDSCAPE = 'LANDSCAPE',
  FOLD_COMPACT = 'FOLD_COMPACT',
  FOLD_EXPANDED = 'FOLD_EXPANDED'
}

/** 纯几何可派生形态：宽高比 >= 1.2 → LANDSCAPE，否则 PORTRAIT；非法几何安全默认 PORTRAIT */
export function resolveViewportForm(widthVp: number, heightVp: number): ViewportForm {
  if (!Number.isFinite(widthVp) || !Number.isFinite(heightVp) || widthVp <= 0 || heightVp <= 0) {
    return ViewportForm.PORTRAIT;
  }
  return widthVp / heightVp >= 1.2 ? ViewportForm.LANDSCAPE : ViewportForm.PORTRAIT;
}

/**
 * 竖屏紧凑顶栏总占高（vp）= 系统安全区 topVp + 固定单行紧凑顶栏内容区高度（44vp）。
 */
export function compactTopBarTotalHeightVp(safeAreaTopVp: number): number {
  return normalizeSafeAreaVp(safeAreaTopVp) + COMPACT_TOP_BAR_HEIGHT_VP;
}

/**
 * 超窄竖屏（< 340vp）时启用水平无滚动条滑动容器兜底，360vp 常规竖屏直接单行排布不换行不截断。
 */
export function shouldScrollCompactEntries(widthVp: number): boolean {
  if (!Number.isFinite(widthVp) || widthVp <= 0) {
    return false;
  }
  return widthVp < COMPACT_NARROW_SCROLL_THRESHOLD_VP;
}

/**
 * 首页内容顶部净空（P1 竖屏紧凑顶栏 + W49 横屏收尾）：
 *   - 横屏（SIDE，底栏 false）已移除应用顶部栏 → inset = 仅系统安全区 topVp；
 *   - 竖屏（BOTTOM_IMMERSIVE）固定单行紧凑顶栏 → inset = topVp + COMPACT_TOP_BAR_HEIGHT_VP(44vp)，
 *     不再随滚动收起/展开产生 48vp 跳动。
 * 纯函数：由 ViewportState.navMode 派生（isBottomNav 为唯一输入轴），可单测。
 */
export function homeTopInsetVp(isBottomNav: boolean, _collapsed: boolean, safeAreaTopVp: number): number {
  if (!isBottomNav) {
    return normalizeSafeAreaVp(safeAreaTopVp);
  }
  return compactTopBarTotalHeightVp(safeAreaTopVp);
}
