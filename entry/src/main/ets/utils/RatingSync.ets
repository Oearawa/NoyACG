/**
 * RatingSync.ets —— 「内容分级是否已变化」的轻量判据（Phase 14-S）
 *
 * 为什么需要它：
 * 旧实现只依赖 `ContentRatingPolicy.onChange` 常驻监听。但监听器活得比页面短：
 * - `HomeViewModel.dispose()` 在 Tabs 内容被 NavDestination 覆盖时会注销监听，
 *   之后回到首页只走 `initLoad()`（`currentPage !== 0` 直接返回）→ 数据永远停在旧分级；
 * - 搜索 / 分类 / 榜单 / 精选 / 收藏这些 VM 则**从未**订阅过分级变更。
 *
 * 于是「切换分级必须重启才生效」。本类给每个 ViewModel 一个极小的状态：
 * 记住「上次加载时的分级代数」，页面重新可见时问一次 `takeChange()`，
 * 变化则重新加载 —— 不依赖组件是否还活着，也不引入第二套全局状态。
 *
 * 与监听机制的关系：两者**互补**。
 * - 监听器负责「当前可见页面」即时刷新；
 * - 本判据负责「页面重新进入 / 监听被注销」时兜底刷新。
 * 两者都调用同一个 ViewModel 的 `load()`，且 ViewModel 内已有请求代次守卫，
 * 因此重复触发不会造成请求风暴或旧数据覆盖。
 */
import { ContentRatingPolicy } from './ContentRatingPolicy';

export class RatingSyncState {
  /** 上次对齐时的分级代数（构造即对齐到「创建这一刻」的分级） */
  private seenRevision: number = 0;

  constructor() {
    // 关键：在**构造时**对齐。ViewModel 创建后自身会按当前分级加载数据，
    // 之后才发生的变更才算「过期」，因此第一次检查不会误报，也不会漏报。
    this.seenRevision = ContentRatingPolicy.getInstance().revisionNow();
  }

  /** 把当前代数标记为已对齐（例如刚按最新分级重载完成） */
  markCurrent(): void {
    this.seenRevision = ContentRatingPolicy.getInstance().revisionNow();
  }

  /** 当前已应用/已对齐的分级版本号 */
  currentSeenRevision(): number {
    return this.seenRevision;
  }

  /** 请求失败时回滚版本号，允许下次返回页面时重试 */
  rollback(revision: number): void {
    this.seenRevision = revision;
  }

  /**
   * 若分级代数已变化，返回 true 并同步为最新（调用方据此重新加载）。
   * 未变化返回 false —— 保证不会因为反复进入页面而重复请求。
   */
  takeChange(): boolean {
    const current: number = ContentRatingPolicy.getInstance().revisionNow();
    if (this.seenRevision === current) {
      return false;
    }
    this.seenRevision = current;
    return true;
  }
}
