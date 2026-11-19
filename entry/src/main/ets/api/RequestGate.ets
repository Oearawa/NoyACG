/**
 * RequestGate.ets —— 请求闸门：断网挂起 + 恢复重放 + 有界重试（I-000004）
 *
 * 架构契约（architect 已裁定）：
 * - 重试 maxAttempts=3 / base=500ms / ×2 + jitter；仅幂等 GET 可重试；
 *   POST 写操作一律不自动重试（防重复提交）；
 * - 可重试：超时 / 5xx / 网络不可达；不可重试：4xx（408/429 单独评估）、
 *   业务错误、取消；
 * - 断网 → 挂起队列（等待恢复）；恢复 → 前台重放（有上限 MAX_REPLAY）；
 * - 重放预算按「单次断网周期」累计：稳定在线超过 REPLAY_RESET_ONLINE_MS 后
 *   重新计数（网络振荡仍受上限约束）；
 * - 后台不重放：应用不可见时恢复网络保持挂起，回前台再放行；
 * - 页面不可见时不抢跑（新请求等待可见再放行）；
 * - 取消传播：退避等待 / 断网等待阶段取消立即中断，绝不重试。
 *
 * 依赖方向：RequestGate 不 import NetworkMonitor（无循环）。NetworkMonitor
 * 在单例构造时调用 RequestGate.getInstance().attach(this) 注册事件。
 * 测试可 new RequestGate() 并且不 attach，直接 setOnline/setOffline 驱动。
 */
import { Logger } from '../utils/Logger';
import { CancelToken, RequestCanceledError } from './CancelToken';
import {
  classifyRetry,
  isRetryableMethod,
  nextRetryDelayMs,
  resolveRetryDelayMs,
  RETRY_MAX_ATTEMPTS,
  RetryDecision
} from './RetryPolicy';

const TAG: string = 'RequestGate';

/** 断网恢复后前台重放上限：一次断网周期内最多放行 MAX_REPLAY 次等待请求 */
export const MAX_REPLAY: number = 6;
/**
 * 重放预算复位窗口：保持在线超过该时长后，视为进入新的断网周期，
 * 重放计数清零（否则预算按进程生命周期累积，第二次真实断网即失效）。
 * 振荡（offline↔online 快速翻转）间隔远小于窗口，不影响重放上限约束。
 */
export const REPLAY_RESET_ONLINE_MS: number = 30 * 1000;
/** 放弃等待（断网 or 不可见）的最长期限：等待 10 分钟后主动失败，避免永久驻留 */
export const WAIT_CEILING_MS: number = 10 * 60 * 1000;
/** 退避/等待采用分片轮询的最小步长（可感知取消） */
export const SLEEP_STEP_MS: number = 100;

export const GATE_MODE_ONLINE: string = 'online';
export const GATE_MODE_OFFLINE: string = 'offline';

/** 网络状态消费方端口（NetworkMonitor 实现并注入） */
export interface NetworkStateSource {
  isOnline(): boolean;
  addListener(listener: NetworkStateListener): void;
  removeListener(listener: NetworkStateListener): void;
}

/** 网络状态订阅端口（RequestGate 实现，交给 NetworkStateSource） */
export interface NetworkStateListener {
  onNetworkLost(): void;
  onNetworkAvailable(): void;
}

/** 一次请求的传输槽：transport 只负责读写槽位，不感知重试/挂起策略 */
export class RequestSlot<R> {
  readonly key: string;
  readonly method: string;
  attempt: number = 0;
  done: boolean = false;
  value: R | undefined = undefined;
  errorObj: Object | undefined = undefined;

  constructor(key: string, method: string) {
    this.key = key;
    this.method = method;
  }
}

/** transport 端口：HttpManager 提供真实 rcp 执行，测试提供内存桩 */
export interface Transport<R> {
  execute(slot: RequestSlot<R>): Promise<void>;
}

/** 闸门拒绝（断网 / 重放上限 / 等待超时）—— 与网络失败语义分离 */
export class GateRejectedError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = 'GateRejectedError';
    this.code = code;
  }
}

/**
 * 请求闸门（单例）。策略状态机：
 * online + visible → 直接执行（带重试）；
 * offline（幂等 GET）→ 挂起等待恢复，恢复后重放（上限 MAX_REPLAY）；
 * offline（POST 等写操作）→ 立即拒绝，绝不发送；
 * 不可见 → 新请求等待可见（不抢跑）。
 */
export class RequestGate implements NetworkStateListener {
  private static instance?: RequestGate;

  private mode: string = GATE_MODE_ONLINE;
  private appVisible: boolean = true;
  private onlineWaiters: (() => void)[] = [];
  private visibleWaiters: (() => void)[] = [];
  /** 本轮断网周期内恢复重放的次数（单次断网周期内累计；稳定在线后清零） */
  private replayCount: number = 0;
  /** 上次进入在线状态的时刻（用于判定是否已稳定在线，非振荡） */
  private lastOnlineAt: number = 0;
  /** 重放预算复位窗口（测试可收紧以加速验证；生产保持默认 30s） */
  public replayResetWindowMs: number = REPLAY_RESET_ONLINE_MS;

  /** 测试可直接 new（策略状态机与单例解耦；生产统一 getInstance） */
  constructor() {
  }

  static getInstance(): RequestGate {
    if (RequestGate.instance === undefined) {
      RequestGate.instance = new RequestGate();
    }
    return RequestGate.instance;
  }

  /** 由 NetworkMonitor 调用（断网 → 挂起） */
  onNetworkLost(): void {
    this.setOffline();
  }

  /** 由 NetworkMonitor 调用（恢复 → 放行） */
  onNetworkAvailable(): void {
    this.setOnline();
  }

  /** 注入网络状态源：注册自身为监听者；幂等 */
  attach(source: NetworkStateSource | null): void {
    if (source === null) {
      return;
    }
    source.addListener(this);
  }

  detach(source: NetworkStateSource | null): void {
    if (source === null) {
      return;
    }
    source.removeListener(this);
  }

  // ==================== 状态入口（测试与 monitor 共用） ====================

  setOnline(): void {
    const now: number = Date.now();
    const changed: boolean = this.mode !== GATE_MODE_ONLINE;
    this.mode = GATE_MODE_ONLINE;
    if (changed) {
      // 距上次进入在线状态已超过稳定窗口 → 新一轮断网周期，重放预算清零；
      // 振荡（快速翻转）间隔 < 窗口，不清零，重放上限约束保持不变
      if (this.lastOnlineAt > 0 && now - this.lastOnlineAt >= this.replayResetWindowMs) {
        this.replayCount = 0;
        Logger.info(TAG, '稳定在线超过复位窗口：重放预算清零（新断网周期）');
      }
      this.lastOnlineAt = now;
      if (this.appVisible) {
        this.flushWaiters(this.onlineWaiters, '在线恢复');
      } else {
        // 后台不重放：队列保持挂起，回前台再由 setAppVisible 放行（L3b）
        Logger.info(TAG, '网络已恢复但应用在后台：挂起队列保持等待（回前台再重放）');
      }
    } else if (this.lastOnlineAt > 0 && now - this.lastOnlineAt >= this.replayResetWindowMs) {
      // 长时间稳定在线（重复 setOnline 防御性调用）：同样允许预算清零
      this.replayCount = 0;
      this.lastOnlineAt = now;
    }
  }

  setOffline(): void {
    const changed: boolean = this.mode !== GATE_MODE_OFFLINE;
    this.mode = GATE_MODE_OFFLINE;
    if (changed) {
      // 注意：不重置 replayCount —— 预算在「稳定在线超过复位窗口」时清零（setOnline），
      // 网络振荡（offline↔online 快速翻转）时依然有界
      Logger.warn(TAG, '网络不可用：幂等 GET 挂起，写操作拒绝发送');
    }
  }

  /** 应用前后台（EntryAbility 驱动；页面不可见不抢跑） */
  setAppVisible(visible: boolean): void {
    const changed: boolean = this.appVisible !== visible;
    this.appVisible = visible;
    if (changed && visible) {
      this.flushWaiters(this.visibleWaiters, '应用回到前台');
      if (this.mode === GATE_MODE_ONLINE) {
        // 后台期间网络已恢复：此前保持挂起的断网请求此刻放行（L3b）
        this.flushWaiters(this.onlineWaiters, '前台恢复后重放');
      }
    }
  }

  isOnline(): boolean {
    return this.mode === GATE_MODE_ONLINE;
  }

  isAppVisible(): boolean {
    return this.appVisible;
  }

  /** 测试辅助：当前统计值 */
  stats(): string {
    return `mode=${this.mode} visible=${this.appVisible} replay=${this.replayCount} onlineWait=${this.onlineWaiters.length} visibleWait=${this.visibleWaiters.length}`;
  }

  // ==================== 主入口 ====================

  /**
   * 执行一次请求（可重试语义由 method 决定）。
   * - 非幂等方法（POST 等）：断网立即拒绝；网络层错误不重试（防重复提交）。
   * - 幂等 GET：断网挂起 → 恢复重放（上限 MAX_REPLAY）→ 有界退避重试。
   * @param key 请求去重键（日志；重试循环内同 key 只会有一个在途请求）
   * @param token 可选取消令牌（等待/退避阶段立即中断）
   */
  async run<R>(method: string, key: string, transport: Transport<R>,
    token?: CancelToken): Promise<R> {
    if (!isRetryableMethod(method)) {
      return await this.runOnce<R>(method, key, transport, token);
    }
    const slot: RequestSlot<R> = new RequestSlot<R>(key, method);
    await this.requireVisible(token);
    let attempt: number = 1;
    let lastError: Object | undefined = undefined;
    for (;;) {
      this.throwIfCanceled(token);
      if (this.mode !== GATE_MODE_ONLINE) {
        await this.waitOnline(token);
        this.replayCount++;
        if (this.replayCount > MAX_REPLAY) {
          throw new GateRejectedError('offline-replay-limit',
            `断网恢复重放超过上限 ${MAX_REPLAY} 次，已放弃`);
        }
      }
      if (attempt > RETRY_MAX_ATTEMPTS) {
        if (lastError === undefined) {
          throw new GateRejectedError('attempt-exhausted', '重试次数用尽');
        }
        throw RequestGate.toError(lastError);
      }
      slot.attempt = attempt;
      slot.done = false;
      slot.errorObj = undefined;
      try {
        await transport.execute(slot);
      } catch (e) {
        slot.done = false;
        slot.errorObj = e as Object;
      }
      this.throwIfCanceled(token);
      if (slot.done) {
        this.replayCount = 0;
        return slot.value as R;
      }
      const decision: RetryDecision = classifyRetry(slot.errorObj);
      if (!decision.retryable) {
        throw RequestGate.toError(slot.errorObj);
      }
      lastError = slot.errorObj;
      // 断网等待期间失败：不消耗重试次数，下一步回到 waitOnline 挂起
      if (this.mode !== GATE_MODE_ONLINE) {
        continue;
      }
      if (attempt < RETRY_MAX_ATTEMPTS) {
        const delayMs: number = resolveRetryDelayMs(slot.errorObj, nextRetryDelayMs(attempt));
        await RequestGate.cancellableDelay(delayMs, token);
      }
      attempt++;
    }
  }

  /** 非幂等（写）单发路径：不重试；断网立即拒绝（防重复提交） */
  private async runOnce<R>(method: string, key: string, transport: Transport<R>,
    token?: CancelToken): Promise<R> {
    this.throwIfCanceled(token);
    await this.requireVisible(token);
    if (this.mode !== GATE_MODE_ONLINE) {
      throw new GateRejectedError('offline',
        `网络不可用，${method} 写操作已拒绝发送（防重复提交）`);
    }
    const slot: RequestSlot<R> = new RequestSlot<R>(key, method);
    slot.attempt = 1;
    try {
      await transport.execute(slot);
    } catch (e) {
      slot.done = false;
      slot.errorObj = e as Object;
    }
    this.throwIfCanceled(token);
    if (slot.done) {
      return slot.value as R;
    }
    throw RequestGate.toError(slot.errorObj);
  }

  // ==================== 等待原语 ====================

  private requireVisible(token: CancelToken | undefined): Promise<void> {
    if (this.appVisible) {
      return Promise.resolve();
    }
    Logger.info(TAG, '应用不可见：请求等待前台（不抢跑）');
    return this.waitFor(this.visibleWaiters, token, '可见性');
  }

  private waitOnline(token: CancelToken | undefined): Promise<void> {
    return this.waitFor(this.onlineWaiters, token, '网络恢复');
  }

  private waitFor(waiters: (() => void)[], token: CancelToken | undefined,
    what: string): Promise<void> {
    const gate: RequestGate = this;
    return new Promise<void>((resolve: () => void, reject: (e: Object) => void) => {
      let settled: boolean = false;
      let timer: number = 0;
      const wake = (): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer !== 0) {
          clearTimeout(timer);
        }
        const index: number = waiters.indexOf(wake);
        if (index >= 0) {
          waiters.splice(index, 1);
        }
        resolve();
      };
      const fail = (e: Object): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer !== 0) {
          clearTimeout(timer);
        }
        const index: number = waiters.indexOf(wake);
        if (index >= 0) {
          waiters.splice(index, 1);
        }
        reject(e);
      };
      waiters.push(wake);
      if (token !== undefined && !token.isCanceled()) {
        token.onCancel((): void => {
          fail(new RequestCanceledError(`等待${what}期间请求被取消`));
        });
      }
      // 竞态兜底：等待注册瞬间条件已满足（例如恢复事件与请求并发到达）
      let satisfied: boolean = false;
      if (what === '网络恢复') {
        // 网络等待需同时可见：后台期间即使 mode 已 online 也不放行（L3b）
        satisfied = gate.mode === GATE_MODE_ONLINE && gate.appVisible;
      } else if (what === '可见性') {
        satisfied = gate.appVisible;
      }
      if (satisfied) {
        wake();
        return;
      }
      // 等待上限：超时主动失败（避免永久驻留，比如无网络能力环境）
      timer = setTimeout((): void => {
        fail(new GateRejectedError('wait-timeout',
          `等待${what}超时（${WAIT_CEILING_MS}ms）`));
      }, WAIT_CEILING_MS);
    });
  }

  private flushWaiters(waiters: (() => void)[], reason: string): void {
    if (waiters.length === 0) {
      return;
    }
    const pending: (() => void)[] = waiters.slice();
    waiters.length = 0;
    for (let i = 0; i < pending.length; i++) {
      try {
        pending[i]();
      } catch (e) {
        Logger.warn(TAG, `唤醒等待者失败 (${reason}): ${(e as Error).message}`);
      }
    }
  }

  private throwIfCanceled(token: CancelToken | undefined): void {
    if (token !== undefined && token.isCanceled()) {
      throw new RequestCanceledError('请求已取消，重试循环中止');
    }
  }

  /** 统一转 Error：ArkTS 限制 throw 只能抛 Error 类型值 */
  private static toError(e: Object | undefined): Error {
    if (e instanceof Error) {
      return e;
    }
    return new Error(e === undefined ? '未知请求错误' : String(e));
  }

  /** 可取消延时：分片轮询，取消立即中断；返回后调用方自行 re-check token */
  private static cancellableDelay(ms: number, token: CancelToken | undefined): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (e: Object) => void) => {
      if (token !== undefined && token.isCanceled()) {
        reject(new RequestCanceledError('退避等待期间请求被取消'));
        return;
      }
      const deadline: number = Date.now() + ms;
      let timer: number = 0;
      const step = (): void => {
        if (token !== undefined && token.isCanceled()) {
          if (timer !== 0) {
            clearTimeout(timer);
          }
          reject(new RequestCanceledError('退避等待期间请求被取消'));
          return;
        }
        const remain: number = deadline - Date.now();
        if (remain <= 0) {
          if (timer !== 0) {
            clearTimeout(timer);
          }
          resolve();
          return;
        }
        if (timer !== 0) {
          clearTimeout(timer);
        }
        timer = setTimeout(step, Math.min(SLEEP_STEP_MS, remain));
      };
      step();
    });
  }
}
