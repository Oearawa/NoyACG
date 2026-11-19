/**
 * RetryPolicy.test.ets —— I-000004 重试策略单测
 *
 * 验证 6 项契约：
 * 1. 超时/网络错误可重试，重试次数有界（maxAttempts=3）；
 * 2. 断网挂起 → 恢复重放（有上限）；
 * 3. 恢复重放成功；
 * 4. 取消传播（不重试）；
 * 5. POST 不重试；
 * 6. 4xx 不重试。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { HttpError } from '../main/ets/api/HttpManager';
import {
  RETRY_MAX_ATTEMPTS,
  RETRY_BASE_DELAY_MS,
  classifyRetry,
  nextRetryDelayMs,
  isRetryableMethod
} from '../main/ets/api/RetryPolicy';
import { CancelToken, RequestCanceledError } from '../main/ets/api/CancelToken';
import {
  GateRejectedError,
  MAX_REPLAY,
  REPLAY_RESET_ONLINE_MS,
  RequestGate,
  RequestSlot,
  Transport
} from '../main/ets/api/RequestGate';
import { ScriptedTransport, delay } from './GateFixtures';

/** 每次测试独立闸门（避免单例状态泄漏） */
function freshGate(): RequestGate {
  const gate: RequestGate = new RequestGate();
  gate.setOnline();
  gate.setAppVisible(true);
  return gate;
}

export default function retryPolicyTest(): void {
  describe('RetryPolicy', () => {
    beforeEach(() => {
    });

    // ---------- 纯策略 ----------

    it('classifiesRetryableAndNonRetryableErrors', 0, () => {
      // 5xx / 超时错误码 / 网络错误 → 可重试
      expect(classifyRetry(new HttpError(500, 'srv', 'http')).retryable).assertTrue();
      expect(classifyRetry(new HttpError(502, 'badgate', 'http')).retryable).assertTrue();
      expect(classifyRetry(new HttpError(503, 'busy', 'http')).retryable).assertTrue();
      expect(classifyRetry(new HttpError(504, 'timeout-up', 'http')).retryable).assertTrue();
      // 408/429 单独评估为可重试
      expect(classifyRetry(new HttpError(408, 'req-timeout', 'http')).retryable).assertTrue();
      expect(classifyRetry(new HttpError(429, 'too-many', 'http')).retryable).assertTrue();
      // 4xx 常规不可重试
      expect(classifyRetry(new HttpError(400, 'bad', 'http')).retryable).assertFalse();
      expect(classifyRetry(new HttpError(401, 'unauth', 'http')).retryable).assertFalse();
      expect(classifyRetry(new HttpError(403, 'forbid', 'http')).retryable).assertFalse();
      expect(classifyRetry(new HttpError(404, 'nf', 'http')).retryable).assertFalse();
      // 业务错误（-2/-3）不可重试
      expect(classifyRetry(new HttpError(-2, 'auth', '')).retryable).assertFalse();
      expect(classifyRetry(new HttpError(-3, 'proto', '')).retryable).assertFalse();
      // 取消不可重试
      expect(classifyRetry(new HttpError(1007900992, 'cancelled', 'cancel')).retryable).assertFalse();
      // 解析失败不可重试（数据已坏，重试同样结果）
      expect(classifyRetry(new HttpError(-1, 'parse', 'parse')).retryable).assertFalse();
    });

    it('computesExponentialBackoffWithJitter', 0, () => {
      // base=500ms ×2^(attempt-1) + [0,100)
      const first: number = nextRetryDelayMs(1);
      const second: number = nextRetryDelayMs(2);
      const third: number = nextRetryDelayMs(3);
      expect(first >= RETRY_BASE_DELAY_MS).assertTrue();
      expect(first < RETRY_BASE_DELAY_MS + 100).assertTrue();
      expect(second >= 2 * RETRY_BASE_DELAY_MS).assertTrue();
      expect(second < 2 * RETRY_BASE_DELAY_MS + 100).assertTrue();
      expect(third >= 4 * RETRY_BASE_DELAY_MS).assertTrue();
      expect(third < 4 * RETRY_BASE_DELAY_MS + 100).assertTrue();
    });

    it('onlyGetIsRetryable', 0, () => {
      expect(isRetryableMethod('GET')).assertTrue();
      expect(isRetryableMethod('POST')).assertFalse();
      expect(isRetryableMethod('PUT')).assertFalse();
      expect(isRetryableMethod('DELETE')).assertFalse();
    });

    // ---------- RequestGate 集成 ----------

    it('retriesTimeoutUpToMaxAttemptsThenThrows', 0, async () => {
      const gate: RequestGate = freshGate();
      const transport: ScriptedTransport =
        new ScriptedTransport([
          new HttpError(0, 'network timeout', 'network'),
          new HttpError(0, 'network timeout', 'network'),
          new HttpError(0, 'network timeout', 'network')
        ]);
      let thrown: Error | null = null;
      try {
        await gate.run<string>('GET', 'k1', transport);
      } catch (e) {
        thrown = e as Error;
      }
      expect(thrown !== null).assertTrue();
      expect(transport.attempts).assertEqual(RETRY_MAX_ATTEMPTS);
      expect(transport.attempts).assertEqual(3);
    });

    it('retriesThenSucceedsOnThirdAttempt', 0, async () => {
      const gate: RequestGate = freshGate();
      const transport: ScriptedTransport =
        new ScriptedTransport([
          new HttpError(503, 'busy', 'http'),
          new HttpError(503, 'busy', 'http'),
          'ok'
        ]);
      const value: string = await gate.run<string>('GET', 'k2', transport);
      expect(value).assertEqual('ok');
      expect(transport.attempts).assertEqual(3);
    });

    it('doesNotRetry4xx', 0, async () => {
      const gate: RequestGate = freshGate();
      const transport: ScriptedTransport =
        new ScriptedTransport([new HttpError(404, 'not found', 'http')]);
      let thrown: Error | null = null;
      try {
        await gate.run<string>('GET', 'k3', transport);
      } catch (e) {
        thrown = e as Error;
      }
      expect(thrown !== null).assertTrue();
      expect((thrown as HttpError).statusCode).assertEqual(404);
      expect(transport.attempts).assertEqual(1);
    });

    it('postNeverAutoRetriesAndFailsFastOffline', 0, async () => {
      const gate: RequestGate = freshGate();
      // 在线：POST 单发，网络失败不重试
      const online: ScriptedTransport = new ScriptedTransport([new HttpError(502, 'bad', 'http')]);
      let thrown: Error | null = null;
      try {
        await gate.run<string>('POST', 'k4', online);
      } catch (e) {
        thrown = e as Error;
      }
      expect(thrown !== null).assertTrue();
      expect(online.attempts).assertEqual(1);
      // 断网：POST 立即拒绝，绝不发送
      gate.setOffline();
      const offline: ScriptedTransport = new ScriptedTransport([new HttpError(500, 'x', 'http')]);
      let rejected: Error | null = null;
      try {
        await gate.run<string>('POST', 'k5', offline);
      } catch (e) {
        rejected = e as Error;
      }
      expect(rejected !== null).assertTrue();
      expect(offline.attempts).assertEqual(0);
    });

    it('suspendsWhileOfflineAndReplaysOnRecovery', 0, async () => {
      const gate: RequestGate = freshGate();
      gate.setOffline();
      const transport: ScriptedTransport = new ScriptedTransport(['recovered']);
      const promise: Promise<string> = gate.run<string>('GET', 'k6', transport);
      // 挂起：尚未执行
      await delay(30);
      expect(transport.attempts).assertEqual(0);
      // 恢复 → 重放
      gate.setOnline();
      const value: string = await promise;
      expect(value).assertEqual('recovered');
      expect(transport.attempts).assertEqual(1);
    });

    it('replayHasBoundedLimitWhileRepeatedlyOffline', 0, async () => {
      const gate: RequestGate = freshGate();
      // 每次重放都立即失败（网络错误，无延迟）：网络振荡时请求反复挂起→唤醒
      const transport: ScriptedTransport =
        new ScriptedTransport([new HttpError(0, 'offline-ish', 'network')]);
      gate.setOffline();
      const promise: Promise<string> = gate.run<string>('GET', 'k7', transport);
      let rejected: Error | null = null;
      // 振荡：setOnline 同步唤醒等待者；随后立即 setOffline，
      // 确保 transport 失败发生在其后（mode=offline → continue → 再次挂起，不触发退避）
      for (let i = 0; i < MAX_REPLAY + 2; i++) {
        gate.setOnline();
        gate.setOffline();
        await delay(3);
      }
      try {
        await promise;
      } catch (e) {
        rejected = e as Error;
      }
      expect(rejected !== null).assertTrue();
      expect((rejected as GateRejectedError).code).assertEqual('offline-replay-limit');
      // 重放上限：第 MAX_REPLAY+1 次唤醒直接拒绝，不再执行传输
      expect(transport.attempts).assertEqual(MAX_REPLAY);
    });

    it('cancelPropagatesAndNeverRetries', 0, async () => {
      const gate: RequestGate = freshGate();
      const token: CancelToken = new CancelToken();
      const transport: ScriptedTransport = new ScriptedTransport(['ok']);
      transport.delayMs = 60;
      const promise: Promise<string> = gate.run<string>('GET', 'k8', transport, token);
      await delay(10);
      token.cancel();
      let thrown: Error | null = null;
      try {
        await promise;
      } catch (e) {
        thrown = e as Error;
      }
      expect(thrown !== null).assertTrue();
      expect(thrown instanceof RequestCanceledError).assertTrue();
      // 取消后不重试：最多 1 次尝试
      expect(transport.attempts).assertEqual(1);
    });

    it('waitsForVisibilityWhenInvisibleNoPreemption', 0, async () => {
      const gate: RequestGate = freshGate();
      gate.setAppVisible(false);
      const transport: ScriptedTransport = new ScriptedTransport(['visible-ok']);
      const promise: Promise<string> = gate.run<string>('GET', 'k9', transport);
      await delay(30);
      expect(transport.attempts).assertEqual(0);
      gate.setAppVisible(true);
      const value: string = await promise;
      expect(value).assertEqual('visible-ok');
      expect(transport.attempts).assertEqual(1);
    });

    // ---------- 回归（L2 / L3b 修订） ----------

    it('replayBudgetResetsAfterStableOnlineSecondCycleWorks', 0, async () => {
      // 旧实现（L2）：replayCount 按进程生命周期累计，网络振荡烧掉 6 次预算后
      // 永不复位（拒绝路径不重置），进程内第二次真实断网周期首请求即被拒。
      // 修复：稳定在线超过复位窗口后预算清零 → 第二轮断网周期重放正常。
      const gate: RequestGate = freshGate();
      gate.replayResetWindowMs = 50;
      // 第一轮：振荡场景（重放即失败、立即再次断网）烧掉重放预算直至拒绝
      const t1: ScriptedTransport =
        new ScriptedTransport([new HttpError(0, 'offline-ish', 'network')]);
      gate.setOffline();
      const p1: Promise<string> = gate.run<string>('GET', 'c1', t1);
      let rejected: Error | null = null;
      for (let i = 0; i < MAX_REPLAY + 2; i++) {
        gate.setOnline();
        gate.setOffline();
        await delay(3);
      }
      try {
        await p1;
      } catch (e) {
        rejected = e as Error;
      }
      expect((rejected as GateRejectedError).code).assertEqual('offline-replay-limit');
      // 稳定在线超过复位窗口 → 预算清零
      await delay(80);
      gate.setOnline();
      await delay(80);
      // 第二轮断网周期：若预算未清零，首请求即被拒（旧代码在此失败）
      gate.setOffline();
      const t2: ScriptedTransport = new ScriptedTransport(['ok-2']);
      const p2: Promise<string> = gate.run<string>('GET', 'c2', t2);
      await delay(20);
      gate.setOnline();
      const v2: string = await p2;
      expect(v2).assertEqual('ok-2');
      expect(t2.attempts).assertEqual(1);
    });

    it('doesNotReplayWhileBackgroundedWaitsUntilForeground', 0, async () => {
      // L3b：恢复网络不无条件放行 —— 后台期间挂起队列保持等待，回前台才重放
      const gate: RequestGate = freshGate();
      gate.replayResetWindowMs = REPLAY_RESET_ONLINE_MS;
      gate.setAppVisible(false);
      gate.setOffline();
      const transport: ScriptedTransport = new ScriptedTransport(['bg-ok']);
      const promise: Promise<string> = gate.run<string>('GET', 'c3', transport);
      await delay(30);
      expect(transport.attempts).assertEqual(0);
      // 后台恢复网络：不得重放
      gate.setOnline();
      await delay(30);
      expect(transport.attempts).assertEqual(0);
      // 回到前台：立即重放
      gate.setAppVisible(true);
      const value: string = await promise;
      expect(value).assertEqual('bg-ok');
      expect(transport.attempts).assertEqual(1);
    });
  });
}
