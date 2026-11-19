/**
 * HistoryPage.ets —— 阅读历史页面（对齐官方横向漫画卡片与响应式双列网格）
 */
import { HdsNavDestination } from '@kit.UIDesignKit';
import { Comic } from '../model/Comic';
import { HistoryRecord } from '../utils/DatabaseManager';
import { PreferenceManager } from '../utils/PreferenceManager';
import { formatHistoryTime } from '../utils/TimeFormat';
import { formatCount } from '../utils/Format';
import { LocalizationManager } from '../utils/LocalizationManager';
import { ViewportState } from '../utils/ViewportState';
import { COVER_ASPECT_RATIO, ResponsiveLayoutMetrics, resolveLayoutPolicy } from '../responsive/LayoutPolicy';
import { contentEndInset } from '../utils/BottomInset';
import { ThemeColors, ThemeDims } from '../utils/Theme';
import { StandardPageScaffold } from '../components/StandardPageScaffold';
import { MangaImage } from '../components/MangaImage';
import { ComicBadgeOverlay } from '../components/ComicBadgeOverlay';
import { HistoryViewModel } from '../viewmodel/HistoryViewModel';
import { Logger } from '../utils/Logger';
import { cardPressOpacity, cardPressScale, cardSpringCurve } from '../utils/SpringMotion';

const TAG: string = 'HistoryPage';

@ComponentV2
export struct HistoryPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local vm: HistoryViewModel = new HistoryViewModel();
  @Local containerWidth: number = 0;
  @Local layout: ResponsiveLayoutMetrics = ViewportState.getInstance().getLayoutPolicy();
  @Local columns: number = ViewportState.getInstance().getLayoutPolicy().listLanes;
  @Local private pressedComicId: string = '';
  private prefs: PreferenceManager = PreferenceManager.getInstance();
  private lm: LocalizationManager = LocalizationManager.getInstance();
  private readonly syncViewport = (): void => {
    const vp: ViewportState = ViewportState.getInstance();
    const targetW: number = this.containerWidth > 0 ? this.containerWidth : vp.widthVp;
    const metrics: ResponsiveLayoutMetrics = resolveLayoutPolicy(targetW, vp.isLandscape());
    this.layout = metrics;
    if (metrics.listLanes !== this.columns) {
      this.columns = metrics.listLanes;
    }
  };

  aboutToAppear(): void {
    this.syncViewport();
    ViewportState.getInstance().addListener(this.syncViewport);
    void this.vm.load();
  }

  aboutToDisappear(): void {
    ViewportState.getInstance().removeListener(this.syncViewport);
  }

  private bottomListInset(): number {
    const vp: ViewportState = ViewportState.getInstance();
    return contentEndInset(0, vp.isBottomNav(), vp.bottomVp) + ThemeDims.SPACE_M;
  }

  private progressText(record: HistoryRecord): string {
    const chapter: string = record.chapterTitle !== ''
      ? record.chapterTitle
      : this.lm.getString($r('app.string.download_chapter_num_fmt'), '章节 #%s', record.chapterId);
    const total: number = record.totalPages !== undefined ? record.totalPages : 0;
    const pageStr: string = total > 0
      ? this.lm.getString($r('app.string.history_page_progress_fmt'), '%1$d/%2$d页', record.pageIndex, total)
      : this.lm.getString($r('app.string.history_page_single_fmt'), '第%d页', record.pageIndex);
    const timeStr: string = formatHistoryTime(record.updateTime, this.prefs.timeFormat, this.lm.timeTexts());
    return `${chapter} · ${pageStr}  ·  ${timeStr}`;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (e) {
      Logger.warn(TAG, `Toast 展示失败: ${(e as Error).message}`);
    }
  }

  private confirmClearAll(): void {
    if (this.vm.records.length === 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: this.lm.getString($r('app.string.history_clear_title'), '清空历史记录'),
      message: this.lm.getString($r('app.string.history_clear_msg'), '确定清空全部阅读记录吗？'),
      autoCancel: true,
      primaryButton: {
        value: this.lm.getString($r('app.string.common_cancel'), '取消'),
        action: () => {}
      },
      secondaryButton: {
        value: this.lm.getString($r('app.string.common_clear'), '清空'),
        fontColor: ThemeColors.ERROR,
        action: () => {
          void this.doClearAll();
        }
      }
    });
  }

  private async doClearAll(): Promise<void> {
    const ok: boolean = await this.vm.clearAll();
    if (ok) {
      this.toast(this.lm.getString($r('app.string.history_cleared'), '已清空历史记录'));
    } else {
      this.toast(this.lm.getString($r('app.string.history_clear_failed'), '清空失败，请稍后重试'));
    }
  }

  @Builder
  RightTrashAction() {
    if (this.vm.records.length > 0) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(22)
          .fontColor([ThemeColors.TEXT_STRONG])
      }
      .width(44)
      .height(44)
      .accessibilityText(this.lm.getString($r('app.string.history_clear_title'), '清空历史记录'))
      .onClick(() => {
        this.confirmClearAll();
      })
    }
  }

  @Builder
  DeleteSwipeAction(comicId: string) {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(18)
          .fontColor([ThemeColors.ON_PRIMARY])
      }
      .width(64)
      .height('100%')
      .backgroundColor(ThemeColors.ERROR)
      .onClick(() => {
        void this.vm.remove(comicId);
      })
    }
    .height('100%')
  }

  private parseTagList(comic: Comic): string[] {
    if (comic.categories === '') {
      return [];
    }
    const raw: string[] = comic.categories.split(/\s+/);
    const out: string[] = [];
    for (let i = 0; i < raw.length && out.length < 2; i++) {
      const t: string = raw[i].trim();
      if (t !== '' && out.indexOf(t) < 0) {
        out.push(t);
      }
    }
    return out;
  }

  @Builder
  HistoryItemCard(record: HistoryRecord) {
    this.HistoryCardBody(record, HistoryViewModel.toComic(record))
  }

  @Builder
  HistoryCardBody(record: HistoryRecord, comic: Comic) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        MangaImage({ imageUrl: comic.cover, coverFill: true })
          .width('100%')
          .height('100%')
        ComicBadgeOverlay({
          isCompleted: comic.isCompleted,
          tags: comic.ptag
        })
      }
      .width(78)
      .aspectRatio(COVER_ASPECT_RATIO)
      .borderRadius(8)
      .clip(true)
      .backgroundColor(ThemeColors.SURFACE)

      Column({ space: 4 }) {
        Text(comic.title)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.TEXT)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        if (comic.author !== '' || comic.views > 0 || comic.favorites > 0) {
          Row({ space: 8 }) {
            if (comic.author !== '') {
              Text(comic.author)
                .fontSize(12)
                .fontColor(ThemeColors.TEXT_SECONDARY)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            } else {
              Blank().layoutWeight(1)
            }
            if (comic.views > 0) {
              Row({ space: 3 }) {
                SymbolGlyph($r('sys.symbol.eye'))
                  .fontSize(12)
                  .fontColor([ThemeColors.TEXT_MUTED])
                  .renderingStrategy(SymbolRenderingStrategy.SINGLE)
                Text(formatCount(comic.views))
                  .fontSize(12)
                  .fontColor(ThemeColors.TEXT_MUTED)
              }
              .alignItems(VerticalAlign.Center)
              .flexShrink(0)
            }
            if (comic.favorites > 0) {
              Row({ space: 3 }) {
                SymbolGlyph($r('sys.symbol.heart_fill'))
                  .fontSize(12)
                  .fontColor([ThemeColors.TEXT_MUTED])
                  .renderingStrategy(SymbolRenderingStrategy.SINGLE)
                Text(formatCount(comic.favorites))
                  .fontSize(12)
                  .fontColor(ThemeColors.TEXT_MUTED)
              }
              .alignItems(VerticalAlign.Center)
              .flexShrink(0)
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }

        if (this.parseTagList(comic).length > 0) {
          Row({ space: 4 }) {
            ForEach(this.parseTagList(comic), (tag: string) => {
              Text(tag)
                .fontSize(11)
                .fontColor(ThemeColors.TEXT_SECONDARY)
                .height(20)
                .padding({ left: 7, right: 7 })
                .borderRadius(10)
                .backgroundColor(ThemeColors.SURFACE)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }, (tag: string) => tag)
          }
          .width('100%')
        }

        Text(this.progressText(record))
          .fontSize(12)
          .fontColor(ThemeColors.TEXT_MUTED)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
      }
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(10)
    .borderRadius(ThemeDims.RADIUS_CARD)
    .backgroundColor(ThemeColors.CARD)
    .alignItems(VerticalAlign.Top)
    .scale({
      x: cardPressScale(this.pressedComicId === record.comicId),
      y: cardPressScale(this.pressedComicId === record.comicId)
    })
    .opacity(cardPressOpacity(this.pressedComicId === record.comicId))
    .animation({ curve: cardSpringCurve() })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.pressedComicId = record.comicId;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        if (this.pressedComicId === record.comicId) {
          this.pressedComicId = '';
        }
      }
    })
    .onClick(() => {
      this.pageStack.pushPathByName('ComicDetail', record.comicId);
    })
  }

  @Builder
  HistoryContent() {
    // 统一响应式列表：单一 List 组件通过 .lanes() 原地重排 1 栏 / 2 栏，保留滚动位置与左滑删除
    List({ space: 8 }) {
      ForEach(this.vm.records, (record: HistoryRecord) => {
        ListItem() {
          this.HistoryItemCard(record)
        }
        .swipeAction({ end: { builder: (): void => { this.DeleteSwipeAction(record.comicId); } } })
      }, (record: HistoryRecord) => `${record.comicId}_${record.title ?? ''}_${record.updateTime}`)
    }
    .lanes(this.layout.listLanes, this.layout.listGutterVp)
    .width('100%')
    .height('100%')
    .padding({
      left: this.layout.pagePaddingVp,
      right: this.layout.pagePaddingVp,
      top: 8
    })
    .contentEndOffset(this.bottomListInset())
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  build() {
    HdsNavDestination() {
      StandardPageScaffold({
        title: $r('app.string.history_title'),
        isLoading: this.vm.isLoading,
        hasContent: this.vm.records.length > 0,
        isEmpty: !this.vm.isLoading && this.vm.errorMessage === '' && this.vm.records.length === 0,
        errorMessage: this.vm.errorMessage,
        emptyIcon: $r('sys.symbol.clock'),
        emptyTitle: $r('app.string.history_empty'),
        emptyMessage: '',
        onRetry: (): void => {
          void this.vm.load();
        },
        onWidthMeasured: (widthVp: number): void => {
          this.containerWidth = widthVp;
          this.syncViewport();
        },
        rightAction: (): void => {
          this.RightTrashAction();
        },
        content: (): void => {
          this.HistoryContent();
        }
      })
    }
    .hideTitleBar(true)
    .withTheme({ enableThemeColorMode: true })
    .backgroundColor(ThemeColors.BG)
    .onShown(() => {
      void this.vm.load();
    })
  }
}

/** 系统路由表构建函数：与 route_map.json 的 "HistoryPageBuilder" 对应 */
@Builder
export function HistoryPageBuilder(name: string, param?: object) {
  HistoryPage()
}
