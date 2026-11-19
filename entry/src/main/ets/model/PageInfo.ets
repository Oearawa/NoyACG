/**
 * PageInfo.ets —— 分页数据容器
 *
 * 统一包裹「首页 / 搜索 / 分类」等列表型接口的返回。
 * 说明：本类是纯数据容器，不加 @ObservedV2；
 * 由 ViewModel 以 @Trace 持有并「整体替换」，即可触发 UI 刷新。
 */
export class PageInfo<T> {
  /** 当前页码（从 1 开始） */
  readonly page: number;
  /** 总页数（源站未返回时为 -1） */
  readonly totalPages: number;
  /** 当前页数据 */
  readonly list: T[];
  /** 是否还有下一页 */
  readonly hasMore: boolean;
  /**
   * 服务端返回的全局总量（Phase 14-Q）。
   * - `>= 0`：服务端明确给出的总量（如榜单/推荐的 `len`）；
   * - `-1`：源站未提供或无法可靠解析，调用方不得把它当成 0 条。
   * 默认 -1，保证既有调用方（搜索/书单）行为不变。
   */
  readonly totalCount: number;

  constructor(page: number, totalPages: number, list: T[], hasMore?: boolean,
    totalCount: number = -1) {
    this.page = page;
    this.totalPages = totalPages;
    this.list = list;
    // 未显式指定 hasMore 时的兜底策略：
    // 源站返回了总页数则按页数判断，否则按当页是否有数据判断
    this.hasMore = hasMore !== undefined ? hasMore
      : (totalPages > 0 ? page < totalPages : list.length > 0);
    this.totalCount = totalCount;
  }
}
