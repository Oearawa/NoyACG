/**
 * ComicDetailLayout.ets —— 漫画详情页纯函数布局与状态映射（无 ArkUI 依赖）
 */
import { normalizeAvoid } from './BottomInset';

export const DETAIL_WIDE_BREAKPOINT_VP: number = 600;
export const DETAIL_CHAPTER_TOUCH_TARGET_VP: number = 44;

export const RECOMMEND_CARD_WIDTH_VP: number = 108;
export const RECOMMEND_COVER_HEIGHT_VP: number = 154;
export const RECOMMEND_TITLE_GAP_VP: number = 5;

export const DETAIL_WIDE_COVER_WIDTH_VP: number = 168;
export const DETAIL_WIDE_COVER_HEIGHT_VP: number = 240;
export const DETAIL_LEFT_PANE_WIDTH: string = '42%';
export const DETAIL_RIGHT_PANE_WIDTH: string = '58%';

export type DetailScaffoldMode = 'loading' | 'auth_required' | 'error' | 'empty' | 'ready';

/** 严格按「真横屏且宽度 >= 600vp（widthVp > heightVp && widthVp >= 600）」触发双栏布局 */
export function detailUseTwoPane(widthVp: number, heightVp?: number): boolean {
  if (!Number.isFinite(widthVp) || widthVp <= 0) {
    return false;
  }
  if (heightVp !== undefined) {
    if (!Number.isFinite(heightVp) || heightVp <= 0) {
      return false;
    }
    return widthVp > heightVp && widthVp >= DETAIL_WIDE_BREAKPOINT_VP;
  }
  return widthVp >= DETAIL_WIDE_BREAKPOINT_VP;
}

/** 根据卡片宽度与纵横比计算固定封面高度（避免 Stack 无高度导致图文超大断层） */
export function recommendCoverHeightVp(cardWidthVp: number, coverRatio: number): number {
  if (!Number.isFinite(cardWidthVp) || cardWidthVp <= 0 || !Number.isFinite(coverRatio) || coverRatio <= 0) {
    return RECOMMEND_COVER_HEIGHT_VP;
  }
  return Math.round(cardWidthVp / coverRatio);
}

/** 根据容器可用宽度计算章节目录列数（单栏/双栏统一规则） */
export function detailChapterColumns(paneWidthVp: number): number {
  if (!Number.isFinite(paneWidthVp) || paneWidthVp < 480) {
    return 1;
  }
  return 2;
}

/** 底部安全区留白，确保最后一条评论不被系统导航条遮挡 */
export function detailBottomInsetVp(bottomSafeAreaVp: number): number {
  return normalizeAvoid(bottomSafeAreaVp) + 16;
}

/** DetailState 字符串值 → 详情页视图模式 */
export function resolveDetailScaffoldMode(state: string): DetailScaffoldMode {
  if (state === 'auth_required') {
    return 'auth_required';
  }
  if (state === 'error') {
    return 'error';
  }
  if (state === 'empty') {
    return 'empty';
  }
  if (state === 'success') {
    return 'ready';
  }
  return 'loading';
}
