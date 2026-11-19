/**
 * ThemeMode.ets —— 主题模式取值（Phase 14-M）
 *
 * 只放常量与纯函数，不依赖任何 Manager，避免 ThemeManager ↔ PreferenceManager 循环引用。
 * 内部值稳定（system/light/dark），持久化 key 的值即这三者之一，
 * 非法旧值一律回退 system（安全默认：跟随设备）。
 */

/** 跟随系统 */
export const THEME_MODE_SYSTEM: string = 'system';
/** 强制浅色 */
export const THEME_MODE_LIGHT: string = 'light';
/** 强制深色 */
export const THEME_MODE_DARK: string = 'dark';

/** 全部合法取值（顺序即设置页选项顺序） */
export const THEME_MODE_VALUES: string[] = [THEME_MODE_SYSTEM, THEME_MODE_LIGHT, THEME_MODE_DARK];

/** 归一化：非法值 / 空串 → 跟随系统 */
export function normalizeThemeMode(mode: string): string {
  return THEME_MODE_VALUES.indexOf(mode) >= 0 ? mode : THEME_MODE_SYSTEM;
}

/** 模式 → 设置页下标（未知 → 0） */
export function themeModeToIndex(mode: string): number {
  const i: number = THEME_MODE_VALUES.indexOf(normalizeThemeMode(mode));
  return i >= 0 ? i : 0;
}

/** 设置页下标 → 模式（越界 → 跟随系统） */
export function indexToThemeMode(index: number): string {
  if (index >= 0 && index < THEME_MODE_VALUES.length) {
    return THEME_MODE_VALUES[index];
  }
  return THEME_MODE_SYSTEM;
}

/**
 * 计算「实际生效的深浅色」。
 * @param mode      用户选择的模式
 * @param systemDark 系统当前是否深色（跟随系统时使用）
 */
export function resolveDark(mode: string, systemDark: boolean): boolean {
  const m: string = normalizeThemeMode(mode);
  if (m === THEME_MODE_DARK) {
    return true;
  }
  if (m === THEME_MODE_LIGHT) {
    return false;
  }
  return systemDark;
}
