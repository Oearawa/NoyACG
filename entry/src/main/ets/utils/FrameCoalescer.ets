/**
 * FrameCoalescer.ets —— 帧内事件合并（Phase 15-R2 从 Classic-UI 分支并入）
 *
 * 用途：同一渲染帧内可能连续收到多次窗口事件（尺寸 + 避让 + 折叠模式），
 * 逐次同步采样会重复读窗口属性、重复提交状态。这里把它们合并成「本帧只执行最后一次」，
 * 不做 wall-clock 防抖、不引入尾部延迟（不改变首帧时序）。
 *
 * 接入点：utils/SafeAreaManager.requestSample()，仅用于**后续**窗口事件；
 * 首次绑定仍走同步采样，避免 UIContext 尚未就绪时把首帧形态算错。
 */

/** Latest work wins within a rendering frame; no wall-clock debounce or trailing delay. */
export class FrameCoalescer {
  private queued: boolean = false;
  private generation: number = 0;
  private latest?: () => void;
  events: number = 0;
  frames: number = 0;
  private schedule: (callback: () => void) => void;

  constructor(schedule: (callback: () => void) => void) {
    this.schedule = schedule;
  }

  request(work: () => void): void {
    this.events++;
    this.latest = work;
    if (this.queued) {
      return;
    }
    this.queued = true;
    const generation = this.generation;
    this.schedule((): void => {
      if (generation !== this.generation) {
        return;
      }
      this.queued = false;
      const latest = this.latest;
      this.latest = undefined;
      this.frames++;
      if (latest !== undefined) {
        latest();
      }
    });
  }

  /**
   * 是否还有未执行的请求（已排帧但回调尚未运行）。
   * Phase 15-R2.2：调用方据此判断「上一帧的回调是否被系统丢弃」——
   * 若某次排帧没被回调（启动期 / 折叠转场 / 窗口不可见都很常见），
   * `queued` 会一直为 true，后续事件只覆盖 latest 而永不执行，采样就此永久停摆。
   */
  isPending(): boolean {
    return this.queued || this.latest !== undefined;
  }

  cancel(): void {
    this.generation++;
    this.latest = undefined;
    this.queued = false;
  }
}
