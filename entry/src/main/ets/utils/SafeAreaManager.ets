/**
 * SafeAreaManager.ets —— 安全区与根窗口几何采样工具
 *
 * 两条独立职责，刻意分开：
 *   1. 页面用的「状态栏 / 底部避让高度」查询（getStatusBarHeight / getBottomSafeAreaHeight），
 *      带缓存但**可失效**（配置变更、折叠形态变化、窗口尺寸变化都会失效）；
 *   2. 根窗口几何采样（sampleWindowGeometry）：读 windowRect + 系统避让 →
 *      换算成 vp → 提交给 ViewportState。导航形态只认这一条链路。
 *
 * Phase 15-R2 修正要点：
 *   - px→vp 不再依赖 UIContext（`getUIContext()` 在 loadContent 之前、窗格重建瞬间会抛，
 *     旧实现整段 try 被吞，导致几何采样根本没执行、navMode 冻结在旧值 → S1）；
 *   - 密度**每次采样重读**，不再永久缓存（折叠展开/显示大小改变会换密度 → R2-5）；
 *   - 主窗口监听器随窗口实例重绑（折叠/多窗口会换 window 对象）。
 */
import { window, display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';
import { pxToVp } from './Geometry';
import { ViewportState } from './ViewportState';
import { FrameCoalescer } from './FrameCoalescer';
import { scheduleUIFrame } from './UIFrameScheduler';

const TAG: string = 'SafeAreaManager';

/**
 * 是否需要重绑主窗口（Phase 15-R2.1 P0-02）。
 * **只按对象身份判断**：折叠/展开不一定换 window 实例，不能假设每次都会换；
 * 反之实例变了就必须重绑，否则旧实例上的 windowSizeChange 不再回调，形态会冻结。
 * `next` 取不到（undefined）时不重绑，避免把可用绑定换成空绑定。
 */
export function shouldRebindWindow(current: Object | undefined, next: Object | undefined): boolean {
  if (next === undefined) {
    return false;
  }
  return current !== next;
}

/**
 * 旧代次回调是否应被丢弃。
 * 重绑后旧窗口的迟到事件（折叠动画期间很常见）不得写入新窗口的几何状态。
 */
export function isStaleWindowEvent(eventGeneration: number, currentGeneration: number): boolean {
  return eventGeneration !== currentGeneration;
}

export class SafeAreaManager {
  /** 应用级上下文（EntryAbility 注入） */
  private static appContext?: common.Context;
  /** 状态栏高度缓存（-1 = 未测量；几何/配置变化时失效） */
  private static cachedStatusBarHeight: number = -1;
  /** 底部导航条/手势条高度缓存（-1 = 未测量；几何/配置变化时失效） */
  private static cachedBottomSafeAreaHeight: number = -1;
  /** 取不到真实值时的兜底高度（主流机型近似值） */
  private static readonly DEFAULT_STATUS_BAR_HEIGHT: number = 36;

  /** 已绑定的主窗口 */
  private static boundWindow?: window.Window;
  /**
   * 当前 WindowStage（Phase 15-R2.1 P0-02）。
   * 重绑时用它 `getMainWindowSync()` 取主窗口，而不是 `window.getLastWindow()`——
   * 前者是「本 UIAbility 的主窗口」，后者在有弹窗/子窗口时可能取到别的窗口。
   */
  private static boundStage?: window.WindowStage;
  /** 绑定代次：每次 bind / unbind +1；旧代次的监听回调据此作废（P0-02 第 7 条） */
  private static bindGeneration: number = 0;
  /** 折叠显示模式（仅作失效信号，不参与形态判定） */
  private static displayMode: number = -1;
  /**
   * 帧内事件合并器（Phase 15-R2 并入）。
   * 同一帧内「尺寸 + 避让 + 折叠」三类事件只触发一次采样；
   * UIContext 未就绪（loadContent 前）时降级为直接执行，绝不丢事件。
   */
  private static frameQueue?: FrameCoalescer;
  /**
   * 当前代次注册的监听器引用。
   * 必须逐次保存：`win.off()` 只认同一个函数引用，静态共享监听器无法表达「代次」，
   * 旧窗口的迟到回调会被当成有效事件。
   */
  private static sizeListener?: (size: window.Size) => void;
  private static avoidAreaListener?: (event: window.AvoidAreaOptions) => void;
  private static foldListener?: (mode: display.FoldDisplayMode) => void;

  /**
   * 请求一次采样：经帧合并后执行。
   * 只有「绑定窗口那一刻」用同步采样，保证首帧形态立即正确。
   */
  private static requestSample(): void {
    const queue: FrameCoalescer | undefined = SafeAreaManager.frameQueue;
    if (queue === undefined) {
      SafeAreaManager.sampleWindowGeometry();
      return;
    }
    if (queue.isPending()) {
      // ★ Phase 15-R2.2 关键修复：上一帧排的回调还没执行，说明那一帧被丢弃了
      //   （启动期未出首帧、折叠转场、窗口不可见都会发生）。
      //   旧实现此时只覆盖 latest 而不再排帧 → queued 永远是 true → 采样永久停摆，
      //   外在表现就是「导航形态只在重启后才正确」。
      //   这里改为立刻同步采样并作废排帧：任何一次事件最多延后一帧，绝不丢失、
      //   绝不卡死，且仍然不使用任何定时器或 wall-clock 防抖。
      queue.cancel();
      SafeAreaManager.sampleWindowGeometry();
      return;
    }
    queue.request((): void => SafeAreaManager.sampleWindowGeometry());
  }

  /**
   * 同步读取当前顶部避让（vp），供自绘顶栏在 build 中直接使用。
   *
   * 与 `getStatusBarHeight()` 的区别：后者是异步 + 独立缓存，首帧还没返回时退回 36，
   * 于是顶栏先按 36 排版、随后跳到真实值（14~30vp），表现为返回按钮/标题「先下后上」错位。
   * 这里直接读几何采样结果，首帧即正确，且与导航形态同源（同一份 windowRect + avoidArea）。
   */
  static topInsetNow(): number {
    const vp: ViewportState = ViewportState.getInstance();
    if (vp.hasCommitted()) {
      return vp.topVp;
    }
    if (SafeAreaManager.cachedStatusBarHeight >= 0) {
      return SafeAreaManager.cachedStatusBarHeight;
    }
    return SafeAreaManager.DEFAULT_STATUS_BAR_HEIGHT;
  }

  /** 注入应用级上下文（EntryAbility.onCreate 调用一次） */
  static init(context: common.Context): void {
    SafeAreaManager.appContext = context;
  }

  // ==================== 页面侧查询（带可失效缓存） ====================

  /**
   * 获取状态栏高度（单位 vp），用作页面顶部 padding.top。
   * 失败兜底 36vp，绝不抛异常。
   */
  static async getStatusBarHeight(context?: common.Context): Promise<number> {
    if (SafeAreaManager.cachedStatusBarHeight >= 0) {
      return SafeAreaManager.cachedStatusBarHeight;
    }
    const ctx: common.Context | undefined = context ?? SafeAreaManager.appContext;
    if (ctx === undefined) {
      Logger.warn(TAG, '未注入上下文，返回默认状态栏高度');
      return SafeAreaManager.DEFAULT_STATUS_BAR_HEIGHT;
    }
    try {
      const win: window.Window = await window.getLastWindow(ctx);
      const density: number = SafeAreaManager.currentDensity();
      const heightVp: number = pxToVp(win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height, density);
      if (heightVp > 0) {
        SafeAreaManager.cachedStatusBarHeight = heightVp;
        return heightVp;
      }
    } catch (e) {
      Logger.warn(TAG, `获取状态栏高度失败，使用默认值: ${(e as BusinessError).message}`);
    }
    return SafeAreaManager.DEFAULT_STATUS_BAR_HEIGHT;
  }

  /**
   * 获取底部导航条/手势条安全区高度（单位 vp）。
   * 取 TYPE_NAVIGATION_INDICATOR（手势条）与 TYPE_SYSTEM 底部避让的较大值：
   * 沉浸式全屏下 TYPE_SYSTEM 底部可能为 0，只取其一会在三键导航设备上算错。
   */
  static async getBottomSafeAreaHeight(context?: common.Context): Promise<number> {
    if (SafeAreaManager.cachedBottomSafeAreaHeight >= 0) {
      return SafeAreaManager.cachedBottomSafeAreaHeight;
    }
    const ctx: common.Context | undefined = context ?? SafeAreaManager.appContext;
    if (ctx === undefined) {
      return 0;
    }
    try {
      const win: window.Window = await window.getLastWindow(ctx);
      const density: number = SafeAreaManager.currentDensity();
      const indicator: number =
        pxToVp(win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height, density);
      const system: number =
        pxToVp(win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).bottomRect.height, density);
      const heightVp: number = Math.max(indicator, system);
      SafeAreaManager.cachedBottomSafeAreaHeight = heightVp;
      return heightVp;
    } catch (e) {
      Logger.warn(TAG, `获取底部安全区高度失败，回退 0: ${(e as BusinessError).message}`);
      return 0;
    }
  }

  /** 使高度缓存失效（配置变更 / 折叠形态变化 / 窗口尺寸变化时调用） */
  static invalidateMetrics(): void {
    SafeAreaManager.cachedStatusBarHeight = -1;
    SafeAreaManager.cachedBottomSafeAreaHeight = -1;
  }

  // ==================== 根窗口几何采样（导航形态唯一输入） ====================

  /** 记录 WindowStage（EntryAbility.onWindowStageCreate 注入一次；重绑时从中取主窗口） */
  static attachWindowStage(stage: window.WindowStage): void {
    SafeAreaManager.boundStage = stage;
  }

  /**
   * 绑定主窗口并注册监听（幂等；窗口实例变化时先解绑再重绑）。
   * 监听器按代次闭包注册：旧窗口的迟到回调在入口处即被丢弃。
   */
  static bindMainWindow(win: window.Window): void {
    if (SafeAreaManager.boundWindow === win) {
      // 同一实例：不重复注册，只刷新一次几何
      SafeAreaManager.sampleWindowGeometry();
      return;
    }
    SafeAreaManager.unbindMainWindow();
    // 代次在 unbind 里已 +1，这里取到的就是「本次绑定」的代次
    const generation: number = SafeAreaManager.bindGeneration;
    SafeAreaManager.boundWindow = win;
    // 帧合并：排到下一渲染帧；UIContext / postFrameCallback 不可用（loadContent 前）时直接执行
    SafeAreaManager.frameQueue = new FrameCoalescer((work: () => void): void => {
      try {
        scheduleUIFrame(win.getUIContext(), work);
      } catch (e) {
        work();
      }
    });

    const sizeListener = (_size: window.Size): void => {
      if (isStaleWindowEvent(generation, SafeAreaManager.bindGeneration)) {
        return;
      }
      SafeAreaManager.requestSample();
    };
    const avoidAreaListener = (event: window.AvoidAreaOptions): void => {
      if (isStaleWindowEvent(generation, SafeAreaManager.bindGeneration)) {
        return;
      }
      if (event.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR ||
        event.type === window.AvoidAreaType.TYPE_SYSTEM) {
        SafeAreaManager.requestSample();
      }
    };
    const foldListener = (mode: display.FoldDisplayMode): void => {
      if (isStaleWindowEvent(generation, SafeAreaManager.bindGeneration)) {
        return;
      }
      if (SafeAreaManager.displayMode === mode) {
        return;
      }
      SafeAreaManager.displayMode = mode;
      SafeAreaManager.invalidateMetrics();
      // 折叠是最关键的一次几何变化，且转场期间排帧可能被丢弃：
      // 这里直接同步采样，不经过帧合并队列。
      SafeAreaManager.sampleWindowGeometry();
    };
    SafeAreaManager.sizeListener = sizeListener;
    SafeAreaManager.avoidAreaListener = avoidAreaListener;
    SafeAreaManager.foldListener = foldListener;

    try {
      win.on('windowSizeChange', sizeListener);
      win.on('avoidAreaChange', avoidAreaListener);
    } catch (e) {
      Logger.warn(TAG, `窗口监听注册失败: ${(e as BusinessError).message}`);
    }
    try {
      if (display.isFoldable()) {
        display.on('foldDisplayModeChange', foldListener);
      }
    } catch (e) {
      Logger.warn(TAG, `显示模式监听不可用: ${(e as BusinessError).message}`);
    }
    SafeAreaManager.invalidateMetrics();
    // 新窗口绑定后立即读一次真实 windowRect + 避让（P0-02 第 6 条）
    SafeAreaManager.sampleWindowGeometry();
    Logger.info(TAG, `窗口重绑 generation=${SafeAreaManager.bindGeneration}`);
  }

  /**
   * 检查主窗口实例，必要时重绑（P0-02）。
   * - 实例相同：只失效缓存并刷新几何，**不重复注册监听**；
   * - 实例变化：走 bindMainWindow（内部先解绑旧窗口再绑新窗口）；
   * - 取不到 WindowStage / 主窗口：退化为刷新现有绑定的几何，绝不丢采样。
   * 不引入任何固定延迟或 wall-clock 防抖。
   */
  static rebindMainWindowIfNeeded(stage?: window.WindowStage): void {
    const useStage: window.WindowStage | undefined = stage ?? SafeAreaManager.boundStage;
    if (useStage === undefined) {
      SafeAreaManager.sampleWindowGeometry();
      return;
    }
    let mainWindow: window.Window | undefined;
    try {
      mainWindow = useStage.getMainWindowSync();
    } catch (e) {
      Logger.warn(TAG, `获取主窗口失败，沿用现有绑定: ${(e as BusinessError).message}`);
      mainWindow = undefined;
    }
    if (!shouldRebindWindow(SafeAreaManager.boundWindow, mainWindow)) {
      // 同一实例（或本次取不到）：只刷新几何，不重复注册监听
      if (mainWindow !== undefined) {
        SafeAreaManager.boundWindow = mainWindow;
      }
      SafeAreaManager.invalidateMetrics();
      SafeAreaManager.sampleWindowGeometry();
      return;
    }
    SafeAreaManager.bindMainWindow(mainWindow as window.Window);
  }

  /** 解绑主窗口（不主动清空高度缓存：缓存会在下次采样时失效重建） */
  static unbindMainWindow(): void {
    // 先递增代次：此后旧窗口的任何迟到回调都会被 isStaleWindowEvent 丢弃
    SafeAreaManager.bindGeneration++;
    const queue: FrameCoalescer | undefined = SafeAreaManager.frameQueue;
    if (queue !== undefined) {
      queue.cancel();
      SafeAreaManager.frameQueue = undefined;
    }
    const win: window.Window | undefined = SafeAreaManager.boundWindow;
    const sizeListener = SafeAreaManager.sizeListener;
    const avoidAreaListener = SafeAreaManager.avoidAreaListener;
    const foldListener = SafeAreaManager.foldListener;
    SafeAreaManager.sizeListener = undefined;
    SafeAreaManager.avoidAreaListener = undefined;
    SafeAreaManager.foldListener = undefined;
    if (win !== undefined) {
      try {
        if (sizeListener !== undefined) {
          win.off('windowSizeChange', sizeListener);
        }
        if (avoidAreaListener !== undefined) {
          win.off('avoidAreaChange', avoidAreaListener);
        }
      } catch (e) {
        Logger.warn(TAG, `窗口监听解绑失败: ${(e as BusinessError).message}`);
      }
    }
    try {
      if (foldListener !== undefined && display.isFoldable()) {
        display.off('foldDisplayModeChange', foldListener);
      }
    } catch (e) {
      Logger.warn(TAG, `显示模式监听解绑失败: ${(e as BusinessError).message}`);
    }
    SafeAreaManager.boundWindow = undefined;
  }

  /**
   * 采样一次根窗口几何并提交给 ViewportState。
   * 全程不读 UIContext、不读内容区尺寸；任何异常只记日志，绝不提交错误样本。
   */
  static sampleWindowGeometry(): void {
    const win: window.Window | undefined = SafeAreaManager.boundWindow;
    if (win === undefined) {
      return;
    }
    try {
      const rect: window.Rect = win.getWindowProperties().windowRect;
      const density: number = SafeAreaManager.currentDensity();
      const widthVp: number = pxToVp(rect.width, density);
      const heightVp: number = pxToVp(rect.height, density);
      const topVp: number =
        pxToVp(win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height, density);
      const indicatorVp: number =
        pxToVp(win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height, density);
      const systemBottomVp: number =
        pxToVp(win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).bottomRect.height, density);
      const bottomVp: number = Math.max(indicatorVp, systemBottomVp);

      const changed: boolean = ViewportState.getInstance().setGeometry(widthVp, heightVp, topVp, bottomVp);
      // 同步刷新安全区高度缓存与 AppStorage，保证 loadContent 首帧即拥有真实安全区与窗口几何
      SafeAreaManager.cachedStatusBarHeight = topVp;
      SafeAreaManager.cachedBottomSafeAreaHeight = bottomVp;
      try {
        AppStorage.setOrCreate('windowWidthVp', widthVp);
        AppStorage.setOrCreate('windowHeightVp', heightVp);
        AppStorage.setOrCreate('topSafeInsetVp', topVp);
        AppStorage.setOrCreate('bottomSafeInsetVp', bottomVp);
      } catch (_e) {
        // 无 UI 上下文（单元测试宿主环境）下忽略 AppStorage 写入
      }
      if (changed) {
        Logger.info(TAG, `几何采样 ${rect.width}x${rect.height}px@${density.toFixed(2)} → ` +
          `${ViewportState.getInstance().geometryHint()} navMode=${ViewportState.getInstance().navMode} ` +
          `avoid(top=${topVp.toFixed(1)},bottom=${bottomVp.toFixed(1)})`);
      }
    } catch (e) {
      Logger.warn(TAG, `几何采样失败（保持上一形态）: ${(e as BusinessError).message}`);
    }
  }

  /** 当前屏幕密度：每次重读，不缓存（折叠/显示大小变化会换密度） */
  private static currentDensity(): number {
    try {
      return display.getDefaultDisplaySync().densityPixels;
    } catch (e) {
      return 0; // 交给 pxToVp 的 normalizeDensity 兜底
    }
  }
}
