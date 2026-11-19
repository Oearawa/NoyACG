import { HdsNavDestination } from '@kit.UIDesignKit';
import { hdsTitleBarStyle } from '../utils/HdsMaterialPolicy';
/**
 * NetworkLogPage.ets —— 应用内网络请求日志（Phase 14-R）
 *
 * 展示本应用发出的 HTTP 请求元数据：时间、方法、脱敏路径、HTTP 状态、耗时、错误。
 * 支持按状态筛选、按接口路径搜索、导出与清空。
 *
 * 明确不是抓包：不记录 Header / Cookie / 请求响应正文，不做 MITM / 证书安装 / 其他应用流量。
 */
import { SegmentSelector } from '../components/SegmentSelector';
import { EmptyState } from '../components/StatusViews';
import { HdsLightButton } from '../components/HdsLightButton';
import {
  NET_FILTER_ALL,
  NET_FILTER_ERROR,
  NET_FILTER_OK,
  NetworkLogEntry,
  NetworkLogManager
} from '../utils/NetworkLogManager';
import { LogExportResult, LogExportStatus } from '../utils/LogStore';
import { SafeAreaManager } from '../utils/SafeAreaManager';
import { LocalizationManager } from '../utils/LocalizationManager';
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import { Logger } from '../utils/Logger';
import { LIST_ROW_LAYOUT, SETTINGS_LAYOUT, SETTINGS_TEXT_LAYOUT } from '../utils/ProfileLayout';

const TAG: string = 'NetworkLogPage';

@ComponentV2
export struct NetworkLogPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  /** 0 = 全部，1 = 仅失败，2 = 仅成功 */
  @Local filterIndex: number = 0;
  @Local keyword: string = '';
  @Local entries: NetworkLogEntry[] = [];
  @Local exporting: boolean = false;
  private manager: NetworkLogManager = NetworkLogManager.getInstance();
  private lm: LocalizationManager = LocalizationManager.getInstance();

  aboutToAppear(): void {
    this.reload();
  }

  private filterValue(): string {
    if (this.filterIndex === 1) {
      return NET_FILTER_ERROR;
    }
    if (this.filterIndex === 2) {
      return NET_FILTER_OK;
    }
    return NET_FILTER_ALL;
  }

  private reload(): void {
    this.entries = this.manager.list(this.filterValue(), this.keyword);
  }

  private filterLabels(): string[] {
    return [
      this.lm.getString($r('app.string.net_filter_all'), '全部'),
      this.lm.getString($r('app.string.net_filter_error'), '失败'),
      this.lm.getString($r('app.string.net_filter_ok'), '成功')
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
        this.toast(this.text($r('app.string.net_export_success'), '网络日志已导出'));
        return;
      }
      this.toast(this.text($r('app.string.net_export_failed'), '导出失败，请稍后重试'));
    } finally {
      this.exporting = false;
    }
  }

  private confirmClear(): void {
    if (this.entries.length === 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: this.text($r('app.string.net_clear'), '清空日志'),
      message: this.text($r('app.string.net_clear_confirm'), '清空后无法恢复，确定继续？'),
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
    this.reload();
  }

  private statusColor(entry: NetworkLogEntry): string {
    return entry.ok ? ThemeColors.TEXT_SECONDARY : ThemeColors.ERROR;
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
                    this.reload();
                  }
                })
                TextInput({ placeholder: this.text($r('app.string.net_search_hint'), '按接口路径搜索'),
                  text: this.keyword })
                  .fontSize(ThemeFonts.BODY_SMALL)
                  .placeholderFont({ size: ThemeFonts.BODY_SMALL })
                  .backgroundColor(ThemeColors.SURFACE)
                  .fontColor(ThemeColors.TEXT)
                  .placeholderColor(ThemeColors.TEXT_MUTED)
                  .height(38)
                  .borderRadius(8)
                  .onChange((value: string) => {
                    this.keyword = value;
                    this.reload();
                  })
                Text(this.text($r('app.string.net_privacy_note'),
                  '仅记录接口访问状态与耗时，用于排查加载失败问题，不包含账号密码及隐私信息'))
                  .fontSize(ThemeFonts.CAPTION + 1)
                  .fontColor(ThemeColors.TEXT_MUTED)
                  .width(SETTINGS_TEXT_LAYOUT.hintWidth)
                  .textAlign(SETTINGS_TEXT_LAYOUT.hintTextAlign)
                Row({ space: 8 }) {
                  HdsLightButton({
                    label: $r('app.string.net_export'),
                    variant: 'neutral',
                    isEnabled: !this.exporting,
                    onAction: () => {
                      this.doExport();
                    }
                  })
                  Blank()
                  if (this.entries.length > 0) {
                    Text($r('app.string.net_clear'))
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
                    icon: $r('sys.symbol.wifi_slash'),
                    title: $r('app.string.net_empty'),
                    message: this.text($r('app.string.net_empty_desc'),
                      '还没有请求记录。打开首页或刷新列表后会自动出现。')
                  })
                } else {
                  ForEach(this.entries, (entry: NetworkLogEntry, index: number) => {
                    Column({ space: 3 }) {
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
                        Text(entry.method)
                          .fontSize(ThemeFonts.CAPTION)
                          .fontColor(ThemeColors.TEXT_MUTED)
                        Text(entry.path)
                          .fontSize(ThemeFonts.BODY_SMALL)
                          .fontColor(ThemeColors.TEXT)
                          .layoutWeight(LIST_ROW_LAYOUT.textColumnWeight)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(entry.statusText())
                          .fontSize(ThemeFonts.CAPTION + 1)
                          .fontColor(this.statusColor(entry))
                      }
                      .width('100%')
                      .alignItems(LIST_ROW_LAYOUT.verticalAlign)

                      Row({ space: 8 }) {
                        Text(entry.timeText())
                          .fontSize(ThemeFonts.CAPTION)
                          .fontColor(ThemeColors.TEXT_MUTED)
                        Text(`${entry.durationMs} ms`)
                          .fontSize(ThemeFonts.CAPTION)
                          .fontColor(ThemeColors.TEXT_MUTED)
                        if (entry.error !== '') {
                          Text(entry.error)
                            .fontSize(ThemeFonts.CAPTION)
                            .fontColor(ThemeColors.ERROR)
                            .layoutWeight(LIST_ROW_LAYOUT.textColumnWeight)
                            .maxLines(2)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                        }
                      }
                      .width('100%')
                      .alignItems(LIST_ROW_LAYOUT.verticalAlign)
                    }
                    .width('100%')
                    .padding({
                      left: SETTINGS_LAYOUT.paddingHorizontal,
                      right: SETTINGS_LAYOUT.paddingHorizontal,
                      top: SETTINGS_LAYOUT.rowPaddingVertical,
                      bottom: SETTINGS_LAYOUT.rowPaddingVertical
                    })
                    .alignItems(SETTINGS_TEXT_LAYOUT.containerAlign)
                  }, (entry: NetworkLogEntry) => entry.id)
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
      content: { title: { mainTitle: $r('app.string.adv_log') } },
      style: hdsTitleBarStyle()
    })
    .backgroundColor(ThemeColors.BG)
  }
}

/** 系统路由表构建函数：与 route_map.json 的 "NetworkLogPageBuilder" 对应 */
@Builder
export function NetworkLogPageBuilder(name: string, param?: object) {
  NetworkLogPage()
}
