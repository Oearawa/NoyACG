/**
 * MaterialPolicy.test.ets —— 材质决策纯函数单测（p1-native-material-shell Task 2）
 *
 * 覆盖材质决策契约（plan 降级矩阵 + D10）：
 *   1. supported === true 且未禁用 → 'system'（走官方沉浸材质）；
 *   2. 能力被禁用（MaterialState.DISABLE / Material.empty / 配置关闭）→ 'solid' 纯色降级；
 *   3. 能力不支持（isImmersiveMaterialSupported() === false / API < 26）→ 'solid' 纯色降级；
 *   4. 决策结果只落在这两个值，无第三态。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  DETAIL_TOP_BAR_BLUR_FULL_VP,
  DETAIL_TOP_BAR_BLUR_START_VP,
  DetailTopBarVisualState,
  ImmersiveSurfaceTokens,
  ReaderSliderGlowState,
  SPATIAL_DIALOG_SCALE_FROM,
  SPATIAL_MENU_SCALE_FROM,
  SPATIAL_PRESS_SCALE,
  SPATIAL_SLIDER_ACTIVE_SCALE,
  SpatialTransitionSpec,
  materialDecision,
  resolveBarMaterialTokens,
  resolveDetailTopBarVisualState,
  resolveFloatingPillMaterialTokens,
  resolveGlassCapsuleBorderColor,
  resolveGlassCapsuleShadowColor,
  resolveGlassCapsuleTintColor,
  resolveMaterialAwareBackgroundColor,
  resolveMaterialAwareBorderWidth,
  resolvePanelMaterialTokens,
  resolveReaderSliderGlowState,
  resolveSegmentTrackBorderColor,
  resolveSegmentTrackTintColor,
  resolveSettingsPillBorderColor,
  resolveSettingsPillSurfaceColor,
  resolveSpatialTransitionSpec
} from '../main/ets/utils/MaterialPolicy';
import {
  ScaffoldTopBarDecoration,
  resolveScaffoldTopBarDecoration
} from '../main/ets/utils/StandardScaffoldLayout';

export default function materialPolicyTest(): void {
  describe('MaterialPolicy', () => {

    it('supportedAndEnabledUsesSystemMaterial', 0, () => {
      expect(materialDecision(true, false)).assertEqual('system');
    });

    it('disabledFallsBackToSolid', 0, () => {
      expect(materialDecision(true, true)).assertEqual('solid');
    });

    it('unsupportedFallsBackToSolid', 0, () => {
      expect(materialDecision(false, false)).assertEqual('solid');
      expect(materialDecision(false, true)).assertEqual('solid');
    });

    it('decisionHasNoThirdState', 0, () => {
      const samples: string[] = [
        materialDecision(true, false),
        materialDecision(true, true),
        materialDecision(false, false),
        materialDecision(false, true)
      ];
      for (let i = 0; i < samples.length; i++) {
        expect(samples[i] === 'system' || samples[i] === 'solid').assertTrue();
      }
    });

    it('immersiveSurfaceTokensAdaptToDarkAndLight', 0, () => {
      const darkBar: ImmersiveSurfaceTokens = resolveBarMaterialTokens(true);
      const lightBar: ImmersiveSurfaceTokens = resolveBarMaterialTokens(false);
      expect(darkBar.tier).assertEqual('bar');
      expect(lightBar.tier).assertEqual('bar');
      expect(darkBar.tintColor === lightBar.tintColor).assertFalse();
      expect(darkBar.foregroundStrongColor).assertEqual('#F8FAFC');
      expect(lightBar.foregroundStrongColor).assertEqual('#1E2430');
      expect(darkBar.borderColor !== '').assertTrue();
      expect(lightBar.borderColor !== '').assertTrue();

      const darkPanel: ImmersiveSurfaceTokens = resolvePanelMaterialTokens(true);
      const lightPanel: ImmersiveSurfaceTokens = resolvePanelMaterialTokens(false);
      expect(darkPanel.tier).assertEqual('panel');
      expect(lightPanel.tier).assertEqual('panel');
      expect(darkPanel.shadowRadius).assertLarger(darkBar.shadowRadius);
      expect(lightPanel.shadowRadius).assertLarger(lightBar.shadowRadius);

      const darkPill: ImmersiveSurfaceTokens = resolveFloatingPillMaterialTokens(true);
      const lightPill: ImmersiveSurfaceTokens = resolveFloatingPillMaterialTokens(false);
      expect(darkPill.tier).assertEqual('floatingPill');
      expect(lightPill.tier).assertEqual('floatingPill');
      expect(darkPill.solidFallbackColor === lightPill.solidFallbackColor).assertFalse();
    });

    it('detailTopBarVisualStateInterpolatesFrom0To96Vp', 0, () => {
      // 0vp 与 <= 8vp：全透明融入封面背景，不开启整栏模糊
      const atZero: DetailTopBarVisualState = resolveDetailTopBarVisualState(0, true);
      const atStart: DetailTopBarVisualState = resolveDetailTopBarVisualState(DETAIL_TOP_BAR_BLUR_START_VP, false);
      expect(atZero.blurProgress).assertEqual(0);
      expect(atZero.useBarBlur).assertFalse();
      expect(atZero.titleOpacity).assertEqual(0);
      expect(atZero.barBackgroundColor).assertEqual('#00000000');
      expect(atStart.blurProgress).assertEqual(0);
      expect(atStart.useBarBlur).assertFalse();

      // 中间态 52vp（8 -> 96vp 的中点）：blurProgress === 0.5
      const midVp: number = (DETAIL_TOP_BAR_BLUR_START_VP + DETAIL_TOP_BAR_BLUR_FULL_VP) / 2;
      const atMid: DetailTopBarVisualState = resolveDetailTopBarVisualState(midVp, false);
      expect(Math.abs(atMid.blurProgress - 0.5) < 0.001).assertTrue();
      expect(atMid.useBarBlur).assertTrue();
      expect(atMid.titleOpacity).assertLarger(0);
      expect(atMid.titleOpacity).assertLess(1);

      // >= 96vp：完全形成模糊背板与标题完全显现
      const atFull: DetailTopBarVisualState = resolveDetailTopBarVisualState(DETAIL_TOP_BAR_BLUR_FULL_VP, true);
      const beyond: DetailTopBarVisualState = resolveDetailTopBarVisualState(320, true);
      expect(atFull.blurProgress).assertEqual(1);
      expect(atFull.titleOpacity).assertEqual(1);
      expect(atFull.useBarBlur).assertTrue();
      expect(atFull.barBackgroundColor).assertEqual('#B8181B22');
      expect(beyond.blurProgress).assertEqual(1);

      // 非法输入安全钳制到 0
      const invalid: DetailTopBarVisualState = resolveDetailTopBarVisualState(Number.NaN, false);
      expect(invalid.blurProgress).assertEqual(0);
      expect(invalid.useBarBlur).assertFalse();
    });

    it('readerSliderGlowAndSpatialMotionSpecs', 0, () => {
      const dialogSpec: SpatialTransitionSpec = resolveSpatialTransitionSpec('dialog');
      const menuSpec: SpatialTransitionSpec = resolveSpatialTransitionSpec('menu');
      const sheetSpec: SpatialTransitionSpec = resolveSpatialTransitionSpec('sheet');
      const hudSpec: SpatialTransitionSpec = resolveSpatialTransitionSpec('hud');
      expect(dialogSpec.scaleFrom).assertEqual(SPATIAL_DIALOG_SCALE_FROM);
      expect(menuSpec.scaleFrom).assertEqual(SPATIAL_MENU_SCALE_FROM);
      expect(sheetSpec.scaleFrom).assertLarger(SPATIAL_DIALOG_SCALE_FROM);
      expect(hudSpec.springDamping).assertLarger(0.7);
      expect(SPATIAL_PRESS_SCALE).assertLess(1.0);

      // 常态滑块无光晕缩放
      const idleGlow: ReaderSliderGlowState = resolveReaderSliderGlowState(false, 5, 20, true);
      expect(idleGlow.isDragging).assertFalse();
      expect(idleGlow.glowShadowRadius).assertEqual(0);
      expect(idleGlow.trackScaleY).assertEqual(1.0);
      expect(idleGlow.progressRatio).assertEqual(0.25);

      // 拖拽态激活光晕半径与弹性放大
      const dragGlow: ReaderSliderGlowState = resolveReaderSliderGlowState(true, 10, 20, false);
      expect(dragGlow.isDragging).assertTrue();
      expect(dragGlow.glowShadowRadius).assertLarger(0);
      expect(dragGlow.trackScaleY).assertEqual(SPATIAL_SLIDER_ACTIVE_SCALE);
      expect(dragGlow.progressRatio).assertEqual(0.5);
      expect(dragGlow.glowShadowColor === '#00000000').assertFalse();
    });

    it('settingsPillColorsProvideHighContrastFillAndBorder', 0, () => {
      expect(resolveSettingsPillSurfaceColor(false, false)).assertEqual('#EEF1F6');
      expect(resolveSettingsPillSurfaceColor(false, true)).assertEqual('#E2E7F0');
      expect(resolveSettingsPillSurfaceColor(true, false)).assertEqual('#262A34');
      expect(resolveSettingsPillSurfaceColor(true, true)).assertEqual('#303643');
      expect(resolveSettingsPillBorderColor(false)).assertEqual('#DCE2EC');
      expect(resolveSettingsPillBorderColor(true)).assertEqual('#343946');
    });

    it('materialAwareSurfaceNeverOverlaysOpaqueBgOverSystemMaterial', 0, () => {
      // 三层光感玻璃契约：无论系统材质是否支持，均必须提供非透明玻璃基底色（Glass Tint）与 1vp 镜面高光描边，
      // 绝不返回全透明 '#00000000' 或 0 边框导致胶囊外壳隐形
      expect(resolveGlassCapsuleTintColor(false)).assertEqual('#D9FFFFFF');
      expect(resolveGlassCapsuleTintColor(true)).assertEqual('#D91E222B');
      expect(resolveGlassCapsuleBorderColor(false)).assertEqual('#E2E8F0');
      expect(resolveGlassCapsuleBorderColor(true)).assertEqual('#33FFFFFF');
      expect(resolveGlassCapsuleShadowColor(false)).assertEqual('#1A0F172A');
      expect(resolveGlassCapsuleShadowColor(true)).assertEqual('#73000000');
      expect(resolveSegmentTrackTintColor(false)).assertEqual('#EBF1F5F9');
      expect(resolveSegmentTrackTintColor(true)).assertEqual('#EB252934');
      expect(resolveSegmentTrackBorderColor(false)).assertEqual('#DCE3EE');
      expect(resolveSegmentTrackBorderColor(true)).assertEqual('#2E3442');

      expect(resolveMaterialAwareBackgroundColor(true, '#D91E222B')).assertEqual('#D91E222B');
      expect(resolveMaterialAwareBackgroundColor(true, '#D9FFFFFF')).assertEqual('#D9FFFFFF');
      expect(resolveMaterialAwareBorderWidth(true, 1)).assertEqual(1);
      expect(resolveMaterialAwareBackgroundColor(false, '#D91E222B')).assertEqual('#D91E222B');
      expect(resolveMaterialAwareBorderWidth(false, 1)).assertEqual(1);
    });

    it('scaffoldTopBarDecorationSupportsUnmaskedTransparentHeader', 0, () => {
      // 详情页 / 首页无遮罩顶栏：transparentHeader=true 时背景完全透明、0vp 底部分割线、不挂载顶栏遮罩材质
      const detailHeaderWithMat: ScaffoldTopBarDecoration = resolveScaffoldTopBarDecoration(true, true, '#D91E222B');
      const detailHeaderNoMat: ScaffoldTopBarDecoration = resolveScaffoldTopBarDecoration(true, false, '#D9FFFFFF');
      expect(detailHeaderWithMat.transparentHeader).assertTrue();
      expect(detailHeaderWithMat.backgroundColor).assertEqual('#00000000');
      expect(detailHeaderWithMat.bottomBorderWidthVp).assertEqual(0);
      expect(detailHeaderWithMat.useSystemMaterial).assertFalse();
      expect(detailHeaderNoMat.backgroundColor).assertEqual('#00000000');
      expect(detailHeaderNoMat.bottomBorderWidthVp).assertEqual(0);
      expect(detailHeaderNoMat.useSystemMaterial).assertFalse();

      // 普通二级页（transparentHeader=false）：无论系统材质是否启用，均保留玻璃基底色 + 1vp 边框
      const stdWithMat: ScaffoldTopBarDecoration = resolveScaffoldTopBarDecoration(false, true, '#D91E222B');
      expect(stdWithMat.transparentHeader).assertFalse();
      expect(stdWithMat.backgroundColor).assertEqual('#D91E222B');
      expect(stdWithMat.bottomBorderWidthVp).assertEqual(1);
      expect(stdWithMat.useSystemMaterial).assertTrue();

      const stdFallback: ScaffoldTopBarDecoration = resolveScaffoldTopBarDecoration(false, false, '#D91E222B');
      expect(stdFallback.backgroundColor).assertEqual('#D91E222B');
      expect(stdFallback.bottomBorderWidthVp).assertEqual(1);
      expect(stdFallback.useSystemMaterial).assertFalse();
    });

  });
}
