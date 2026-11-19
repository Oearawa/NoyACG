/**
 * ReaderGestureMath.ets —— 阅读器缩放与防越界拖拽纯函数几何计算（无 ArkUI 依赖）
 */
import { ReaderMode, TapZoneAction } from './ReaderTypes';

export const MIN_ZOOM_SCALE: number = 1.0;
export const MAX_ZOOM_SCALE: number = 3.5;
export const DOUBLE_TAP_ZOOM_SCALE: number = 2.0;
export const PAN_ACTIVE_THRESHOLD: number = 1.02;
export const PINCH_SNAP_RESET_THRESHOLD: number = 1.05;
export const PAN_EDGE_PAGE_TURN_THRESHOLD_VP: number = 88;
export const PAN_EDGE_START_TOLERANCE_VP: number = 2;
export const PAN_EDGE_AXIS_DOMINANCE_RATIO: number = 1.35;
export const PINCH_END_PAN_COOLDOWN_MS: number = 180;
export type PanEdgeTurnDirection = 'none' | 'prev' | 'next';
export const TAP_MAX_MOVE_VP: number = 12;
export const TAP_MAX_DURATION_MS: number = 350;
export const DOUBLE_TAP_INTERVAL_MS: number = 180;
export const DOUBLE_TAP_MAX_DISTANCE_VP: number = 48;

export class ZoomOffset {
  readonly x: number;
  readonly y: number;

  constructor(x: number, y: number) {
    this.x = x;
    this.y = y;
  }
}

export class ZoomTransformState {
  readonly scale: number;
  readonly offsetX: number;
  readonly offsetY: number;

  constructor(scale: number, offsetX: number, offsetY: number) {
    this.scale = scale;
    this.offsetX = offsetX;
    this.offsetY = offsetY;
  }
}

/** 钳制缩放倍率至 [1.0, 3.5] */
export function clampZoomScale(scale: number): number {
  if (!Number.isFinite(scale)) {
    return MIN_ZOOM_SCALE;
  }
  return Math.max(MIN_ZOOM_SCALE, Math.min(scale, MAX_ZOOM_SCALE));
}

/** 仅在放大态（scale > 1.02）下接管单指拖拽，避免与未放大态翻页/滚动手势冲突 */
export function isPanEnabledForScale(scale: number): boolean {
  return Number.isFinite(scale) && scale > PAN_ACTIVE_THRESHOLD;
}

/** 将平移偏移量严格钳制在放大后的视口边界内，防止把图片拖出屏幕 */
export function clampPanOffset(
  offsetX: number,
  offsetY: number,
  scale: number,
  viewportWidth: number,
  viewportHeight: number
): ZoomOffset {
  const safeScale: number = clampZoomScale(scale);
  if (!isPanEnabledForScale(safeScale) ||
    !Number.isFinite(viewportWidth) || viewportWidth <= 0 ||
    !Number.isFinite(viewportHeight) || viewportHeight <= 0) {
    return new ZoomOffset(0, 0);
  }
  const maxX: number = (viewportWidth * (safeScale - 1)) / 2;
  const maxY: number = (viewportHeight * (safeScale - 1)) / 2;
  const safeX: number = Number.isFinite(offsetX) ? Math.max(-maxX, Math.min(offsetX, maxX)) : 0;
  const safeY: number = Number.isFinite(offsetY) ? Math.max(-maxY, Math.min(offsetY, maxY)) : 0;
  return new ZoomOffset(safeX, safeY);
}

/** 双击切换 1.0x <-> 2.0x（以点击坐标计算初始偏移并钳制在边界内） */
export function toggleDoubleTapZoom(
  currentScale: number,
  tapX: number,
  tapY: number,
  viewportWidth: number,
  viewportHeight: number
): ZoomTransformState {
  if (isPanEnabledForScale(currentScale)) {
    return resetZoomTransform();
  }
  const nextScale: number = DOUBLE_TAP_ZOOM_SCALE;
  if (!Number.isFinite(viewportWidth) || viewportWidth <= 0 ||
    !Number.isFinite(viewportHeight) || viewportHeight <= 0) {
    return new ZoomTransformState(nextScale, 0, 0);
  }
  const centerX: number = viewportWidth / 2;
  const centerY: number = viewportHeight / 2;
  const safeTapX: number = Number.isFinite(tapX) ? tapX : centerX;
  const safeTapY: number = Number.isFinite(tapY) ? tapY : centerY;
  const rawX: number = (centerX - safeTapX) * (nextScale - 1);
  const rawY: number = (centerY - safeTapY) * (nextScale - 1);
  const clamped: ZoomOffset = clampPanOffset(rawX, rawY, nextScale, viewportWidth, viewportHeight);
  return new ZoomTransformState(nextScale, clamped.x, clamped.y);
}

/** 切页/切章时重置为原始未缩放状态 */
export function resetZoomTransform(): ZoomTransformState {
  return new ZoomTransformState(MIN_ZOOM_SCALE, 0, 0);
}

/** 是否锁定外层 List / Swiper 滚动（双指触控中、捏合中或已处于放大态） */
export function shouldLockReaderScroll(
  activeTouchCount: number,
  isPinching: boolean,
  scale: number
): boolean {
  return activeTouchCount >= 2 || isPinching || isPanEnabledForScale(scale);
}

/** 双指捏合结束时的吸附计算：< 1.05x 自动归位 1.0x，否则钳制偏移 */
export function resolvePinchEndTransform(
  scale: number,
  offsetX: number,
  offsetY: number,
  viewportWidth: number,
  viewportHeight: number
): ZoomTransformState {
  if (!Number.isFinite(scale) || scale < PINCH_SNAP_RESET_THRESHOLD) {
    return resetZoomTransform();
  }
  const nextScale: number = clampZoomScale(scale);
  const clamped: ZoomOffset = clampPanOffset(offsetX, offsetY, nextScale, viewportWidth, viewportHeight);
  return new ZoomTransformState(nextScale, clamped.x, clamped.y);
}

/**
 * 双指捏合结束后的防误触冷却窗口（默认 180ms）：
 * 避免松手瞬间残留的单指移动直接触发边缘翻页。
 */
export function isWithinPinchCooldown(
  lastPinchEndTimeMs: number,
  nowMs: number,
  cooldownMs: number = PINCH_END_PAN_COOLDOWN_MS
): boolean {
  if (!Number.isFinite(lastPinchEndTimeMs) || lastPinchEndTimeMs <= 0 || !Number.isFinite(nowMs)) {
    return false;
  }
  const elapsed: number = nowMs - lastPinchEndTimeMs;
  return elapsed >= 0 && elapsed < cooldownMs;
}

/**
 * 放大态单指拖拽结束时的边缘越界翻页判定：
 * 1. 起始偏移（panStartX/panStartY）必须已贴对应边缘（容差 ±2vp）；未贴边起拖只平移动画到边缘，绝不误翻页；
 * 2. 主轴过冲距离须 >= 88vp（thresholdVp）；
 * 3. 主轴位移须明显大于副轴位移（|mainDelta| >= |crossDelta| * 1.35），过滤斜向查看拖动。
 */
export function resolveZoomedPanEdgeTurn(
  panStartX: number,
  panStartY: number,
  deltaX: number,
  deltaY: number,
  scale: number,
  viewportWidth: number,
  viewportHeight: number,
  mode: ReaderMode,
  thresholdVp: number = PAN_EDGE_PAGE_TURN_THRESHOLD_VP
): PanEdgeTurnDirection {
  const safeScale: number = clampZoomScale(scale);
  if (!isPanEnabledForScale(safeScale) ||
    !Number.isFinite(viewportWidth) || viewportWidth <= 0 ||
    !Number.isFinite(viewportHeight) || viewportHeight <= 0) {
    return 'none';
  }
  const maxX: number = (viewportWidth * (safeScale - 1)) / 2;
  const maxY: number = (viewportHeight * (safeScale - 1)) / 2;
  const safeStartX: number = Number.isFinite(panStartX) ? panStartX : 0;
  const safeStartY: number = Number.isFinite(panStartY) ? panStartY : 0;
  const safeDeltaX: number = Number.isFinite(deltaX) ? deltaX : 0;
  const safeDeltaY: number = Number.isFinite(deltaY) ? deltaY : 0;
  const rawX: number = safeStartX + safeDeltaX;
  const rawY: number = safeStartY + safeDeltaY;

  if (mode === ReaderMode.VERTICAL_STRIP) {
    if (Math.abs(safeDeltaY) < Math.abs(safeDeltaX) * PAN_EDGE_AXIS_DOMINANCE_RATIO) {
      return 'none';
    }
    if (safeStartY >= maxY - PAN_EDGE_START_TOLERANCE_VP &&
      safeDeltaY >= thresholdVp &&
      rawY - maxY >= thresholdVp) {
      return 'prev';
    }
    if (safeStartY <= -maxY + PAN_EDGE_START_TOLERANCE_VP &&
      -safeDeltaY >= thresholdVp &&
      -maxY - rawY >= thresholdVp) {
      return 'next';
    }
    return 'none';
  }

  if (Math.abs(safeDeltaX) < Math.abs(safeDeltaY) * PAN_EDGE_AXIS_DOMINANCE_RATIO) {
    return 'none';
  }
  if (safeStartX >= maxX - PAN_EDGE_START_TOLERANCE_VP &&
    safeDeltaX >= thresholdVp &&
    rawX - maxX >= thresholdVp) {
    return mode === ReaderMode.PAGE_RTL ? 'next' : 'prev';
  }
  if (safeStartX <= -maxX + PAN_EDGE_START_TOLERANCE_VP &&
    -safeDeltaX >= thresholdVp &&
    -maxX - rawX >= thresholdVp) {
    return mode === ReaderMode.PAGE_RTL ? 'prev' : 'next';
  }
  return 'none';
}

/**
 * 解析单击在视口中的 vp 坐标：
 * 优先使用 onTouch(Down) 在外层固定视口记录的 (downTouchX, downTouchY)，
 * 避免 Exclusive 手势组延迟触发时 fingerList[0].localX/localY 变成 0 导致误判为左上角翻页。
 */
export function resolveTapCoordinateVp(
  hasDownTouch: boolean,
  downX: number,
  downY: number,
  gestureLocalX: number,
  gestureLocalY: number,
  viewportWidth: number,
  viewportHeight: number
): ZoomOffset {
  const safeW: number = Number.isFinite(viewportWidth) && viewportWidth > 0 ? viewportWidth : 360;
  const safeH: number = Number.isFinite(viewportHeight) && viewportHeight > 0 ? viewportHeight : 780;
  if (hasDownTouch && Number.isFinite(downX) && Number.isFinite(downY)) {
    return new ZoomOffset(downX, downY);
  }
  if (Number.isFinite(gestureLocalX) && Number.isFinite(gestureLocalY) &&
    (gestureLocalX > 0 || gestureLocalY > 0)) {
    return new ZoomOffset(gestureLocalX, gestureLocalY);
  }
  return new ZoomOffset(safeW / 2, safeH / 2);
}

/** 计算双指触点间的欧氏距离（vp） */
export function computePinchDistanceVp(
  x0: number,
  y0: number,
  x1: number,
  y1: number
): number {
  const dx: number = x1 - x0;
  const dy: number = y1 - y0;
  const dist: number = Math.sqrt(dx * dx + dy * dy);
  return Number.isFinite(dist) ? dist : 0;
}

/** 判定单指按下到抬起是否构成有效轻点（无多指、未超位移阈值、未超时） */
export function isSingleFingerTapCandidate(
  hadMultiTouch: boolean,
  isPinching: boolean,
  isPanDragging: boolean,
  movedTooFar: boolean,
  durationMs: number
): boolean {
  if (hadMultiTouch || isPinching || isPanDragging || movedTooFar) {
    return false;
  }
  return Number.isFinite(durationMs) && durationMs >= 0 && durationMs <= TAP_MAX_DURATION_MS;
}

/** 判定两次有效轻点是否构成双击（时间间隔 <= 260ms 且距离 <= 48vp） */
export function isDoubleTapMatch(
  prevTapTimeMs: number,
  prevTapX: number,
  prevTapY: number,
  currTapTimeMs: number,
  currTapX: number,
  currTapY: number
): boolean {
  if (!Number.isFinite(prevTapTimeMs) || prevTapTimeMs <= 0 || !Number.isFinite(currTapTimeMs)) {
    return false;
  }
  const dt: number = currTapTimeMs - prevTapTimeMs;
  if (dt < 0 || dt > DOUBLE_TAP_INTERVAL_MS) {
    return false;
  }
  return computePinchDistanceVp(prevTapX, prevTapY, currTapX, currTapY) <= DOUBLE_TAP_MAX_DISTANCE_VP;
}

/**
 * 是否需要等待 180ms 双击判定窗口：
 * - 边缘翻页区域（PREV_PAGE / NEXT_PAGE）一律返回 false，抬手 0ms 立即翻页；
 * - 仅当开启「双击缩放」且点击落入中心菜单区（TOGGLE_HUD）时返回 true。
 */
export function shouldDeferTapForDoubleZoom(
  action: TapZoneAction,
  doubleTapZoomEnabled: boolean
): boolean {
  return doubleTapZoomEnabled && action === TapZoneAction.TOGGLE_HUD;
}
