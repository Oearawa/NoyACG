/**
 * BigTagViewModel.ets —— 分类网格状态机（Phase 14-Q）
 *
 * 数据：POST /api/bigtaglist（空表单）→ { status, data: [{tag, search, cover}] }。
 * 这是官方分类目录；不再把 Phase 14-N 的 12 项视觉参考目录当作正式数据源
 * （旧 CategoryViewModel 保留未动，仅为不破坏既有测试）。
 *
 * 分类点击：`search.join(' ') || tag` → SearchParam(mode=tag)，沿用 Phase 14-J3 链路。
 */
import { BigTagItem, buildBigTagQuery } from '../model/LeaderboardModels';
import { SearchParam, buildTagSearchParam } from '../model/NavParams';
import { AuthRequiredError } from '../api/ApiErrors';
import { BigTagRepository } from '../api/DiscoveryRepository';
import { BigTagPort } from '../source/DiscoverySourcePort';
import { RatingSyncState } from '../utils/RatingSync';

@ObservedV2
export class BigTagViewModel {
  @Trace items: BigTagItem[] = [];
  @Trace isLoading: boolean = false;
  @Trace errorMessage: string = '';
  @Trace needsLogin: boolean = false;
  /** 是否已成功加载过（用于区分「空目录」与「尚未加载」） */
  @Trace loaded: boolean = false;

  private port: BigTagPort;
  private generation: number = 0;  /** 内容分级变更判据（Phase 14-S）：分类目录随分级变化 */
  private ratingSync: RatingSyncState = new RatingSyncState();

  constructor(port?: BigTagPort) {
    this.port = port ?? new BigTagRepository();
  }

  /** 分级已变化则重新拉取目录（Phase 14-S） */
  reloadIfRatingChanged(): boolean {
    if (!this.ratingSync.takeChange()) {
      return false;
    }
    this.load();
    return true;
  }

  /** 分级变化广播的即时入口（Phase 14-T）：分类目录随分级变化，直接重取整表 */
  refreshForRating(): void {
    this.ratingSync.markCurrent();
    this.load();
  }

  async load(): Promise<void> {
    const gen: number = ++this.generation;
    this.isLoading = true;
    this.errorMessage = '';
    this.needsLogin = false;
    try {
      const items: BigTagItem[] = await this.port.fetchBigTags();
      if (gen !== this.generation) {
        return;
      }
      this.items = items;
      this.loaded = true;
      this.isLoading = false;
    } catch (e) {
      if (gen !== this.generation) {
        return;
      }
      this.errorMessage = e instanceof Error ? e.message : '';
      this.needsLogin = e instanceof AuthRequiredError;
      this.isLoading = false;
    }
  }

  retry(): void {
    this.load();
  }

  /** 分类点击的搜索关键词：search 非空 → 空格连接；否则退回 tag。 */
  queryFor(item: BigTagItem): string {
    return buildBigTagQuery(item.search, item.tag);
  }

  /** 分类点击 → 既有 mode=tag 搜索参数（不重复编码、不造分类 ID）。 */
  searchParamFor(item: BigTagItem): SearchParam {
    return buildTagSearchParam(this.queryFor(item));
  }
}
