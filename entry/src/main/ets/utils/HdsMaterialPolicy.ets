import { hdsMaterial, SystemMaterialParams, TitleBarStyleOptions, HdsNavigationTitleBarStyle } from '@kit.UIDesignKit';
import { Logger } from './Logger';
import { uiMaterial } from '@kit.ArkUI';
import { ThemeColors } from './Theme';

// HDS owns device capability, theme adaptation and material fallback.
export const HDS_SYSTEM_MATERIAL: SystemMaterialParams = {
  materialType: hdsMaterial.MaterialType.ADAPTIVE,
  materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
};

/** 优先启用 HDS IMMERSIVE 光感玻璃材质，设备不支持时自动回退 ADAPTIVE */
export function resolveHdsSystemMaterial(): SystemMaterialParams {
  try {
    const types: hdsMaterial.MaterialType[] = hdsMaterial.getSystemMaterialTypes();
    if (types !== undefined && types.indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0) {
      return {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      };
    }
  } catch (_e) {
    // 忽略查询异常，回退 ADAPTIVE
  }
  return HDS_SYSTEM_MATERIAL;
}

// HDS scroll styles otherwise retain their default title colors after an app theme change.
export function hdsTitleBarStyle(): TitleBarStyleOptions {
  const titleStyle: HdsNavigationTitleBarStyle = {
    contentStyle: {
      titleStyle: {
        mainTitleColor: ThemeColors.TEXT_STRONG,
        subTitleColor: ThemeColors.TEXT_SECONDARY
      }
    }
  };
  return {
    systemMaterialEffect: resolveHdsSystemMaterial(),
    originalStyle: titleStyle,
    scrollEffectStyle: titleStyle
  };
}

let capabilityReported: boolean = false;

export function reportHdsMaterialSupport(): void {
  if (capabilityReported) {
    return;
  }
  capabilityReported = true;
  try {
    const types: hdsMaterial.MaterialType[] = hdsMaterial.getSystemMaterialTypes();
    Logger.info('HdsMaterial', `system material types=${types.join(',')}; policy=ADAPTIVE`);
    Logger.info('HdsMaterial', `ArkUI supported=${uiMaterial.isImmersiveMaterialSupported()} state=${uiMaterial.getMaterialInfo().state}`);
  } catch (e) {
    Logger.warn('HdsMaterial', 'Material capability query failed; HDS retains its ADAPTIVE fallback');
  }
}
