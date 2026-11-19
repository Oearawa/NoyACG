/**
 * CommunityCreatePostSheet.ets —— 社区发帖编辑器（阶段 3）
 *
 * - 标题非空校验、正文多行输入、快捷插入官方 [pack:name] 表情标签
 * - 3 列图片网格：PhotoViewPicker 选图 + 沙箱转存 + 无 Cookie 图床上传（最多 9 张）
 * - 三层沉浸光感玻璃弹窗与底部工具栏
 */
import { common } from '@kit.AbilityKit';
import { uiMaterial } from '@kit.ArkUI';
import { NoyClient } from '../api/NoyClient';
import {
  buildCreatePostImageList,
  CommunityDraftImage,
  MAX_COMMUNITY_IMAGES,
  pickAndCacheCommunityImages,
  UploadStatus
} from '../utils/CommunityMediaHelper';
import {
  appendStickerTag,
  canSubmitPost,
  COMMUNITY_QUICK_STICKERS,
  validatePostDraft
} from '../utils/CommunityWriteHelper';
import { buildBarImmersiveMaterial, buildPanelImmersiveMaterial } from '../utils/ImmersiveMaterial';
import {
  resolveGlassCapsuleBorderColor,
  resolveGlassCapsuleShadowColor,
  resolveGlassCapsuleTintColor
} from '../utils/MaterialPolicy';
import { ThemeColors } from '../utils/Theme';
import { ThemeManager } from '../utils/ThemeManager';
import { ViewportState } from '../utils/ViewportState';
import { LocalizationManager } from '../utils/LocalizationManager';

@ComponentV2
export struct CommunityCreatePostSheet {
  @Event onClose: () => void = (): void => {};
  @Event onCreated: () => void = (): void => {};

  @Local private titleText: string = '';
  @Local private contentText: string = '';
  @Local private images: CommunityDraftImage[] = [];
  @Local private showStickers: boolean = false;
  @Local private submitting: boolean = false;
  @Local private errorMsg: string = '';
  @Local private bottomAvoidVp: number = ViewportState.getInstance().bottomVp;
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();

  private readonly panelMaterial: uiMaterial.Material | undefined = buildPanelImmersiveMaterial();
  private readonly barMaterial: uiMaterial.Material | undefined = buildBarImmersiveMaterial();
  private disposed: boolean = false;

  aboutToDisappear(): void {
    this.disposed = true;
  }

  private updateImageAt(index: number, updater: (item: CommunityDraftImage) => CommunityDraftImage): void {
    if (index < 0 || index >= this.images.length) {
      return;
    }
    const copy: CommunityDraftImage[] = this.images.slice();
    copy[index] = updater(copy[index]);
    this.images = copy;
  }

  private async pickImages(): Promise<void> {
    const remain: number = MAX_COMMUNITY_IMAGES - this.images.length;
    if (remain <= 0) {
      return;
    }
    const hostContext: common.Context | undefined = this.getUIContext().getHostContext();
    if (hostContext === undefined) {
      this.errorMsg = this.lm.getString($r('app.string.community_err_ctx'), '无法获取应用上下文');
      return;
    }
    this.errorMsg = '';
    try {
      const picked: CommunityDraftImage[] = await pickAndCacheCommunityImages(hostContext, remain);
      if (picked.length === 0 || this.disposed) {
        return;
      }
      const startIndex: number = this.images.length;
      const merged: CommunityDraftImage[] = this.images.concat(picked);
      this.images = merged;
      for (let i = 0; i < picked.length; i++) {
        await this.uploadSingleAt(startIndex + i);
      }
    } catch (e) {
      this.errorMsg = e instanceof Error
        ? e.message : this.lm.getString($r('app.string.community_err_pick_img'), '选择图片失败');
    }
  }

  private async uploadSingleAt(index: number): Promise<void> {
    if (this.disposed || index < 0 || index >= this.images.length) {
      return;
    }
    const target: CommunityDraftImage = this.images[index];
    this.updateImageAt(index, (item: CommunityDraftImage): CommunityDraftImage => {
      const next: CommunityDraftImage = new CommunityDraftImage(
        item.id, item.localUri, item.cachePath, item.internalUri, item.contentType
      );
      next.status = UploadStatus.UPLOADING;
      return next;
    });

    try {
      const file: string = await NoyClient.getInstance().uploadImage(target.cachePath, target.contentType);
      if (this.disposed) {
        return;
      }
      const currentIdx: number = this.findImageIndexById(target.id);
      if (currentIdx >= 0) {
        this.updateImageAt(currentIdx, (item: CommunityDraftImage): CommunityDraftImage => {
          const next: CommunityDraftImage = new CommunityDraftImage(
            item.id, item.localUri, item.cachePath, item.internalUri, item.contentType
          );
          next.status = UploadStatus.SUCCESS;
          next.serverFile = file;
          return next;
        });
      }
    } catch (e) {
      if (this.disposed) {
        return;
      }
      const currentIdx: number = this.findImageIndexById(target.id);
      if (currentIdx >= 0) {
        const msg: string = e instanceof Error ? e.message : '上传失败';
        this.updateImageAt(currentIdx, (item: CommunityDraftImage): CommunityDraftImage => {
          const next: CommunityDraftImage = new CommunityDraftImage(
            item.id, item.localUri, item.cachePath, item.internalUri, item.contentType
          );
          next.status = UploadStatus.FAILED;
          next.errorMsg = msg;
          return next;
        });
      }
    }
  }

  private findImageIndexById(id: string): number {
    for (let i = 0; i < this.images.length; i++) {
      if (this.images[i].id === id) {
        return i;
      }
    }
    return -1;
  }

  private removeImageAt(index: number): void {
    if (index < 0 || index >= this.images.length) {
      return;
    }
    const copy: CommunityDraftImage[] = this.images.slice();
    copy.splice(index, 1);
    this.images = copy;
  }

  private async handleSubmit(): Promise<void> {
    const validationError: string = validatePostDraft(this.titleText, this.contentText);
    if (validationError !== '') {
      this.errorMsg = validationError;
      return;
    }
    if (!canSubmitPost(this.titleText, this.contentText, this.images, this.submitting)) {
      this.errorMsg = this.lm.getString($r('app.string.community_err_wait_upload'), '请等待图片上传完成或移除失败图片');
      return;
    }
    this.submitting = true;
    this.errorMsg = '';
    try {
      const files: string[] = buildCreatePostImageList(this.images);
      await NoyClient.getInstance().createPost(this.titleText.trim(), this.contentText.trim(), files);
      this.onCreated();
    } catch (e) {
      this.errorMsg = e instanceof Error
        ? e.message : this.lm.getString($r('app.string.community_err_publish'), '发布失败，请稍后重试');
    } finally {
      this.submitting = false;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick((): void => {
          if (!this.submitting) {
            this.onClose();
          }
        })

      Column({ space: 12 }) {
        Row() {
          Text($r('app.string.community_create_title'))
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
            if (!this.submitting) {
              this.onClose();
            }
          })
        }
        .width('100%')

        Scroll() {
          Column({ space: 10 }) {
            TextInput({ placeholder: this.lm.getString($r('app.string.community_create_title_ph'), '输入帖子标题（必填）'), text: this.titleText })
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

            TextArea({ placeholder: this.lm.getString($r('app.string.community_create_content_ph'), '分享你的想法、推漫或讨论...'), text: this.contentText })
              .height(130)
              .fontSize(14)
              .fontColor(ThemeColors.TEXT)
              .backgroundColor(ThemeColors.SURFACE)
              .borderRadius(12)
              .padding(12)
              .onChange((val: string): void => {
                this.contentText = val;
              })

            if (this.showStickers) {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(COMMUNITY_QUICK_STICKERS, (tag: string) => {
                  Text(tag)
                    .fontSize(12)
                    .fontColor(ThemeColors.PRIMARY)
                    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                    .borderRadius(12)
                    .backgroundColor(ThemeColors.SURFACE)
                    .margin({ right: 6, bottom: 6 })
                    .onClick((): void => {
                      this.contentText = appendStickerTag(this.contentText, tag);
                    })
                }, (tag: string): string => tag)
              }
              .width('100%')
            }

            // 3 列已选图片预览网格
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.images, (img: CommunityDraftImage, idx: number) => {
                Stack({ alignContent: Alignment.TopEnd }) {
                  Image(img.localUri)
                    .width('100%')
                    .height('100%')
                    .objectFit(ImageFit.Cover)

                  // 上传状态遮罩
                  if (img.status === UploadStatus.UPLOADING || img.status === UploadStatus.PENDING) {
                    Stack({ alignContent: Alignment.Center }) {
                      Text($r('app.string.community_uploading'))
                        .fontSize(11)
                        .fontColor('#FFFFFF')
                    }
                    .width('100%')
                    .height('100%')
                    .backgroundColor('#80000000')
                  } else if (img.status === UploadStatus.FAILED) {
                    Column({ space: 2 }) {
                      Text($r('app.string.community_upload_failed'))
                        .fontSize(11)
                        .fontColor('#FFFFFF')
                      Text($r('app.string.community_tap_retry'))
                        .fontSize(10)
                        .fontColor('#FFD166')
                    }
                    .width('100%')
                    .height('100%')
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor('#99000000')
                    .onClick((): void => {
                      void this.uploadSingleAt(idx);
                    })
                  }

                  // 删除角标
                  Stack({ alignContent: Alignment.Center }) {
                    SymbolGlyph($r('sys.symbol.xmark'))
                      .fontSize(12)
                      .fontColor(['#FFFFFF'])
                  }
                  .width(22)
                  .height(22)
                  .borderRadius(11)
                  .backgroundColor('#AA000000')
                  .margin(4)
                  .onClick((): void => {
                    this.removeImageAt(idx);
                  })
                }
                .width('31%')
                .aspectRatio(1)
                .margin({ right: idx % 3 === 2 ? 0 : '3.5%', bottom: 8 })
                .borderRadius(10)
                .clip(true)
              }, (img: CommunityDraftImage): string => `${img.id}_${img.status}`)

              if (this.images.length < MAX_COMMUNITY_IMAGES) {
                Column({ space: 4 }) {
                  SymbolGlyph($r('sys.symbol.plus'))
                    .fontSize(22)
                    .fontColor([ThemeColors.TEXT_SECONDARY])
                  Text(`${this.images.length}/${MAX_COMMUNITY_IMAGES}`)
                    .fontSize(11)
                    .fontColor(ThemeColors.TEXT_MUTED)
                }
                .width('31%')
                .aspectRatio(1)
                .margin({ bottom: 8 })
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .borderRadius(10)
                .backgroundColor(ThemeColors.SURFACE)
                .border({
                  width: 1,
                  color: resolveGlassCapsuleBorderColor(this.theme.isDark)
                })
                .onClick((): void => {
                  void this.pickImages();
                })
              }
            }
            .width('100%')

            if (this.errorMsg !== '') {
              Text(this.errorMsg)
                .fontSize(12)
                .fontColor(ThemeColors.ERROR)
                .width('100%')
            }
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)

        // 底部三层沉浸光感工具栏
        Row({ space: 10 }) {
          Row({ space: 5 }) {
            SymbolGlyph($r('sys.symbol.face_smiling'))
              .fontSize(18)
              .fontColor([this.showStickers ? ThemeColors.PRIMARY : ThemeColors.TEXT_SECONDARY])
            Text($r('app.string.community_emoji'))
              .fontSize(13)
              .fontColor(this.showStickers ? ThemeColors.PRIMARY : ThemeColors.TEXT_SECONDARY)
          }
          .padding({ left: 10, right: 10, top: 7, bottom: 7 })
          .borderRadius(16)
          .backgroundColor(ThemeColors.SURFACE)
          .onClick((): void => {
            this.showStickers = !this.showStickers;
          })

          Row({ space: 5 }) {
            SymbolGlyph($r('sys.symbol.picture'))
              .fontSize(18)
              .fontColor([ThemeColors.TEXT_SECONDARY])
            Text($r('app.string.community_image'))
              .fontSize(13)
              .fontColor(ThemeColors.TEXT_SECONDARY)
          }
          .padding({ left: 10, right: 10, top: 7, bottom: 7 })
          .borderRadius(16)
          .backgroundColor(ThemeColors.SURFACE)
          .onClick((): void => {
            void this.pickImages();
          })

          Blank()

          Text(this.submitting
            ? $r('app.string.community_publishing')
            : $r('app.string.community_publish'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.ON_PRIMARY)
            .padding({ left: 18, right: 18, top: 8, bottom: 8 })
            .borderRadius(18)
            .backgroundColor(canSubmitPost(this.titleText, this.contentText, this.images, this.submitting)
              ? ThemeColors.PRIMARY
              : ThemeColors.TEXT_MUTED)
            .onClick((): void => {
              void this.handleSubmit();
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .borderRadius(20)
        .backgroundColor(resolveGlassCapsuleTintColor(this.theme.isDark))
        .border({
          width: 1,
          color: resolveGlassCapsuleBorderColor(this.theme.isDark)
        })
        .shadow({
          radius: 16,
          color: resolveGlassCapsuleShadowColor(this.theme.isDark),
          offsetX: 0,
          offsetY: 4
        })
        .systemMaterial(this.barMaterial)
      }
      .width('100%')
      .height('82%')
      .padding({
        left: 16,
        right: 16,
        top: 16,
        bottom: Math.max(16, this.bottomAvoidVp + 8)
      })
      .borderRadius({ topLeft: 24, topRight: 24 })
      .backgroundColor(resolveGlassCapsuleTintColor(this.theme.isDark))
      .border({
        width: 1,
        color: resolveGlassCapsuleBorderColor(this.theme.isDark)
      })
      .shadow({
        radius: 24,
        color: resolveGlassCapsuleShadowColor(this.theme.isDark),
        offsetX: 0,
        offsetY: -4
      })
      .systemMaterial(this.panelMaterial)
    }
    .width('100%')
    .height('100%')
  }
}
