/**
 * SearchLayoutHelper.ets —— 搜索页响应式顶栏、热门标签合并、筛选摘要与分页留白纯函数
 */
import { SEARCH_FINISHED_ALL, SEARCH_SORT_DEFAULT, SEARCH_TYPE_DEFAULT } from '../source/NoyAcgSource';
import { paginationFloatingInsetVp } from './Pagination';
import { shouldUseInlineSecondaryHeader } from './StandardScaffoldLayout';

export const DEFAULT_HOT_SEARCH_TAGS: string[] = [
  '奇幻', '戀愛', '校園', '日常', '搞笑',
  '異世界', '百合', '冒險', '科幻', '懸疑'
];

/** 是否启用横屏/宽屏单行内联搜索顶栏 */
export function isSearchInlineHeader(widthVp: number, heightVp: number): boolean {
  return shouldUseInlineSecondaryHeader(widthVp, heightVp);
}

/** 横屏/宽屏下是否在顶栏右侧同屏展示筛选胶囊 */
export function shouldShowInlineSearchFilters(
  widthVp: number,
  heightVp: number,
  hasSearchState: boolean
): boolean {
  return hasSearchState && isSearchInlineHeader(widthVp, heightVp);
}

/** 竖屏下是否在搜索框下方展示筛选栏 */
export function shouldShowStackedSearchFilters(
  widthVp: number,
  heightVp: number,
  hasSearchState: boolean
): boolean {
  return hasSearchState && !isSearchInlineHeader(widthVp, heightVp);
}

export function hasActiveSearchFilters(sort: string, type: string, finished: string): boolean {
  return sort !== SEARCH_SORT_DEFAULT ||
    type !== SEARCH_TYPE_DEFAULT ||
    finished !== SEARCH_FINISHED_ALL;
}

/** 合并并去重热门搜索标签（优先使用缓存高频标签，不足时由精选标签兜底） */
export function mergeHotSearchTags(
  cachedTags: string[],
  fallbackTags: string[] = DEFAULT_HOT_SEARCH_TAGS,
  limit: number = 10
): string[] {
  const seen: Set<string> = new Set<string>();
  const out: string[] = [];
  const appendFrom = (src: string[]): void => {
    for (let i = 0; i < src.length && out.length < limit; i++) {
      const clean: string = src[i].trim();
      if (clean !== '' && !seen.has(clean)) {
        seen.add(clean);
        out.push(clean);
      }
    }
  };
  appendFrom(cachedTags);
  appendFrom(fallbackTags);
  return out;
}

/** 搜索结果统计文案 */
export function formatSearchResultSummary(
  totalCount: number,
  loadedCount: number,
  sortLabel: string,
  typeLabel: string,
  finishedLabel: string,
  activeFilters: boolean
): string {
  const countText: string = totalCount >= 0
    ? `共 ${totalCount} 部相关作品`
    : `本页已加载 ${loadedCount} 部相关作品`;
  if (!activeFilters) {
    return countText;
  }
  return `${countText} · ${sortLabel} / ${typeLabel} / ${finishedLabel}`;
}

/** 搜索结果列表底部避让高度（总页数 > 1 时预留悬浮 PaginationBar 高度） */
export function searchResultBottomInsetVp(totalPages: number, bottomSafeVp: number): number {
  return paginationFloatingInsetVp(totalPages > 1, bottomSafeVp);
}
