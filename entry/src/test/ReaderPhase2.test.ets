/**
 * ReaderPhase2.test.ets —— 阅读器二期（滑动窗口预加载/淘汰、缩放平移手势、方向/亮度/音量键生命周期）测试
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { CancelToken } from '../main/ets/api/CancelToken';
import {
  PreloadWindowUpdate,
  ReaderImageFetcher,
  ReaderPreloadScheduler,
  WindowRange,
  computePreloadOrder,
  computePreloadRange,
  computeRetainRange
} from '../main/ets/reader/ReaderPreloadWindow';
import {
  DOUBLE_TAP_INTERVAL_MS,
  DOUBLE_TAP_ZOOM_SCALE,
  MAX_ZOOM_SCALE,
  MIN_ZOOM_SCALE,
  PAN_EDGE_AXIS_DOMINANCE_RATIO,
  PAN_EDGE_PAGE_TURN_THRESHOLD_VP,
  PAN_EDGE_START_TOLERANCE_VP,
  PINCH_END_PAN_COOLDOWN_MS,
  ZoomOffset,
  ZoomTransformState,
  clampPanOffset,
  clampZoomScale,
  computePinchDistanceVp,
  isDoubleTapMatch,
  isPanEnabledForScale,
  isSingleFingerTapCandidate,
  isWithinPinchCooldown,
  resetZoomTransform,
  resolvePinchEndTransform,
  resolveTapCoordinateVp,
  resolveZoomedPanEdgeTurn,
  shouldDeferTapForDoubleZoom,
  shouldLockReaderScroll,
  toggleDoubleTapZoom
} from '../main/ets/reader/ReaderGestureMath';
import { resolveReaderTapAction } from '../main/ets/reader/ReaderLayout';
import { TapZoneAction } from '../main/ets/reader/ReaderTypes';
import {
  KEYCODE_VOLUME_DOWN,
  KEYCODE_VOLUME_UP,
  MAX_READER_BRIGHTNESS,
  MIN_READER_BRIGHTNESS,
  ReaderDeviceAdapter,
  ReaderDeviceController,
  SYSTEM_BRIGHTNESS,
  VOLUME_KEY_DEBOUNCE_MS,
  VolumeKeyAction,
  clampReaderBrightness,
  resolveVolumeKeyAction
} from '../main/ets/reader/ReaderDeviceController';
import {
  READER_VERTICAL_PAGE_STEP_RATIO,
  ReaderPageWindow,
  computeReaderContentWidthVp,
  computeReaderPageWindow,
  computeVerticalPageTurnStepVp,
  resolveHorizontalTurnControllerAction,
  resolvePageTurnAnimated
} from '../main/ets/reader/ReaderLayout';
import { ReaderMode } from '../main/ets/reader/ReaderTypes';
import { OrientationLockMode } from '../main/ets/utils/PreferenceManager';
import { delay } from './DetailStubs';

class StubImageFetcher implements ReaderImageFetcher {
  tokensByUrl: Map<string, CancelToken> = new Map<string, CancelToken>();
  releasedUrls: string[] = [];
  hangUrls: Set<string> = new Set<string>();

  async fetch(url: string, token: CancelToken): Promise<string> {
    this.tokensByUrl.set(url, token);
    if (this.hangUrls.has(url)) {
      await new Promise<void>((resolve: () => void) => {
        token.onCancel((): void => {
          resolve();
        });
      });
    }
    return `file://cache/${url}`;
  }

  release(url: string): void {
    this.releasedUrls.push(url);
  }
}

class StubDeviceAdapter implements ReaderDeviceAdapter {
  orientations: OrientationLockMode[] = [];
  brightnesses: number[] = [];
  subscribeCount: number = 0;
  unsubscribeCount: number = 0;
  subscribedCallback?: (keyCode: number) => void;

  async setPreferredOrientation(mode: OrientationLockMode): Promise<void> {
    this.orientations.push(mode);
  }

  async setBrightness(brightness: number): Promise<void> {
    this.brightnesses.push(brightness);
  }

  subscribeVolumeKeys(onKeyDown: (keyCode: number) => void): void {
    this.subscribeCount += 1;
    this.subscribedCallback = onKeyDown;
  }

  unsubscribeVolumeKeys(): void {
    this.unsubscribeCount += 1;
    this.subscribedCallback = undefined;
  }
}

export default function readerPhase2Test() {
  describe('ReaderPreloadWindow', () => {
    it('windowRangesAndPriorityOrderRespectBoundaries', 0, () => {
      const startPreload: WindowRange = computePreloadRange(0, 20);
      expect(startPreload.start).assertEqual(0);
      expect(startPreload.end).assertEqual(4);

      const endRetain: WindowRange = computeRetainRange(19, 20);
      expect(endRetain.start).assertEqual(14);
      expect(endRetain.end).assertEqual(19);

      const order: number[] = computePreloadOrder(5, 20);
      expect(order.join(',')).assertEqual('5,6,7,8,9,4,3');

      const winMid: ReaderPageWindow = computeReaderPageWindow(10, 20);
      expect(winMid.prefetchStart).assertEqual(8);
      expect(winMid.prefetchEnd).assertEqual(14);
      expect(winMid.retainStart).assertEqual(5);
      expect(winMid.retainEnd).assertEqual(18);

      const winEmpty: ReaderPageWindow = computeReaderPageWindow(0, 0);
      expect(winEmpty.prefetchEnd < winEmpty.prefetchStart).assertTrue();
      expect(winEmpty.retainEnd < winEmpty.retainStart).assertTrue();

      expect(computeReaderContentWidthVp(360, ReaderMode.VERTICAL_STRIP)).assertEqual(360);
      expect(computeReaderContentWidthVp(800, ReaderMode.VERTICAL_STRIP)).assertEqual(760);
      expect(computeReaderContentWidthVp(1200, ReaderMode.VERTICAL_STRIP)).assertEqual(760);
      expect(computeReaderContentWidthVp(1200, ReaderMode.PAGE_LTR)).assertEqual(1200);

      // 垂直滚动整屏点击翻页步进：严格 1.0 倍视口高度（无 15% 上一页残留）
      expect(READER_VERTICAL_PAGE_STEP_RATIO).assertEqual(1.0);
      expect(computeVerticalPageTurnStepVp(780)).assertEqual(780);
      expect(computeVerticalPageTurnStepVp(0)).assertEqual(0);
      expect(computeVerticalPageTurnStepVp(Number.NaN)).assertEqual(0);

      // 翻页动画开关注入
      expect(resolvePageTurnAnimated(true)).assertTrue();
      expect(resolvePageTurnAnimated(false)).assertFalse();

      // 横向翻页（PAGE_LTR / PAGE_RTL）控制器动作路由
      expect(resolveHorizontalTurnControllerAction(0, 10, -1, true)).assertEqual('none');
      expect(resolveHorizontalTurnControllerAction(9, 10, 1, true)).assertEqual('none');
      expect(resolveHorizontalTurnControllerAction(0, 0, 1, true)).assertEqual('none');
      expect(resolveHorizontalTurnControllerAction(2, 10, 1, true)).assertEqual('show_next');
      expect(resolveHorizontalTurnControllerAction(2, 10, -1, true)).assertEqual('show_prev');
      expect(resolveHorizontalTurnControllerAction(2, 10, 1, false)).assertEqual('jump_index');
      expect(resolveHorizontalTurnControllerAction(2, 10, -1, false)).assertEqual('jump_index');
    });

    it('rapidPageJumpCancelsInFlightAndEvictsOutOfWindowPages', 0, async () => {
      const fetcher: StubImageFetcher = new StubImageFetcher();
      fetcher.hangUrls.add('p3');
      const scheduler: ReaderPreloadScheduler = new ReaderPreloadScheduler(fetcher);
      const urls: string[] = [];
      for (let i = 0; i < 30; i++) {
        urls.push(`p${i}`);
      }
      scheduler.setChapterUrls(urls);

      scheduler.onPageChanged(0);
      await delay(10);
      // Prefetch [0, 4]: p0, p1, p2, p4 resolved (4 retained); p3 hanging (1 in-flight)
      expect(scheduler.getRetainedCount()).assertEqual(4);
      expect(scheduler.getInFlightCount()).assertEqual(1);

      // Jump to page 20 -> p3 is outside retain window [15, 28], so its CancelToken cancels & p0,p1,p2,p4 evict
      const jumpUpdate: PreloadWindowUpdate = scheduler.onPageChanged(20);
      expect(jumpUpdate.canceledIndices.indexOf(3) >= 0).assertTrue();
      expect(fetcher.tokensByUrl.get('p3')?.isCanceled()).assertTrue();
      expect(jumpUpdate.evictedIndices.length).assertEqual(4);
      expect(fetcher.releasedUrls.length).assertEqual(4);

      await delay(10);
      scheduler.dispose();
      expect(scheduler.getInFlightCount()).assertEqual(0);
      expect(scheduler.getRetainedCount()).assertEqual(0);
    });
  });

  describe('ReaderGestureMath', () => {
    it('doubleTapPinchClampAndPanBounds', 0, () => {
      expect(clampZoomScale(0.2)).assertEqual(MIN_ZOOM_SCALE);
      expect(clampZoomScale(5.8)).assertEqual(MAX_ZOOM_SCALE);
      expect(clampZoomScale(Number.NaN)).assertEqual(MIN_ZOOM_SCALE);

      expect(isPanEnabledForScale(1.0)).assertFalse();
      expect(isPanEnabledForScale(1.02)).assertFalse();
      expect(isPanEnabledForScale(1.5)).assertTrue();

      const zoomed: ZoomTransformState = toggleDoubleTapZoom(1.0, 200, 300, 400, 800);
      expect(zoomed.scale).assertEqual(DOUBLE_TAP_ZOOM_SCALE);

      const clampedPan: ZoomOffset = clampPanOffset(5000, -5000, 2.0, 400, 800);
      expect(clampedPan.x).assertEqual(200);
      expect(clampedPan.y).assertEqual(-400);

      const unzoomed: ZoomTransformState = toggleDoubleTapZoom(zoomed.scale, 200, 300, 400, 800);
      expect(unzoomed.scale).assertEqual(1.0);
      expect(unzoomed.offsetX).assertEqual(0);
      expect(unzoomed.offsetY).assertEqual(0);

      const reset: ZoomTransformState = resetZoomTransform();
      expect(reset.scale).assertEqual(1.0);
    });

    it('scrollLockPinchSnapAndEdgeTurnBoundaries', 0, () => {
      // Multi-finger / pinching / zoomed locks outer List & Swiper
      expect(shouldLockReaderScroll(1, false, 1.0)).assertFalse();
      expect(shouldLockReaderScroll(2, false, 1.0)).assertTrue();
      expect(shouldLockReaderScroll(1, true, 1.0)).assertTrue();
      expect(shouldLockReaderScroll(0, false, 1.1)).assertTrue();

      // Pinch settle: < 1.05 snaps back to 1.0x centered; >= 1.05 retains & clamps offsets
      const snapped: ZoomTransformState = resolvePinchEndTransform(1.04, 15, -15, 400, 800);
      expect(snapped.scale).assertEqual(1.0);
      expect(snapped.offsetX).assertEqual(0);
      expect(snapped.offsetY).assertEqual(0);

      const retained: ZoomTransformState = resolvePinchEndTransform(2.0, 900, -900, 400, 800);
      expect(retained.scale).assertEqual(2.0);
      expect(retained.offsetX).assertEqual(200);
      expect(retained.offsetY).assertEqual(-400);

      // Zoomed pan edge turn thresholds & anti-accidental guards (2.0x on 400x800 => maxX=200, maxY=400)
      expect(PAN_EDGE_PAGE_TURN_THRESHOLD_VP).assertEqual(88);
      expect(PAN_EDGE_START_TOLERANCE_VP).assertEqual(2);
      expect(PAN_EDGE_AXIS_DOMINANCE_RATIO).assertEqual(1.35);
      expect(PINCH_END_PAN_COOLDOWN_MS).assertEqual(180);

      // 场景 A：未贴边起拖（从中心 panStart=0 大幅拖至边缘之外）只允许平移动画贴边，绝不触发翻页
      expect(resolveZoomedPanEdgeTurn(0, 0, 320, 0, 2.0, 400, 800, ReaderMode.PAGE_LTR))
        .assertEqual('none');
      expect(resolveZoomedPanEdgeTurn(0, 0, -320, 0, 2.0, 400, 800, ReaderMode.PAGE_RTL))
        .assertEqual('none');
      expect(resolveZoomedPanEdgeTurn(0, 0, 0, -520, 2.0, 400, 800, ReaderMode.VERTICAL_STRIP))
        .assertEqual('none');

      // 场景 B：已贴边起拖 + 过冲 >= 88vp + 满足 1.35 主轴比才触发翻页
      expect(resolveZoomedPanEdgeTurn(200, 0, PAN_EDGE_PAGE_TURN_THRESHOLD_VP, 10, 2.0, 400, 800, ReaderMode.PAGE_LTR))
        .assertEqual('prev');
      expect(resolveZoomedPanEdgeTurn(-200, 0, -PAN_EDGE_PAGE_TURN_THRESHOLD_VP, -10, 2.0, 400, 800, ReaderMode.PAGE_LTR))
        .assertEqual('next');
      expect(resolveZoomedPanEdgeTurn(200, 0, PAN_EDGE_PAGE_TURN_THRESHOLD_VP, 0, 2.0, 400, 800, ReaderMode.PAGE_RTL))
        .assertEqual('next');
      expect(resolveZoomedPanEdgeTurn(-200, 0, -PAN_EDGE_PAGE_TURN_THRESHOLD_VP, 0, 2.0, 400, 800, ReaderMode.PAGE_RTL))
        .assertEqual('prev');
      expect(resolveZoomedPanEdgeTurn(0, -400, 12, -95, 2.0, 400, 800, ReaderMode.VERTICAL_STRIP))
        .assertEqual('next');
      expect(resolveZoomedPanEdgeTurn(0, 400, -12, 95, 2.0, 400, 800, ReaderMode.VERTICAL_STRIP))
        .assertEqual('prev');

      // 场景 C：贴边起拖但距离不足 88vp，或斜向拖动主轴比 < 1.35，均不误触翻页
      expect(resolveZoomedPanEdgeTurn(200, 0, 65, 0, 2.0, 400, 800, ReaderMode.PAGE_LTR))
        .assertEqual('none');
      expect(resolveZoomedPanEdgeTurn(-200, 0, -95, 80, 2.0, 400, 800, ReaderMode.PAGE_LTR))
        .assertEqual('none');
      expect(resolveZoomedPanEdgeTurn(0, -400, 80, -95, 2.0, 400, 800, ReaderMode.VERTICAL_STRIP))
        .assertEqual('none');

      // 场景 D：双指捏合结束后 180ms 内处于冷却窗口，超过 180ms 放行
      expect(isWithinPinchCooldown(1000, 1120)).assertTrue();
      expect(isWithinPinchCooldown(1000, 1180)).assertFalse();
      expect(isWithinPinchCooldown(0, 1050)).assertFalse();

      // TouchObject.x/y takes priority over delayed Exclusive TapGesture fingerList (0, 0)
      const tapPt: ZoomOffset = resolveTapCoordinateVp(true, 180, 400, 0, 0, 360, 800);
      expect(tapPt.x).assertEqual(180);
      expect(tapPt.y).assertEqual(400);
      expect(resolveReaderTapAction(tapPt.x, tapPt.y, 360, 800, ReaderMode.PAGE_LTR, true))
        .assertEqual(TapZoneAction.TOGGLE_HUD);

      // Pinch distance calculation (3-4-5 triangle)
      expect(computePinchDistanceVp(100, 100, 103, 104)).assertEqual(5);

      // Single-finger tap candidate vs drag / multi-touch / double-tap
      expect(isSingleFingerTapCandidate(false, false, false, false, 90)).assertTrue();
      expect(isSingleFingerTapCandidate(false, false, false, true, 90)).assertFalse();
      expect(isSingleFingerTapCandidate(true, false, false, false, 90)).assertFalse();
      expect(isSingleFingerTapCandidate(false, false, false, false, 450)).assertFalse();

      expect(DOUBLE_TAP_INTERVAL_MS).assertEqual(180);
      expect(shouldDeferTapForDoubleZoom(TapZoneAction.PREV_PAGE, true)).assertFalse();
      expect(shouldDeferTapForDoubleZoom(TapZoneAction.NEXT_PAGE, true)).assertFalse();
      expect(shouldDeferTapForDoubleZoom(TapZoneAction.TOGGLE_HUD, false)).assertFalse();
      expect(shouldDeferTapForDoubleZoom(TapZoneAction.TOGGLE_HUD, true)).assertTrue();

      expect(isDoubleTapMatch(1000, 180, 400, 1150, 192, 410)).assertTrue();
      expect(isDoubleTapMatch(1000, 180, 400, 1250, 180, 400)).assertFalse();
      expect(isDoubleTapMatch(1000, 180, 400, 1100, 300, 400)).assertFalse();
    });
  });

  describe('ReaderDeviceControllerLifecycle', () => {
    let adapter: StubDeviceAdapter = new StubDeviceAdapter();
    let controller: ReaderDeviceController = new ReaderDeviceController(adapter);

    beforeEach(() => {
      adapter = new StubDeviceAdapter();
      controller = new ReaderDeviceController(adapter);
    });

    it('orientationAndBrightnessRestoreStrictlyOnExitAndBackground', 0, async () => {
      expect(clampReaderBrightness(0.0)).assertEqual(MIN_READER_BRIGHTNESS);
      expect(clampReaderBrightness(1.8)).assertEqual(MAX_READER_BRIGHTNESS);

      await controller.enterReader(OrientationLockMode.LANDSCAPE, true);
      expect(controller.isForeground).assertTrue();
      expect(adapter.orientations[adapter.orientations.length - 1]).assertEqual(OrientationLockMode.LANDSCAPE);

      await controller.setCustomBrightness(0.35);
      expect(controller.followSystemBrightness).assertFalse();
      expect(adapter.brightnesses[adapter.brightnesses.length - 1]).assertEqual(0.35);

      await controller.onBackground();
      expect(controller.isForeground).assertFalse();
      expect(adapter.brightnesses[adapter.brightnesses.length - 1]).assertEqual(SYSTEM_BRIGHTNESS);

      await controller.enterReader(OrientationLockMode.PORTRAIT, true);
      await controller.exitReader();
      expect(controller.isForeground).assertFalse();
      expect(adapter.orientations[adapter.orientations.length - 1]).assertEqual(OrientationLockMode.SYSTEM);
      expect(adapter.brightnesses[adapter.brightnesses.length - 1]).assertEqual(SYSTEM_BRIGHTNESS);
    });

    it('volumeKeysInterceptOnlyWhenEnabledAndForeground', 0, async () => {
      expect(resolveVolumeKeyAction(KEYCODE_VOLUME_UP, false, true)).assertEqual(VolumeKeyAction.NONE);
      expect(resolveVolumeKeyAction(KEYCODE_VOLUME_UP, true, false)).assertEqual(VolumeKeyAction.NONE);

      await controller.enterReader(OrientationLockMode.SYSTEM, true);
      expect(controller.handleKeyCode(KEYCODE_VOLUME_UP)).assertEqual(VolumeKeyAction.PREV_PAGE);
      expect(controller.handleKeyCode(KEYCODE_VOLUME_DOWN)).assertEqual(VolumeKeyAction.NEXT_PAGE);

      controller.setVolumeKeyPageTurn(false);
      expect(controller.handleKeyCode(KEYCODE_VOLUME_UP)).assertEqual(VolumeKeyAction.NONE);

      controller.setVolumeKeyPageTurn(true);
      await controller.exitReader();
      expect(controller.handleKeyCode(KEYCODE_VOLUME_DOWN)).assertEqual(VolumeKeyAction.NONE);
    });

    it('volumeKeyDebounceAndSubscriptionLifecycle', 0, async () => {
      const triggered: VolumeKeyAction[] = [];
      controller.setVolumeKeyTriggerListener((action: VolumeKeyAction): void => {
        triggered.push(action);
      });

      // 关闭时进前台不注册订阅
      await controller.enterReader(OrientationLockMode.SYSTEM, false);
      expect(adapter.subscribeCount).assertEqual(0);
      expect(adapter.unsubscribeCount > 0).assertTrue();

      // 动态打开开关立即注册硬件订阅
      controller.setVolumeKeyPageTurn(true);
      expect(adapter.subscribeCount).assertEqual(1);
      expect(adapter.subscribedCallback !== undefined).assertTrue();

      // 180ms 内连续重复按键被防抖拦截；超过 180ms 放行
      expect(controller.handleKeyCode(KEYCODE_VOLUME_UP, 1000)).assertEqual(VolumeKeyAction.PREV_PAGE);
      expect(controller.handleKeyCode(KEYCODE_VOLUME_UP, 1000 + VOLUME_KEY_DEBOUNCE_MS - 1))
        .assertEqual(VolumeKeyAction.NONE);
      expect(controller.handleKeyCode(KEYCODE_VOLUME_UP, 1000 + VOLUME_KEY_DEBOUNCE_MS))
        .assertEqual(VolumeKeyAction.PREV_PAGE);
      expect(controller.handleKeyCode(KEYCODE_VOLUME_DOWN, 2000)).assertEqual(VolumeKeyAction.NEXT_PAGE);

      // 物理回调触发翻页监听
      if (adapter.subscribedCallback !== undefined) {
        adapter.subscribedCallback(KEYCODE_VOLUME_DOWN);
      }
      expect(triggered.length).assertEqual(1);
      expect(triggered[0]).assertEqual(VolumeKeyAction.NEXT_PAGE);

      // 退后台或动态关闭开关立即解除硬件订阅
      const prevUnsub: number = adapter.unsubscribeCount;
      await controller.onBackground();
      expect(adapter.unsubscribeCount > prevUnsub).assertTrue();
      expect(adapter.subscribedCallback === undefined).assertTrue();
    });
  });
}
