/**
 * RatingBridge.ets —— 内容分级变化的「页面级」订阅桥（Phase 14-T）
 *
 * 为什么不再只靠 ViewModel 的 revision 自增：
 * Phase 14-S 的刷新完全依赖 `aboutToAppear` / `onPageShow` 里的 `reloadIfRatingChanged()`。
 * 但 HarmonyOS Navigation 的页面是**保留式**的：被新页面覆盖后旧页面仍然存活，
 * 既不会重新执行 `aboutToAppear`，`onPageShow` 也只对 @Entry 页面有效（对 NavDestination 无效）。
 * 于是「切换分级 → 返回列表」这条最常见的路径上，没有任何代码去检查 revision，
 * 数据只能等应用重启 —— 这正是 Phase 14-S 被判定失败的原因。
 *
 * 本类的职责很窄：
 * 1. 页面可见期间订阅 `ContentRatingPolicy` 的变更广播；
 * 2. 收到广播后调用页面传入的回调（回调里只做一件事：让 VM 按新分级重新请求）；
 * 3. 页面销毁时退订，避免悬挂监听与重复刷新。
 *
 * 与 `RatingSyncState`（拉取式判据）互补：
 * - 广播覆盖「页面还活着，只是被盖住」；
 * - `onShown` + `reloadIfRatingChanged()` 覆盖「页面被销毁后重建 / 从后台回到前台」。
 * 两条路径都调用同一个 `refreshForRating()`，且 VM 内已有请求代次与防重入，重复触发不会造成请求风暴。
 */
import { ContentRatingListener, ContentRatingPolicy } from './ContentRatingPolicy';

/** 分级变化回调（页面只应转调 ViewModel 的 refresForRating 类方法） */
export type RatingBridgeHandler = () => void;

export class RatingBridge {
  private readonly handler: RatingBridgeHandler;
  /** 订阅用的稳定函数引用（offChange 依赖同一引用才能正确退订） */
  private readonly listener: ContentRatingListener;
  private active: boolean = false;

  constructor(handler: RatingBridgeHandler) {
    this.handler = handler;
    this.listener = (): void => {
      this.handler();
    };
  }

  /** 页面可见：订阅（幂等，重复调用不会重复注册） */
  start(): void {
    if (this.active) {
      return;
    }
    ContentRatingPolicy.getInstance().onChange(this.listener);
    this.active = true;
  }

  /** 页面销毁：退订（幂等） */
  stop(): void {
    if (!this.active) {
      return;
    }
    ContentRatingPolicy.getInstance().offChange(this.listener);
    this.active = false;
  }

  /** 当前是否已订阅（仅用于诊断日志与测试） */
  isActive(): boolean {
    return this.active;
  }
}
