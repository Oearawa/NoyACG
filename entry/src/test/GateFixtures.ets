/**
 * GateFixtures.ets —— I-000004 RequestGate/NetworkMonitor 测试夹具
 *
 * 内存 transport 与 FakeBridge：不触网、不依赖系统能力，
 * 只验证挂起/恢复/重放/重试/取消的策略行为。
 */
import { CancelToken, RequestCanceledError } from '../main/ets/api/CancelToken';
import {
  GateRejectedError,
  RequestGate,
  RequestSlot,
  Transport
} from '../main/ets/api/RequestGate';
import { NetworkMonitor, ConnectionBridge, BridgeEvents } from '../main/ets/api/NetworkMonitor';
import { HttpError } from '../main/ets/api/HttpManager';

/** 可编程 GET transport：按调用次数驱动结果序列 */
export class ScriptedTransport implements Transport<string> {
  /** 每次调用的执行计划；超过计划长度则报错 */
  results: (string | Error)[] = [];
  attempts: number = 0;
  canceled: boolean = false;
  delayMs: number = 0;

  constructor(results: (string | Error)[]) {
    this.results = results;
  }

  async execute(slot: RequestSlot<string>): Promise<void> {
    this.attempts++;
    if (this.delayMs > 0) {
      await GateFixtures.delay(this.delayMs);
    }
    const idx: number = this.attempts - 1;
    if (this.canceled) {
      throw new GateRejectedError('canceled', 'transport canceled');
    }
    // 超量时重复最后一个结果（模拟服务端持续 5xx / 持续超时）
    const effective: number = idx >= this.results.length ? this.results.length - 1 : idx;
    const item: string | Error = this.results[effective];
    if (item instanceof Error) {
      throw item;
    }
    slot.done = true;
    slot.value = item;
  }
}

/** Fake ConnectionBridge：事件由测试手动触发，不注册系统监听 */
export class FakeBridge implements ConnectionBridge {
  online: boolean = true;
  started: boolean = false;
  stopped: boolean = false;
  events?: BridgeEvents = undefined;
  queryResults: boolean[] = [];

  start(events: BridgeEvents): void {
    this.started = true;
    this.events = events;
  }

  stop(): void {
    this.stopped = true;
    this.started = false;
  }

  queryOnline(callback: (online: boolean) => void): void {
    if (this.queryResults.length > 0) {
      callback(this.queryResults.shift() ?? true);
    } else {
      callback(this.online);
    }
  }

  /** 模拟系统 netAvailable 事件 */
  emitAvailable(): void {
    if (this.events !== undefined) {
      this.events.onAvailable();
    }
  }

  /** 模拟系统 netLost 事件 */
  emitLost(): void {
    if (this.events !== undefined) {
      this.events.onLost();
    }
  }
}

/** 通用延时 */
export function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout((): void => {
      resolve();
    }, ms);
  });
}

/** 分组工具 */
export class GateFixtures {
  static delay(ms: number): Promise<void> {
    return delay(ms);
  }
}
