/**
 * ReaderChapterDrawer.ets —— 阅读器内章节目录抽屉
 *
 * 实色高对比度表面背景 + 半透明暗色遮罩 + 1vp 细边框，彻底阻断底层漫画透出。
 */
import { ReaderChapterItem } from '../../reader/ReaderTypes';
import { READER_HUD_BACK_TARGET_VP } from '../../reader/ReaderLayout';
import { ThemeColors } from '../../utils/Theme';
import { ThemeManager } from '../../utils/ThemeManager';
import { LocalizationManager } from '../../utils/LocalizationManager';
import { buildPanelImmersiveMaterial } from '../../utils/ImmersiveMaterial';
import {
  resolveSettingsPillBorderColor,
  resolveSettingsPillSurfaceColor
} from '../../utils/MaterialPolicy';
import { spatialSheetTransition } from '../../utils/ImmersiveMotion';
import { uiMaterial } from '@kit.ArkUI';

@ComponentV2
export struct ReaderChapterDrawer {
  @Require @Param chapters: ReaderChapterItem[];
  @Require @Param currentChapterId: string;
  @Param topSafeVp: number = 0;
  @Param bottomSafeVp: number = 0;
  @Param embeddedInSheet: boolean = false;
  @Event onSelectChapter: (chapter: ReaderChapterItem) => void = (_c: ReaderChapterItem): void => {};
  @Event onClose: () => void = (): void => {};
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();
  private readonly panelMaterial: uiMaterial.Material | undefined = buildPanelImmersiveMaterial();

  @Builder
  ChapterListBody() {
    if (this.chapters.length === 0) {
      Column({ space: 8 }) {
        Text($r('app.string.reader_drawer_empty'))
          .fontSize(13)
          .fontColor(ThemeColors.TEXT_SECONDARY)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else {
      List({ space: 6 }) {
        ForEach(this.chapters, (chapter: ReaderChapterItem) => {
          ListItem() {
            Row({ space: 8 }) {
              Text(chapter.title === ''
                ? this.lm.getString($r('app.string.detail_chapter_num_fmt'), '第 %d 话', chapter.order)
                : chapter.title)
                .fontSize(14)
                .fontWeight(chapter.id === this.currentChapterId ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(chapter.id === this.currentChapterId
                  ? this.theme.accent
                  : ThemeColors.TEXT_STRONG)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)

              if (chapter.id === this.currentChapterId) {
                Text($r('app.string.reader_drawer_current'))
                  .fontSize(10)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.theme.onAccent)
                  .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                  .backgroundColor(this.theme.accent)
                  .borderRadius(10)
              }
            }
            .width('100%')
            .constraintSize({ minHeight: READER_HUD_BACK_TARGET_VP })
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor(chapter.id === this.currentChapterId
              ? this.theme.accentSoft
              : resolveSettingsPillSurfaceColor(this.theme.isDark, false))
            .border({
              width: chapter.id === this.currentChapterId ? 1.5 : 1,
              color: chapter.id === this.currentChapterId
                ? this.theme.accent
                : resolveSettingsPillBorderColor(this.theme.isDark)
            })
            .borderRadius(12)
            .onClick(() => {
              this.onSelectChapter(chapter);
            })
          }
        }, (chapter: ReaderChapterItem) => chapter.id)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 12, right: 12, top: 10, bottom: Math.max(this.bottomSafeVp, 12) })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  build() {
    if (this.embeddedInSheet) {
      Column() {
        this.ChapterListBody()
      }
      .width('100%')
      .height('100%')
    } else {
      Stack({ alignContent: Alignment.End }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#73000000')
          .transition(TransitionEffect.OPACITY.animation({ duration: 180 }))
          .onClick(() => {
            this.onClose();
          })

        Column({ space: 0 }) {
          Row() {
            Text(`${this.lm.getString($r('app.string.reader_toc'), '目录')} (${this.chapters.length})`)
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(ThemeColors.TEXT_STRONG)
              .layoutWeight(1)

            Row() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(16)
                .fontColor([ThemeColors.TEXT_STRONG])
            }
            .width(32)
            .height(32)
            .borderRadius(16)
            .backgroundColor(resolveSettingsPillSurfaceColor(this.theme.isDark, false))
            .border({
              width: 1,
              color: resolveSettingsPillBorderColor(this.theme.isDark)
            })
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .responseRegion({ x: -6, y: -6, width: READER_HUD_BACK_TARGET_VP, height: READER_HUD_BACK_TARGET_VP })
            .onClick(() => {
              this.onClose();
            })
          }
          .width('100%')
          .padding({ left: 16, right: 14, top: Math.max(this.topSafeVp, 12), bottom: 10 })
          .alignItems(VerticalAlign.Center)

          Divider()
            .color(ThemeColors.DIVIDER)
            .strokeWidth(1)

          this.ChapterListBody()
        }
        .width('78%')
        .constraintSize({ minWidth: 260, maxWidth: 360 })
        .height('100%')
        .backgroundColor(ThemeColors.CARD)
        .border({
          width: { left: 1 },
        color: this.theme.isDark ? '#2E323D' : '#E2E8F0'
      })
      .borderRadius({ topLeft: 20, bottomLeft: 20 })
      .systemMaterial(this.panelMaterial)
      .clip(true)
      .transition(spatialSheetTransition(TransitionEdge.END))
      }
      .width('100%')
      .height('100%')
    }
  }
}
