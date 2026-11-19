/**
 * NetworkMonitor.ets —— 系统断网检测与在线状态订阅（I-000004）
 *
 * 基于 @ohos.net.connection（@kit.NetworkKit）订阅：
 * - netAvailable / netLost / netUnavailable → 在线状态翻转；
 * - 恢复后通知 RequestGate（前台重放）；断网通知 RequestGate（挂起队列）；
 * - 订阅前先查询默认网络（getDefaultNet）确定初始状态，避免断网时乐观放行。
 *
 * 权限：ohos.permission.GET_NETWORK_INFO（module.json5 requestPermissions，
 * system_grant，无需用户弹窗）。无能力环境（单元测试运行时）start() 内部
 * try/catch 静默降级为「乐观在线」，由 HttpManager 的 rcp 错误重试兜底。
 *
 * 可测性：ConnectionBridge 抽象 + 构造函数注入，测试用 FakeBridge 驱动事件。
 */
import { connection } from '@kit.NetworkKit';
import { Logger } from '../utils/Logger';
import { NetworkStateListener, NetworkStateSource, RequestGate } from './RequestGate';

const TAG: string = 'NetworkMonitor';

/** 桥接端口：系统实现 / 测试桩 */
export interface ConnectionBridge {
  /** 注册系统监听并查询初始在线状态 */
  start(events: BridgeEvents): void;
  /** 注销系统监听 */
  stop(): void;
  /** 尽力查询当前默认网络是否可用（回调只会被调用至多一次；失败回调 false） */
  queryOnline(callback: (online: boolean) => void): void;
}

/** 桥接回调端口（类实现；避免 ArkTS 对象字面量限制） */
export class BridgeEvents {
  onAvailable: () => void = (): void => {
  };
  onLost: () => void = (): void => {
  };
}

/** 系统实现：@ohos.net.connection 订阅 */
class SystemConnectionBridge implements ConnectionBridge {
  private netConn?: connection.NetConnection;
  private events?: BridgeEvents;
  private registered: boolean = false;

  start(events: BridgeEvents): void {
    if (this.registered) {
      return;
    }
    this.events = events;
    try {
      const netConn: connection.NetConnection = connection.createNetConnection();
      this.netConn = netConn;
      netConn.on('netAvailable', (): void => {
        if (this.events !== undefined) {
          this.events.onAvailable();
        }
      });
      netConn.on('netLost', (): void => {
        if (this.events !== undefined) {
          this.events.onLost();
        }
      });
      netConn.on('netUnavailable', (): void => {
        if (this.events !== undefined) {
          this.events.onLost();
        }
      });
      netConn.register((): void => {
      });
      this.registered = true;
      Logger.info(TAG, '系统网络订阅已注册（netAvailable/netLost/netUnavailable）');
    } catch (e) {
      // 无网络能力环境：静默降级为乐观在线（重试层兜底）
      Logger.warn(TAG, `网络订阅注册失败，降级乐观在线: ${(e as Error).message}`);
      this.registered = false;
    }
  }

  stop(): void {
    if (!this.registered || this.netConn === undefined) {
      return;
    }
    try {
      this.netConn.unregister((): void => {
      });
    } catch (e) {
      Logger.warn(TAG, `网络订阅注销失败: ${(e as Error).message}`);
    }
    this.netConn = undefined;
    this.registered = false;
  }

  queryOnline(callback: (online: boolean) => void): void {
    try {
      connection.getDefaultNet().then((net: connection.NetHandle): void => {
        // netId === 0 表示当前无默认网络（连接管理约定）
        callback(net.netId !== 0);
      }).catch((): void => {
        callback(false);
      });
    } catch (e) {
      callback(false);
    }
  }
}

/**
 * 断网检测器（单例）。
 * 构造注入 bridge 便于测试；生产使用 SystemConnectionBridge。
 */
export class NetworkMonitor implements NetworkStateSource {
  private static instance?: NetworkMonitor;

  private bridge: ConnectionBridge;
  private started: boolean = false;
  private online: boolean = true;
  private listeners: NetworkStateListener[] = [];

  constructor(bridge?: ConnectionBridge) {
    this.bridge = bridge === undefined ? new SystemConnectionBridge() : bridge;
  }

  static getInstance(): NetworkMonitor {
    if (NetworkMonitor.instance === undefined) {
      NetworkMonitor.instance = new NetworkMonitor();
      // 接线：系统事件 → RequestGate（单例互注册，无循环依赖）
      NetworkMonitor.instance.attachGate(RequestGate.getInstance());
    }
    return NetworkMonitor.instance;
  }

  /** 订阅系统网络事件（幂等） */
  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    const events: BridgeEvents = new BridgeEvents();
    events.onAvailable = (): void => {
      this.handleAvailable();
    };
    events.onLost = (): void => {
      this.handleLost();
    };
    this.bridge.start(events);
    this.bridge.queryOnline((online: boolean): void => {
      this.applyOnline(online);
    });
  }

  /** 停止订阅（应用退出） */
  stop(): void {
    this.bridge.stop();
    this.started = false;
  }

  isOnline(): boolean {
    return this.online;
  }

  addListener(listener: NetworkStateListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  removeListener(listener: NetworkStateListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  /** 测试辅助：直接注入状态翻转事件（FakeBridge 也走这里） */
  handleAvailable(): void {
    this.applyOnline(true);
  }

  handleLost(): void {
    this.applyOnline(false);
  }

  private applyOnline(online: boolean): void {
    if (this.online === online) {
      return;
    }
    this.online = online;
    if (online) {
      Logger.info(TAG, '网络已恢复');
      this.notifyAvailable();
    } else {
      Logger.warn(TAG, '网络已断开');
      this.notifyLost();
    }
  }

  private notifyLost(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      try {
        this.listeners[i].onNetworkLost();
      } catch (e) {
        Logger.warn(TAG, `断网通知失败: ${(e as Error).message}`);
      }
    }
  }

  private notifyAvailable(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      try {
        this.listeners[i].onNetworkAvailable();
      } catch (e) {
        Logger.warn(TAG, `恢复通知失败: ${(e as Error).message}`);
      }
    }
  }

  /** 测试辅助：当前监听者数量 */
  listenerCount(): number {
    return this.listeners.length;
  }

  private attachGate(gate: RequestGate): void {
    this.addListener(gate);
  }
}
