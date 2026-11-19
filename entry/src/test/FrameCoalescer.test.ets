/**
 * FrameCoalescer.test.ets —— 帧内事件合并单测（Phase 15-R2 合并后新增）
 *
 * 合并自 Classic-UI 分支的两个基础设施类（FrameCoalescer / UIFrameScheduler）中，
 * FrameCoalescer 是可以脱离 ArkUI 运行的关键逻辑，这里用「手动排帧」的假调度器验证：
 *   1. 同一帧内多次请求只排一次帧；
 *   2. 只执行最后一次请求（latest-wins）；
 *   3. cancel 之后旧回调不再执行（世代号）；
 *   4. 执行完一帧后可以继续排下一帧。
 */
import { describe, it, expect } from '@ohos/hypium';
import { FrameCoalescer } from '../main/ets/utils/FrameCoalescer';

/** 手动排帧的假调度器：把回调收起来，由测试决定何时「进入下一帧」 */
class ManualFrames {
  pending: Array<() => void> = [];

  schedule = (callback: () => void): void => {
    this.pending.push(callback);
  };

  /** 执行当前排队的帧回调（模拟一帧结束） */
  runFrame(): void {
    const batch: Array<() => void> = this.pending;
    this.pending = [];
    for (let i = 0; i < batch.length; i++) {
      batch[i]();
    }
  }

  queued(): number {
    return this.pending.length;
  }
}

export default function frameCoalescerTest(): void {
  describe('FrameCoalescer', () => {

    it('sameFrameRequestsScheduleOnce', 0, () => {
      const frames: ManualFrames = new ManualFrames();
      const queue: FrameCoalescer = new FrameCoalescer(frames.schedule);
      let count: number = 0;
      queue.request((): void => { count++; });
      queue.request((): void => { count++; });
      queue.request((): void => { count++; });
      // 三次请求只排了一次帧
      expect(frames.queued()).assertEqual(1);
      expect(queue.events).assertEqual(3);
      expect(queue.frames).assertEqual(0);
      // 执行时只跑最后一次（latest-wins），不是三次
      frames.runFrame();
      expect(count).assertEqual(1);
      expect(queue.frames).assertEqual(1);
    });

    it('latestWorkWins', 0, () => {
      const frames: ManualFrames = new ManualFrames();
      const queue: FrameCoalescer = new FrameCoalescer(frames.schedule);
      let last: string = '';
      queue.request((): void => { last = 'first'; });
      queue.request((): void => { last = 'second'; });
      queue.request((): void => { last = 'third'; });
      frames.runFrame();
      expect(last).assertEqual('third');
    });

    it('nextFrameSchedulesAgain', 0, () => {
      const frames: ManualFrames = new ManualFrames();
      const queue: FrameCoalescer = new FrameCoalescer(frames.schedule);
      let count: number = 0;
      queue.request((): void => { count++; });
      frames.runFrame();
      // 上一帧执行完，再次请求应重新排帧
      queue.request((): void => { count++; });
      expect(frames.queued()).assertEqual(1);
      frames.runFrame();
      expect(count).assertEqual(2);
      expect(queue.frames).assertEqual(2);
    });

    it('cancelInvalidatesPendingFrame', 0, () => {
      const frames: ManualFrames = new ManualFrames();
      const queue: FrameCoalescer = new FrameCoalescer(frames.schedule);
      let count: number = 0;
      queue.request((): void => { count++; });
      // 解绑窗口：已排的帧必须作废
      queue.cancel();
      frames.runFrame();
      expect(count).assertEqual(0);
      expect(queue.frames).assertEqual(0);
    });

    it('requestAfterCancelWorks', 0, () => {
      const frames: ManualFrames = new ManualFrames();
      const queue: FrameCoalescer = new FrameCoalescer(frames.schedule);
      let count: number = 0;
      queue.request((): void => { count++; });
      queue.cancel();
      queue.request((): void => { count++; });
      frames.runFrame();
      expect(count).assertEqual(1);
    });

    // ---------- Phase 15-R2.2：排帧被丢弃时不得永久卡死 ----------

    it('isPendingReportsUnservedWork', 0, () => {
      const frames: ManualFrames = new ManualFrames();
      const queue: FrameCoalescer = new FrameCoalescer(frames.schedule);
      // 空闲时没有待执行请求
      expect(queue.isPending()).assertFalse();
      queue.request((): void => {});
      // 已排帧但还没进入下一帧：必须有待执行标记（调用方据此触发同步兜底）
      expect(queue.isPending()).assertTrue();
      frames.runFrame();
      expect(queue.isPending()).assertFalse();
    });

    it('droppedFrameStillReportsPending', 0, () => {
      const frames: ManualFrames = new ManualFrames();
      const queue: FrameCoalescer = new FrameCoalescer(frames.schedule);
      let count: number = 0;
      queue.request((): void => { count++; });
      // 模拟「这一帧被系统丢弃」：不调用 runFrame，直接再来一次请求
      queue.request((): void => { count++; });
      // 旧实现：queued 一直为 true，后面所有请求只会覆盖 latest，永远不执行（= 必须重启）
      expect(queue.isPending()).assertTrue();
      expect(count).assertEqual(0);
      // 调用方的兜底：cancel + 同步执行，随后队列回到可重新排帧的状态
      queue.cancel();
      expect(queue.isPending()).assertFalse();
      count = count + 1;
      queue.request((): void => { count++; });
      frames.runFrame();
      expect(count).assertEqual(2);
      expect(queue.isPending()).assertFalse();
    });

    it('cancelThenRequestSchedulesAgain', 0, () => {
      const frames: ManualFrames = new ManualFrames();
      const queue: FrameCoalescer = new FrameCoalescer(frames.schedule);
      queue.request((): void => {});
      queue.cancel();
      // cancel 之后必须能重新排帧（否则兜底路径会把队列永久废掉）
      queue.request((): void => {});
      expect(frames.queued()).assertEqual(2);
      frames.runFrame();
      expect(queue.isPending()).assertFalse();
    });
  });
}
