/**
 * PagedLoader.ets —— 通用分页加载器：帖子列表、评论、楼中楼都能用。
 *
 * 已知接口特性：
 * - 每页约 40 条；第 1 页会多带一条置顶帖 → 必须按 id 去重
 * - 判断是否到底严格使用接口返回的 over，严禁使用会漂移的 len
 * - 翻页期间有新帖会让后面的页整体后移 → 同样靠去重兜底
 */
export interface PageResult<T> {
  items: T[];
  over: boolean;
}

export type PageFetcher<T> = (page: number) => Promise<PageResult<T>>;

export class PagedLoader<T> {
  items: T[] = [];
  page: number = 0;
  over: boolean = false;
  loading: boolean = false;

  private readonly fetcher: PageFetcher<T>;
  private readonly idOf: (item: T) => string;
  private seen: Set<string> = new Set<string>();
  private epoch: number = 0;

  constructor(fetcher: PageFetcher<T>, idOf: (item: T) => string) {
    this.fetcher = fetcher;
    this.idOf = idOf;
  }

  /** 下拉刷新 / 切换排序或关键词后调用 */
  async refresh(): Promise<void> {
    this.epoch++;
    this.items = [];
    this.seen = new Set<string>();
    this.page = 0;
    this.over = false;
    this.loading = false;
    await this.loadMore();
  }

  /** 触底加载。失败会抛出异常（page 不前进），由界面决定是否重试 */
  async loadMore(): Promise<void> {
    if (this.loading || this.over) {
      return;
    }
    this.loading = true;
    const myEpoch: number = this.epoch;
    try {
      const next: number = this.page + 1;
      const r: PageResult<T> = await this.fetcher(next);
      if (myEpoch !== this.epoch) {
        return;
      }
      for (let i = 0; i < r.items.length; i++) {
        const it: T = r.items[i];
        const id: string = this.idOf(it);
        if (!this.seen.has(id)) {
          this.seen.add(id);
          this.items.push(it);
        }
      }
      this.page = next;
      this.over = r.over || r.items.length === 0;
    } finally {
      if (myEpoch === this.epoch) {
        this.loading = false;
      }
    }
  }
}
