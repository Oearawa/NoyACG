/**
 * ContentFilter.ets —— 标签屏蔽的统一过滤入口（Phase 14-R）
 *
 * 分层定位：Repository（或 ViewModel 的数据落地点）在把服务端数组交给 UI 之前，
 * 统一调用本模块过滤一次。**页面不得各写一套标签判断**。
 *
 * 分页语义（重要）：
 * 过滤在客户端进行，服务端 `len` 仍然是**未过滤**的总量。
 * 因此本模块只过滤 `list`，绝不改写 `totalCount` / `totalPages`；
 * 某一页过滤后少于 20 条是正常现象，不能据此推断「没有下一页」。
 */
import { Comic } from '../model/Comic';
import { PageInfo } from '../model/PageInfo';
import { PreferenceManager } from '../utils/PreferenceManager';
import { BlockedTagSet, filterBlockedItems } from '../utils/BlockedTags';

/** 当前生效的屏蔽集合（每次调用都读内存快照，保证「改完立即生效」） */
export function currentBlockedTags(): BlockedTagSet {
  return PreferenceManager.getInstance().getBlockedTagsSync();
}

/** 当前是否启用了标签屏蔽（用于 UI 决定是否展示「已过滤」提示） */
export function isBlockingActive(): boolean {
  return !currentBlockedTags().isEmpty();
}

/** 过滤漫画数组（不改写入参，保持服务端原始顺序） */
export function filterComics(list: Comic[]): Comic[] {
  return filterBlockedItems(list, currentBlockedTags());
}

/**
 * 过滤分页结果：只替换 `list`，保留服务端 `page` / `totalPages` / `totalCount` / `hasMore`。
 */
export function filterPageInfo(page: PageInfo<Comic>): PageInfo<Comic> {
  const blocked: BlockedTagSet = currentBlockedTags();
  if (blocked.isEmpty()) {
    return page;
  }
  const kept: Comic[] = filterBlockedItems(page.list, blocked);
  if (kept.length === page.list.length) {
    return page;
  }
  return new PageInfo<Comic>(page.page, page.totalPages, kept, page.hasMore, page.totalCount);
}

/** 本页被滤掉的条数（UI 提示 / 测试断言用） */
export function removedFromPage(page: PageInfo<Comic>): number {
  return page.list.length - filterComics(page.list).length;
}
