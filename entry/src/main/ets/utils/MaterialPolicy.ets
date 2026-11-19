/**
 * MaterialPolicy.ets —— 材质决策纯函数（p1-native-material-shell Task 2）
 *
 * 全应用唯一材质决策：任何 surface 在「官方沉浸材质」与「纯色降级」之间二选一。
 * 本文件是纯函数（零 ArkUI / 零设备调用），可单测；能力探测在 ImmersiveMaterial.ets 完成。
 *
 * 契约（plan 降级矩阵 + D10）：
 *   - 'system'：走 uiMaterial.ImmersiveMaterial（systemMaterial / systemMaterialEffect / HDS_SYSTEM_MATERIAL）；
 *   - 'solid' ：纯色降级 = ThemeColors.SURFACE，且不得与 border / shadow 并存（D10）。
 */
import { ThemeColors } from './Theme';

/** 材质决策结果：'system' = 官方沉浸材质；'solid' = 纯色降级。 */
export type MaterialDecision = 'system' | 'solid';

/**
 * 在「能力支持度」与「禁用开关」之上做二值决策（纯函数，无副作用）。
 *
 * @param supported 设备/API 支持沉浸材质（isImmersiveMaterialSupported() === true 且 SDK >= 26）
 * @param disabled  应用配置或组件级关闭（MaterialState.DISABLE / Material.empty / 配置关闭）
 * @returns 'system' 当且仅当 supported && !disabled；否则一律 'solid'（无第三态）。
 */
export function materialDecision(supported: boolean, disabled: boolean): MaterialDecision {
  if (supported && !disabled) {
    return 'system';
  }
  return 'solid';
}

/**
 * solid 降级用纯色（D10）：ThemeColors.SURFACE。
 * 施加该底色处不得再叠加 border / shadow（systemMaterial 接管语义之外的降级面同样遵守）。
 */
export function solidFallbackColor(): string {
  return ThemeColors.SURFACE;
}

/** 浮层导航胶囊（SideRail / PaginationBar）三层光感玻璃基底色（85% 不透明度） */
export function resolveGlassCapsuleTintColor(isDark: boolean): string {
  return isDark ? '#D91E222B' : '#D9FFFFFF';
}

/** 浮层导航胶囊 1vp 镜面高光描边色 */
export function resolveGlassCapsuleBorderColor(isDark: boolean): string {
  return isDark ? '#33FFFFFF' : '#E2E8F0';
}

/** 浮层导航胶囊柔和悬浮阴影色 */
export function resolveGlassCapsuleShadowColor(isDark: boolean): string {
  return isDark ? '#73000000' : '#1A0F172A';
}

/** 内联分段胶囊（SegmentSelector）玻璃槽底色 */
export function resolveSegmentTrackTintColor(isDark: boolean): string {
  return isDark ? '#EB252934' : '#EBF1F5F9';
}

/** 内联分段胶囊 1vp 边框色 */
export function resolveSegmentTrackBorderColor(isDark: boolean): string {
  return isDark ? '#2E3442' : '#DCE3EE';
}

/**
 * 解析带系统材质组件的背景色（三层光感玻璃契约）：
 * 无论系统材质是否启用，均必须保留半透明玻璃基底色（fallbackColor / Glass Tint），
 * 严禁返回全透明 '#00000000'，确保在纯色背景上也具备温润玻璃实体感。
 */
export function resolveMaterialAwareBackgroundColor(
  _hasSystemMaterial: boolean,
  fallbackColor: string
): string {
  return fallbackColor;
}

/**
 * 解析带系统材质组件的描边宽度（三层光感玻璃契约）：
 * 始终保留 1vp 镜面高光细描边，绝不归零导致胶囊边缘隐形。
 */
export function resolveMaterialAwareBorderWidth(
  _hasSystemMaterial: boolean,
  fallbackBorderWidthVp: number = 1
): number {
  return fallbackBorderWidthVp;
}

/** 底部导航栏高对比度实色表面（浅色 #FFFFFF / 深色 #1C1E24） */
export function resolveBottomBarSurfaceColor(isDark: boolean): string {
  return isDark ? '#1C1E24' : '#FFFFFF';
}

/** 停靠式分页栏高对比度实色表面（浅色 #FFFFFF / 深色 #181A20） */
export function resolvePaginationSurfaceColor(isDark: boolean): string {
  return isDark ? '#181A20' : '#FFFFFF';
}

/** 停靠式栏体细分割线颜色（浅色 #E2E8F0 / 深色 #2E323D） */
export function resolveBarDividerColor(isDark: boolean): string {
  return isDark ? '#2E323D' : '#E2E8F0';
}

/** 分级沉浸式系统材质层级 */
export type ImmersiveMaterialTier = 'bar' | 'panel' | 'floatingPill';

export interface ImmersiveSurfaceTokens {
  tier: ImmersiveMaterialTier;
  /** 材质色调底色（配合官方 uiMaterial 形成深浅色自适应高对比度表面） */
  tintColor: string;
  /** 降级实色底色 */
  solidFallbackColor: string;
  /** 1vp 边缘高光细描边颜色 */
  borderColor: string;
  /** 边缘流光高光起始色 */
  specularStartColor: string;
  /** 边缘流光高光结束色 */
  specularEndColor: string;
  /** 前景强对比文字/图标色 */
  foregroundStrongColor: string;
  /** 前景次级文字/图标色 */
  foregroundSecondaryColor: string;
  /** 阴影颜色 */
  shadowColor: string;
  /** 阴影半径（vp） */
  shadowRadius: number;
}

/** 浮动胶囊导航 / 顶栏背板材质 Token */
export function resolveBarMaterialTokens(isDark: boolean): ImmersiveSurfaceTokens {
  if (isDark) {
    return {
      tier: 'bar',
      tintColor: '#B8181B22',
      solidFallbackColor: '#1C1E24',
      borderColor: '#29FFFFFF',
      specularStartColor: '#42FFFFFF',
      specularEndColor: '#12FFFFFF',
      foregroundStrongColor: '#F8FAFC',
      foregroundSecondaryColor: '#CBD5E1',
      shadowColor: '#40000000',
      shadowRadius: 20
    };
  }
  return {
    tier: 'bar',
    tintColor: '#CCFFFFFF',
    solidFallbackColor: '#FFFFFF',
    borderColor: '#A6FFFFFF',
    specularStartColor: '#E6FFFFFF',
    specularEndColor: '#66E2E8F0',
    foregroundStrongColor: '#1E2430',
    foregroundSecondaryColor: '#475569',
    shadowColor: '#1A0F172A',
    shadowRadius: 18
  };
}

/** 空间化弹窗与设置面板材质 Token */
export function resolvePanelMaterialTokens(isDark: boolean): ImmersiveSurfaceTokens {
  if (isDark) {
    return {
      tier: 'panel',
      tintColor: '#CC1C1F26',
      solidFallbackColor: '#1E2025',
      borderColor: '#24FFFFFF',
      specularStartColor: '#3DFFFFFF',
      specularEndColor: '#14A78BFA',
      foregroundStrongColor: '#F8FAFC',
      foregroundSecondaryColor: '#94A3B8',
      shadowColor: '#52000000',
      shadowRadius: 28
    };
  }
  return {
    tier: 'panel',
    tintColor: '#D9FFFFFF',
    solidFallbackColor: '#FFFFFF',
    borderColor: '#A6FFFFFF',
    specularStartColor: '#F2FFFFFF',
    specularEndColor: '#66C4B5FD',
    foregroundStrongColor: '#1E2430',
    foregroundSecondaryColor: '#475569',
    shadowColor: '#240F172A',
    shadowRadius: 24
  };
}

/** 轻量悬浮动作胶囊控件材质 Token */
export function resolveFloatingPillMaterialTokens(isDark: boolean): ImmersiveSurfaceTokens {
  if (isDark) {
    return {
      tier: 'floatingPill',
      tintColor: '#AD222631',
      solidFallbackColor: '#252A34',
      borderColor: '#2EFFFFFF',
      specularStartColor: '#47FFFFFF',
      specularEndColor: '#14FFFFFF',
      foregroundStrongColor: '#F8FAFC',
      foregroundSecondaryColor: '#CBD5E1',
      shadowColor: '#33000000',
      shadowRadius: 12
    };
  }
  return {
    tier: 'floatingPill',
    tintColor: '#D6F8FAFC',
    solidFallbackColor: '#F1F3F6',
    borderColor: '#A6FFFFFF',
    specularStartColor: '#EBFFFFFF',
    specularEndColor: '#40CBD5E1',
    foregroundStrongColor: '#1E2430',
    foregroundSecondaryColor: '#475569',
    shadowColor: '#140F172A',
    shadowRadius: 10
  };
}

/** 设置页选择器胶囊底色（浅色 #EEF1F6 / 深色 #262A34，按压态加深反馈） */
export function resolveSettingsPillSurfaceColor(isDark: boolean, isPressed: boolean = false): string {
  if (isDark) {
    return isPressed ? '#303643' : '#262A34';
  }
  return isPressed ? '#E2E7F0' : '#EEF1F6';
}

/** 设置页选择器胶囊 1vp 细边框色 */
export function resolveSettingsPillBorderColor(isDark: boolean): string {
  return isDark ? '#343946' : '#DCE2EC';
}

export const DETAIL_TOP_BAR_BLUR_START_VP: number = 8;
export const DETAIL_TOP_BAR_BLUR_FULL_VP: number = 96;

export interface DetailTopBarVisualState {
  blurProgress: number;
  titleOpacity: number;
  dividerOpacity: number;
  useBarBlur: boolean;
  barBackgroundColor: string;
  dividerColor: string;
  foregroundColor: string;
  pillBackgroundColor: string;
  pillBorderColor: string;
}

/**
 * 漫画详情页顶栏随滚动偏移（0 -> 96vp）渐进模糊背板与高对比反色状态（纯函数，可单测）。
 */
export function resolveDetailTopBarVisualState(
  scrollOffsetVp: number,
  isDark: boolean
): DetailTopBarVisualState {
  const safeOffset: number = Number.isFinite(scrollOffsetVp) && scrollOffsetVp > 0 ? scrollOffsetVp : 0;
  const rawProgress: number = (safeOffset - DETAIL_TOP_BAR_BLUR_START_VP) /
    (DETAIL_TOP_BAR_BLUR_FULL_VP - DETAIL_TOP_BAR_BLUR_START_VP);
  const progress: number = Math.max(0, Math.min(1, rawProgress));
  const titleOpacity: number = Math.max(0, Math.min(1, (progress - 0.15) / 0.85));
  const barTokens: ImmersiveSurfaceTokens = resolveBarMaterialTokens(isDark);
  const pillTokens: ImmersiveSurfaceTokens = resolveFloatingPillMaterialTokens(isDark);

  const maxAlpha: number = isDark ? 184 : 204;
  const alphaInt: number = Math.round(maxAlpha * progress);
  const alphaHex: string = alphaInt.toString(16).padStart(2, '0').toUpperCase();
  const rgbHex: string = isDark ? '181B22' : 'FFFFFF';
  const barBg: string = progress <= 0.01 ? '#00000000' : `#${alphaHex}${rgbHex}`;

  return {
    blurProgress: progress,
    titleOpacity: titleOpacity,
    dividerOpacity: progress,
    useBarBlur: progress > 0.02,
    barBackgroundColor: barBg,
    dividerColor: barTokens.borderColor,
    foregroundColor: barTokens.foregroundStrongColor,
    pillBackgroundColor: pillTokens.tintColor,
    pillBorderColor: pillTokens.borderColor
  };
}

export const SPATIAL_DIALOG_SCALE_FROM: number = 0.90;
export const SPATIAL_MENU_SCALE_FROM: number = 0.92;
export const SPATIAL_SHEET_SCALE_FROM: number = 0.96;
export const SPATIAL_HUD_SCALE_FROM: number = 0.96;
export const SPATIAL_PRESS_SCALE: number = 0.97;
export const SPATIAL_SLIDER_ACTIVE_SCALE: number = 1.03;

export type SpatialMotionKind = 'dialog' | 'sheet' | 'menu' | 'hud';

export interface SpatialTransitionSpec {
  kind: SpatialMotionKind;
  scaleFrom: number;
  springResponse: number;
  springDamping: number;
}

/** 返回空间化弹性转场规范参数（纯函数，可单测） */
export function resolveSpatialTransitionSpec(kind: SpatialMotionKind): SpatialTransitionSpec {
  if (kind === 'dialog') {
    return {
      kind: 'dialog',
      scaleFrom: SPATIAL_DIALOG_SCALE_FROM,
      springResponse: 0.32,
      springDamping: 0.82
    };
  }
  if (kind === 'menu') {
    return {
      kind: 'menu',
      scaleFrom: SPATIAL_MENU_SCALE_FROM,
      springResponse: 0.28,
      springDamping: 0.82
    };
  }
  if (kind === 'sheet') {
    return {
      kind: 'sheet',
      scaleFrom: SPATIAL_SHEET_SCALE_FROM,
      springResponse: 0.34,
      springDamping: 0.84
    };
  }
  return {
    kind: 'hud',
    scaleFrom: SPATIAL_HUD_SCALE_FROM,
    springResponse: 0.26,
    springDamping: 0.86
  };
}

export interface ReaderSliderGlowState {
  isDragging: boolean;
  progressRatio: number;
  trackScaleY: number;
  glowShadowRadius: number;
  glowShadowColor: string;
  pillBorderColor: string;
}

/** 计算阅读器页码/亮度滑块的拖拽光感交互态（纯函数，可单测） */
export function resolveReaderSliderGlowState(
  isDragging: boolean,
  currentVal: number,
  maxVal: number,
  isDark: boolean
): ReaderSliderGlowState {
  const safeMax: number = Number.isFinite(maxVal) && maxVal > 0 ? maxVal : 1;
  const safeCur: number = Number.isFinite(currentVal) ? currentVal : 0;
  const ratio: number = Math.max(0, Math.min(1, safeCur / safeMax));
  return {
    isDragging: isDragging,
    progressRatio: ratio,
    trackScaleY: isDragging ? SPATIAL_SLIDER_ACTIVE_SCALE : 1.0,
    glowShadowRadius: isDragging ? 14 : 0,
    glowShadowColor: isDragging ? (isDark ? '#80A78BFA' : '#667C3AED') : '#00000000',
    pillBorderColor: isDragging
      ? (isDark ? '#80A78BFA' : '#807C3AED')
      : (isDark ? '#29FFFFFF' : '#A6FFFFFF')
  };
}
