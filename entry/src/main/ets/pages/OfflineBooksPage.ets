import { HdsNavDestination } from '@kit.UIDesignKit';
import { StandardPageScaffold } from '../components/StandardPageScaffold';
import { HdsLightButton } from '../components/HdsLightButton';
import { MangaImage } from '../components/MangaImage';
import { DownloadFactory, DownloadServices } from '../download/DownloadFactory';
import { DownloadTask } from '../model/DownloadTask';
import { ComicReaderParam } from '../model/ReaderParam';
import { ROUTE_DOWNLOAD } from '../model/ProfileMenu';
import { CacheViewModel } from '../viewmodel/CacheViewModel';
import {
  DiskOfflineBook,
  OfflineBookChapter,
  OfflineBookGroup,
  aggregateOfflineBooksWithDisk,
  deleteOfflineBook,
  scanDiskOfflineBooks
} from '../utils/OfflineBooksHelper';
import { ThemeColors } from '../utils/Theme';
import { ThemeManager } from '../utils/ThemeManager';
import { ViewportState } from '../utils/ViewportState';
import { Logger } from '../utils/Logger';
import { LocalizationManager } from '../utils/LocalizationManager';
import { cardPressOpacity, cardPressScale, cardSpringCurve } from '../utils/SpringMotion';

const TAG: string = 'OfflineBooksPage';

@ComponentV2
export struct OfflineBooksPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local books: OfflineBookGroup[] = [];
  @Local totalBytes: number = 0;
  @Local isLoading: boolean = false;
  @Local expandedBookId: string = '';
  @Local private pressedBookId: string = '';
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();

  private async loadBooks(): Promise<void> {
    if (this.isLoading) {
      return;
    }
    this.isLoading = true;
    try {
      const services: DownloadServices | undefined = DownloadFactory.get();
      if (services === undefined) {
        this.books = [];
        this.totalBytes = 0;
        return;
      }
      const tasks: DownloadTask[] = await services.manager.listTasks();
      const diskBooks: DiskOfflineBook[] = await scanDiskOfflineBooks(services.storage);
      const diskTotalBytes: number = await services.manager.getDownloadSize();
      const grouped: OfflineBookGroup[] = aggregateOfflineBooksWithDisk(tasks, diskBooks);
      this.books = grouped;
      this.totalBytes = diskTotalBytes;
    } catch (e) {
      Logger.warn(TAG, `加载离线漫画失败: ${(e as Error).message}`);
    } finally {
      this.isLoading = false;
    }
  }

  private openReader(bookId: string, chapter: OfflineBookChapter): void {
    this.pageStack.pushPathByName('ComicReader',
      new ComicReaderParam(bookId, chapter.chapterId, chapter.chapterTitle, 1));
  }

  private toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
    } catch (_e) {
      // ignore toast errors
    }
  }

  private confirmDeleteBook(group: OfflineBookGroup): void {
    try {
      this.getUIContext().showAlertDialog({
        title: this.lm.getString($r('app.string.offline_delete_title'), '删除本地资源'),
        message: `${group.bookTitle} (${group.chapters.length}, ${CacheViewModel.formatBytes(group.totalBytes)})`,
        autoCancel: true,
        alignment: DialogAlignment.Bottom,
        buttons: [
          {
            value: this.lm.getString($r('app.string.common_cancel'), '取消'),
            fontColor: this.theme.textSecondary,
            action: () => {}
          },
          {
            value: this.lm.getString($r('app.string.common_delete'), '删除'),
            fontColor: '#DC2626',
            action: () => {
              void this.doDeleteBook(group.bookId);
            }
          }
        ]
      });
    } catch (e) {
      Logger.warn(TAG, `弹窗失败: ${(e as Error).message}`);
    }
  }

  private async doDeleteBook(bookId: string): Promise<void> {
    const services: DownloadServices | undefined = DownloadFactory.get();
    if (services === undefined) {
      return;
    }
    await deleteOfflineBook(services.manager, bookId);
    await this.loadBooks();
    this.toast(this.lm.getString($r('app.string.offline_deleted_toast'), '已删除该漫画本地资源'));
  }

  build() {
    HdsNavDestination() {
      StandardPageScaffold({
        title: this.lm.getString($r('app.string.offline_title'), '离线阅读'),
        isLoading: this.isLoading,
        hasContent: this.books.length > 0,
        isEmpty: !this.isLoading && this.books.length === 0,
        emptyIcon: $r('sys.symbol.book'),
        emptyTitle: this.lm.getString($r('app.string.offline_empty_title'), '暂无已下载漫画'),
        emptyMessage: this.lm.getString(
          $r('app.string.offline_empty_msg'),
          '下载完成的漫画会集中展示在这里，无网络也能随时阅读'
        ),
        showSecondaryAction: true,
        secondaryActionText: this.lm.getString($r('app.string.offline_go_downloads'), '前往下载管理'),
        onSecondaryAction: (): void => {
          this.pageStack.pushPathByName(ROUTE_DOWNLOAD, null);
        },
        onBack: (): void => {
          this.pageStack.pop();
        },
        rightAction: (): void => {
          this.SizeBadge();
        },
        content: (): void => {
          this.BooksContent();
        }
      })
    }
    .hideTitleBar(true)
    .withTheme({ enableThemeColorMode: true })
    .backgroundColor(ThemeColors.BG)
    .onShown(() => {
      void this.loadBooks();
    })
  }

  @Builder
  SizeBadge() {
    HdsLightButton({
      label: CacheViewModel.formatBytes(this.totalBytes),
      variant: 'neutral',
      minWidthVp: 0,
      heightVp: 34,
      radiusVp: 17,
      hPaddingVp: 12,
      onAction: () => {
        void this.loadBooks();
      }
    })
  }

  @Builder
  BooksContent() {
    List({ space: 10 }) {
      ForEach(this.books, (group: OfflineBookGroup) => {
        ListItem() {
          this.BookCard(group)
        }
      }, (group: OfflineBookGroup) => `${group.bookId}_${group.chapters.length}_${group.totalBytes}`)
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 16, right: 16, top: 6, bottom: 24 + ViewportState.getInstance().bottomVp })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  BookCard(group: OfflineBookGroup) {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.TopStart }) {
          if (group.coverUrl !== '') {
            MangaImage({ imageUrl: group.coverUrl, coverFill: true })
              .width('100%')
              .height('100%')
          } else {
            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.book'))
                .fontSize(26)
                .fontColor([this.theme.textSecondary])
            }
            .width('100%')
            .height('100%')
          }
          Text($r('app.string.download_offline_badge'))
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.onAccent)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(this.theme.accent)
            .borderRadius({ topLeft: 10, bottomRight: 8 })
        }
        .width(84)
        .height(112)
        .borderRadius(10)
        .clip(true)
        .backgroundColor(ThemeColors.CARD)

        Column({ space: 4 }) {
          // 第 1 行：标题
          Text(group.bookTitle)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.theme.textPrimary)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          // 第 2 行：元信息
          Text($r('app.string.offline_local_source'))
            .fontSize(13)
            .fontColor(this.theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          // 第 3 行：标签胶囊
          Row({ space: 6 }) {
            Text(this.lm.getString(
              $r('app.string.offline_total_chapters_fmt'),
              '共 %d 话',
              group.chapters.length
            ))
              .fontSize(11)
              .fontColor(this.theme.textSecondary)
              .height(20)
              .padding({ left: 7, right: 7 })
              .borderRadius(10)
              .backgroundColor(ThemeColors.CARD)
          }
          .width('100%')

          Blank()

          // 第 4 行：占用信息 + 选话 / 删除胶囊
          Row({ space: 8 }) {
            Text(this.lm.getString(
              $r('app.string.offline_downloaded_summary_fmt'),
              '已下载 %1$d 话 · %2$s',
              group.chapters.length,
              CacheViewModel.formatBytes(group.totalBytes)
            ))
              .fontSize(12.5)
              .fontColor(this.theme.textSecondary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            HdsLightButton({
              label: this.expandedBookId === group.bookId
                ? this.lm.getString($r('app.string.offline_collapse'), '收起')
                : this.lm.getString($r('app.string.offline_chapters'), '选话'),
              variant: 'neutral',
              minWidthVp: 0,
              heightVp: 30,
              radiusVp: 15,
              hPaddingVp: 10,
              fontSizeFp: 12,
              touchTargetHeightVp: 40,
              onAction: () => {
                this.expandedBookId = this.expandedBookId === group.bookId ? '' : group.bookId;
              }
            })

            HdsLightButton({
              label: this.lm.getString($r('app.string.common_delete'), '删除'),
              variant: 'danger',
              minWidthVp: 0,
              heightVp: 30,
              radiusVp: 15,
              hPaddingVp: 10,
              fontSizeFp: 12,
              touchTargetHeightVp: 40,
              onAction: () => {
                this.confirmDeleteBook(group);
              }
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .height(112)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .scale({
        x: cardPressScale(this.pressedBookId === group.bookId),
        y: cardPressScale(this.pressedBookId === group.bookId)
      })
      .opacity(cardPressOpacity(this.pressedBookId === group.bookId))
      .animation({ curve: cardSpringCurve() })
      .onTouch((event: TouchEvent): void => {
        if (event.type === TouchType.Down) {
          this.pressedBookId = group.bookId;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          if (this.pressedBookId === group.bookId) {
            this.pressedBookId = '';
          }
        }
      })
      .onClick(() => {
        if (group.chapters.length > 0) {
          this.openReader(group.bookId, group.chapters[0]);
        }
      })

      if (this.expandedBookId === group.bookId) {
        Column({ space: 6 }) {
          ForEach(group.chapters, (ch: OfflineBookChapter) => {
            Row({ space: 8 }) {
              Text(ch.chapterTitle)
                .fontSize(13)
                .fontColor(this.theme.textPrimary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(this.lm.getString($r('app.string.offline_pages_fmt'), '%d 页', ch.completedImages))
                .fontSize(12)
                .fontColor(this.theme.textSecondary)
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(12)
                .fontColor([this.theme.textSecondary])
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
            .backgroundColor(ThemeColors.CARD)
            .borderRadius(10)
            .onClick(() => {
              this.openReader(group.bookId, ch);
            })
          }, (ch: OfflineBookChapter) => ch.chapterId)
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(ThemeColors.SURFACE)
    .borderRadius(16)
    .borderWidth(0)
  }
}

@Builder
export function OfflineBooksPageBuilder(_name: string, _param?: object) {
  OfflineBooksPage()
}
