/**
 * SegmentSelector.ets —— 轻量级无边框胶囊分段选择器（纯 V2 实现）
 *
 * 严格单选高亮（仅当前 selectedIndex 显示主题强调底色，其余透明），
 * 轨道零勾边（borderWidth: 0），接入非线性物理弹簧按压动效。
 */
import { ThemeManager } from '../utils/ThemeManager';
import { buildPillImmersiveMaterial } from '../utils/ImmersiveMaterial';
import { resolveSegmentTrackTintColor } from '../utils/MaterialPolicy';
import {
  springPressCurve,
  springPressOpacity,
  springPressScale
} from '../utils/SpringMotion';

@ComponentV2
export struct SegmentSelector {
  @Param labels: string[] = [];
  @Param selectedIndex: number = 0;
  @Param compact: boolean = false;
  @Event onSelect: (index: number) => void = (_index: number) => {};
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private pressedIndex: number = -1;
  private readonly material = buildPillImmersiveMaterial();

  private normalizedSelectedIndex(): number {
    if (this.selectedIndex < 0 || this.selectedIndex >= this.labels.length) {
      return 0;
    }
    return this.selectedIndex;
  }

  build() {
    Row() {
      ForEach(this.labels, (label: string, index: number) => {
        Text(label)
          .fontSize(this.compact ? 12 : 13)
          .minFontSize(10)
          .maxFontSize(this.compact ? 12 : 13)
          .fontWeight(index === this.normalizedSelectedIndex() ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(index === this.normalizedSelectedIndex()
            ? this.theme.onAccent
            : this.theme.textPrimary)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .height(this.compact ? 26 : 30)
          .layoutWeight(1)
          .padding({ left: 6, right: 6 })
          .borderRadius(this.compact ? 13 : 15)
          .backgroundColor(index === this.normalizedSelectedIndex()
            ? this.theme.accent
            : Color.Transparent)
          .scale({
            x: springPressScale(this.pressedIndex === index),
            y: springPressScale(this.pressedIndex === index)
          })
          .opacity(springPressOpacity(this.pressedIndex === index))
          .animation({ curve: springPressCurve(this.pressedIndex === index) })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.pressedIndex = index;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.pressedIndex = -1;
            }
          })
          .onClick(() => {
            if (index !== this.normalizedSelectedIndex()) {
              this.onSelect(index);
            }
          })
      }, (label: string, index: number) => `${index}_${label}`)
    }
    .width('100%')
    .padding(this.compact ? 2 : 4)
    .backgroundColor(resolveSegmentTrackTintColor(this.theme.isDark))
    .borderWidth(0)
    .systemMaterial(this.material)
    .borderRadius(this.compact ? 15 : 19)
  }
}
