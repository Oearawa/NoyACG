import { describe, expect, it } from '@ohos/hypium';
import {
  DEFAULT_THEME_ACCENT,
  THEME_ACCENT_PALETTES,
  ThemeAccentId,
  normalizeThemeAccent,
  resolveThemeAccentTone
} from '../main/ets/utils/ThemeAccent';
import { ThemeManager } from '../main/ets/utils/ThemeManager';
import { PreferenceManager } from '../main/ets/utils/PreferenceManager';
import { resolveSafeSelectedTab, resolveVisibleNavTabs } from '../main/ets/utils/NavTabsPolicy';

export default function themeAccentAndSettingsTest(): void {
  describe('ThemeAccentAndSettingsTest', () => {
    it('allSixSoftPalettesResolveLightAndDarkTonesCorrectly', 0, () => {
      expect(THEME_ACCENT_PALETTES.length).assertEqual(6);
      const ids: ThemeAccentId[] = [
        'mist_iris',
        'celadon_sage',
        'slate_blue',
        'muted_rose',
        'amber_tea',
        'graphite'
      ];
      for (let i = 0; i < ids.length; i++) {
        const id: ThemeAccentId = ids[i];
        expect(normalizeThemeAccent(id)).assertEqual(id);
        const light = resolveThemeAccentTone(id, false);
        const dark = resolveThemeAccentTone(id, true);
        expect(light.primary !== '').assertTrue();
        expect(dark.primary !== '').assertTrue();
        expect(light.primary !== dark.primary).assertTrue();
        expect(light.onPrimary).assertEqual('#FFFFFF');
        expect(dark.onPrimary).assertEqual('#121212');
      }

      // 默认主题为青瓷绿，非法/旧配置回退默认青瓷绿
      expect(DEFAULT_THEME_ACCENT).assertEqual('celadon_sage');
      expect(normalizeThemeAccent('')).assertEqual(DEFAULT_THEME_ACCENT);
      expect(normalizeThemeAccent('unknown_color')).assertEqual('celadon_sage');
    });

    it('themeManagerLiveAccentSwitchUpdatesPaletteInPlace', 0, () => {
      const tm: ThemeManager = ThemeManager.getInstance();
      tm.restore('light', 'mist_iris');
      expect(tm.accentId).assertEqual('mist_iris');
      expect(tm.accent).assertEqual('#6B5CE7');
      expect(tm.accentSoft).assertEqual('#EFEBFD');
      expect(tm.accentBorder).assertEqual('#D9D0FA');

      tm.applyAccent('celadon_sage');
      expect(tm.accentId).assertEqual('celadon_sage');
      expect(tm.accent).assertEqual('#3D7A68');
      expect(tm.accentSoft).assertEqual('#E7F2EE');
      expect(tm.accentBorder).assertEqual('#C5DFD6');

      tm.applyMode('dark');
      expect(tm.accent).assertEqual('#7EC4AF');
      expect(tm.accentSoft).assertEqual('#1D302A');

      // 恢复默认，避免污染其他单测
      tm.restore('system', DEFAULT_THEME_ACCENT);
    });

    it('readerChapterAndHomeTopSyncWithSlateBlueAndCeladonSage', 0, () => {
      const tm: ThemeManager = ThemeManager.getInstance();
      tm.restore('light', 'slate_blue');
      expect(tm.accent).assertEqual('#4A6FA5');
      expect(tm.accentSoft).assertEqual('#E9EFF7');
      expect(tm.accentBorder).assertEqual('#C8D7EC');
      expect(tm.onAccent).assertEqual('#FFFFFF');

      tm.applyMode('dark');
      expect(tm.accent).assertEqual('#88ADE0');
      expect(tm.accentSoft).assertEqual('#1E293A');
      expect(tm.accentBorder).assertEqual('#31435E');
      expect(tm.onAccent).assertEqual('#121212');

      tm.applyAccent('celadon_sage');
      expect(tm.accent).assertEqual('#7EC4AF');
      expect(tm.accentSoft).assertEqual('#1D302A');
      expect(tm.accentBorder).assertEqual('#2F4D44');

      tm.restore('system', DEFAULT_THEME_ACCENT);
    });

    it('preferenceManagerStoresThemeAccentAndNavBarToggles', 0, async () => {
      const prefs: PreferenceManager = PreferenceManager.getInstance();
      prefs.reset();
      expect(prefs.getThemeAccentSync()).assertEqual('celadon_sage');
      expect(prefs.getAppLanguageSync()).assertEqual('default');
      expect(prefs.getPageTurnAnimationEnabledSync()).assertTrue();

      await prefs.setPageTurnAnimationEnabled(false);
      expect(prefs.getPageTurnAnimationEnabledSync()).assertFalse();

      await prefs.setThemeAccent('slate_blue');
      expect(prefs.getThemeAccentSync()).assertEqual('slate_blue');

      await prefs.setNavShowCommunity(false);
      await prefs.setNavShowShelf(false);
      const visible = resolveVisibleNavTabs({
        showLatest: prefs.navShowLatest,
        showCommunity: prefs.navShowCommunity,
        showShelf: prefs.navShowShelf
      });
      expect(visible.length).assertEqual(3);
      expect(visible[0]).assertEqual('home');
      expect(visible[1]).assertEqual('latest');
      expect(visible[2]).assertEqual('profile');
      expect(resolveSafeSelectedTab('community', visible)).assertEqual('home');

      prefs.reset();
      expect(prefs.getThemeAccentSync()).assertEqual('celadon_sage');
      expect(prefs.getAppLanguageSync()).assertEqual('default');
      expect(prefs.getPageTurnAnimationEnabledSync()).assertTrue();
    });
  });
}
