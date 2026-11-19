/**
 * ChapterSection.ets —— 章节目录区（标题 + 正倒序切换 + 懒加载分组/章节行）
 */
import { ComicDetail as ComicDetailModel } from '../../model/ComicDetail';
import { ChapterRow, ChapterRowKind } from '../../model/ChapterRow';
import { ComicReaderParam } from '../../model/ReaderParam';
import { ComicDetailViewModel } from '../../viewmodel/ComicDetailViewModel';
import { ThemeColors } from '../../utils/Theme';
import { ThemeManager } from '../../utils/ThemeManager';
import { LocalizationManager } from '../../utils/LocalizationManager';
import { buildPillImmersiveMaterial } from '../../utils/ImmersiveMaterial';
import {
  resolveSettingsPillBorderColor,
  resolveSettingsPillSurfaceColor
} from '../../utils/MaterialPolicy';
import { DETAIL_CHAPTER_TOUCH_TARGET_VP } from '../../utils/ComicDetailLayout';
import { uiMaterial } from '@kit.ArkUI';

@ComponentV2
export struct ChapterSection {
  @Require @Param detail: ComicDetailModel;
  @Require @Param vm: ComicDetailViewModel;
  @Event onOpenReader: (param: ComicReaderParam | null) => void = (_p: ComicReaderParam | null): void => {};
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();
  private readonly pillMaterial: uiMaterial.Material | undefined = buildPillImmersiveMaterial();

  @Builder
  GroupHeaderRow(row: ChapterRow) {
    Row() {
      SymbolGlyph(row.isExpanded ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([ThemeColors.PRIMARY])
        .margin({ right: 8 })
      Text(row.groupName)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemeColors.TEXT)
        .layoutWeight(1)
      Text(this.lm.getString($r('app.string.detail_group_count_fmt'), '%d 话', row.groupCount))
        .fontSize(11)
        .fontColor(ThemeColors.TEXT_MUTED)
    }
    .width('100%')
    .constraintSize({ minHeight: DETAIL_CHAPTER_TOUCH_TARGET_VP })
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .backgroundColor(ThemeColors.CARD_ALT)
    .onClick(() => {
      this.vm.toggleGroup(row.groupId);
    })
  }

  @Builder
  ChapterItemRow(row: ChapterRow) {
    Row() {
      Column({ space: 2 }) {
        Row({ space: 6 }) {
          Text(row.chapter === null ? '' : row.chapter.title)
            .fontSize(14)
            .fontColor(ThemeColors.TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (row.chapter !== null && this.vm.isCurrentChapter(row.chapter.id)) {
            Text($r('app.string.detail_ch_reading'))
              .fontSize(10)
              .fontColor(ThemeColors.BG)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .backgroundColor(ThemeColors.PRIMARY)
              .borderRadius(6)
          } else if (row.chapter !== null && this.vm.isChapterRead(row.chapter.id)) {
            Text($r('app.string.detail_ch_read'))
              .fontSize(10)
              .fontColor(ThemeColors.TEXT_MUTED)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .backgroundColor(ThemeColors.SURFACE)
              .borderRadius(6)
          }
        }
        .width('100%')

        if (row.chapter !== null && (row.chapter.updatedAt !== '' || row.chapter.pageCount > 0)) {
          Text(`${row.chapter.updatedAt}` +
            (row.chapter.pageCount > 0 ? `  (${row.chapter.pageCount}P)` : ''))
            .fontSize(11)
            .fontColor(ThemeColors.TEXT_MUTED)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick(() => {
        if (row.chapter !== null) {
          this.onOpenReader(this.vm.selectChapter(row.chapter));
        }
      })

      Row({ space: 8 }) {
        Text(row.chapter === null ? '' : `#${row.chapter.order}`)
          .fontSize(12)
          .fontColor(ThemeColors.PRIMARY)
        if (row.chapter !== null) {
          if (this.vm.isChapterDownloaded(row.chapter.id)) {
            Text($r('app.string.detail_ch_offline'))
              .fontSize(11)
              .fontColor(ThemeColors.PRIMARY)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor(ThemeColors.SURFACE_PRIMARY)
              .borderRadius(12)
          } else {
            Text($r('app.string.detail_action_download'))
              .fontSize(11)
              .fontColor(ThemeColors.PRIMARY)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .borderWidth(1)
              .borderColor(ThemeColors.PRIMARY)
              .borderRadius(12)
              .onClick(() => {
                if (row.chapter !== null) {
                  this.vm.downloadChapter(row.chapter);
                }
              })
          }
        }
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .constraintSize({ minHeight: DETAIL_CHAPTER_TOUCH_TARGET_VP })
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor(ThemeColors.CARD)
    .borderRadius(6)
    .margin({ left: 12, right: 12, top: 3, bottom: 3 })
  }

  build() {
    Column({ space: 0 }) {
      Row({ space: 8 }) {
        Text(this.lm.getString(
          $r('app.string.detail_chapters_header_fmt'),
          '章节目录 (%1$d 话 / %2$d 分组)',
          this.vm.displayChapterCount,
          this.vm.displayGroupCount
        ))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.TEXT)
          .layoutWeight(1)

        if (!this.vm.isOfflineFallback && this.detail.chapters.length > 0) {
          Text($r('app.string.detail_download_all'))
            .fontSize(12)
            .fontColor(ThemeColors.PRIMARY)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor(resolveSettingsPillSurfaceColor(this.theme.isDark, false))
            .border({
              width: 1,
              color: resolveSettingsPillBorderColor(this.theme.isDark)
            })
            .borderRadius(14)
            .systemMaterial(this.pillMaterial)
            .onClick(() => {
              void this.vm.downloadAllMissingChapters();
            })
        }

        Row({ space: 4 }) {
          Text(this.vm.isChapterReversed
            ? $r('app.string.detail_order_desc')
            : $r('app.string.detail_order_asc'))
            .fontSize(12)
            .fontColor(ThemeColors.PRIMARY)
          SymbolGlyph(this.vm.isChapterReversed ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_up'))
            .fontSize(12)
            .fontColor([ThemeColors.PRIMARY])
        }
        .alignItems(VerticalAlign.Center)
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor(resolveSettingsPillSurfaceColor(this.theme.isDark, false))
        .border({
          width: 1,
          color: resolveSettingsPillBorderColor(this.theme.isDark)
        })
        .borderRadius(14)
        .systemMaterial(this.pillMaterial)
        .onClick(() => {
          this.vm.toggleChapterOrder();
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 6 })
      .alignItems(VerticalAlign.Center)

      LazyForEach(this.vm.chapterRows, (row: ChapterRow) => {
        if (row.kind === ChapterRowKind.GROUP_HEADER) {
          this.GroupHeaderRow(row)
        } else {
          this.ChapterItemRow(row)
        }
      }, (row: ChapterRow) => row.key)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
