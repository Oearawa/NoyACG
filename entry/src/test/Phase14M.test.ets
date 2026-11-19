/**
 * Phase14M.test.ets —— 动态主题回归测试（Phase 14-M）
 *
 * 验证三件事：
 *   1. 模式解析：system / light / dark 与「系统深浅」的组合换算正确，非法值回退 system；
 *   2. 调色板切换：切换后 ThemeColors（静态 getter → 当前调色板）真的换了颜色，
 *      且两套调色板的文字/背景、主色按钮、错误色对比度都达标（浅色不是深色取反）；
 *   3. 系统深浅变化只在「跟随系统」时生效，强制模式下不被系统覆盖。
 *
 * 边界：系统深浅由 SystemModePort 桩提供，属应用侧逻辑验证；
 * 真机上的实际观感（状态栏、弹窗、阅读器）标记 RUNTIME_UNVERIFIED。
 */
import { describe, it, expect, beforeEach, afterEach } from '@ohos/hypium';
import {
  THEME_MODE_DARK,
  THEME_MODE_LIGHT,
  THEME_MODE_SYSTEM,
  THEME_MODE_VALUES,
  indexToThemeMode,
  normalizeThemeMode,
  resolveDark,
  themeModeToIndex
} from '../main/ets/utils/ThemeMode';
import { ThemeManager, SystemModePort } from '../main/ets/utils/ThemeManager';
import { DEFAULT_THEME_ACCENT } from '../main/ets/utils/ThemeAccent';
import { ThemeColors } from '../main/ets/utils/Theme';
import { PreferenceManager } from '../main/ets/utils/PreferenceManager';

/** 可控系统深浅端口 */
class FakeSystemMode implements SystemModePort {
  dark: boolean = true;

  isSystemDark(): boolean {
    return this.dark;
  }
}

/** 相对亮度（与 Phase14K 主题契约测试同一套算法） */
function luminance(hex: string): number {
  const s: string = hex.charAt(0) === '#' ? hex.substring(1) : hex;
  const toLin = (v: number): number => {
    const c: number = v / 255;
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  };
  if (s.length === 8) {
    return 0.2126 * toLin(parseInt(s.substring(2, 4), 16))
      + 0.7152 * toLin(parseInt(s.substring(4, 6), 16))
      + 0.0722 * toLin(parseInt(s.substring(6, 8), 16));
  }
  return 0.2126 * toLin(parseInt(s.substring(0, 2), 16))
    + 0.7152 * toLin(parseInt(s.substring(2, 4), 16))
    + 0.0722 * toLin(parseInt(s.substring(4, 6), 16));
}

function contrast(a: string, b: string): number {
  const la: number = luminance(a);
  const lb: number = luminance(b);
  const hi: number = Math.max(la, lb);
  const lo: number = Math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

export default function phase14mTest() {
  describe('Phase14M_ThemeMode', () => {
    it('modesAreThreeAndOrdered', 0, () => {
      expect(THEME_MODE_VALUES.length).assertEqual(3);
      expect(THEME_MODE_VALUES[0]).assertEqual(THEME_MODE_SYSTEM);
      expect(THEME_MODE_VALUES[1]).assertEqual(THEME_MODE_LIGHT);
      expect(THEME_MODE_VALUES[2]).assertEqual(THEME_MODE_DARK);
    });

    it('normalizeFallsBackToSystem', 0, () => {
      expect(normalizeThemeMode('')).assertEqual(THEME_MODE_SYSTEM);
      expect(normalizeThemeMode('sepia')).assertEqual(THEME_MODE_SYSTEM);
      expect(normalizeThemeMode(THEME_MODE_LIGHT)).assertEqual(THEME_MODE_LIGHT);
      expect(normalizeThemeMode(THEME_MODE_DARK)).assertEqual(THEME_MODE_DARK);
    });

    it('resolveDarkMatrix', 0, () => {
      // 强制模式不受系统影响
      expect(resolveDark(THEME_MODE_LIGHT, true)).assertFalse();
      expect(resolveDark(THEME_MODE_DARK, false)).assertTrue();
      // 跟随系统
      expect(resolveDark(THEME_MODE_SYSTEM, true)).assertTrue();
      expect(resolveDark(THEME_MODE_SYSTEM, false)).assertFalse();
      // 非法值按跟随系统
      expect(resolveDark('junk', true)).assertTrue();
    });

    it('indexRoundTrip', 0, () => {
      for (let i = 0; i < THEME_MODE_VALUES.length; i++) {
        expect(indexToThemeMode(themeModeToIndex(THEME_MODE_VALUES[i]))).assertEqual(THEME_MODE_VALUES[i]);
      }
      expect(indexToThemeMode(7)).assertEqual(THEME_MODE_SYSTEM);
      expect(themeModeToIndex('junk')).assertEqual(0);
    });
  });

  describe('Phase14M_Palette', () => {
    let sys: FakeSystemMode = new FakeSystemMode();
    let tm: ThemeManager = ThemeManager.getInstance();

    beforeEach(() => {
      sys = new FakeSystemMode();
      tm.setSystemModePortForTest(sys);
      tm.restore(THEME_MODE_SYSTEM, DEFAULT_THEME_ACCENT);
    });

    afterEach(() => {
      // 恢复为深色（既有观感）+ 生产端口，避免污染其它用例
      sys.dark = true;
      tm.applyMode(THEME_MODE_DARK);
      tm.resetSystemModePort();
    });

    it('lightModeSwitchesRealColors', 0, () => {
      tm.applyMode(THEME_MODE_DARK);
      const darkBg: string = ThemeColors.BG;
      const darkText: string = ThemeColors.TEXT;
      tm.applyMode(THEME_MODE_LIGHT);
      // ThemeColors 是静态 getter → 读到的必须是真的新调色板
      expect(ThemeColors.BG === darkBg).assertFalse();
      expect(ThemeColors.TEXT === darkText).assertFalse();
      expect(luminance(ThemeColors.BG) > 0.7).assertTrue();   // 浅底
      expect(luminance(ThemeColors.TEXT) < 0.1).assertTrue(); // 深字
      expect(tm.isDark).assertFalse();
    });

    it('darkModeRestoresDarkColors', 0, () => {
      tm.applyMode(THEME_MODE_LIGHT);
      tm.applyMode(THEME_MODE_DARK);
      expect(tm.isDark).assertTrue();
      expect(luminance(ThemeColors.BG) < 0.05).assertTrue();
      expect(luminance(ThemeColors.TEXT) > 0.7).assertTrue();
    });

    it('systemModeFollowsSystemDark', 0, () => {
      sys.dark = false;
      tm.applyMode(THEME_MODE_SYSTEM);
      expect(tm.isDark).assertFalse();
      sys.dark = true;
      tm.onSystemColorModeChanged();
      expect(tm.isDark).assertTrue();
    });

    it('forcedModeIgnoresSystemChange', 0, () => {
      tm.applyMode(THEME_MODE_LIGHT);
      sys.dark = true;
      tm.onSystemColorModeChanged();
      // 强制浅色时，系统变深色不应覆盖用户选择
      expect(tm.isDark).assertFalse();
    });

    it('lightPaletteMeetsContrast', 0, () => {
      tm.applyMode(THEME_MODE_LIGHT);
      expect(contrast(ThemeColors.BG, ThemeColors.TEXT) >= 7).assertTrue();
      expect(contrast(ThemeColors.BG, ThemeColors.TEXT_STRONG) >= 7).assertTrue();
      expect(contrast(ThemeColors.BG, ThemeColors.TEXT_SECONDARY) >= 4.5).assertTrue();
      expect(contrast(ThemeColors.CARD, ThemeColors.TEXT) >= 7).assertTrue();
      expect(contrast(ThemeColors.PRIMARY, ThemeColors.ON_PRIMARY) >= 4.5).assertTrue();
      expect(contrast(ThemeColors.CARD, ThemeColors.ERROR) >= 4.5).assertTrue();
    });

    it('darkPaletteMeetsContrast', 0, () => {
      tm.applyMode(THEME_MODE_DARK);
      expect(contrast(ThemeColors.BG, ThemeColors.TEXT) >= 7).assertTrue();
      expect(contrast(ThemeColors.BG, ThemeColors.TEXT_SECONDARY) >= 4.5).assertTrue();
      expect(contrast(ThemeColors.CARD, ThemeColors.TEXT) >= 7).assertTrue();
      expect(contrast(ThemeColors.PRIMARY, ThemeColors.ON_PRIMARY) >= 4.5).assertTrue();
      expect(contrast(ThemeColors.CARD, ThemeColors.ERROR) >= 4.5).assertTrue();
    });

    it('lightAndDarkAreNotInverts', 0, () => {
      // 浅色不是「深色取反」：卡片仍比页面底色亮，默认青瓷绿主色仍保持 G > B > R
      tm.applyMode(THEME_MODE_LIGHT);
      expect(luminance(ThemeColors.CARD) >= luminance(ThemeColors.BG)).assertTrue();
      const primary: string = ThemeColors.PRIMARY.toUpperCase();
      // 青瓷绿系：G 分量高于 R 与 B
      const r: number = parseInt(primary.substring(1, 3), 16);
      const g: number = parseInt(primary.substring(3, 5), 16);
      const b: number = parseInt(primary.substring(5, 7), 16);
      expect(g > r).assertTrue();
      expect(g > b).assertTrue();
    });

    it('preferenceNormalizesThemeMode', 0, () => {
      // 偏好层同样做归一化（无 Preferences 实例时降级为内存生效，返回 false 不影响内存值）
      const prefs: PreferenceManager = PreferenceManager.getInstance();
      prefs.setThemeMode('sepia');
      expect(prefs.getThemeModeSync()).assertEqual(THEME_MODE_SYSTEM);
      prefs.setThemeMode(THEME_MODE_LIGHT);
      expect(prefs.getThemeModeSync()).assertEqual(THEME_MODE_LIGHT);
      prefs.setThemeMode(THEME_MODE_SYSTEM);
      expect(prefs.getThemeModeSync()).assertEqual(THEME_MODE_SYSTEM);
    });
  });
}
