/**
 * ThemeAccent.ets —— 6 套低饱和莫兰迪/东方雅致主题色板（浅/深色双态，纯定义无 UI 依赖）
 */

export type ThemeAccentId =
  'mist_iris' |
  'celadon_sage' |
  'slate_blue' |
  'muted_rose' |
  'amber_tea' |
  'graphite';

export const DEFAULT_THEME_ACCENT: ThemeAccentId = 'celadon_sage';

export interface ThemeAccentTone {
  primary: string;
  primaryPressed: string;
  softBg: string;
  softBorder: string;
  onPrimary: string;
}

export interface ThemeAccentPalette {
  id: ThemeAccentId;
  name: string;
  light: ThemeAccentTone;
  dark: ThemeAccentTone;
}

export const THEME_ACCENT_PALETTES: ThemeAccentPalette[] = [
  {
    id: 'mist_iris',
    name: '暮云紫',
    light: {
      primary: '#6B5CE7',
      primaryPressed: '#594AD4',
      softBg: '#EFEBFD',
      softBorder: '#D9D0FA',
      onPrimary: '#FFFFFF'
    },
    dark: {
      primary: '#A599F5',
      primaryPressed: '#9184E8',
      softBg: '#27233D',
      softBorder: '#3D3661',
      onPrimary: '#121212'
    }
  },
  {
    id: 'celadon_sage',
    name: '青瓷绿',
    light: {
      primary: '#3D7A68',
      primaryPressed: '#316455',
      softBg: '#E7F2EE',
      softBorder: '#C5DFD6',
      onPrimary: '#FFFFFF'
    },
    dark: {
      primary: '#7EC4AF',
      primaryPressed: '#6BB39D',
      softBg: '#1D302A',
      softBorder: '#2F4D44',
      onPrimary: '#121212'
    }
  },
  {
    id: 'slate_blue',
    name: '雾岚蓝',
    light: {
      primary: '#4A6FA5',
      primaryPressed: '#3C5C8C',
      softBg: '#E9EFF7',
      softBorder: '#C8D7EC',
      onPrimary: '#FFFFFF'
    },
    dark: {
      primary: '#88ADE0',
      primaryPressed: '#749AD0',
      softBg: '#1E293A',
      softBorder: '#31435E',
      onPrimary: '#121212'
    }
  },
  {
    id: 'muted_rose',
    name: '豆沙玫瑰',
    light: {
      primary: '#A65D6A',
      primaryPressed: '#8E4D59',
      softBg: '#F6EAEC',
      softBorder: '#E6C8CE',
      onPrimary: '#FFFFFF'
    },
    dark: {
      primary: '#DF96A3',
      primaryPressed: '#CE8290',
      softBg: '#382227',
      softBorder: '#57353D',
      onPrimary: '#121212'
    }
  },
  {
    id: 'amber_tea',
    name: '琥珀茶棕',
    light: {
      primary: '#9A6B42',
      primaryPressed: '#825834',
      softBg: '#F5EDE5',
      softBorder: '#E3D0BE',
      onPrimary: '#FFFFFF'
    },
    dark: {
      primary: '#D8A87C',
      primaryPressed: '#C69569',
      softBg: '#35281D',
      softBorder: '#523E2D',
      onPrimary: '#121212'
    }
  },
  {
    id: 'graphite',
    name: '石墨青灰',
    light: {
      primary: '#4E5D6C',
      primaryPressed: '#3F4C59',
      softBg: '#EBEEF2',
      softBorder: '#CDD5DF',
      onPrimary: '#FFFFFF'
    },
    dark: {
      primary: '#9EB0C2',
      primaryPressed: '#8A9DB0',
      softBg: '#222830',
      softBorder: '#36404D',
      onPrimary: '#121212'
    }
  }
];

export function normalizeThemeAccent(raw: string): ThemeAccentId {
  for (let i = 0; i < THEME_ACCENT_PALETTES.length; i++) {
    if (THEME_ACCENT_PALETTES[i].id === raw) {
      return THEME_ACCENT_PALETTES[i].id;
    }
  }
  return DEFAULT_THEME_ACCENT;
}

export function findThemeAccentPalette(id: ThemeAccentId): ThemeAccentPalette {
  for (let i = 0; i < THEME_ACCENT_PALETTES.length; i++) {
    if (THEME_ACCENT_PALETTES[i].id === id) {
      return THEME_ACCENT_PALETTES[i];
    }
  }
  return THEME_ACCENT_PALETTES[1];
}

export function resolveThemeAccentTone(id: ThemeAccentId, isDark: boolean): ThemeAccentTone {
  const palette: ThemeAccentPalette = findThemeAccentPalette(id);
  return isDark ? palette.dark : palette.light;
}

export function themeAccentIndex(id: ThemeAccentId): number {
  for (let i = 0; i < THEME_ACCENT_PALETTES.length; i++) {
    if (THEME_ACCENT_PALETTES[i].id === id) {
      return i;
    }
  }
  return 0;
}

export function themeAccentByIndex(index: number): ThemeAccentId {
  if (index >= 0 && index < THEME_ACCENT_PALETTES.length) {
    return THEME_ACCENT_PALETTES[index].id;
  }
  return DEFAULT_THEME_ACCENT;
}

export function themeAccentName(id: ThemeAccentId, locale: string = 'zh-CN'): string {
  if (locale === 'en-US') {
    if (id === 'mist_iris') {
      return 'Mist Iris';
    }
    if (id === 'celadon_sage') {
      return 'Celadon Sage';
    }
    if (id === 'slate_blue') {
      return 'Slate Blue';
    }
    if (id === 'muted_rose') {
      return 'Muted Rose';
    }
    if (id === 'amber_tea') {
      return 'Amber Tea';
    }
    return 'Graphite';
  }
  if (locale === 'zh-TW') {
    if (id === 'mist_iris') {
      return '暮雲紫';
    }
    if (id === 'celadon_sage') {
      return '青瓷綠';
    }
    if (id === 'slate_blue') {
      return '霧靄藍';
    }
    if (id === 'muted_rose') {
      return '枯玫瑰';
    }
    if (id === 'amber_tea') {
      return '琥珀茶';
    }
    return '石墨灰';
  }
  return findThemeAccentPalette(id).name;
}

export function themeAccentNames(locale: string = 'zh-CN'): string[] {
  const names: string[] = [];
  for (let i = 0; i < THEME_ACCENT_PALETTES.length; i++) {
    names.push(themeAccentName(THEME_ACCENT_PALETTES[i].id, locale));
  }
  return names;
}

export function themeAccentResource(id: ThemeAccentId): Resource {
  if (id === 'mist_iris') {
    return $r('app.string.theme_accent_mist_iris');
  }
  if (id === 'celadon_sage') {
    return $r('app.string.theme_accent_celadon_sage');
  }
  if (id === 'slate_blue') {
    return $r('app.string.theme_accent_slate_blue');
  }
  if (id === 'muted_rose') {
    return $r('app.string.theme_accent_muted_rose');
  }
  if (id === 'amber_tea') {
    return $r('app.string.theme_accent_amber_tea');
  }
  return $r('app.string.theme_accent_graphite');
}

export function themeAccentResources(): Resource[] {
  const list: Resource[] = [];
  for (let i = 0; i < THEME_ACCENT_PALETTES.length; i++) {
    list.push(themeAccentResource(THEME_ACCENT_PALETTES[i].id));
  }
  return list;
}
