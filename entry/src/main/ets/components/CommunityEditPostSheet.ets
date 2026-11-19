/**
 * CommunityEditPostSheet.ets —— 作者编辑帖子弹窗（阶段 3）
 *
 * - 预填当前标题与正文（服务端接口不支持修改图片）
 * - 提交调用 NoyClient.editPost(id, title, content)，成功后回调刷新详情
 */
import { uiMaterial } from '@kit.ArkUI';
import { NoyClient } from '../api/NoyClient';
import { validatePostDraft } from '../utils/CommunityWriteHelper';
import { buildPanelImmersiveMaterial } from '../utils/ImmersiveMaterial';
import {
  resolveGlassCapsuleBorderColor,
  resolveGlassCapsuleShadowColor,
  resolveGlassCapsuleTintColor
} from '../utils/MaterialPolicy';
import { ThemeColors } from '../utils/Theme';
import { ThemeManager } from '../utils/ThemeManager';
import { LocalizationManager } from '../utils/LocalizationManager';

@ComponentV2
export struct CommunityEditPostSheet {
  @Param postId: number = 0;
  @Param initialTitle: string = '';
  @Param initialContent: string = '';
  @Event onClose: () => void = (): void => {};
  @Event onSaved: () => void = (): void => {};

  @Local private titleText: string = '';
  @Local private contentText: string = '';
  @Local private saving: boolean = false;
  @Local private errorMsg: string = '';
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();

  private readonly panelMaterial: uiMaterial.Material | undefined = buildPanelImmersiveMaterial();

  aboutToAppear(): void {
    this.titleText = this.initialTitle;
    this.contentText = this.initialContent;
  }

  private async handleSave(): Promise<void> {
    const validationError: string = validatePostDraft(this.titleText, this.contentText);
    if (validationError !== '') {
      this.errorMsg = validationError;
      return;
    }
    if (this.saving || this.postId <= 0) {
      return;
    }
    this.saving = true;
    this.errorMsg = '';
    try {
      await NoyClient.getInstance().editPost(this.postId, this.titleText.trim(), this.contentText.trim());
      this.onSaved();
    } catch (e) {
      this.errorMsg = e instanceof Error
        ? e.message : this.lm.getString($r('app.string.community_err_save'), '保存失败，请稍后重试');
    } finally {
      this.saving = false;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick((): void => {
          if (!this.saving) {
            this.onClose();
          }
        })

      Column({ space: 12 }) {
        Row() {
          Text($r('app.string.community_edit_title'))
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.TEXT)
            .layoutWeight(1)

          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(18)
              .fontColor([ThemeColors.TEXT_SECONDARY])
          }
          .width(32)
          .height(32)
          .borderRadius(16)
          .backgroundColor(ThemeColors.SURFACE)
          .onClick((): void => {
            if (!this.saving) {
              this.onClose();
            }
          })
        }
        .width('100%')

        Text($r('app.string.community_edit_note'))
          .fontSize(11)
          .fontColor(ThemeColors.TEXT_MUTED)
          .width('100%')

        TextInput({ placeholder: this.lm.getString($r('app.string.community_edit_title_ph'), '输入帖子标题'), text: this.titleText })
          .height(42)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.TEXT)
          .backgroundColor(ThemeColors.SURFACE)
          .borderRadius(12)
          .padding({ left: 12, right: 12 })
          .onChange((val: string): void => {
            this.titleText = val;
          })

        TextArea({ placeholder: this.lm.getString($r('app.string.community_edit_content_ph'), '输入帖子正文'), text: this.contentText })
          .height(150)
          .fontSize(14)
          .fontColor(ThemeColors.TEXT)
          .backgroundColor(ThemeColors.SURFACE)
          .borderRadius(12)
          .padding(12)
          .onChange((val: string): void => {
            this.contentText = val;
          })

        if (this.errorMsg !== '') {
          Text(this.errorMsg)
            .fontSize(12)
            .fontColor(ThemeColors.ERROR)
            .width('100%')
        }

        Row({ space: 12 }) {
          Text($r('app.string.common_cancel'))
            .fontSize(14)
            .fontColor(ThemeColors.TEXT_SECONDARY)
            .padding({ left: 16, right: 16, top: 9, bottom: 9 })
            .borderRadius(18)
            .backgroundColor(ThemeColors.SURFACE)
            .onClick((): void => {
              if (!this.saving) {
                this.onClose();
              }
            })

          Text(this.saving
            ? $r('app.string.community_saving')
            : $r('app.string.community_save_changes'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.ON_PRIMARY)
            .padding({ left: 18, right: 18, top: 9, bottom: 9 })
            .borderRadius(18)
            .backgroundColor(validatePostDraft(this.titleText, this.contentText) === '' && !this.saving
              ? ThemeColors.PRIMARY
              : ThemeColors.TEXT_MUTED)
            .onClick((): void => {
              void this.handleSave();
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
      }
      .width('90%')
      .constraintSize({ maxWidth: 420 })
      .padding(20)
      .borderRadius(22)
      .backgroundColor(resolveGlassCapsuleTintColor(this.theme.isDark))
      .border({
        width: 1,
        color: resolveGlassCapsuleBorderColor(this.theme.isDark)
      })
      .shadow({
        radius: 24,
        color: resolveGlassCapsuleShadowColor(this.theme.isDark),
        offsetX: 0,
        offsetY: 8
      })
      .systemMaterial(this.panelMaterial)
    }
    .width('100%')
    .height('100%')
  }
}
