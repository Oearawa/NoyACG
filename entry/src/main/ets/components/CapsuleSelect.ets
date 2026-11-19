/**
 * CapsuleSelect.ets —— 统一无边框光感胶囊下拉触发器（@ComponentV2）
 *
 * 规范：34vp 高（compact 30vp）、borderWidth: 0、高对比度 textPrimary + 非线性物理弹簧按压动效。
 */
import { uiMaterial } from '@kit.ArkUI';
import { ThemeManager } from '../utils/ThemeManager';
import { buildInteractiveButtonMaterial } from '../utils/ImmersiveMaterial';
import { immersiveMenuOptions } from '../utils/ImmersiveMotion';
import {
  springPressCurve,
  springPressOpacity,
  springPressScale
} from '../utils/SpringMotion';

@ComponentV2
export struct CapsuleSelect {
  @Require @Param label: ResourceStr = '';
  @Require @Param options: ResourceStr[] = [];
  @Param selectedIndex: number = 0;
  @Param isEnabled: boolean = true;
  @Param compact: boolean = false;
  @Event onSelect: (index: number) => void = (_index: number): void => {};
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private isPressed: boolean = false;
  private readonly interactiveMaterial: uiMaterial.Material | undefined = buildInteractiveButtonMaterial();

  private menuElements(): Array<MenuElement> {
    const list: Array<MenuElement> = [];
    for (let i = 0; i < this.options.length; i++) {
      const idx: number = i;
      const opt: ResourceStr = this.options[i];
      list.push({
        value: opt,
        action: (): void => {
          this.onSelect(idx);
        }
      });
    }
    return list;
  }

  build() {
    Button({ type: ButtonType.Capsule, stateEffect: this.isEnabled }) {
      Row({ space: this.compact ? 3 : 4 }) {
        Text(this.label)
          .fontSize(this.compact ? 12 : 13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isEnabled ? this.theme.textPrimary : this.theme.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: this.compact ? 92 : 148 })
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(this.compact ? 11 : 12)
          .fontColor([this.isEnabled ? this.theme.textPrimary : this.theme.textSecondary])
      }
      .padding({ left: this.compact ? 9 : 14, right: this.compact ? 9 : 14 })
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Center)
    }
    .height(this.compact ? 30 : 34)
    .constraintSize({ minWidth: this.compact ? 0 : 88 })
    .borderRadius(this.compact ? 15 : 17)
    .buttonStyle(ButtonStyleMode.NORMAL)
    .backgroundColor(this.theme.isDark ? '#252A36' : '#EEF2F6')
    .borderWidth(0)
    .systemMaterial(this.interactiveMaterial)
    .scale({
      x: springPressScale(this.isPressed, this.isEnabled),
      y: springPressScale(this.isPressed, this.isEnabled)
    })
    .opacity(springPressOpacity(this.isPressed, this.isEnabled))
    .animation({ curve: springPressCurve(this.isPressed) })
    .hitTestBehavior(this.isEnabled ? HitTestMode.Default : HitTestMode.None)
    .onTouch((event: TouchEvent) => {
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
    .bindMenu(this.isEnabled ? this.menuElements() : [], immersiveMenuOptions(this.theme.isDark))
  }
}
