/**
 * DiscoveryModels.ets —— 内容发现功能的数据契约与纯逻辑（Phase 14-N）
 *
 * 约束：
 * - 这里只登记仓库内已有真实证据的榜单字段、搜索模式与视觉参考中的分类名称；
 * - 不创造排行榜/分类/推荐 API、不创造分类 ID、不把分类名当服务端 ID；
 * - UI 状态与网络副作用仍由 ViewModel / Repository 承担。
 */
import { Comic } from './Comic';
import { SearchParam, buildTagSearchParam } from './NavParams';

/** 仓库内真实存在的两个聚合首页数组语义（POST /api/home）。 */
export const RANK_TYPE_READING: string = 'reading';
export const RANK_TYPE_HIGH_QUALITY: string = 'high_quality';
export const RANK_TYPE_VALUES: string[] = [RANK_TYPE_READING, RANK_TYPE_HIGH_QUALITY];

/**
 * 时间维度只是 UI 标识，不是请求参数。
 * 审计结论：仓库内没有周榜/月榜接口或参数，只有 readDay/favDay 这类「日」数组。
 */
export const RANK_PERIOD_DAY: string = 'day';
export const RANK_PERIOD_WEEK: string = 'week';
export const RANK_PERIOD_MONTH: string = 'month';
export const RANK_PERIOD_VALUES: string[] = [RANK_PERIOD_DAY, RANK_PERIOD_WEEK, RANK_PERIOD_MONTH];
export const RANK_SUPPORTED_PERIODS: string[] = [RANK_PERIOD_DAY];

export function isRankPeriodSupported(period: string): boolean {
  return RANK_SUPPORTED_PERIODS.indexOf(period) >= 0;
}

export function rankPeriodIndex(period: string): number {
  const i: number = RANK_PERIOD_VALUES.indexOf(period);
  return i >= 0 ? i : 0;
}

/** 榜单类型 → /api/home 中真实字段名；不发起任何请求参数猜测。 */
export function rankFeedField(rankType: string): string {
  if (rankType === RANK_TYPE_HIGH_QUALITY) {
    return 'proportion';
  }
  return 'readDay';
}

/** 完整数据集的本地分页：只切数组，不伪造服务端分页响应。 */
export function localPage<T>(items: T[], page: number, pageSize: number): T[] {
  if (!Number.isFinite(page) || page < 1 || !Number.isFinite(pageSize) || pageSize <= 0) {
    return [];
  }
  const start: number = (page - 1) * pageSize;
  if (start >= items.length) {
    return [];
  }
  const end: number = Math.min(items.length, start + pageSize);
  const result: T[] = [];
  for (let i = start; i < end; i++) {
    result.push(items[i]);
  }
  return result;
}

/** 本地分页后排名连续性：第 2 页首条为 pageSize+1。 */
export function rankNumber(page: number, pageSize: number, index: number): number {
  if (page < 1 || pageSize <= 0 || index < 0) {
    return 0;
  }
  return (page - 1) * pageSize + index + 1;
}

@ObservedV2
export class RankItem {
  @Trace rank: number = 0;
  @Trace comic: Comic = new Comic();

  constructor(rank: number, comic: Comic) {
    this.rank = rank;
    this.comic = comic;
  }
}

/**
 * 分类目录：仅来自用户提供的 140185 视觉参考中可见的 12 个名称。
 * 这不是服务端分类接口/ID；tagRes 固定使用参考图中的繁体名称，
 * 供已验证的 mode=tag 搜索使用，并明确标记 API_UNVERIFIED。
 */
export interface CategoryDefinition {
  key: string;
  nameRes: Resource;
  tagRes: Resource;
}

export const CATEGORY_DEFINITIONS: CategoryDefinition[] = [
  { key: 'fantasy', nameRes: $r('app.string.category_fantasy'), tagRes: $r('app.string.category_tag_fantasy') },
  { key: 'romance', nameRes: $r('app.string.category_romance'), tagRes: $r('app.string.category_tag_romance') },
  { key: 'daily', nameRes: $r('app.string.category_daily'), tagRes: $r('app.string.category_tag_daily') },
  { key: 'comedy', nameRes: $r('app.string.category_comedy'), tagRes: $r('app.string.category_tag_comedy') },
  { key: 'hotblood', nameRes: $r('app.string.category_hotblood'), tagRes: $r('app.string.category_tag_hotblood') },
  { key: 'action', nameRes: $r('app.string.category_action'), tagRes: $r('app.string.category_tag_action') },
  { key: 'mystery', nameRes: $r('app.string.category_mystery'), tagRes: $r('app.string.category_tag_mystery') },
  { key: 'healing', nameRes: $r('app.string.category_healing'), tagRes: $r('app.string.category_tag_healing') },
  { key: 'school', nameRes: $r('app.string.category_school'), tagRes: $r('app.string.category_tag_school') },
  { key: 'music', nameRes: $r('app.string.category_music'), tagRes: $r('app.string.category_tag_music') },
  { key: 'four_panel', nameRes: $r('app.string.category_four_panel'), tagRes: $r('app.string.category_tag_four_panel') },
  { key: 'yuri', nameRes: $r('app.string.category_yuri'), tagRes: $r('app.string.category_tag_yuri') }
];

export function categoryDefinitionByKey(key: string): CategoryDefinition | null {
  for (let i = 0; i < CATEGORY_DEFINITIONS.length; i++) {
    if (CATEGORY_DEFINITIONS[i].key === key) {
      return CATEGORY_DEFINITIONS[i];
    }
  }
  return null;
}

@ObservedV2
export class CategoryItem {
  @Trace key: string = '';
  @Trace name: string = '';
  @Trace tag: string = '';
  @Trace cover: string = '';
  @Trace hasCover: boolean = false;

  constructor(key: string = '', name: string = '', tag: string = '', cover: string = '') {
    this.key = key;
    this.name = name;
    this.tag = tag;
    this.cover = cover;
    this.hasCover = cover !== '';
  }
}

/** 分类点击：复用 Phase 14-J3 已验证的 mode=tag 搜索参数。 */
export function buildCategorySearchParam(tag: string): SearchParam {
  return buildTagSearchParam(tag);
}

/**
 * 从真实 /api/home 漫画列表里找分类代表封面。
 * 只有 Comic.categories 明确包含该分类名时才使用；找不到返回空串，由 UI 显示占位。
 */
export function categoryCoverFor(tag: string, comics: Comic[]): string {
  if (tag === '') {
    return '';
  }
  for (let i = 0; i < comics.length; i++) {
    const comic: Comic = comics[i];
    const tags: string[] = comic.categories.split(' ');
    for (let j = 0; j < tags.length; j++) {
      if (tags[j].trim() === tag && comic.cover !== '') {
        return comic.cover;
      }
    }
  }
  return '';
}

/** 个人化精选：仓库内没有独立推荐接口，明确不允许发起伪装请求。 */
export const PERSONALIZED_STATUS_API_UNVERIFIED: string = 'API_UNVERIFIED';

export function personalizedCanLoad(): boolean {
  return false;
}
