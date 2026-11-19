/**
 * ViewportState.ets —— 根窗口几何与导航形态的唯一状态源（Phase 15-R2）
 *
 * 职责边界：
 *   - `navMode` 只由 `setGeometry()` 写入，UI 层只读；
 *   - `setGeometry()` 只接受「根窗口真实尺寸 + 系统避让」，不接受任何内容区信号；
 *   - 尺寸非法（<=0 / 非有限）时**一个字段都不改**，避免把错误样本冻结成形态（对应 S1）。
 *
 * 本类刻意不保存 `portrait`：朝向已由 `navMode` 单值表达（底栏=竖向窗口，侧栏=宽窗口）。
 * 若同时保存一个可能落后的布尔，就会出现「形态说底栏、朝向说横屏」这类自相矛盾状态。
 */
import { NavigationMode, resolveNavigationMode } from './NavigationMode';
import { Breakpoint, resolveBreakpoint } from '../responsive/BreakpointManager';
import { ResponsiveLayoutMetrics, resolveLayoutPolicy } from '../responsive/LayoutPolicy';

@ObservedV2
export class ViewportState {
  /** 实例计数：必须先于 shared 初始化，否则构造时读到 undefined（NaN） */
  private static instanceSeq: number = 0;
  private static readonly shared: ViewportState = new ViewportState();

  /** 导航形态：全应用唯一形态值（六项 Tabs 属性、内容留白、图标布局都从它派生） */
  @Trace navMode: NavigationMode = NavigationMode.BOTTOM_IMMERSIVE;
  /** 官方四档窗口宽度断点（xs / sm / md / lg） */
  @Trace breakpoint: Breakpoint = Breakpoint.SM;
  /** 根窗口宽度（vp），仅用于调试戳与日志 */
  @Trace widthVp: number = 0;
  /** 根窗口高度（vp），仅用于调试戳与日志 */
  @Trace heightVp: number = 0;
  /** 顶部系统避让（vp） */
  @Trace topVp: number = 0;
  /** 底部系统避让（手势条 / 三键导航，vp） */
  @Trace bottomVp: number = 0;

  /** 实例身份（诊断用：确认全应用只有一份 ViewportState） */
  readonly instanceId: number;
  /** 变化监听器（UI 壳层显式订阅，不依赖隐式深度观察） */
  private listeners: Array<() => void> = [];
  /** 是否已收到过一组合法几何（冷启动判定与滞回判定由此区分） */
  private initialized: boolean = false;
  /** 成功提交次数（诊断用，不参与布局） */
  commits: number = 0;

  constructor() {
    ViewportState.instanceSeq++;
    this.instanceId = ViewportState.instanceSeq;
  }

  static getInstance(): ViewportState {
    return ViewportState.shared;
  }

  /**
   * 订阅几何/形态变化（Phase 15-R3）。
   *
   * 为什么需要显式订阅：实测在真机上，`@Local viewport = getInstance()` 读 `viewport.navMode`
   * 的隐式依赖在「窗口配置变更」这条路径上没有触发组件重绘（@Monitor 也未回调），
   * 于是形态只在冷启动时正确。这里改成「采样提交 → 直接回调订阅者 → 订阅者写 @Local 基元」，
   * 由基元赋值可靠地驱动重绘，不依赖 @Trace 在跨模块单例上的通知时机。
   */
  addListener(listener: () => void): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  removeListener(listener: () => void): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  private notifyListeners(): void {
    const snapshot: Array<() => void> = this.listeners.slice();
    for (let i = 0; i < snapshot.length; i++) {
      try {
        snapshot[i]();
      } catch (e) {
        // 单个订阅者异常不得影响其余订阅者与采样本身
      }
    }
  }

  /**
   * 提交一组合法几何。
   * @returns 是否有字段真的变化（供调用方决定是否打日志）
   */
  setGeometry(widthVp: number, heightVp: number, topVp: number, bottomVp: number): boolean {
    if (!Number.isFinite(widthVp) || !Number.isFinite(heightVp) || widthVp <= 0 || heightVp <= 0) {
      return false;
    }
    const mode: NavigationMode = resolveNavigationMode(widthVp, heightVp,
      this.initialized ? this.navMode : undefined);
    const nextBp: Breakpoint = resolveBreakpoint(widthVp);
    const top: number = Number.isFinite(topVp) && topVp > 0 ? topVp : 0;
    const bottom: number = Number.isFinite(bottomVp) && bottomVp > 0 ? bottomVp : 0;

    let changed: boolean = false;
    if (this.navMode !== mode) {
      this.navMode = mode;
      changed = true;
    }
    if (this.breakpoint !== nextBp) {
      this.breakpoint = nextBp;
      changed = true;
    }
    if (Math.abs(this.widthVp - widthVp) >= 0.01) {
      this.widthVp = widthVp;
      changed = true;
    }
    if (Math.abs(this.heightVp - heightVp) >= 0.01) {
      this.heightVp = heightVp;
      changed = true;
    }
    if (Math.abs(this.topVp - top) >= 0.01) {
      this.topVp = top;
      changed = true;
    }
    if (Math.abs(this.bottomVp - bottom) >= 0.01) {
      this.bottomVp = bottom;
      changed = true;
    }
    this.initialized = true;
    if (changed) {
      this.commits++;
      // 显式通知：UI 壳层据此把形态/几何写入自己的 @Local 基元
      this.notifyListeners();
    }
    return changed;
  }

  /**
   * 是否已经提交过至少一组合法几何。
   * 页面用它区分「topVp 真的是 0」与「还没采过样」，避免顶栏在首帧多加一段 padding。
   */
  hasCommitted(): boolean {
    return this.initialized;
  }

  /** 是否底部导航（单点判断，等价于 isBottomNavigation(navMode)） */
  isBottomNav(): boolean {
    return this.navMode === NavigationMode.BOTTOM_IMMERSIVE;
  }

  /** 是否横屏/宽屏模式（与主页侧边栏 SideRail 严格同源） */
  isLandscape(): boolean {
    return !this.isBottomNav();
  }

  /** 按当前窗口（或指定内容区实测宽度）计算统一响应式布局策略 */
  getLayoutPolicy(containerWidthVp?: number): ResponsiveLayoutMetrics {
    const targetWidth: number = containerWidthVp !== undefined &&
      Number.isFinite(containerWidthVp) && containerWidthVp > 0
      ? containerWidthVp
      : (this.widthVp > 0 ? this.widthVp : 390);
    return resolveLayoutPolicy(targetWidth, this.isLandscape());
  }

  /** 诊断字符串：`1264x1848px@3.00 → 421.3x616.0vp r=0.684` */
  geometryHint(): string {
    const ratio: number = this.heightVp > 0 ? this.widthVp / this.heightVp : 0;
    return `${this.widthVp.toFixed(1)}x${this.heightVp.toFixed(1)}vp r=${ratio.toFixed(3)}`;
  }
}
