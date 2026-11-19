/**
 * PersonalizedViewModel.ets —— 个人化精选能力边界（Phase 14-N）
 *
 * 审计结论：仓库内没有独立个人化推荐接口，也没有用户偏好 → 推荐链路。
 * /api/home、book.recommend、book/random 均不是个人化精选，按任务要求不得冒充。
 * 本 VM 不发起网络请求、不生成假数据、不提供虚假分页。
 */
import { Comic } from '../model/Comic';
import {
  PERSONALIZED_STATUS_API_UNVERIFIED,
  personalizedCanLoad
} from '../model/DiscoveryModels';

@ObservedV2
export class PersonalizedViewModel {
  @Trace status: string = PERSONALIZED_STATUS_API_UNVERIFIED;
  @Trace items: Comic[] = [];
  @Trace isLoading: boolean = false;
  @Trace errorMessage: string = '';

  canLoad(): boolean {
    return personalizedCanLoad();
  }

  load(): void {
    this.status = PERSONALIZED_STATUS_API_UNVERIFIED;
    this.items = [];
    this.isLoading = false;
    this.errorMessage = '';
  }

  retry(): void {
    this.load();
  }
}
