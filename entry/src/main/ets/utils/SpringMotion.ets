/**
 * SpringMotion.ets —— 全仓统一的非线性物理弹簧交互动效
 *
 * 规范：
 * - 按压下沉（TouchType.Down）：curves.springMotion(0.26, 0.85)，缩放至 0.94 + 轻微压暗 0.88；
 * - 释放回弹（TouchType.Up / Cancel）：curves.springMotion(0.34, 0.70)，弹性回弹至 1.0；
 * - 禁用态统一使用 0.45 透明度，绝不让可用按钮呈现低对比度浅灰。
 */
import { curves } from '@kit.ArkUI';

export const SPRING_PRESS_SCALE: number = 0.94;
export const SPRING_PRESS_OPACITY: number = 0.88;
export const SPRING_DISABLED_OPACITY: number = 0.45;

export const SPRING_DOWN_RESPONSE: number = 0.26;
export const SPRING_DOWN_DAMPING: number = 0.85;
export const SPRING_UP_RESPONSE: number = 0.34;
export const SPRING_UP_DAMPING: number = 0.70;

export function springPressCurve(pressed: boolean): ICurve {
  return pressed
    ? curves.springMotion(SPRING_DOWN_RESPONSE, SPRING_DOWN_DAMPING)
    : curves.springMotion(SPRING_UP_RESPONSE, SPRING_UP_DAMPING);
}

export function springPressScale(pressed: boolean, enabled: boolean = true): number {
  return enabled && pressed ? SPRING_PRESS_SCALE : 1.0;
}

export function springPressOpacity(pressed: boolean, enabled: boolean = true): number {
  if (!enabled) {
    return SPRING_DISABLED_OPACITY;
  }
  return pressed ? SPRING_PRESS_OPACITY : 1.0;
}

export const CARD_PRESS_SCALE: number = 0.968;
export const CARD_PRESS_OPACITY: number = 0.94;
export const CARD_SPRING_RESPONSE: number = 0.32;
export const CARD_SPRING_DAMPING: number = 0.78;

export function cardSpringCurve(): ICurve {
  return curves.springMotion(CARD_SPRING_RESPONSE, CARD_SPRING_DAMPING);
}

export function cardPressScale(pressed: boolean): number {
  return pressed ? CARD_PRESS_SCALE : 1.0;
}

export function cardPressOpacity(pressed: boolean): number {
  return pressed ? CARD_PRESS_OPACITY : 1.0;
}
