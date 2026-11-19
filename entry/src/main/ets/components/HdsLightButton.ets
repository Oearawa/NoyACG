/**
 * HdsLightButton.ets —— 全仓统一无边框光感胶囊按钮（@ComponentV2）
 *
 * 特性：
 * - 官方 Button({ type: ButtonType.Capsule, stateEffect: true }) + interactive ImmersiveMaterial；
 * - 零勾边（borderWidth: 0），支持 'neutral' | 'accentSoft' | 'accentSolid' | 'danger' 四态；
 * - 接入全仓统一非线性物理弹簧按压/回弹动效（SpringMotion）。
 */
import { uiMaterial } from '@kit.ArkUI';
import { buildInteractiveButtonMaterial } from '../utils/ImmersiveMaterial';
import {
  springPressCurve,
  springPressOpacity,
  springPressScale
} from '../utils/SpringMotion';
import { ThemeManager } from '../utils/ThemeManager';

export type HdsLightButtonVariant = 'neutral' | 'accentSoft' | 'accentSolid' | 'danger';

export function resolveHdsLightButtonTextColor(
  variant: HdsLightButtonVariant,
  isEnabled: boolean,
  theme: ThemeManager
): string {
  if (variant === 'accentSolid') {
    return theme.onAccent;
  }
  if (variant === 'accentSoft') {
    return theme.accent;
  }
  if (variant === 'danger') {
    return theme.isDark ? '#F87171' : '#DC2626';
  }
  return isEnabled ? theme.textPrimary : theme.textSecondary;
}

export function resolveHdsLightButtonBgColor(
  variant: HdsLightButtonVariant,
  theme: ThemeManager
): string {
  if (variant === 'accentSolid') {
    return theme.accent;
  }
  if (variant === 'accentSoft') {
    return theme.accentSoft;
  }
  if (variant === 'danger') {
    return theme.isDark ? '#3B1D22' : '#FEE2E2';
  }
  return theme.isDark ? '#252A36' : '#EEF2F6';
}

@ComponentV2
export struct HdsLightButton {
  @Param label: ResourceStr = '';
  @Param leadingIcon: Resource | undefined = undefined;
  @Param trailingIcon: Resource | undefined = undefined;
  @Param dotColor: string = '';
  @Param variant: HdsLightButtonVariant = 'neutral';
  @Param minWidthVp: number = 88;
  @Param heightVp: number = 34;
  @Param radiusVp: number = 17;
  @Param hPaddingVp: number = 14;
  @Param fontSizeFp: number = 13;
  @Param iconSizeVp: number = 12;
  @Param fullWidth: boolean = false;
  @Param isEnabled: boolean = true;
  @Param touchTargetHeightVp: number = 0;
  @Event onAction: () => void = (): void => {};

  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private isPressed: boolean = false;
  private readonly interactiveMaterial: uiMaterial.Material | undefined = buildInteractiveButtonMaterial();

  private resolveTextColor(): string {
    return resolveHdsLightButtonTextColor(this.variant, this.isEnabled, this.theme);
  }

  private touchOffsetY(): number {
    if (this.touchTargetHeightVp <= this.heightVp) {
      return 0;
    }
    return -(this.touchTargetHeightVp - this.heightVp) / 2;
  }

  build() {
    Button({ type: ButtonType.Capsule, stateEffect: this.isEnabled }) {
      Row({ space: 4 }) {
        if (this.dotColor !== '') {
          Column()
            .width(10)
            .height(10)
            .borderRadius(5)
            .backgroundColor(this.dotColor)
        }
        if (this.leadingIcon !== undefined) {
          SymbolGlyph(this.leadingIcon)
            .fontSize(this.iconSizeVp)
            .fontColor([this.resolveTextColor()])
        }
        if (this.label !== '') {
          Text(this.label)
            .fontSize(this.fontSizeFp)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.resolveTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.trailingIcon !== undefined) {
          SymbolGlyph(this.trailingIcon)
            .fontSize(this.iconSizeVp)
            .fontColor([this.resolveTextColor()])
        }
      }
      .padding({ left: this.hPaddingVp, right: this.hPaddingVp })
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Center)
    }
    .width(this.fullWidth ? '100%' : undefined)
    .constraintSize({ minWidth: this.fullWidth ? 0 : this.minWidthVp })
    .height(this.heightVp)
    .borderRadius(this.radiusVp)
    .buttonStyle(ButtonStyleMode.NORMAL)
    .backgroundColor(resolveHdsLightButtonBgColor(this.variant, this.theme))
    .borderWidth(0)
    .systemMaterial(this.interactiveMaterial)
    .scale({
      x: springPressScale(this.isPressed, this.isEnabled),
      y: springPressScale(this.isPressed, this.isEnabled)
    })
    .opacity(springPressOpacity(this.isPressed, this.isEnabled))
    .animation({ curve: springPressCurve(this.isPressed) })
    .responseRegion(this.touchTargetHeightVp > this.heightVp
      ? { x: 0, y: this.touchOffsetY(), width: '100%', height: this.touchTargetHeightVp }
      : undefined)
    .hitTestBehavior(this.isEnabled ? HitTestMode.Default : HitTestMode.None)
    .onTouch((event: TouchEvent): void => {
      if (!this.isEnabled) {
        this.isPressed = false;
        return;
      }
      if (event.type === TouchType.Down) {
        this.isPressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.isPressed = false;
      }
    })
    .onClick((): void => {
      if (this.isEnabled) {
        this.onAction();
      }
    })
  }
}
