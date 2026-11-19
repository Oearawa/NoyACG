/**
 * UIFrameScheduler.ets —— 把回调排到下一渲染帧（Phase 15-R2 从 Classic-UI 分支并入）
 *
 * 供 FrameCoalescer 使用：合并后的工作在下一帧执行，避免与当前布局同帧竞争。
 * 注意：`UIContext.postFrameCallback` 在 loadContent 之前不可用，
 * 因此调用方（SafeAreaManager）必须对「取 UIContext / 排帧」失败做降级（直接同步执行）。
 */
import { FrameCallback, UIContext } from '@kit.ArkUI';

class OneFrameCallback extends FrameCallback {
  private work: () => void;
  constructor(work: () => void) {
    super();
    this.work = work;
  }
  onFrame(_time: number): void {
    this.work();
  }
}

export function scheduleUIFrame(context: UIContext, work: () => void): void {
  context.postFrameCallback(new OneFrameCallback(work));
}
