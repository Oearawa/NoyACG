/**
 * ContentRatingSelector.ets —— 设置页「内容类型」行（Phase 14-J1）
 *
 * 使用 API 26 原生 `Select`（下拉菜单）：菜单天然以触发控件为锚点，
 * 通过 `menuAlign(MenuAlignType.END)` 让弹出层右缘对齐触发控件，按空间自适应展开方向，
 * 点击外部/系统返回键由系统关闭 —— 不使用全局居中 CustomDialog 冒充下拉菜单。
 *
 * 三选项 ↔ 协议值映射：仅全年龄=false / 仅限制级=true / 显示全部=both（见 SettingsViewModel）。
 */
import { SettingsViewModel } from '../viewmodel/SettingsViewModel';
import { PreferenceManager } from '../utils/PreferenceManager';
import { CapsuleSelect } from './CapsuleSelect';
import { ThemeColors, ThemeFonts, ThemeDims } from '../utils/Theme';
import { LocalizationManager } from '../utils/LocalizationManager';
import { Logger } from '../utils/Logger';
import { LIST_ROW_LAYOUT, SETTINGS_TEXT_LAYOUT } from '../utils/ProfileLayout';

const TAG: string = 'ContentRatingSelector';

@ComponentV2
export struct ContentRatingSelector {
  @Local vm: SettingsViewModel = new SettingsViewModel();

  aboutToAppear(): void {
    this.vm.initialize();
  }

  build() {
    Row({ space: ThemeDims.SPACE_M }) {
      Column({ space: 3 }) {
        Text($r('app.string.settings_rating_title'))
          .fontSize(ThemeFonts.BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.TEXT)
          .width(SETTINGS_TEXT_LAYOUT.hintWidth)
          .textAlign(SETTINGS_TEXT_LAYOUT.hintTextAlign)
        Text($r('app.string.settings_rating_desc'))
          .fontSize(12)
          .fontColor(ThemeColors.TEXT_MUTED)
          .width(SETTINGS_TEXT_LAYOUT.hintWidth)
          .textAlign(SETTINGS_TEXT_LAYOUT.hintTextAlign)
          .maxLines(SETTINGS_TEXT_LAYOUT.hintMaxLines)
          .textOverflow({ overflow: SETTINGS_TEXT_LAYOUT.hintOverflow })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(LIST_ROW_LAYOUT.textColumnWeight)

      CapsuleSelect({
        label: this.labelRes(),
        options: [
          $r('app.string.rating_all_ages'),
          $r('app.string.rating_adult'),
          $r('app.string.rating_all')
        ],
        selectedIndex: this.vm.currentIndex(),
        onSelect: (index: number): void => {
          this.select(index);
        }
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 当前选项文案（资源，随系统语言解析） */
  private labelRes(): Resource {
    const index: number = this.vm.currentIndex();
    if (index === 1) {
      return $r('app.string.rating_adult');
    }
    if (index === 2) {
      return $r('app.string.rating_all');
    }
    return $r('app.string.rating_all_ages');
  }

  /** 失败提示（复用设置页「内容类型」文案 + 通用失败后缀） */
  private toastFailText(): string {
    return LocalizationManager.getInstance().getString($r('app.string.settings_rating_title'), '内容类型');
  }

  private select(index: number): void {
    if (index === this.vm.currentIndex()) {
      return;
    }
    if (index > 0) {
      try {
        const lm: LocalizationManager = LocalizationManager.getInstance();
        this.getUIContext().showAlertDialog({
          title: lm.getString($r('app.string.rating_confirm_title'), '开启限制级内容'),
          message: lm.getString(
            $r('app.string.rating_confirm_msg'),
            '请确认您已满 18 周岁，并自愿查看包含成人/限制级在内的全部内容。'
          ),
          autoCancel: true,
          alignment: DialogAlignment.Center,
          primaryButton: {
            value: lm.getString($r('app.string.common_cancel'), '取消'),
            action: () => {}
          },
          secondaryButton: {
            value: lm.getString($r('app.string.rating_confirm_btn'), '确认已满 18 岁并开启'),
            fontColor: ThemeColors.PRIMARY,
            action: () => {
              void PreferenceManager.getInstance().setCommunityAdultConfirmed(true);
              this.applySelection(index);
            }
          }
        });
        return;
      } catch (_e) {
        // 无 UI 上下文时降级直接应用（不标记社区成人确认）
      }
    }
    this.applySelection(index);
  }

  private applySelection(index: number): void {
    this.vm.selectIndex(index).then((ok: boolean) => {
      if (ok && this.vm.lastSwitchToast !== '') {
        this.toast(this.vm.lastSwitchToast);
      } else if (!ok && this.vm.errorMessage !== '') {
        Logger.warn(TAG, this.vm.errorMessage);
        this.toast(this.vm.errorMessage);
      }
    }).catch((e: Error) => {
      Logger.error(TAG, `内容类型切换异常: ${e.message}`);
      this.toast(LocalizationManager.getInstance().getString(
        $r('app.string.rating_switch_failed'),
        '内容类型切换失败'
      ));
    });
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (e) {
      Logger.warn(TAG, `Toast 展示失败: ${(e as Error).message}`);
    }
  }
}
