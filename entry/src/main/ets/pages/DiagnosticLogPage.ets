import { HdsNavDestination } from '@kit.UIDesignKit';
import { hdsTitleBarStyle } from '../utils/HdsMaterialPolicy';
/**
 * DiagnosticLogPage.ets —— 应用内错误报告（Phase 14-R）
 *
 * 展示 DiagnosticLogManager 收集的 error / warn：
 * 时间、模块、级别、摘要；点击展开脱敏后的堆栈；支持筛选、导出、清空。
 *
 * 诚实的边界（页面内也写明）：
 * - 只覆盖「本应用主动记录的异常」与 ArkTS 未捕获异常回调；
 * - Native 进程崩溃 / 系统级故障不在本页能力范围，仍需系统日志；
 * - 不自动上传，导出文件保存在应用沙盒 `filesDir/exports/`。
 */
import { SegmentSelector } from '../components/SegmentSelector';
import { EmptyState } from '../components/StatusViews';
import { HdsLightButton } from '../components/HdsLightButton';
import {
  DiagnosticLogEntry,
  DiagnosticLogManager,
  LOG_LEVEL_ERROR,
  LOG_LEVEL_WARN
} from '../utils/DiagnosticLogManager';
import { LogExportResult, LogExportStatus } from '../utils/LogStore';
import { SafeAreaManager } from '../utils/SafeAreaManager';
import { LocalizationManager } from '../utils/LocalizationManager';
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import { Logger } from '../utils/Logger';
import { LIST_ROW_LAYOUT, SETTINGS_LAYOUT, SETTINGS_TEXT_LAYOUT } from '../utils/ProfileLayout';

const TAG: string = 'DiagnosticLogPage';

@ComponentV2
export struct DiagnosticLogPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  /** 0 = 全部，1 = 错误，2 = 警告 */
  @Local filterIndex: number = 0;
  @Local entries: DiagnosticLogEntry[] = [];
  @Local expandedId: string = '';
  @Local exporting: boolean = false;
  private manager: DiagnosticLogManager = DiagnosticLogManager.getInstance();
  private lm: LocalizationManager = LocalizationManager.getInstance();

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    const level: string = this.filterIndex === 1 ? LOG_LEVEL_ERROR
      : (this.filterIndex === 2 ? LOG_LEVEL_WARN : '');
    this.entries = this.manager.list(level);
  }

  private filterLabels(): string[] {
    return [
      this.lm.getString($r('app.string.diag_filter_all'), '全部'),
      this.lm.getString($r('app.string.diag_filter_error'), '错误'),
      this.lm.getString($r('app.string.diag_filter_warn'), '警告')
    ];
  }

  private text(res: Resource, fallback: string): string {
    return this.lm.getString(res, fallback);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
    } catch (e) {
      Logger.warn(TAG, `Toast 展示失败: ${(e as Error).message}`);
    }
  }

  private async doExport(): Promise<void> {
    if (this.exporting) {
      return;
    }
    this.exporting = true;
    try {
      const result: LogExportResult =
        await this.manager.exportWithPicker(this.getUIContext().getHostContext());
      if (result.status === LogExportStatus.CANCELED) {
        this.toast(this.text($r('app.string.log_export_cancelled'), '已取消导出'));
        return;
      }
      if (result.status === LogExportStatus.SUCCESS) {
        this.toast(this.text($r('app.string.diag_export_success'), '错误报告已导出'));
        return;
      }
      this.toast(this.text($r('app.string.diag_export_failed'), '导出失败，请稍后重试'));
    } finally {
      this.exporting = false;
    }
  }

  private confirmClear(): void {
    if (this.entries.length === 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: this.text($r('app.string.diag_clear'), '清空日志'),
      message: this.text($r('app.string.diag_clear_confirm'), '清空后无法恢复，确定继续？'),
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
    this.expandedId = '';
    this.reload();
  }

  build() {
    HdsNavDestination() {
      Column() {
        Scroll() {
          Row() {
            Column({ space: SETTINGS_LAYOUT.groupSpacing }) {
              Column({ space: 8 }) {
                SegmentSelector({
                  labels: this.filterLabels(),
                  selectedIndex: this.filterIndex,
                  onSelect: (index: number): void => {
                    this.filterIndex = index;
                    this.expandedId = '';
                    this.reload();
                  }
                })
                Text(this.lm.getString($r('app.string.diag_capability_note'),
                  '仅记录影响正常使用的程序异常，方便排查问题'))
                  .fontSize(ThemeFonts.CAPTION + 1)
                  .fontColor(ThemeColors.TEXT_MUTED)
                  .width(SETTINGS_TEXT_LAYOUT.hintWidth)
                  .textAlign(SETTINGS_TEXT_LAYOUT.hintTextAlign)
                Row({ space: 8 }) {
                  HdsLightButton({
                    label: $r('app.string.diag_export'),
                    variant: 'neutral',
                    isEnabled: !this.exporting,
                    onAction: () => {
                      this.doExport();
                    }
                  })
                  Blank()
                  if (this.entries.length > 0) {
                    Text($r('app.string.diag_clear'))
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

              Column({ space: 0 }) {
                if (this.entries.length === 0) {
                  EmptyState({
                    icon: $r('sys.symbol.exclamationmark_triangle'),
                    title: $r('app.string.diag_empty'),
                    message: this.text($r('app.string.diag_empty_desc'),
                      '运行正常，暂无异常记录')
                  })
                } else {
                  ForEach(this.entries, (entry: DiagnosticLogEntry, index: number) => {
                    Column({ space: 4 }) {
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
                        Text(entry.level === LOG_LEVEL_ERROR ? 'E' : 'W')
                          .fontSize(ThemeFonts.CAPTION)
                          .fontWeight(FontWeight.Bold)
                          .fontColor(entry.level === LOG_LEVEL_ERROR ? ThemeColors.ERROR : ThemeColors.RATING)
                        Text(entry.timeText())
                          .fontSize(ThemeFonts.CAPTION + 1)
                          .fontColor(ThemeColors.TEXT_MUTED)
                        Text(entry.module)
                          .fontSize(ThemeFonts.CAPTION + 1)
                          .fontColor(ThemeColors.TEXT_SECONDARY)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .layoutWeight(LIST_ROW_LAYOUT.textColumnWeight)
                      }
                      .width('100%')
                      .alignItems(LIST_ROW_LAYOUT.verticalAlign)

                      Text(entry.summary())
                        .fontSize(ThemeFonts.BODY_SMALL)
                        .fontColor(ThemeColors.TEXT)
                        .width(SETTINGS_TEXT_LAYOUT.hintWidth)
                        .textAlign(SETTINGS_TEXT_LAYOUT.hintTextAlign)

                      if (this.expandedId === entry.id && entry.stack !== '') {
                        Text(entry.stack)
                          .fontSize(ThemeFonts.CAPTION)
                          .fontColor(ThemeColors.TEXT_MUTED)
                          .width(SETTINGS_TEXT_LAYOUT.hintWidth)
                          .textAlign(SETTINGS_TEXT_LAYOUT.hintTextAlign)
                          .padding({ top: 4 })
                      }
                    }
                    .width('100%')
                    .padding({
                      left: SETTINGS_LAYOUT.paddingHorizontal,
                      right: SETTINGS_LAYOUT.paddingHorizontal,
                      top: SETTINGS_LAYOUT.rowPaddingVertical,
                      bottom: SETTINGS_LAYOUT.rowPaddingVertical
                    })
                    .alignItems(SETTINGS_TEXT_LAYOUT.containerAlign)
                    .onClick(() => {
                      if (entry.stack === '') {
                        return;
                      }
                      this.expandedId = this.expandedId === entry.id ? '' : entry.id;
                    })
                  }, (entry: DiagnosticLogEntry) => entry.id)
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
      content: { title: { mainTitle: $r('app.string.adv_report') } },
      style: hdsTitleBarStyle()
    })
    .backgroundColor(ThemeColors.BG)
  }
}

/** 系统路由表构建函数：与 route_map.json 的 "DiagnosticLogPageBuilder" 对应 */
@Builder
export function DiagnosticLogPageBuilder(name: string, param?: object) {
  DiagnosticLogPage()
}
