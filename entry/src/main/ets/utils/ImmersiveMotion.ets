/**
 * ImmersiveMotion.ets —— 官方沉浸式空间动效与菜单光感工厂
 *
 * 统一封装：
 * - spatialDialogTransition()：居中弹窗 0.90 -> 1.0 空间缩放 + 弹簧阻尼转场；
 * - spatialSheetTransition()：半屏/侧边面板边缘滑动 + 空间弹性展开；
 * - spatialMenuTransition()：锚点下拉/筛选菜单 0.92 -> 1.0 弹簧弹出；
 * - spatialHudTransition()：阅读器上下控栏空间唤出与收起；
 * - immersiveMenuOptions()：挂载官方 uiMaterial.ImmersiveMaterial 与高光描边的菜单样式。
 */
import { curves } from '@kit.ArkUI';
import {
  ImmersiveSurfaceTokens,
  SpatialTransitionSpec,
  resolveBarMaterialTokens,
  resolveSpatialTransitionSpec
} from './MaterialPolicy';
import { buildImmersiveMaterial } from './ImmersiveMaterial';

/** 空间化弹窗弹出转场（0.90 -> 1.0 + springMotion） */
export function spatialDialogTransition(): TransitionEffect {
  const spec: SpatialTransitionSpec = resolveSpatialTransitionSpec('dialog');
  return TransitionEffect.OPACITY
    .combine(TransitionEffect.scale({ x: spec.scaleFrom, y: spec.scaleFrom }))
    .animation({ curve: curves.springMotion(spec.springResponse, spec.springDamping) });
}

/** 空间化菜单弹出转场（0.92 -> 1.0 + springMotion） */
export function spatialMenuTransition(): TransitionEffect {
  const spec: SpatialTransitionSpec = resolveSpatialTransitionSpec('menu');
  return TransitionEffect.OPACITY
    .combine(TransitionEffect.scale({ x: spec.scaleFrom, y: spec.scaleFrom }))
    .animation({ curve: curves.springMotion(spec.springResponse, spec.springDamping) });
}

/** 空间化面板滑入转场（底部设置浮层 / 侧边章节抽屉） */
export function spatialSheetTransition(edge: TransitionEdge = TransitionEdge.BOTTOM): TransitionEffect {
  const spec: SpatialTransitionSpec = resolveSpatialTransitionSpec('sheet');
  return TransitionEffect.move(edge)
    .combine(TransitionEffect.OPACITY)
    .animation({ curve: curves.springMotion(spec.springResponse, spec.springDamping) });
}

/** 阅读器顶部/底部控制栏空间唤出转场（快速响应弹簧曲线，零迟滞跟手） */
export function spatialHudTransition(isTop: boolean): TransitionEffect {
  const shiftY: number = isTop ? -8 : 8;
  return TransitionEffect.OPACITY
    .combine(TransitionEffect.translate({ y: shiftY }))
    .combine(TransitionEffect.scale({ x: 0.98, y: 0.98 }))
    .animation({ curve: curves.springMotion(0.22, 0.88) });
}

/** 沉浸式下拉菜单样式（官方 systemMaterial + 1vp 边缘高光描边 + 空间弹出动画） */
export function immersiveMenuOptions(isDark: boolean): MenuOptions {
  const tokens: ImmersiveSurfaceTokens = resolveBarMaterialTokens(isDark);
  const material = buildImmersiveMaterial();
  return {
    systemMaterial: material,
    backgroundColor: material === undefined ? tokens.solidFallbackColor : undefined,
    outlineWidth: '1vp',
    outlineColor: tokens.borderColor,
    transition: spatialMenuTransition()
  };
}
