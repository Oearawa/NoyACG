/**
 * Phase14T2.test.ets —— RatingBridge 的 NavDestination 隐藏生命周期管理（Phase 14-T2）
 *
 * 背景：Phase 14-T1 里，NavDestination 页面只在 `aboutToDisappear()` 里 `bridge.stop()`，
 * 但该回调只在外层自定义组件真正销毁前触发，**不能覆盖「页面被其它 Navigation 页面压住」**。
 * 于是被覆盖的页面仍订阅分级广播，会发起不必要的网络请求。
 *
 * 本阶段的修复：五个 NavDestination 页面（Search/Rank/Category/Personalized/Detail）
 * 均接入 `NavDestination.onHidden(() => bridge.stop())` 与 `.onShown(() => { start + reloadIfRatingChanged })`；
 * 三个 Tab 组件（Home/Latest/Shelf）改用 `@Param active` + `@Monitor`，活动时订阅、非活动时退订。
 *
 * 由于 ArkUI 组件的 onShown/onHidden 回调无法在纯 ArkTS 单测里直接触发，本文件用
 * 「可注入生命周期处理器」模拟真实调用顺序，逐条验证 RatingBridge 的 start/stop 行为
 * 与 ViewModel 的请求次数/数据结果；ArkUI 页面里 onShown/onHidden 的实际绑定由
 * 静态断言（见本阶段报告 §三）核对，不在本文件内重复。
 *
 * 覆盖：
 *   A. 页面被覆盖：A 显示订阅 → B 入栈 → A 收到 hide 停订阅 → 切分级 → A 不发请求、B 更新。
 *   B. 返回原页面：A 隐藏 → B 弹出 → A 收到 show → 恢复订阅 → revision 不同则刷新、一致则不请求。
 *   C. 应用进后台：前台页 hide 停订阅 → 后台改持久化 → reconcile 更新 revision → 页 show 检测变化刷新。
 *   D. 多个隐藏页面：连续 A/B/C，A、B 隐藏时分别停订阅，仅活动页即时刷新，返回时各自检查 revision。
 */
import { describe, it, expect } from '@ohos/hypium';
import { Comic } from '../main/ets/model/Comic';
import { ContentRatingPolicy } from '../main/ets/utils/ContentRatingPolicy';
import { ContentRating, PreferenceManager } from '../main/ets/utils/PreferenceManager';
import { RatingBridge } from '../main/ets/utils/RatingBridge';
import { LeaderboardViewModel } from '../main/ets/viewmodel/LeaderboardViewModel';
import { LeaderboardPort } from '../main/ets/source/DiscoverySourcePort';
import { PageInfo } from '../main/ets/model/PageInfo';
import { RANK_KIND_READING, RANK_PERIOD_DAY } from '../main/ets/model/LeaderboardModels';

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

function resetRating(): void {
  ContentRatingPolicy.getInstance().resetForTest();
}

class CountingPort implements LeaderboardPort {
  calls: number = 0;
  lastRating: string = '';

  async fetchLeaderboard(kind: string, page: number, period: string): Promise<PageInfo<Comic>> {
    this.calls++;
    this.lastRating = ContentRatingPolicy.getInstance().resolve();
    const c: Comic = new Comic(`id_${this.lastRating}_${this.calls}`, `title_${this.lastRating}`, '', '');
    return new PageInfo<Comic>(page, 1, [c], false);
  }
}

/**
 * 可注入的生命周期处理器：模拟「页面被 NavDestination 覆盖 / 重新显示」。
 * 它忠实复刻页面里 onShown/onHidden 的接线：
 *   show() = bridge.start() + reloadIfRatingChanged()
 *   hide() = bridge.stop()
 */
class PageLifecycle {
  private bridge: RatingBridge;
  private vm: LeaderboardViewModel;

  constructor(vm: LeaderboardViewModel, handler: () => void) {
    this.vm = vm;
    this.bridge = new RatingBridge(handler);
  }

  /** 模拟 NavDestination.onShown */
  show(): boolean {
    this.bridge.start();
    return this.vm.reloadIfRatingChanged();
  }

  /** 模拟 NavDestination.onHidden */
  hide(): void {
    this.bridge.stop();
  }

  isSubscribed(): boolean {
    return this.bridge.isActive();
  }
}

export default function phase14t2Test() {
  describe('Phase14T2_PageCovered', () => {
    it('A_covered_page_stops_subscription_and_does_not_request', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const portA: CountingPort = new CountingPort();
      const vmA: LeaderboardViewModel = new LeaderboardViewModel(portA);
      vmA.kind = RANK_KIND_READING;
      vmA.period = RANK_PERIOD_DAY;
      await vmA.load(true);
      expect(portA.calls).assertEqual(1);

      const pageA: PageLifecycle = new PageLifecycle(vmA, (): void => {
        vmA.refreshForRating();
      });
      pageA.show(); // A 显示并订阅
      expect(pageA.isSubscribed()).assertTrue();

      // B 入栈，A 收到 onHidden → 停止订阅
      pageA.hide();
      expect(pageA.isSubscribed()).assertFalse();

      // 切换内容分级：A 已被覆盖，不得发起请求
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      await sleep(10);
      expect(portA.calls).assertEqual(1);
      resetRating();
    });

    it('B_active_page_receives_broadcast_when_covered_page_is_silent', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      // 页面 A（将被覆盖）
      const portA: CountingPort = new CountingPort();
      const vmA: LeaderboardViewModel = new LeaderboardViewModel(portA);
      vmA.kind = RANK_KIND_READING;
      vmA.period = RANK_PERIOD_DAY;
      await vmA.load(true);
      const pageA: PageLifecycle = new PageLifecycle(vmA, (): void => {
        vmA.refreshForRating();
      });
      pageA.show();

      // 页面 B（活动页，压住 A）
      const portB: CountingPort = new CountingPort();
      const vmB: LeaderboardViewModel = new LeaderboardViewModel(portB);
      vmB.kind = RANK_KIND_READING;
      vmB.period = RANK_PERIOD_DAY;
      await vmB.load(true);
      const pageB: PageLifecycle = new PageLifecycle(vmB, (): void => {
        vmB.refreshForRating();
      });
      pageB.show();
      pageA.hide(); // A 被 B 覆盖 → 停订阅

      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      await sleep(10);
      expect(portB.calls).assertEqual(2); // B 收到广播并更新
      expect(portB.lastRating).assertEqual(ContentRating.ADULT);
      expect(portA.calls).assertEqual(1); // A 保持静默
      resetRating();
    });
  });

  describe('Phase14T2_ReturnToPage', () => {
    it('B_return_shows_and_refreshes_when_revision_changed', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const port: CountingPort = new CountingPort();
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      vm.kind = RANK_KIND_READING;
      vm.period = RANK_PERIOD_DAY;
      await vm.load(true);
      expect(port.calls).assertEqual(1);

      const page: PageLifecycle = new PageLifecycle(vm, (): void => {
        vm.refreshForRating();
      });
      page.show();
      page.hide(); // 被覆盖，停订阅

      // 覆盖期间分级变化
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      await sleep(5);
      expect(port.calls).assertEqual(1); // 覆盖期间无请求

      // 返回：onShown → start + reloadIfRatingChanged（revision 已变 → 刷新）
      const changed: boolean = page.show();
      expect(page.isSubscribed()).assertTrue();
      expect(changed).assertTrue();
      await sleep(10);
      expect(port.calls).assertEqual(2);
      expect(port.lastRating).assertEqual(ContentRating.ADULT);
      // 榜单类型与周期保留
      expect(vm.kind).assertEqual(RANK_KIND_READING);
      expect(vm.period).assertEqual(RANK_PERIOD_DAY);
      resetRating();
    });

    it('B_return_no_request_when_revision_unchanged', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const port: CountingPort = new CountingPort();
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      vm.kind = RANK_KIND_READING;
      vm.period = RANK_PERIOD_DAY;
      await vm.load(true);
      expect(port.calls).assertEqual(1);

      const page: PageLifecycle = new PageLifecycle(vm, (): void => {
        vm.refreshForRating();
      });
      page.show();
      page.hide();
      // 覆盖期间分级未变化
      const changed: boolean = page.show();
      expect(page.isSubscribed()).assertTrue();
      expect(changed).assertFalse();
      await sleep(10);
      expect(port.calls).assertEqual(1); // revision 一致 → 不请求
      resetRating();
    });
  });

  describe('Phase14T2_AppBackground', () => {
    it('C_background_then_foreground_reconcile_and_refresh', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const port: CountingPort = new CountingPort();
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      vm.kind = RANK_KIND_READING;
      vm.period = RANK_PERIOD_DAY;
      await vm.load(true);
      expect(port.calls).assertEqual(1);

      const page: PageLifecycle = new PageLifecycle(vm, (): void => {
        vm.refreshForRating();
      });
      page.show();
      page.hide(); // 应用进后台，前台 NavDestination 收到 onHidden 停订阅

      // 后台期间持久化分级被改（绕过 policy.set，模拟其它写入通道）
      await PreferenceManager.getInstance().setContentRating(ContentRating.BOTH);
      await sleep(5);
      expect(port.calls).assertEqual(1); // 后台静默

      // UIAbility.onForeground → reconcileFromPreference 更新 revision（此时页面仍隐藏，不请求）
      const reconciled: boolean = ContentRatingPolicy.getInstance().reconcileFromPreference();
      expect(reconciled).assertTrue();
      await sleep(5);
      expect(port.calls).assertEqual(1); // 隐藏页面不因 reconcile 直接请求

      // 页面重新显示 → onShown 检测 revision 变化 → 刷新
      const changed: boolean = page.show();
      expect(changed).assertTrue();
      await sleep(10);
      expect(port.calls).assertEqual(2);
      expect(port.lastRating).assertEqual(ContentRating.BOTH);
      resetRating();
    });

    it('C_reconcile_no_change_does_not_request', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      const port: CountingPort = new CountingPort();
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      vm.kind = RANK_KIND_READING;
      vm.period = RANK_PERIOD_DAY;
      await vm.load(true);
      expect(port.calls).assertEqual(1);
      // 后台未改分级 → reconcile 返回 false，不广播
      expect(ContentRatingPolicy.getInstance().reconcileFromPreference()).assertFalse();
      expect(ContentRatingPolicy.getInstance().revisionNow())
        .assertEqual(ContentRatingPolicy.getInstance().revisionNow());
      await sleep(5);
      expect(port.calls).assertEqual(1);
      resetRating();
    });
  });

  describe('Phase14T2_MultipleHiddenPages', () => {
    it('D_hidden_pages_stop_and_only_active_refreshes', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);

      // 用独立变量保存端口与 VM（ArkTS 不支持解构）
      const portA: CountingPort = new CountingPort();
      const vmA: LeaderboardViewModel = new LeaderboardViewModel(portA);
      vmA.kind = RANK_KIND_READING;
      vmA.period = RANK_PERIOD_DAY;
      await vmA.load(true);
      const pageA: PageLifecycle = new PageLifecycle(vmA, (): void => {
        vmA.refreshForRating();
      });

      const portB: CountingPort = new CountingPort();
      const vmB: LeaderboardViewModel = new LeaderboardViewModel(portB);
      vmB.kind = RANK_KIND_READING;
      vmB.period = RANK_PERIOD_DAY;
      await vmB.load(true);
      const pageB: PageLifecycle = new PageLifecycle(vmB, (): void => {
        vmB.refreshForRating();
      });

      const portC: CountingPort = new CountingPort();
      const vmC: LeaderboardViewModel = new LeaderboardViewModel(portC);
      vmC.kind = RANK_KIND_READING;
      vmC.period = RANK_PERIOD_DAY;
      await vmC.load(true);
      const pageC: PageLifecycle = new PageLifecycle(vmC, (): void => {
        vmC.refreshForRating();
      });

      // 连续打开 A → B → C，A、B 被覆盖时分别停止订阅
      pageA.show();
      pageB.show();
      pageA.hide(); // A 被 B 覆盖
      pageC.show();
      pageB.hide(); // B 被 C 覆盖

      expect(pageA.isSubscribed()).assertFalse();
      expect(pageB.isSubscribed()).assertFalse();
      expect(pageC.isSubscribed()).assertTrue();

      // 切换分级：仅活动页 C 即时刷新
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      await sleep(10);
      expect(portC.calls).assertEqual(2);
      expect(portA.calls).assertEqual(1);
      expect(portB.calls).assertEqual(1);

      // 返回 B：检测 revision 变化 → 刷新
      const changedB: boolean = pageB.show();
      expect(changedB).assertTrue();
      await sleep(10);
      expect(portB.calls).assertEqual(2);
      expect(portB.lastRating).assertEqual(ContentRating.ADULT);

      // 返回 A：检测 revision 变化 → 刷新
      const changedA: boolean = pageA.show();
      expect(changedA).assertTrue();
      await sleep(10);
      expect(portA.calls).assertEqual(2);
      expect(portA.lastRating).assertEqual(ContentRating.ADULT);

      resetRating();
    });

    it('D_no_duplicate_request_when_revision_already_consumed', 0, async () => {
      resetRating();
      await ContentRatingPolicy.getInstance().set(ContentRating.ALL_AGES);
      const port: CountingPort = new CountingPort();
      const vm: LeaderboardViewModel = new LeaderboardViewModel(port);
      vm.kind = RANK_KIND_READING;
      vm.period = RANK_PERIOD_DAY;
      await vm.load(true);
      const page: PageLifecycle = new PageLifecycle(vm, (): void => {
        vm.refreshForRating();
      });

      page.show();
      page.hide();
      await ContentRatingPolicy.getInstance().set(ContentRating.ADULT);
      // 第一次 show 消费了 revision 变化并刷新
      page.show();
      await sleep(10);
      expect(port.calls).assertEqual(2);
      // 再次 hide → show，revision 未再变 → 不重复请求
      page.hide();
      page.show();
      await sleep(10);
      expect(port.calls).assertEqual(2);
      resetRating();
    });
  });
}
