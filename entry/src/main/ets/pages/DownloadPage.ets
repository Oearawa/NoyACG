import { HdsNavDestination } from '@kit.UIDesignKit';
/**
 * DownloadPage.ets —— 下载管理与离线章节入口（StandardPageScaffold 统一骨架）
 *
 * 约束：
 * - 页面只读 DownloadViewModel 的 @Trace 状态，不直接触碰文件系统 / 数据库 / RCP；
 * - 统一使用 StandardPageScaffold + 材质规范，所有可交互按钮触控热区 >= 40vp；
 * - 「删除记录」与「删除实际文件」严格区分，删除文件必须二次确认；
 * - 离线章节通过 ComicReaderParam(bookId, chapterId, ...) 进入同一个阅读器。
 */
import { DownloadViewModel } from '../viewmodel/DownloadViewModel';
import { StandardPageScaffold } from '../components/StandardPageScaffold';
import { HdsLightButton } from '../components/HdsLightButton';
import { DownloadStatus, DownloadTask } from '../model/DownloadTask';
import { ComicReaderParam } from '../model/ReaderParam';
import { SafeAreaManager } from '../utils/SafeAreaManager';
import { ViewportState } from '../utils/ViewportState';
import { ResponsiveLayoutMetrics, resolveLayoutPolicy } from '../responsive/LayoutPolicy';
import { PreferenceManager } from '../utils/PreferenceManager';
import { formatDownloadTime } from '../utils/TimeFormat';
import { LocalizationManager } from '../utils/LocalizationManager';
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import { ThemeManager } from '../utils/ThemeManager';
import {
  springPressCurve,
  springPressOpacity,
  springPressScale
} from '../utils/SpringMotion';
import { Logger } from '../utils/Logger';

const TAG: string = 'DownloadPage';

@ComponentV2
export struct DownloadPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local vm: DownloadViewModel = new DownloadViewModel();
  /** 当前展开详情的任务 id */
  @Local expandedTaskId: string = '';
  /** 容器实测宽度（vp） */
  @Local containerWidth: number = 0;
  /** 统一响应式布局策略 */
  @Local layout: ResponsiveLayoutMetrics = ViewportState.getInstance().getLayoutPolicy();
  /** 是否宽屏/横屏双列模式 */
  @Local isLandscape: boolean = ViewportState.getInstance().isLandscape();
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();
  @Local private isRefreshPressed: boolean = false;
  /** 偏好单例：时间格式变化时任务时间随之更新 */
  private prefs: PreferenceManager = PreferenceManager.getInstance();
  private readonly syncViewport = (): void => {
    const vp: ViewportState = ViewportState.getInstance();
    const targetW: number = this.containerWidth > 0 ? this.containerWidth : vp.widthVp;
    const metrics: ResponsiveLayoutMetrics = resolveLayoutPolicy(targetW, vp.isLandscape());
    this.layout = metrics;
    const nextLandscape: boolean = metrics.listLanes >= 2;
    if (nextLandscape !== this.isLandscape) {
      this.isLandscape = nextLandscape;
    }
  };

  aboutToAppear(): void {
    this.syncViewport();
    ViewportState.getInstance().addListener(this.syncViewport);
  }

  aboutToDisappear(): void {
    ViewportState.getInstance().removeListener(this.syncViewport);
    // 页面销毁后 VM 不再回写 UI 状态；下载任务由全局 Manager 继续
    this.vm.dispose();
  }

  build() {
    HdsNavDestination() {
      StandardPageScaffold({
        title: this.lm.getString($r('app.string.download_title'), '下载管理'),
        isLoading: false,
        hasContent: true,
        isEmpty: false,
        onBack: (): void => {
          this.pageStack.pop();
        },
        rightAction: (): void => {
          this.RightRefreshAction();
        },
        onWidthMeasured: (widthVp: number): void => {
          this.containerWidth = widthVp;
          this.syncViewport();
        },
        content: (): void => {
          this.DownloadBody();
        }
      })
    }
    .hideTitleBar(true)
    .withTheme({ enableThemeColorMode: true })
    .backgroundColor(ThemeColors.BG)
    .onReady(() => {
      Logger.info(TAG, 'onReady: 初始化下载任务列表');
      this.vm.initialize();
    })
  }

  @Builder
  DownloadBody() {
    Column() {
      this.Summary()

      if (this.vm.errorMessage !== '') {
        Text(this.vm.errorMessage)
          .fontSize(12)
          .fontColor(ThemeColors.ERROR)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 6 })
      }
      if (this.vm.notice !== '') {
        Text(this.vm.notice)
          .fontSize(12)
          .fontColor(ThemeColors.PRIMARY)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 6 })
      }

      if (this.vm.tasks.length === 0) {
        this.EmptyView()
      } else {
        // 统一响应式列表：单一 List 通过 .lanes() 原地重排 1 栏 / 2 栏，保留滚动状态
        List({ space: 10 }) {
          ForEach(this.vm.tasks, (task: DownloadTask) => {
            ListItem() {
              this.TaskCard(task)
            }
          }, (task: DownloadTask) => task.taskId)
        }
        .lanes(this.layout.listLanes, this.layout.listGutterVp)
        .width('100%')
        .layoutWeight(1)
        .padding({
          left: this.layout.pagePaddingVp,
          right: this.layout.pagePaddingVp,
          bottom: 24 + ViewportState.getInstance().bottomVp
        })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Start)
  }


  @Builder
  StatusBadge(label: string, count: number, accent: boolean = false) {
    if (count > 0) {
      Text(`${label} ${count}`)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(accent ? this.theme.accent : this.theme.textSecondary)
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .backgroundColor(accent
          ? this.theme.accentSoft
          : (this.theme.isDark ? '#252A36' : '#EEF2F6'))
        .borderRadius(10)
    }
  }

  @Builder
  RightRefreshAction() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph($r('sys.symbol.arrow_clockwise'))
        .fontSize(18)
        .fontColor([this.theme.textPrimary])
    }
    .width(36)
    .height(36)
    .buttonStyle(ButtonStyleMode.NORMAL)
    .backgroundColor(this.theme.isDark ? '#252A36' : '#EEF2F6')
    .borderWidth(0)
    .scale({
      x: springPressScale(this.isRefreshPressed),
      y: springPressScale(this.isRefreshPressed)
    })
    .opacity(springPressOpacity(this.isRefreshPressed))
    .animation({ curve: springPressCurve(this.isRefreshPressed) })
    .responseRegion({ x: -4, y: -4, width: 44, height: 44 })
    .accessibilityText(this.lm.getString($r('app.string.common_refresh'), '刷新'))
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.isRefreshPressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.isRefreshPressed = false;
      }
    })
    .onClick(() => {
      void this.vm.refresh();
    })
  }

  /** 顶部总览卡片：占用体积 + 精简状态摘要 + 对称 2×2 等宽无边框胶囊操作网格 */
  @Builder
  Summary() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Row({ space: 8 }) {
          Text($r('app.string.download_offline_usage'))
            .fontSize(13)
            .fontColor(this.theme.textSecondary)
          Text(this.vm.formattedDownloadSize())
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.theme.textPrimary)
        }
        .alignItems(VerticalAlign.Center)
        .layoutWeight(1)

        Text(this.lm.getString(
          $r('app.string.download_summary_fmt'),
          '进行中 %1$d · 已完成 %2$d',
          this.vm.queuedTasks.length + this.vm.activeTasks.length,
          this.vm.completedTasks.length
        ))
          .fontSize(12)
          .fontColor(this.theme.textSecondary)
          .maxLines(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Grid() {
        GridItem() {
          HdsLightButton({
            label: this.lm.getString($r('app.string.download_resume_all'), '全部继续'),
            variant: 'accentSolid',
            fullWidth: true,
            minWidthVp: 0,
            heightVp: 36,
            radiusVp: 18,
            onAction: () => {
              void this.vm.resumeAll();
            }
          })
        }
        GridItem() {
          HdsLightButton({
            label: this.lm.getString($r('app.string.download_pause_all'), '全部暂停'),
            variant: 'neutral',
            fullWidth: true,
            minWidthVp: 0,
            heightVp: 36,
            radiusVp: 18,
            onAction: () => {
              void this.vm.pauseAll();
            }
          })
        }
        GridItem() {
          HdsLightButton({
            label: this.lm.getString($r('app.string.download_cancel_all'), '取消全部'),
            variant: 'danger',
            fullWidth: true,
            minWidthVp: 0,
            heightVp: 36,
            radiusVp: 18,
            onAction: () => {
              void this.vm.cancelAll();
            }
          })
        }
        GridItem() {
          HdsLightButton({
            label: this.lm.getString($r('app.string.download_clear_offline'), '清空离线'),
            variant: 'danger',
            fullWidth: true,
            minWidthVp: 0,
            heightVp: 36,
            radiusVp: 18,
            onAction: () => {
              this.confirmDeleteAllOffline();
            }
          })
        }
      }
      .columnsTemplate('1fr 1fr')
      .columnsGap(10)
      .rowsGap(10)
      .width('100%')
      .height(82)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.theme.isDark ? ThemeColors.SURFACE : ThemeColors.CARD)
    .borderRadius(16)
    .borderWidth(0)
    .margin({ left: 16, right: 16, top: 8, bottom: 10 })
  }

  @Builder
  EmptyView() {
    Column({ space: 10 }) {
      Text($r('app.string.download_empty_title'))
        .fontSize(15)
        .fontColor(ThemeColors.TEXT_STRONG)
      Text($r('app.string.download_empty_desc'))
        .fontSize(12)
        .fontColor(ThemeColors.TEXT_MUTED)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 32, right: 32 })
  }

  /** 任务卡片：状态 / 进度 / 完成数 / 失败原因 / 操作 / 详情 */
  @Builder
  TaskCard(task: DownloadTask) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.statusLabel(task.status))
          .fontSize(11)
          .fontColor(ThemeColors.BG)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .backgroundColor(this.statusColor(task.status))
          .borderRadius(8)
        Text(task.bookTitle === '' ? task.bookId : task.bookTitle)
          .fontSize(13)
          .fontColor(ThemeColors.TEXT_SECONDARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (task.status === DownloadStatus.COMPLETED) {
          Text($r('app.string.download_offline_badge'))
            .fontSize(10)
            .fontColor(ThemeColors.PRIMARY)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(task.chapterTitle === ''
        ? this.lm.getString($r('app.string.download_chapter_num_fmt'), '章节 #%s', task.chapterId)
        : task.chapterTitle)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemeColors.TEXT_STRONG)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Progress({ value: task.progressPercent, total: 100, type: ProgressType.Linear })
        .color(this.theme.accent)
        .backgroundColor(this.theme.isDark ? '#252A36' : '#EEF2F6')
        .height(4)
        .width('100%')

      Text(this.lm.getString(
        $r('app.string.download_pages_progress_fmt'),
        '%1$d / %2$s 张 · %3$d%%',
        task.completedImages,
        task.totalImages === 0 ? '?' : `${task.totalImages}`,
        task.progressPercent
      ) + (task.failedImages > 0
        ? this.lm.getString($r('app.string.download_pages_failed_fmt'), ' · 失败 %d 张', task.failedImages)
        : ''))
        .fontSize(11)
        .fontColor(ThemeColors.TEXT_MUTED)
        .width('100%')

      if (task.lastError !== '') {
        Text(task.lastError)
          .fontSize(11)
          .fontColor(ThemeColors.ERROR)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      Row({ space: 8 }) {
        HdsLightButton({
          label: this.lm.getString($r('app.string.download_detail'), '详情'),
          variant: 'neutral',
          minWidthVp: 0,
          heightVp: 30,
          radiusVp: 15,
          hPaddingVp: 12,
          fontSizeFp: 12,
          touchTargetHeightVp: 40,
          onAction: () => {
            this.pageStack.pushPathByName('ComicDetail', task.bookId);
          }
        })

        if (task.status === DownloadStatus.QUEUED
          || task.status === DownloadStatus.PREPARING
          || task.status === DownloadStatus.DOWNLOADING) {
          HdsLightButton({
            label: this.lm.getString($r('app.string.download_pause'), '暂停'),
            variant: 'neutral',
            minWidthVp: 0,
            heightVp: 30,
            radiusVp: 15,
            hPaddingVp: 12,
            fontSizeFp: 12,
            touchTargetHeightVp: 40,
            onAction: () => {
              void this.vm.pause(task);
            }
          })
          HdsLightButton({
            label: this.lm.getString($r('app.string.download_cancel'), '取消'),
            variant: 'danger',
            minWidthVp: 0,
            heightVp: 30,
            radiusVp: 15,
            hPaddingVp: 12,
            fontSizeFp: 12,
            touchTargetHeightVp: 40,
            onAction: () => {
              void this.vm.cancel(task);
            }
          })
        } else if (task.status === DownloadStatus.PAUSED) {
          HdsLightButton({
            label: this.lm.getString($r('app.string.download_resume'), '继续'),
            variant: 'accentSoft',
            minWidthVp: 0,
            heightVp: 30,
            radiusVp: 15,
            hPaddingVp: 12,
            fontSizeFp: 12,
            touchTargetHeightVp: 40,
            onAction: () => {
              void this.vm.resume(task);
            }
          })
          HdsLightButton({
            label: this.lm.getString($r('app.string.download_cancel'), '取消'),
            variant: 'danger',
            minWidthVp: 0,
            heightVp: 30,
            radiusVp: 15,
            hPaddingVp: 12,
            fontSizeFp: 12,
            touchTargetHeightVp: 40,
            onAction: () => {
              void this.vm.cancel(task);
            }
          })
        } else if (task.status === DownloadStatus.FAILED
          || task.status === DownloadStatus.INCOMPLETE
          || task.status === DownloadStatus.CANCELED) {
          HdsLightButton({
            label: this.lm.getString($r('app.string.download_resume'), '继续'),
            variant: 'accentSoft',
            minWidthVp: 0,
            heightVp: 30,
            radiusVp: 15,
            hPaddingVp: 12,
            fontSizeFp: 12,
            touchTargetHeightVp: 40,
            onAction: () => {
              void this.vm.retry(task);
            }
          })
          HdsLightButton({
            label: this.lm.getString($r('app.string.download_repair'), '修复'),
            variant: 'neutral',
            minWidthVp: 0,
            heightVp: 30,
            radiusVp: 15,
            hPaddingVp: 12,
            fontSizeFp: 12,
            touchTargetHeightVp: 40,
            onAction: () => {
              void this.vm.repair(task);
            }
          })
        } else if (task.status === DownloadStatus.COMPLETED) {
          HdsLightButton({
            label: this.lm.getString($r('app.string.download_read_offline'), '离线阅读'),
            variant: 'accentSoft',
            minWidthVp: 0,
            heightVp: 30,
            radiusVp: 15,
            hPaddingVp: 12,
            fontSizeFp: 12,
            touchTargetHeightVp: 40,
            onAction: () => {
              this.pageStack.pushPathByName('ComicReader',
                new ComicReaderParam(task.bookId, task.chapterId, task.chapterTitle, 1));
            }
          })
        }

        HdsLightButton({
          label: this.lm.getString($r('app.string.common_delete'), '删除'),
          variant: 'danger',
          minWidthVp: 0,
          heightVp: 30,
          radiusVp: 15,
          hPaddingVp: 12,
          fontSizeFp: 12,
          touchTargetHeightVp: 40,
          onAction: () => {
            this.confirmDelete(task);
          }
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(ThemeColors.CARD)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 删除二次确认（API 26 `UIContext.showAlertDialog` 的 `buttons` 三按钮形态）：
   * 「仅删记录」保留文件，「删除文件」才真正清除永久下载图片。
   * 两者绝不合并，避免误删用户已离线的内容。
   */
  private confirmDeleteAllOffline(): void {
    this.getUIContext().showAlertDialog({
      title: this.lm.getString($r('app.string.download_clear_all_title'), '清空全部离线文件'),
      message: `${this.vm.formattedDownloadSize()}`,
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      buttons: [
        {
          value: this.lm.getString($r('app.string.common_cancel'), '取消'),
          fontColor: this.theme.textSecondary,
          action: () => {}
        },
        {
          value: this.lm.getString($r('app.string.download_clear_all_confirm'), '确认清空'),
          fontColor: '#DC2626',
          action: () => {
            void this.vm.deleteAllOffline();
          }
        }
      ]
    });
  }

  private confirmDelete(task: DownloadTask): void {
    this.getUIContext().showAlertDialog({
      title: this.lm.getString($r('app.string.download_delete_task_title'), '删除下载任务'),
      message: `「${task.chapterTitle === '' ? task.chapterId : task.chapterTitle}」\n` +
        this.lm.getString($r('app.string.download_delete_task_msg'), '「删除文件」会同时清除该章节的永久下载图片，此操作不可恢复。'),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      buttons: [
        {
          value: this.lm.getString($r('app.string.common_cancel'), '取消'),
          fontColor: ThemeColors.TEXT_MUTED,
          action: () => {
          }
        },
        {
          value: this.lm.getString($r('app.string.download_delete_record_only'), '仅删记录'),
          fontColor: ThemeColors.PRIMARY,
          action: () => {
            this.vm.deleteChapter(task, false);
          }
        },
        {
          value: this.lm.getString($r('app.string.download_delete_files'), '删除文件'),
          fontColor: ThemeColors.ERROR,
          action: () => {
            this.vm.deleteChapter(task, true);
          }
        }
      ]
    });
  }

  private statusLabel(status: DownloadStatus): string {
    switch (status) {
      case DownloadStatus.QUEUED: return this.lm.getString($r('app.string.download_status_queued'), '等待中');
      case DownloadStatus.PREPARING: return this.lm.getString($r('app.string.download_status_preparing'), '准备中');
      case DownloadStatus.DOWNLOADING: return this.lm.getString($r('app.string.download_status_downloading'), '下载中');
      case DownloadStatus.PAUSED: return this.lm.getString($r('app.string.download_status_paused'), '已暂停');
      case DownloadStatus.COMPLETED: return this.lm.getString($r('app.string.download_status_completed'), '已完成');
      case DownloadStatus.FAILED: return this.lm.getString($r('app.string.download_status_failed'), '失败');
      case DownloadStatus.CANCELED: return this.lm.getString($r('app.string.download_status_canceled'), '已取消');
      case DownloadStatus.INCOMPLETE: return this.lm.getString($r('app.string.download_status_incomplete'), '不完整');
      default: return status;
    }
  }

  private statusColor(status: DownloadStatus): string {
    switch (status) {
      case DownloadStatus.COMPLETED: return ThemeColors.SUCCESS;
      case DownloadStatus.DOWNLOADING:
      case DownloadStatus.PREPARING: return ThemeColors.PRIMARY;
      case DownloadStatus.FAILED:
      case DownloadStatus.INCOMPLETE: return ThemeColors.ERROR;
      case DownloadStatus.PAUSED:
      case DownloadStatus.CANCELED: return ThemeColors.TEXT_MUTED;
      default: return ThemeColors.INFO;
    }
  }

  /**
   * 时间文案：Phase 14-K 起统一由 utils/TimeFormat 产出，
   * 具体格式取决于设置页「时间格式化」（绝对 YYYY-MM-DD / 相对 N 小时前）。
   */
  private formatTime(timestamp: number): string {
    return formatDownloadTime(timestamp, this.prefs.timeFormat, this.lm.timeTexts());
  }
}

/** 系统路由表构建函数：与 route_map.json 的 "DownloadPageBuilder" 对应 */
@Builder
export function DownloadPageBuilder(name: string, param?: object) {
  DownloadPage()
}
