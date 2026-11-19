/**
 * Pagination.ets —— 数字分页纯逻辑（Phase 14-N）
 *
 * 不依赖 ArkUI 组件、不保存状态、不发起请求；
 * PaginationBar 与对应 ViewModel 共用这些规则，方便宿主单测覆盖边界。
 */
export interface PaginationWindow {
  pages: number[];
  showFirst: boolean;
  showStartEllipsis: boolean;
  showLast: boolean;
  showEndEllipsis: boolean;
  canPrev: boolean;
  canNext: boolean;
}

/** 窄屏最多 5 个数字按钮，宽屏最多 7 个（不含首尾与箭头）。 */
export function paginationButtonCount(containerWidthVp: number): number {
  return Number.isFinite(containerWidthVp) && containerWidthVp >= 600 ? 7 : 5;
}

/** 页码归一：空数据回到第 1 页；越界夹到合法范围。 */
export function normalizePage(page: number, totalPages: number): number {
  if (!Number.isFinite(totalPages) || totalPages <= 0) {
    return 1;
  }
  if (!Number.isFinite(page)) {
    return 1;
  }
  const n: number = Math.floor(page);
  if (n < 1) {
    return 1;
  }
  if (n > totalPages) {
    return Math.floor(totalPages);
  }
  return n;
}

/** 由真实总量与每页条数算总页数；总量未知/为 0 时返回 0，不虚构页数。 */
export function computeTotalPages(totalCount: number, pageSize: number): number {
  if (!Number.isFinite(totalCount) || totalCount <= 0) {
    return 0;
  }
  if (!Number.isFinite(pageSize) || pageSize <= 0) {
    return 0;
  }
  return Math.ceil(totalCount / pageSize);
}

/** 动态页码窗口：总页数较少时全列；较多时保留首尾与省略号。 */
export function computePaginationWindow(
  currentPage: number,
  totalPages: number,
  maxButtons: number
): PaginationWindow {
  const empty: PaginationWindow = {
    pages: [],
    showFirst: false,
    showStartEllipsis: false,
    showLast: false,
    showEndEllipsis: false,
    canPrev: false,
    canNext: false
  };
  if (!Number.isFinite(totalPages) || totalPages <= 0) {
    return empty;
  }
  const total: number = Math.floor(totalPages);
  const current: number = normalizePage(currentPage, total);
  const limit: number = Number.isFinite(maxButtons) && maxButtons >= 3 ? Math.floor(maxButtons) : 5;
  if (total <= limit) {
    const pages: number[] = [];
    for (let i = 1; i <= total; i++) {
      pages.push(i);
    }
    return {
      pages: pages,
      showFirst: false,
      showStartEllipsis: false,
      showLast: false,
      showEndEllipsis: false,
      canPrev: current > 1,
      canNext: current < total
    };
  }
  let start: number = Math.max(1, current - Math.floor(limit / 2));
  let end: number = Math.min(total, start + limit - 1);
  start = Math.max(1, end - limit + 1);
  const showFirst: boolean = start > 1;
  const showLast: boolean = end < total;
  const pages: number[] = [];
  for (let i = start; i <= end; i++) {
    pages.push(i);
  }
  return {
    pages: pages,
    showFirst: showFirst,
    showStartEllipsis: start > 2,
    showLast: showLast,
    showEndEllipsis: end < total - 1,
    canPrev: current > 1,
    canNext: current < total
  };
}

/**
 * 窄屏底部分页胶囊专用的紧凑对称页码窗口（含首尾与当前页槽位，永不溢出 360vp）：
 * - total <= 5：完整展示 1..total；
 * - 首页附近（current <= 2）：< 1 2 3 … total >；
 * - 末页附近（current >= total - 1）：< 1 … (total-2) (total-1) total >；
 * - 中间页：total < 100 时展示 3 页窗口，total >= 100 时展示紧凑对称窗口（如 < 1 … 6 … 2306 >）。
 */
export function computeCompactBarWindow(
  currentPage: number,
  totalPages: number
): PaginationWindow {
  if (!Number.isFinite(totalPages) || totalPages <= 0) {
    return computePaginationWindow(currentPage, totalPages, 5);
  }
  const total: number = Math.floor(totalPages);
  const current: number = normalizePage(currentPage, total);
  if (total <= 5) {
    return computePaginationWindow(current, total, 5);
  }
  if (current <= 2) {
    return {
      pages: [1, 2, 3],
      showFirst: false,
      showStartEllipsis: false,
      showLast: true,
      showEndEllipsis: total > 4,
      canPrev: current > 1,
      canNext: current < total
    };
  }
  if (current >= total - 1) {
    return {
      pages: [total - 2, total - 1, total],
      showFirst: true,
      showStartEllipsis: total > 4,
      showLast: false,
      showEndEllipsis: false,
      canPrev: current > 1,
      canNext: current < total
    };
  }
  if (total < 100) {
    return computePaginationWindow(current, total, 3);
  }
  if (current === 3) {
    return {
      pages: [2, 3],
      showFirst: true,
      showStartEllipsis: false,
      showLast: true,
      showEndEllipsis: total > 4,
      canPrev: true,
      canNext: true
    };
  }
  if (current === total - 2) {
    return {
      pages: [total - 2, total - 1],
      showFirst: true,
      showStartEllipsis: total > 4,
      showLast: true,
      showEndEllipsis: false,
      canPrev: true,
      canNext: true
    };
  }
  return {
    pages: [current],
    showFirst: true,
    showStartEllipsis: true,
    showLast: true,
    showEndEllipsis: true,
    canPrev: true,
    canNext: true
  };
}

/** 跳页输入解析：只允许 1..totalPages 的正整数；非法返回 0。 */
export function parseJumpPage(raw: string, totalPages: number): number {
  if (!Number.isFinite(totalPages) || totalPages <= 0) {
    return 0;
  }
  const text: string = raw.trim();
  if (text === '') {
    return 0;
  }
  const value: number = Number(text);
  if (!Number.isFinite(value) || !Number.isInteger(value)) {
    return 0;
  }
  if (value < 1 || value > totalPages) {
    return 0;
  }
  return value;
}

/** 请求中、越界、同页重复点击都不得触发翻页。 */
export function canChangePage(
  loading: boolean,
  currentPage: number,
  totalPages: number,
  targetPage: number
): boolean {
  if (loading || !Number.isFinite(totalPages) || totalPages <= 0) {
    return false;
  }
  if (!Number.isInteger(targetPage) || targetPage < 1 || targetPage > totalPages) {
    return false;
  }
  return targetPage !== normalizePage(currentPage, totalPages);
}

/* ==================== Phase 14-N1：统计口径（三个数量概念不得混用） ==================== */

/**
 * 服务端数字分页：totalCount / totalPages 来自服务端明确返回的全局总量。
 * 只有在这种模式下才允许展示「总量 / 页数」。
 */
export const COUNT_MODE_SERVER_TOTAL: string = 'serverTotal';
/**
 * 本地数据集分页：totalCount 只是本次响应实际取得的数组长度，totalPages 是本地页数。
 * /api/home 无服务端总量字段，readDay / proportion 长度随服务端波动，故走此模式。
 */
export const COUNT_MODE_LOCAL_LOADED: string = 'localLoaded';
/** 总量未知（Cursor / 无限滚动）：不展示任何虚构数字。 */
export const COUNT_MODE_UNKNOWN: string = 'unknown';
export const COUNT_MODE_VALUES: string[] = [
  COUNT_MODE_SERVER_TOTAL, COUNT_MODE_LOCAL_LOADED, COUNT_MODE_UNKNOWN
];

/** 文案标识：PaginationBar 用字面量 $r 分支选择，不做动态资源拼接。 */
export const STAT_LABEL_TOTAL: string = 'total';
export const STAT_LABEL_LOADED: string = 'loaded';
export const STAT_LABEL_UNKNOWN: string = 'unknown';
export const STAT_LABEL_PAGES: string = 'pages';
export const STAT_LABEL_LOCAL_PAGES: string = 'localPages';
export const STAT_LABEL_NONE: string = 'none';

export interface PaginationStats {
  mode: string;
  countLabel: string;
  pagesLabel: string;
  count: number;
  pages: number;
  /** 总量已知（含 0）时才允许渲染数字；未知时只显示「总量未知」。 */
  showCountNumber: boolean;
  showPages: boolean;
}

/** 非法的统计口径一律收敛为 unknown，绝不回退成「服务端总量」。 */
export function normalizeCountMode(mode: string): string {
  return COUNT_MODE_VALUES.indexOf(mode) >= 0 ? mode : COUNT_MODE_UNKNOWN;
}

/**
 * 本地数据集页数：只由本次已获取条数与客户端 pageSize 计算，
 * 不代表服务端分页协议，也不代表服务端总页数。
 */
export function computeLocalPages(loadedCount: number, pageSize: number): number {
  return computeTotalPages(loadedCount, pageSize);
}

/** 依统计口径决定展示文案与数字；不改变 currentPage / totalPages 本身。 */
export function resolvePaginationStats(
  mode: string, totalCount: number, totalPages: number
): PaginationStats {
  const normalized: string = normalizeCountMode(mode);
  const safePages: number = Number.isFinite(totalPages) && totalPages > 0
    ? Math.floor(totalPages) : 0;
  const hidden: PaginationStats = {
    mode: normalized,
    countLabel: STAT_LABEL_UNKNOWN,
    pagesLabel: STAT_LABEL_NONE,
    count: 0,
    pages: 0,
    showCountNumber: false,
    showPages: false
  };
  if (normalized === COUNT_MODE_UNKNOWN) {
    return hidden;
  }
  if (!Number.isFinite(totalCount) || totalCount < 0) {
    return hidden;
  }
  const local: boolean = normalized === COUNT_MODE_LOCAL_LOADED;
  return {
    mode: normalized,
    countLabel: local ? STAT_LABEL_LOADED : STAT_LABEL_TOTAL,
    pagesLabel: safePages > 0
      ? (local ? STAT_LABEL_LOCAL_PAGES : STAT_LABEL_PAGES)
      : STAT_LABEL_NONE,
    count: Math.floor(totalCount),
    pages: safePages,
    showCountNumber: true,
    showPages: safePages > 0
  };
}

/* ==================== 排行榜横屏双列与底部防遮挡契约 ==================== */

export const RANK_WIDE_BREAKPOINT_VP: number = 600;
export const PAGINATION_BAR_COMPACT_HEIGHT_VP: number = 56;
export const PAGINATION_BAR_REGULAR_HEIGHT_VP: number = 92;
export const PAGINATION_CAPSULE_HEIGHT_VP: number = 46;
export const PAGINATION_CAPSULE_BOTTOM_GAP_VP: number = 8;
export const PAGINATION_CAPSULE_TOP_GAP_VP: number = 12;

/**
 * 分页胶囊栏是否采用宽屏/横屏单行左右排布（纯函数，可单测）。
 */
export function isPaginationWideLayout(containerWidthVp: number, compactProp: boolean): boolean {
  return compactProp || (Number.isFinite(containerWidthVp) && containerWidthVp >= RANK_WIDE_BREAKPOINT_VP);
}

/**
 * 悬浮单行分页胶囊栏（48vp + 8vp 底边距 + 12vp 内容间距 + 系统底部避让）的列表防遮挡留白（vp）。
 */
export function paginationFloatingInsetVp(
  hasPagination: boolean,
  bottomSafeAreaVp: number
): number {
  const safeBottom: number = Number.isFinite(bottomSafeAreaVp) && bottomSafeAreaVp > 0
    ? bottomSafeAreaVp : 0;
  if (!hasPagination) {
    return safeBottom;
  }
  return PAGINATION_CAPSULE_HEIGHT_VP + PAGINATION_CAPSULE_BOTTOM_GAP_VP +
    PAGINATION_CAPSULE_TOP_GAP_VP + safeBottom;
}

/**
 * 排行榜列数：竖屏/窄屏（<600vp）保持单列；宽屏/横屏（>=600vp）切换双列。
 */
export function rankListColumns(widthVp: number): number {
  if (!Number.isFinite(widthVp) || widthVp < RANK_WIDE_BREAKPOINT_VP) {
    return 1;
  }
  return 2;
}

/**
 * 排行榜列表/网格底部防遮挡留白（vp）：
 * 与浮动底部分页栏等高 + 系统底部安全区，确保滚动到底部时最后一行标题与标签完整可见。
 */
export function rankBottomInsetVp(
  hasPagination: boolean,
  compact: boolean,
  bottomSafeAreaVp: number
): number {
  const safeBottom: number = Number.isFinite(bottomSafeAreaVp) && bottomSafeAreaVp > 0
    ? bottomSafeAreaVp : 0;
  if (!hasPagination) {
    return safeBottom;
  }
  const barH: number = compact ? PAGINATION_BAR_COMPACT_HEIGHT_VP : PAGINATION_BAR_REGULAR_HEIGHT_VP;
  return barH + safeBottom;
}
