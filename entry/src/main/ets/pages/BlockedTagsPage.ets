import { HdsNavDestination } from '@kit.UIDesignKit';
import { hdsTitleBarStyle } from '../utils/HdsMaterialPolicy';
/**
 * BlockedTagsPage.ets —— 屏蔽标签管理（Phase 14-R）
 *
 * 能力：
 * - 手动输入标签并加入黑名单（精确匹配，去重，空值拒绝）；
 * - 逐条移除、一键清空（二次确认）；
 * - 明确区分「本机匿名配置」与「按账号隔离的本地配置」——
 *   **没有云同步**：换设备不会带走，这与服务端是否提供同步接口无关（14-P 未发现该类接口）。
 *
 * 数据真相：BlockedTagManager → PreferenceManager（工程唯一偏好管理器）。
 * 页面不直接读 Preferences，也不自己做字符串匹配。
 */
import { EmptyState } from '../components/StatusViews';
import { BlockedTagManager } from '../utils/BlockedTagManager';
import { MAX_BLOCKED_TAGS } from '../utils/BlockedTags';
import { SafeAreaManager } from '../utils/SafeAreaManager';
import { LocalizationManager } from '../utils/LocalizationManager';
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import { Logger } from '../utils/Logger';
import { LIST_ROW_LAYOUT, SETTINGS_LAYOUT, SETTINGS_TEXT_LAYOUT } from '../utils/ProfileLayout';

const TAG: string = 'BlockedTagsPage';

@ComponentV2
export struct BlockedTagsPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  /** 输入框内容（仅页面本地状态，未提交前不落盘） */
  @Local input: string = '';
  @Local tags: string[] = [];
  @Local isSaving: boolean = false;
  @Local isAccountScope: boolean = false;
  @Local errorText: string = '';
  private manager: BlockedTagManager = BlockedTagManager.getInstance();
  private lm: LocalizationManager = LocalizationManager.getInstance();

  aboutToAppear(): void {
    this.manager.reload();
    this.syncFromManager();
  }

  private syncFromManager(): void {
    this.tags = this.manager.tags.slice();
    this.isSaving = this.manager.isSaving;
    this.isAccountScope = this.manager.isAccountScoped();
  }

  private text(res: Resource, fallback: string): string {
    return this.lm.getString(res, fallback);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (e) {
      Logger.warn(TAG, `Toast 展示失败: ${(e as Error).message}`);
    }
  }

  private async addTag(): Promise<void> {
    const value: string = this.input.trim();
    if (value === '') {
      this.errorText = this.text($r('app.string.blocked_invalid'), '请输入完整标签名称');
      return;
    }
    if (this.manager.isFull()) {
      this.errorText = this.lm.getString($r('app.string.blocked_limit'),
        '最多只能屏蔽 %d 个标签', MAX_BLOCKED_TAGS);
      return;
    }
    this.errorText = '';
    const ok: boolean = await this.manager.add(value);
    this.syncFromManager();
    if (!ok) {
      this.errorText = this.text($r('app.string.blocked_invalid'), '请输入完整标签名称');
      return;
    }
    this.input = '';
    if (this.manager.errorMessage === 'not_persisted') {
      this.toast(this.text($r('app.string.blocked_save_failed'), '已生效，但未能保存到本地'));
    }
  }

  private async removeTag(tag: string): Promise<void> {
    const ok: boolean = await this.manager.remove(tag);
    this.syncFromManager();
    if (!ok) {
      this.toast(this.text($r('app.string.blocked_save_failed'), '已生效，但未能保存到本地'));
    }
  }

  private confirmClear(): void {
    if (this.tags.length === 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: this.text($r('app.string.blocked_clear'), '清空屏蔽标签'),
      message: this.text($r('app.string.blocked_clear_confirm'),
        '将移除全部屏蔽标签，被过滤的内容会重新出现在首页、榜单与搜索中。'),
      autoCancel: true,
      primaryButton: {
        value: this.text($r('app.string.common_cancel'), '取消'),
        action: () => {
        }
      },
      secondaryButton: {
        value: this.text($r('app.string.common_confirm'), '确定'),
        fontColor: ThemeColors.ERROR,
        action: () => {
          this.doClear();
        }
      }
    });
  }

  private async doClear(): Promise<void> {
    await this.manager.clear();
    this.syncFromManager();
    this.errorText = '';
  }

  build() {
    HdsNavDestination() {
      Column() {
        Scroll() {
          Row() {
            Column({ space: SETTINGS_LAYOUT.groupSpacing }) {
              // 作用域说明：明确「仅本机、按账号隔离」，不暗示云同步
              Column({ space: 4 }) {
                Text(this.isAccountScope
                  ? $r('app.string.blocked_scope_account') : $r('app.string.blocked_scope_local'))
                  .fontSize(ThemeFonts.BODY_SMALL)
                  .fontColor(ThemeColors.TEXT_SECONDARY)
                  .width(SETTINGS_TEXT_LAYOUT.hintWidth)
                  .textAlign(SETTINGS_TEXT_LAYOUT.hintTextAlign)
                Text($r('app.string.blocked_scope_note'))
                  .fontSize(ThemeFonts.CAPTION + 1)
                  .fontColor(ThemeColors.TEXT_MUTED)
                  .width(SETTINGS_TEXT_LAYOUT.hintWidth)
                  .textAlign(SETTINGS_TEXT_LAYOUT.hintTextAlign)
              }
              .width('100%')
              .padding({ left: SETTINGS_LAYOUT.paddingHorizontal + 4, right: SETTINGS_LAYOUT.paddingHorizontal + 4 })
              .alignItems(SETTINGS_TEXT_LAYOUT.containerAlign)

              // 添加区
              Column({ space: 8 }) {
                TextInput({ placeholder: this.text($r('app.string.blocked_add_placeholder'), '输入完整标签名称'),
                  text: this.input })
                  .fontSize(ThemeFonts.BODY_SMALL)
                  .placeholderFont({ size: ThemeFonts.BODY_SMALL })
                  .backgroundColor(ThemeColors.SURFACE)
                  .fontColor(ThemeColors.TEXT)
                  .placeholderColor(ThemeColors.TEXT_MUTED)
                  .height(38)
                  .borderRadius(8)
                  .enterKeyType(EnterKeyType.Done)
                  .onChange((value: string) => {
                    this.input = value;
                    if (this.errorText !== '') {
                      this.errorText = '';
                    }
                  })
                  .onSubmit(() => {
                    this.addTag();
                  })

                if (this.errorText !== '') {
                  Text(this.errorText)
                    .fontSize(ThemeFonts.CAPTION + 1)
                    .fontColor(ThemeColors.ERROR)
                    .width(SETTINGS_TEXT_LAYOUT.hintWidth)
                    .textAlign(SETTINGS_TEXT_LAYOUT.hintTextAlign)
                }

                Row({ space: 8 }) {
                  Text($r('app.string.blocked_add'))
                    .fontSize(ThemeFonts.BODY_SMALL)
                    .fontColor(this.isSaving ? ThemeColors.TEXT_MUTED : ThemeColors.TEXT_SECONDARY)
                    .padding({
                      left: SETTINGS_LAYOUT.buttonPaddingH,
                      right: SETTINGS_LAYOUT.buttonPaddingH,
                      top: SETTINGS_LAYOUT.buttonPaddingV,
                      bottom: SETTINGS_LAYOUT.buttonPaddingV
                    })
                    .borderWidth(1)
                    .borderColor(ThemeColors.DIVIDER)
                    .borderRadius(SETTINGS_LAYOUT.buttonRadius)
                    .backgroundColor(ThemeColors.SURFACE)
                    .enabled(!this.isSaving)
                    .onClick(() => {
                      this.addTag();
                    })
                  Blank()
                  if (this.tags.length > 0) {
                    Text($r('app.string.blocked_clear'))
                      .fontSize(ThemeFonts.BODY_SMALL)
                      .fontColor(ThemeColors.TEXT_MUTED)
                      .padding({
                        left: SETTINGS_LAYOUT.buttonPaddingH,
                        right: SETTINGS_LAYOUT.buttonPaddingH,
                        top: SETTINGS_LAYOUT.buttonPaddingV,
                        bottom: SETTINGS_LAYOUT.buttonPaddingV
                      })
                      .onClick(() => {
                        this.confirmClear();
                      })
                  }
                }
                .width('100%')
                .alignItems(LIST_ROW_LAYOUT.verticalAlign)
              }
              .width('100%')
              .padding({
                left: SETTINGS_LAYOUT.paddingHorizontal,
                right: SETTINGS_LAYOUT.paddingHorizontal,
                top: SETTINGS_LAYOUT.paddingVertical,
                bottom: SETTINGS_LAYOUT.paddingVertical
              })
              .backgroundColor(ThemeColors.CARD)
              .borderRadius(SETTINGS_LAYOUT.cardRadius)
              .alignItems(SETTINGS_TEXT_LAYOUT.containerAlign)

              // 已屏蔽列表
              Column({ space: 0 }) {
                if (this.tags.length === 0) {
                  EmptyState({
                    icon: $r('sys.symbol.nosign'),
                    title: $r('app.string.blocked_empty'),
                    message: this.text($r('app.string.blocked_empty_desc'),
                      '还没有屏蔽任何标签。加入后，含该标签内容的列表会被过滤。')
                  })
                } else {
                  ForEach(this.tags, (tag: string, index: number) => {
                    Column({ space: 0 }) {
                      if (index > 0) {
                        Divider()
                          .color(ThemeColors.DIVIDER)
                          .strokeWidth(1)
                          .margin({
                            left: SETTINGS_LAYOUT.dividerInset,
                            right: SETTINGS_LAYOUT.dividerInset
                          })
                      }
                      Row({ space: 8 }) {
                        Text(tag)
                          .fontSize(ThemeFonts.BODY)
                          .fontColor(ThemeColors.TEXT)
                          .layoutWeight(LIST_ROW_LAYOUT.textColumnWeight)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text($r('app.string.blocked_remove'))
                          .fontSize(ThemeFonts.BODY_SMALL)
                          .fontColor(ThemeColors.TEXT_SECONDARY)
                          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                          .borderRadius(12)
                          .backgroundColor(ThemeColors.SURFACE)
                          .onClick(() => {
                            this.removeTag(tag);
                          })
                      }
                      .width('100%')
                      .constraintSize({ minHeight: SETTINGS_LAYOUT.rowMinHeight })
                      .padding({
                        left: SETTINGS_LAYOUT.paddingHorizontal,
                        right: SETTINGS_LAYOUT.paddingHorizontal,
                        top: SETTINGS_LAYOUT.rowPaddingVertical,
                        bottom: SETTINGS_LAYOUT.rowPaddingVertical
                      })
                      .alignItems(LIST_ROW_LAYOUT.verticalAlign)
                    }
                    .width('100%')
                  }, (tag: string) => tag)
                }
              }
              .width('100%')
              .backgroundColor(ThemeColors.CARD)
              .borderRadius(SETTINGS_LAYOUT.cardRadius)

              Column().width('100%').height(ThemeDims.SPACE_L)
            }
            .width('100%')
            .constraintSize({ maxWidth: ThemeDims.CONTENT_MAX_WIDTH })
            .padding({
              left: ThemeDims.PAGE_PADDING,
              right: ThemeDims.PAGE_PADDING,
              top: 8,
              bottom: 20
            })
            .alignItems(SETTINGS_TEXT_LAYOUT.containerAlign)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }
        .layoutWeight(LIST_ROW_LAYOUT.textColumnWeight)
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemeColors.BG)
    }
    .withTheme({ enableThemeColorMode: true })
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      content: { title: { mainTitle: $r('app.string.settings_block_tags') } },
      style: hdsTitleBarStyle()
    })
    .backgroundColor(ThemeColors.BG)
  }
}

/** 系统路由表构建函数：与 route_map.json 的 "BlockedTagsPageBuilder" 对应 */
@Builder
export function BlockedTagsPageBuilder(name: string, param?: object) {
  BlockedTagsPage()
}
