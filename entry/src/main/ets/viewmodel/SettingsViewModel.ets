/**
 * SettingsViewModel.ets —— 设置页视图模型（Phase 14-J1）
 *
 * 只做两件事：
 * 1. 把「内容分级」三选项在 UI 文案 ↔ 协议值之间做**纯函数**映射（便于单测）；
 * 2. 暴露保存状态，写操作统一委托 ContentRatingPolicy（唯一真相源 → PreferenceManager）。
 *
 * 不新建第二套内容分级状态：`contentRating` 只是 policy 的镜像，供 UI 即时刷新。
 */
import { ContentRating } from '../utils/PreferenceManager';
import { ContentRatingPolicy } from '../utils/ContentRatingPolicy';
import { LocalizationManager } from '../utils/LocalizationManager';

/** UI 文案（顺序即 Select 选项顺序，不可随意调整） */
export const RATING_LABELS: string[] = ['仅全年龄内容', '仅限制级内容', '显示全部内容'];

/** 协议值 → 选项下标（非法值 → 0 全年龄） */
export function ratingToIndex(rating: string): number {
  if (rating === ContentRating.ADULT) {
    return 1;
  }
  if (rating === ContentRating.BOTH) {
    return 2;
  }
  return 0;
}

/** 选项下标 → 协议值（越界 → 全年龄） */
export function indexToRating(index: number): string {
  if (index === 1) {
    return ContentRating.ADULT;
  }
  if (index === 2) {
    return ContentRating.BOTH;
  }
  return ContentRating.ALL_AGES;
}

/** 协议值 → UI 文案 */
export function ratingLabel(rating: string): string {
  return RATING_LABELS[ratingToIndex(rating)];
}

/** 切换内容类型成功后的即时提示文案 */
export function ratingSwitchedToast(rating: string): string {
  const lm: LocalizationManager = LocalizationManager.getInstance();
  if (rating === ContentRating.ADULT) {
    return lm.getString($r('app.string.rating_toast_adult'), '已切换至仅限制级内容，返回首页自动刷新');
  }
  if (rating === ContentRating.BOTH) {
    return lm.getString($r('app.string.rating_toast_both'), '已切换至显示全部内容，返回首页自动刷新');
  }
  return lm.getString($r('app.string.rating_toast_all_ages'), '已切换至仅全年龄内容，返回首页自动刷新');
}

@ObservedV2
export class SettingsViewModel {
  /** 当前内容分级（policy 的镜像，驱动 UI） */
  @Trace contentRating: string = ContentRating.ALL_AGES;
  /** 保存中（防重复点击） */
  @Trace saving: boolean = false;
  /** 最近一次错误（空串 = 无） */
  @Trace errorMessage: string = '';
  /** 最近一次实际切换成功后的即时提示文案（未变化或失败时为空串） */
  @Trace lastSwitchToast: string = '';

  private policy: ContentRatingPolicy = ContentRatingPolicy.getInstance();

  /** 页面进入时同步一次当前值（policy 已在启动时载入偏好） */
  initialize(): void {
    this.contentRating = this.policy.resolve();
  }

  /** 当前选中下标（Select.selected 用） */
  currentIndex(): number {
    return ratingToIndex(this.contentRating);
  }

  /** 当前值文案（Select.value 用） */
  currentLabel(): string {
    return ratingLabel(this.contentRating);
  }

  /**
   * 选择第 index 项：写偏好 → policy 更新 → 返回是否成功。
   * 失败不伪造成功：errorMessage 会反映失败原因。
   */
  async selectIndex(index: number): Promise<boolean> {
    if (this.saving) {
      return false;
    }
    this.lastSwitchToast = '';
    const next: string = indexToRating(index);
    if (next === this.contentRating) {
      return true; // 未变化，不触发多余刷新与提示
    }
    this.saving = true;
    this.errorMessage = '';
    try {
      const ok: boolean = await this.policy.set(next);
      this.contentRating = this.policy.resolve();
      if (ok) {
        this.lastSwitchToast = ratingSwitchedToast(this.contentRating);
      }
      return ok;
    } catch (e) {
      this.errorMessage = `内容类型保存失败: ${(e as Error).message}`;
      return false;
    } finally {
      this.saving = false;
    }
  }
}
