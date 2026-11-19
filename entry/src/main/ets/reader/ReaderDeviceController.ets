/**
 * ReaderDeviceController.ets —— 阅读器设备控制（方向锁定 / 独立亮度 / 音量键翻页 + 严格生命周期还原）
 *
 * 生命周期硬性保障：
 * - 退出阅读器（exitReader）必须强制恢复系统默认方向（OrientationLockMode.SYSTEM -> UNSPECIFIED）
 *   与系统默认亮度（-1），并停止音量键拦截；
 * - 退入后台（onBackground）必须恢复系统默认亮度（-1）并停止音量键拦截。
 * - 原生 Window 调用封装在 ReaderDeviceAdapter 内并做 try-catch 保护，单元测试可注入桩适配器。
 */
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { inputConsumer, KeyEvent as InputKeyEvent } from '@kit.InputKit';
import { OrientationLockMode } from '../utils/PreferenceManager';
import { Logger } from '../utils/Logger';

const TAG: string = 'ReaderDeviceController';

export const MIN_READER_BRIGHTNESS: number = 0.05;
export const MAX_READER_BRIGHTNESS: number = 1.0;
export const SYSTEM_BRIGHTNESS: number = -1;
export const KEYCODE_VOLUME_UP: number = 16;
export const KEYCODE_VOLUME_DOWN: number = 17;
export const VOLUME_KEY_DEBOUNCE_MS: number = 180;

export enum VolumeKeyAction {
  NONE = 'none',
  PREV_PAGE = 'prev_page',
  NEXT_PAGE = 'next_page'
}

export interface ReaderDeviceAdapter {
  setPreferredOrientation(mode: OrientationLockMode): Promise<void>;
  setBrightness(brightness: number): Promise<void>;
  subscribeVolumeKeys?(onKeyDown: (keyCode: number) => void): void;
  unsubscribeVolumeKeys?(): void;
}

/** 钳制阅读器自定义亮度至 [0.05, 1.0] */
export function clampReaderBrightness(value: number): number {
  if (!Number.isFinite(value)) {
    return 0.6;
  }
  return Math.max(MIN_READER_BRIGHTNESS, Math.min(value, MAX_READER_BRIGHTNESS));
}

/** 音量键翻页拦截判定：仅当开关开启且阅读器处于前台时才映射上一页/下一页 */
export function resolveVolumeKeyAction(
  keyCode: number,
  enabled: boolean,
  isForeground: boolean
): VolumeKeyAction {
  if (!enabled || !isForeground) {
    return VolumeKeyAction.NONE;
  }
  if (keyCode === KEYCODE_VOLUME_UP) {
    return VolumeKeyAction.PREV_PAGE;
  }
  if (keyCode === KEYCODE_VOLUME_DOWN) {
    return VolumeKeyAction.NEXT_PAGE;
  }
  return VolumeKeyAction.NONE;
}

function mapOrientation(mode: OrientationLockMode): window.Orientation {
  if (mode === OrientationLockMode.PORTRAIT) {
    return window.Orientation.PORTRAIT;
  }
  if (mode === OrientationLockMode.LANDSCAPE) {
    return window.Orientation.LANDSCAPE;
  }
  return window.Orientation.UNSPECIFIED;
}

export class ArkUIWindowDeviceAdapter implements ReaderDeviceAdapter {
  private readonly contextProvider: () => common.Context | undefined;
  private volumeUpCallback?: (event: InputKeyEvent) => void;
  private volumeDownCallback?: (event: InputKeyEvent) => void;

  constructor(contextProvider: () => common.Context | undefined) {
    this.contextProvider = contextProvider;
  }

  subscribeVolumeKeys(onKeyDown: (keyCode: number) => void): void {
    this.unsubscribeVolumeKeys();
    const upCb = (_event: InputKeyEvent): void => {
      onKeyDown(KEYCODE_VOLUME_UP);
    };
    const downCb = (_event: InputKeyEvent): void => {
      onKeyDown(KEYCODE_VOLUME_DOWN);
    };
    try {
      const upOpts: inputConsumer.KeyPressedConfig = {
        key: KEYCODE_VOLUME_UP,
        action: 1,
        isRepeat: false
      };
      const downOpts: inputConsumer.KeyPressedConfig = {
        key: KEYCODE_VOLUME_DOWN,
        action: 1,
        isRepeat: false
      };
      inputConsumer.on('keyPressed', upOpts, upCb);
      inputConsumer.on('keyPressed', downOpts, downCb);
      this.volumeUpCallback = upCb;
      this.volumeDownCallback = downCb;
    } catch (e) {
      const err = e as BusinessError;
      Logger.warn(TAG, `订阅物理音量键失败: ${err.code} - ${err.message}`);
    }
  }

  unsubscribeVolumeKeys(): void {
    try {
      if (this.volumeUpCallback !== undefined) {
        inputConsumer.off('keyPressed', this.volumeUpCallback);
        this.volumeUpCallback = undefined;
      }
      if (this.volumeDownCallback !== undefined) {
        inputConsumer.off('keyPressed', this.volumeDownCallback);
        this.volumeDownCallback = undefined;
      }
    } catch (e) {
      const err = e as BusinessError;
      Logger.warn(TAG, `取消订阅物理音量键失败: ${err.code} - ${err.message}`);
    }
  }

  async setPreferredOrientation(mode: OrientationLockMode): Promise<void> {
    try {
      const ctx: common.Context | undefined = this.contextProvider();
      if (ctx === undefined) {
        return;
      }
      const win: window.Window = await window.getLastWindow(ctx);
      await win.setPreferredOrientation(mapOrientation(mode));
    } catch (e) {
      const err = e as BusinessError;
      Logger.warn(TAG, `设置屏幕方向失败: ${err.code} - ${err.message}`);
    }
  }

  async setBrightness(brightness: number): Promise<void> {
    try {
      const ctx: common.Context | undefined = this.contextProvider();
      if (ctx === undefined) {
        return;
      }
      const win: window.Window = await window.getLastWindow(ctx);
      await win.setWindowBrightness(brightness);
    } catch (e) {
      const err = e as BusinessError;
      Logger.warn(TAG, `设置窗口亮度失败: ${err.code} - ${err.message}`);
    }
  }
}

@ObservedV2
export class ReaderDeviceController {
  @Trace orientationLock: OrientationLockMode = OrientationLockMode.SYSTEM;
  @Trace followSystemBrightness: boolean = true;
  @Trace customBrightness: number = 0.6;
  @Trace volumeKeyPageTurn: boolean = false;
  @Trace isForeground: boolean = false;

  private readonly adapter: ReaderDeviceAdapter;
  private lastVolumeKeyCode: number = 0;
  private lastVolumeKeyTs: number = 0;
  private keyTriggerListener?: (action: VolumeKeyAction) => void;

  constructor(adapter: ReaderDeviceAdapter) {
    this.adapter = adapter;
  }

  setVolumeKeyTriggerListener(listener?: (action: VolumeKeyAction) => void): void {
    this.keyTriggerListener = listener;
  }

  private syncVolumeKeySubscription(): void {
    if (this.isForeground && this.volumeKeyPageTurn) {
      if (this.adapter.subscribeVolumeKeys !== undefined) {
        this.adapter.subscribeVolumeKeys((keyCode: number): void => {
          const action: VolumeKeyAction = this.handleKeyCode(keyCode);
          if (action !== VolumeKeyAction.NONE && this.keyTriggerListener !== undefined) {
            this.keyTriggerListener(action);
          }
        });
      }
    } else if (this.adapter.unsubscribeVolumeKeys !== undefined) {
      this.adapter.unsubscribeVolumeKeys();
    }
  }

  /** 进入阅读器前台并应用持久化的方向与亮度设置 */
  async enterReader(orientationLock: OrientationLockMode, volumeKeyPageTurn: boolean): Promise<void> {
    this.isForeground = true;
    this.orientationLock = orientationLock;
    this.volumeKeyPageTurn = volumeKeyPageTurn;
    this.syncVolumeKeySubscription();
    await this.adapter.setPreferredOrientation(orientationLock);
    if (!this.followSystemBrightness) {
      await this.adapter.setBrightness(clampReaderBrightness(this.customBrightness));
    }
  }

  /** 切换屏幕方向锁定 */
  async setOrientationLock(mode: OrientationLockMode): Promise<void> {
    this.orientationLock = mode;
    if (this.isForeground) {
      await this.adapter.setPreferredOrientation(mode);
    }
  }

  /** 切换跟随系统亮度 / 自定义亮度 */
  async setFollowSystemBrightness(follow: boolean): Promise<void> {
    this.followSystemBrightness = follow;
    if (follow) {
      await this.adapter.setBrightness(SYSTEM_BRIGHTNESS);
    } else if (this.isForeground) {
      await this.adapter.setBrightness(clampReaderBrightness(this.customBrightness));
    }
  }

  /** 设置独立亮度（自动关闭跟随系统并钳制至 [0.05, 1.0]） */
  async setCustomBrightness(value: number): Promise<void> {
    const clamped: number = clampReaderBrightness(value);
    this.customBrightness = clamped;
    this.followSystemBrightness = false;
    if (this.isForeground) {
      await this.adapter.setBrightness(clamped);
    }
  }

  setVolumeKeyPageTurn(enabled: boolean): void {
    this.volumeKeyPageTurn = enabled;
    this.syncVolumeKeySubscription();
  }

  /** 判定当前按键是否应被阅读器拦截为翻页动作（含同键 180ms 防抖与硬件/窗口双通道去重） */
  handleKeyCode(keyCode: number, nowMs: number = Date.now()): VolumeKeyAction {
    const action: VolumeKeyAction =
      resolveVolumeKeyAction(keyCode, this.volumeKeyPageTurn, this.isForeground);
    if (action === VolumeKeyAction.NONE) {
      return VolumeKeyAction.NONE;
    }
    if (this.lastVolumeKeyCode === keyCode &&
      this.lastVolumeKeyTs > 0 &&
      nowMs >= this.lastVolumeKeyTs &&
      nowMs - this.lastVolumeKeyTs < VOLUME_KEY_DEBOUNCE_MS) {
      return VolumeKeyAction.NONE;
    }
    this.lastVolumeKeyCode = keyCode;
    this.lastVolumeKeyTs = nowMs;
    return action;
  }

  /** 退入后台：恢复系统默认亮度并停止音量键拦截 */
  async onBackground(): Promise<void> {
    this.isForeground = false;
    this.syncVolumeKeySubscription();
    await this.adapter.setBrightness(SYSTEM_BRIGHTNESS);
  }

  /** 退出阅读器：强制恢复系统默认方向（UNSPECIFIED）与系统默认亮度（-1）并注销音量键拦截 */
  async exitReader(): Promise<void> {
    this.isForeground = false;
    this.syncVolumeKeySubscription();
    await this.adapter.setPreferredOrientation(OrientationLockMode.SYSTEM);
    await this.adapter.setBrightness(SYSTEM_BRIGHTNESS);
  }
}
