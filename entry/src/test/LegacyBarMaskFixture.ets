// Historical R2.1 contracts retained for regression tests only.
// No application component imports or renders this retired mask implementation.
export const BAR_MASK_DARK: string = '#8C121212';
export const BAR_MASK_LIGHT: string = '#B3F5F6F8';

export function barMaskColor(isDark: boolean): string {
  return isDark ? BAR_MASK_DARK : BAR_MASK_LIGHT;
}

export function barMaskHeight(barHeightVp: number, gapVp: number): number {
  const bar: number = Number.isFinite(barHeightVp) && barHeightVp > 0 ? barHeightVp : 0;
  const gap: number = Number.isFinite(gapVp) && gapVp > 0 ? gapVp : 0;
  return bar + gap * 2;
}
