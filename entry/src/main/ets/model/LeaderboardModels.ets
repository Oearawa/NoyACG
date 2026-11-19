/**
 * LeaderboardModels.ets —— 排行榜 / 分类目录 / 个人化精选的协议契约与纯逻辑（Phase 14-Q）
 *
 * 证据来源（Phase 14-P 研究报告 + 首方 Web 前端 bundle，均为 FIRST_PARTY_WEB_CODE）：
 *   阅读榜   POST /api/readLeaderboard   { page, type }
 *   收藏榜   POST /api/favLeaderboard    { page, type }
 *   高质量榜 POST /api/proportion        { page }        ← 不带 type
 *   个人精选 POST /api/favoritesrecommend { page }
 *   分类目录 POST /api/bigtaglist         {}             → { status, data: [{tag, search, cover}] }
 *   分页响应 { status, info: Book[], len }，每页 20，page 从 1 起。
 *
 * 约束：
 * - 月榜参数是 `moon`（首方白名单 `x(e){return e==='week'||e==='moon'?e:'day'}`），不是 `month`；
 * - 高质量榜没有周期维度，禁止把阅读/收藏榜的 type 参数错发；
 * - 不创造分类 ID；`cover` 是漫画 Bid，不是分类主键；
 * - 本文件不发起请求，只提供可被宿主单测覆盖的纯逻辑。
 */

// ==================== 榜单类型 ====================

export const RANK_KIND_READING: string = 'reading';
export const RANK_KIND_FAVORITE: string = 'favorite';
export const RANK_KIND_QUALITY: string = 'quality';
export const RANK_KIND_VALUES: string[] = [RANK_KIND_READING, RANK_KIND_FAVORITE, RANK_KIND_QUALITY];

/** 榜单类型 → 真实端点（首方 rankings-CYXAJkYb.js 的四个函数之一）。 */
export function rankKindPath(kind: string): string {
  if (kind === RANK_KIND_FAVORITE) {
    return '/api/favLeaderboard';
  }
  if (kind === RANK_KIND_QUALITY) {
    return '/api/proportion';
  }
  return '/api/readLeaderboard';
}

export function isValidRankKind(kind: string): boolean {
  return RANK_KIND_VALUES.indexOf(kind) >= 0;
}

// ==================== 周期 ====================

/** 日榜 */
export const RANK_PERIOD_DAY: string = 'day';
/** 周榜 */
export const RANK_PERIOD_WEEK: string = 'week';
/** 月榜——首方协议值就是 `moon`（非 `month`），此处原样登记，不做“纠正”。 */
export const RANK_PERIOD_MOON: string = 'moon';
export const RANK_PERIOD_VALUES: string[] = [RANK_PERIOD_DAY, RANK_PERIOD_WEEK, RANK_PERIOD_MOON];

/** 周期白名单：无效值一律回落 day（与首方 x(e) 行为一致）。 */
export function normalizeRankPeriod(period: string): string {
  return period === RANK_PERIOD_WEEK || period === RANK_PERIOD_MOON ? period : RANK_PERIOD_DAY;
}

export function isValidRankPeriod(period: string): boolean {
  return RANK_PERIOD_VALUES.indexOf(period) >= 0;
}

/** 高质量榜无周期维度：UI 隐藏周期切换，请求也不带 type。 */
export function rankKindSupportsPeriod(kind: string): boolean {
  return kind === RANK_KIND_READING || kind === RANK_KIND_FAVORITE;
}

/**
 * 构造榜单请求表单。
 * - reading/favorite → { page, type }（type 经白名单归一）
 * - quality         → { page }（绝不带 type）
 */
export function buildLeaderboardForm(kind: string, page: number, period: string): Record<string, string> {
  const safePage: number = Number.isFinite(page) && page >= 1 ? Math.floor(page) : 1;
  const form: Record<string, string> = { 'page': String(safePage) };
  if (rankKindSupportsPeriod(kind)) {
    form['type'] = normalizeRankPeriod(period);
  }
  return form;
}

/** 个人化精选请求表单：只有 page。 */
export function buildRecommendForm(page: number): Record<string, string> {
  const safePage: number = Number.isFinite(page) && page >= 1 ? Math.floor(page) : 1;
  return { 'page': String(safePage) };
}

// ==================== 服务端总量 len ====================

/** len 无法可靠解析时使用 -1，调用方必须按「总量未知」处理，不得当成 0 条。 */
export const SERVER_LEN_UNKNOWN: number = -1;

/**
 * 严格解析服务端 `len`：
 * - 只接受有限非负整数（number 或纯数字字符串）；
 * - null / 缺失 / 空串 / 负数 / 小数 / 非数字 / 超出安全整数 → 返回 -1（未知）。
 */
export function normalizeServerLen(value: number | string | null | undefined): number {
  if (typeof value === 'number') {
    if (!Number.isFinite(value) || value < 0) {
      return SERVER_LEN_UNKNOWN;
    }
    const floored: number = Math.floor(value);
    return floored > Number.MAX_SAFE_INTEGER ? SERVER_LEN_UNKNOWN : floored;
  }
  if (typeof value === 'string') {
    const text: string = value.trim();
    if (text === '' || !/^\d+$/.test(text)) {
      return SERVER_LEN_UNKNOWN;
    }
    const parsed: number = Number(text);
    if (!Number.isFinite(parsed) || parsed > Number.MAX_SAFE_INTEGER) {
      return SERVER_LEN_UNKNOWN;
    }
    return parsed;
  }
  return SERVER_LEN_UNKNOWN;
}

/** 服务端总页数：首方 `Math.max(1, Math.ceil(len / 20))`；len 未知返回 0。 */
export function serverTotalPages(len: number, pageSize: number): number {
  if (!Number.isFinite(len) || len < 0) {
    return 0;
  }
  if (!Number.isFinite(pageSize) || pageSize <= 0) {
    return 0;
  }
  return Math.max(1, Math.ceil(len / pageSize));
}

// ==================== 分类目录 ====================

/**
 * 分类条目（对齐首方 bigtaglist 的 `data[]`）。
 * - `tag`    显示名称（原样保留，不做繁简转换）
 * - `search` 搜索标签数组（可能为空）
 * - `coverBid` 代表漫画 Bid；<0 表示缺失
 * - `cover`  由 coverBid 生成的封面 URL（经统一图片 URL 工具）
 */
@ObservedV2
export class BigTagItem {
  @Trace tag: string = '';
  @Trace search: string[] = [];
  @Trace coverBid: number = -1;
  @Trace cover: string = '';
  @Trace hasCover: boolean = false;

  constructor(tag: string = '', search: string[] = [], coverBid: number = -1,
    cover: string = '') {
    this.tag = tag;
    this.search = search;
    this.coverBid = coverBid;
    this.cover = cover;
    this.hasCover = cover !== '';
  }

  /** 分类点击的搜索关键词：search 非空则空格连接，否则退回 tag。 */
  get query(): string {
    const joined: string = this.search.length > 0 ? this.search.join(' ') : '';
    return joined !== '' ? joined : this.tag;
  }
}

/** 分类点击关键词（纯函数版，供单测与 UI 共用）：`search.join(' ') || tag`。 */
export function buildBigTagQuery(search: string[], tag: string): string {
  let joined: string = '';
  for (let i = 0; i < search.length; i++) {
    const part: string = typeof search[i] === 'string' ? search[i].trim() : '';
    if (part !== '') {
      joined = joined === '' ? part : `${joined} ${part}`;
    }
  }
  if (joined !== '') {
    return joined;
  }
  return typeof tag === 'string' ? tag.trim() : '';
}

/** 分类匹配用的稳定标识：tag + Bid（同 tag 不同封面视为不同条目，保持服务端顺序）。 */
export function bigTagKey(tag: string, coverBid: number): string {
  return `${tag}#${coverBid}`;
}

// ==================== 首页区块 → 独立页面映射 ====================

/** 首页聚合区块标识（与 /api/home 字段名一致）。 */
export const HOME_SECTION_READ_DAY: string = 'readDay';
export const HOME_SECTION_FAV_DAY: string = 'favDay';
export const HOME_SECTION_PROPORTION: string = 'proportion';
export const HOME_SECTION_FS: string = 'fs';
export const HOME_SECTION_VALUES: string[] = [
  HOME_SECTION_READ_DAY, HOME_SECTION_FAV_DAY, HOME_SECTION_PROPORTION, HOME_SECTION_FS
];

/** 区块 → 目标路由名；空串表示没有独立页面。 */
export const HOME_ROUTE_RANK: string = 'RankPage';
export const HOME_ROUTE_PERSONALIZED: string = 'PersonalizedPage';

/**
 * 首页区块 → 目标页面（Phase 14-P 官方 Web 首页映射）：
 *   readDay    → RankPage(reading)
 *   favDay     → RankPage(favorite)
 *   proportion → RankPage(quality)
 *   fs         → PersonalizedPage（官方命名为「收藏推薦」，即 favoritesrecommend）
 */
export function homeSectionRoute(section: string): string {
  if (section === HOME_SECTION_FS) {
    return HOME_ROUTE_PERSONALIZED;
  }
  if (section === HOME_SECTION_READ_DAY || section === HOME_SECTION_FAV_DAY
    || section === HOME_SECTION_PROPORTION) {
    return HOME_ROUTE_RANK;
  }
  return '';
}

/** 区块 → 榜单类型（非榜单区块返回空串）。 */
export function homeSectionRankKind(section: string): string {
  if (section === HOME_SECTION_READ_DAY) {
    return RANK_KIND_READING;
  }
  if (section === HOME_SECTION_FAV_DAY) {
    return RANK_KIND_FAVORITE;
  }
  if (section === HOME_SECTION_PROPORTION) {
    return RANK_KIND_QUALITY;
  }
  return '';
}

/** 区块 → 榜单周期（首页预览都是「日」维度；非榜单区块返回空串）。 */
export function homeSectionRankPeriod(section: string): string {
  return homeSectionRankKind(section) === '' ? '' : RANK_PERIOD_DAY;
}
