/**
 * NetworkMonitor.test.ets —— I-000004 断网订阅与闸门联动测试
 *
 * FakeBridge 不注册系统监听，事件由测试手动触发；
 * 验证：断网 → gate 挂起；恢复 → gate 放行；初始状态查询；
 * 幂等 start；listener 注册/移除。
 */
import { describe, it, expect } from '@ohos/hypium';
import { NetworkMonitor, ConnectionBridge } from '../main/ets/api/NetworkMonitor';
import { NetworkStateListener, RequestGate, RequestSlot, Transport } from '../main/ets/api/RequestGate';
import { FakeBridge, delay, ScriptedTransport } from './GateFixtures';

class RecordingListener implements NetworkStateListener {
  readonly seen: string[] = [];

  onNetworkLost(): void {
    this.seen.push('lost');
  }

  onNetworkAvailable(): void {
    this.seen.push('avail');
  }
}

class RecordingTransport implements Transport<string> {
  calls: number = 0;

  async execute(slot: RequestSlot<string>): Promise<void> {
    this.calls++;
    slot.done = true;
    slot.value = 'x';
  }
}

export default function networkMonitorTest(): void {
  describe('NetworkMonitor', () => {
    it('startsSubscribesAndPropagatesLossToGate', 0, async () => {
      const bridge: FakeBridge = new FakeBridge();
      bridge.online = true;
      const monitor: NetworkMonitor = new NetworkMonitor(bridge);
      const gate: RequestGate = new RequestGate();
      gate.setOnline();
      gate.setAppVisible(true);
      monitor.addListener(gate);
      monitor.start();
      // 初始在线
      expect(monitor.isOnline()).assertTrue();
      expect(gate.isOnline()).assertTrue();
      // 断网事件 → gate 挂起
      bridge.emitLost();
      expect(monitor.isOnline()).assertFalse();
      expect(gate.isOnline()).assertFalse();
      // 恢复事件 → gate 放行
      bridge.emitAvailable();
      expect(monitor.isOnline()).assertTrue();
      expect(gate.isOnline()).assertTrue();
      monitor.removeListener(gate);
      monitor.stop();
    });

    it('startIsIdempotentAndStopUnregisters', 0, () => {
      const bridge: FakeBridge = new FakeBridge();
      const monitor: NetworkMonitor = new NetworkMonitor(bridge);
      monitor.start();
      monitor.start();
      expect(bridge.started).assertTrue();
      monitor.stop();
      expect(bridge.stopped).assertTrue();
    });

    it('listenersReceiveOrderedEvents', 0, () => {
      const bridge: FakeBridge = new FakeBridge();
      const monitor: NetworkMonitor = new NetworkMonitor(bridge);
      const listener: RecordingListener = new RecordingListener();
      monitor.addListener(listener);
      monitor.addListener(listener);
      monitor.start();
      bridge.emitLost();
      bridge.emitAvailable();
      expect(listener.seen.length).assertEqual(2);
      expect(listener.seen[0]).assertEqual('lost');
      expect(listener.seen[1]).assertEqual('avail');
      monitor.removeListener(listener);
      monitor.stop();
    });

    it('queryOnlineInitialStateDrivesGate', 0, async () => {
      const bridge: FakeBridge = new FakeBridge();
      bridge.queryResults = [false];
      const monitor: NetworkMonitor = new NetworkMonitor(bridge);
      const gate: RequestGate = new RequestGate();
      gate.setOnline();
      gate.setAppVisible(true);
      monitor.addListener(gate);
      monitor.start();
      await delay(20);
      // 初始查询 offline → gate 立即挂起
      expect(monitor.isOnline()).assertFalse();
      expect(gate.isOnline()).assertFalse();
      monitor.removeListener(gate);
      monitor.stop();
    });

    it('offlinePostIsRejectedEndToEnd', 0, async () => {
      const bridge: FakeBridge = new FakeBridge();
      bridge.online = true;
      const monitor: NetworkMonitor = new NetworkMonitor(bridge);
      const gate: RequestGate = new RequestGate();
      gate.setOnline();
      gate.setAppVisible(true);
      monitor.addListener(gate);
      monitor.start();
      bridge.emitLost();
      const transport: ScriptedTransport = new ScriptedTransport([]);
      let rejected: Error | null = null;
      try {
        await gate.run<string>('POST', 'p1', transport);
      } catch (e) {
        rejected = e as Error;
      }
      expect(rejected !== null).assertTrue();
      expect(transport.attempts).assertEqual(0);
      monitor.removeListener(gate);
      monitor.stop();
    });
  });
}
