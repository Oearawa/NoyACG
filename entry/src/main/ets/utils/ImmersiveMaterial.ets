/**
 * ImmersiveMaterial.ets —— 华为官方 @kit.ArkUI uiMaterial.ImmersiveMaterial 唯一材质入口
 *
 * 严格遵循 D10 规范：
 * 1. 全仓严禁使用通用模糊 API；
 * 2. 统一通过 uiMaterial.ImmersiveMaterial + CommonMethod.systemMaterial 施加官方沉浸光感玻璃材质；
 * 3. 当设备不支持或材质被禁用（material === undefined）时，无缝回退到高对比度纯净表面色。
 */
import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import {
  materialDecision,
  resolveGlassCapsuleBorderColor,
  resolveGlassCapsuleShadowColor,
  resolveGlassCapsuleTintColor
} from './MaterialPolicy';

/** SDK guard for the API 26 component material. */
function sdkApiVersion(): number {
  try {
    return deviceInfo.sdkApiVersion;
  } catch (e) {
    return 0;
  }
}

/**
 * 是否支持组件级沉浸材质。
 * 以 `uiMaterial.isImmersiveMaterialSupported()`（硬件能力）为准，非 sdkApiVersion。
 */
export function supportsImmersiveMaterial(): boolean {
  try {
    if (sdkApiVersion() < 26) {
      return false;
    }
    return uiMaterial.isImmersiveMaterialSupported();
  } catch (e) {
    return false;
  }
}

/**
 * 当前应用材质配置是否被禁用（DISABLE）。
 * 禁用时 `ImmersiveMaterial` 会退化为纯色，提前探测以便 UI 直接走纯色降级。
 */
export function isMaterialDisabled(): boolean {
  try {
    if (!supportsImmersiveMaterial()) {
      return true;
    }
    return uiMaterial.getMaterialInfo().state === uiMaterial.MaterialState.DISABLE;
  } catch (e) {
    return true;
  }
}

/** 构建通用官方沉浸光感玻璃材质（REGULAR 档位） */
export function buildImmersiveMaterial(
  style: uiMaterial.ImmersiveStyle = uiMaterial.ImmersiveStyle.REGULAR,
  applyShadow: boolean = true,
  interactive: boolean = false
): uiMaterial.ImmersiveMaterial | undefined {
  if (materialDecision(supportsImmersiveMaterial(), isMaterialDisabled()) === 'solid') {
    return undefined;
  }
  try {
    return new uiMaterial.ImmersiveMaterial({
      style: style,
      applyShadow: applyShadow,
      interactive: interactive
    });
  } catch (e) {
    return undefined;
  }
}

/** 构建导航栏 / 顶栏 / 底栏 / 分页栏官方沉浸玻璃材质 */
export function buildBarImmersiveMaterial(applyShadow: boolean = true): uiMaterial.ImmersiveMaterial | undefined {
  return buildImmersiveMaterial(uiMaterial.ImmersiveStyle.REGULAR, applyShadow, false);
}

/** 构建弹窗 / 抽屉 / 半屏设置面板官方厚层沉浸玻璃材质 */
export function buildPanelImmersiveMaterial(): uiMaterial.ImmersiveMaterial | undefined {
  return buildImmersiveMaterial(uiMaterial.ImmersiveStyle.THICK, true, false);
}

/** 构建轻量交互胶囊控件官方沉浸玻璃材质（开启 interactive 光感形变反馈） */
export function buildPillImmersiveMaterial(): uiMaterial.ImmersiveMaterial | undefined {
  return buildImmersiveMaterial(uiMaterial.ImmersiveStyle.THIN, false, true);
}

/** 构建交互光感按钮材质（interactive: true，适配 HdsLightButton 与 CapsuleSelect） */
export function buildInteractiveButtonMaterial(): uiMaterial.ImmersiveMaterial | undefined {
  return buildImmersiveMaterial(uiMaterial.ImmersiveStyle.THIN, false, true);
}

/**
 * 把官方三层光感玻璃材质施加到任意组件：
 * 1. System Material Shader（.systemMaterial）；
 * 2. Glass Tint 玻璃基底色（#D9FFFFFF / #D91E222B）；
 * 3. Specular Rim 1vp 高光边框 + 柔和悬浮阴影。
 *
 * 严禁设置 Color.Transparent 或 0 边框导致容器外壳隐形。
 */
export class SurfaceMaterialModifier implements AttributeModifier<CommonAttribute> {
  private readonly material?: uiMaterial.ImmersiveMaterial;
  private readonly isDark: boolean;
  private readonly fallbackColor?: string;

  constructor(
    material: uiMaterial.ImmersiveMaterial | undefined,
    isDark: boolean = false,
    fallbackColor?: string
  ) {
    this.material = material;
    this.isDark = isDark;
    this.fallbackColor = fallbackColor;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    instance.backgroundColor(this.fallbackColor ?? resolveGlassCapsuleTintColor(this.isDark));
    instance.border({ width: 1, color: resolveGlassCapsuleBorderColor(this.isDark) });
    instance.shadow({
      radius: 24,
      color: resolveGlassCapsuleShadowColor(this.isDark),
      offsetX: 0,
      offsetY: 6
    });
    if (this.material !== undefined) {
      instance.systemMaterial(this.material);
    }
  }
}
