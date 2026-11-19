/**
 * ComicListItem.ets —— 单列列表项（最新页 / 榜单完整列表通用）
 *
 * Phase 14-H 新增：对齐原版 R3 列表项结构——
 * - 左侧 5:7 封面（显式宽高）+ 统一角标层（Phase 14-T：已移除排名/评分角标）；
 * - 右侧：标题（单行省略）、元信息行（年份 作者 | ★评分 浏览 点赞）、简介（2 行省略）、标签按钮行。
 *
 * 数据真实性：全部字段来自 Comic（书单协议已映射），数字经 formatCount 缩写；
 * 简介为空 / 标签为空 / 评分为 0 时不渲染对应行，不编造内容。
 */
import { Comic } from '../model/Comic';
import { MangaImage } from './MangaImage';
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import { formatCount } from '../utils/Format';
import { CARD_TEXT_LAYOUT, STABLE_LIST_INFO_HEIGHT, LIST_COVER_WIDTH } from '../utils/StableLayout';
import { ComicBadgeOverlay } from './ComicBadgeOverlay';
import { COVER_ASPECT_RATIO } from '../responsive/LayoutPolicy';
import { cardPressOpacity, cardPressScale, cardSpringCurve } from '../utils/SpringMotion';

@ComponentV2
export struct ComicListItem {
  /** 列表项数据 */
  @Require @Param comic: Comic;
  /** 封面宽度（vp，显式） */
  @Param coverWidth: number = LIST_COVER_WIDTH;
  /** 全局路由栈：点击进入详情页 */
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local private isPressed: boolean = false;

  /** 标签数组（categories 空格分隔，最多 3 个） */
  private tagList(): string[] {
    const raw: string[] = this.comic.categories.split(' ');
    const tags: string[] = [];
    for (let i = 0; i < raw.length && tags.length < 3; i++) {
      const t: string = raw[i].trim();
      if (t !== '' && tags.indexOf(t) < 0) {
        tags.push(t);
      }
    }
    return tags;
  }

  /** 评分文案（ratingSum/2，1 位小数；无评分返回空串） */
  private ratingText(): string {
    if (this.comic.ratingSum <= 0) {
      return '';
    }
    return (this.comic.ratingSum / 2).toFixed(1);
  }

  /** 年份 · 作者前缀文本 */
  private authorMetaLine(): string {
    const year: string = this.comic.publishYear !== '' ? this.comic.publishYear : '';
    const by: string = this.comic.author !== '' ? this.comic.author : '';
    if (year !== '' && by !== '') {
      return `${year} ${by}`;
    }
    return year !== '' ? year : by;
  }

  build() {
    Row({ space: 12 }) {
      // 左侧 3:4 封面 + 状态徽标
      Stack({ alignContent: Alignment.TopStart }) {
        MangaImage({ imageUrl: this.comic.cover, coverFill: true })
          .width('100%')
          .height('100%')
        ComicBadgeOverlay({
          isCompleted: this.comic.isCompleted,
          tags: this.comic.ptag
        })
      }
      .width(84)
      .height(112)
      .borderRadius(10)
      .clip(true)
      .backgroundColor(ThemeColors.CARD)

      // 右侧信息：固定信息区高度，字段缺失/补齐不再改变列表项高度，且抗挤压
      Column({ space: 4 }) {
        Text(this.comic.title)
          .fontSize(ThemeFonts.TITLE_CARD)
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.TEXT_STRONG)
          .width('100%')
          .maxLines(1)
          .lineHeight(CARD_TEXT_LAYOUT.titleLineHeight)
          .textOverflow({ overflow: CARD_TEXT_LAYOUT.overflow })

        if (this.authorMetaLine() !== '' || this.ratingText() !== '' ||
          this.comic.views > 0 || this.comic.favorites > 0) {
          Row({ space: 8 }) {
            if (this.authorMetaLine() !== '') {
              Text(this.authorMetaLine())
                .fontSize(ThemeFonts.CAPTION)
                .fontColor(ThemeColors.TEXT_SECONDARY)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            } else {
              Blank().layoutWeight(1)
            }
            if (this.ratingText() !== '') {
              Row({ space: 2 }) {
                SymbolGlyph($r('sys.symbol.star_fill'))
                  .fontSize(11)
                  .fontColor([ThemeColors.RATING])
                  .renderingStrategy(SymbolRenderingStrategy.SINGLE)
                Text(this.ratingText())
                  .fontSize(ThemeFonts.CAPTION)
                  .fontColor(ThemeColors.RATING)
              }
              .alignItems(VerticalAlign.Center)
              .flexShrink(0)
            }
            if (this.comic.views > 0) {
              Row({ space: 2 }) {
                SymbolGlyph($r('sys.symbol.eye'))
                  .fontSize(11)
                  .fontColor([ThemeColors.TEXT_SECONDARY])
                  .renderingStrategy(SymbolRenderingStrategy.SINGLE)
                Text(formatCount(this.comic.views))
                  .fontSize(ThemeFonts.CAPTION)
                  .fontColor(ThemeColors.TEXT_SECONDARY)
              }
              .alignItems(VerticalAlign.Center)
              .flexShrink(0)
            }
            if (this.comic.favorites > 0) {
              Row({ space: 2 }) {
                SymbolGlyph($r('sys.symbol.heart_fill'))
                  .fontSize(11)
                  .fontColor([ThemeColors.TEXT_SECONDARY])
                  .renderingStrategy(SymbolRenderingStrategy.SINGLE)
                Text(formatCount(this.comic.favorites))
                  .fontSize(ThemeFonts.CAPTION)
                  .fontColor(ThemeColors.TEXT_SECONDARY)
              }
              .alignItems(VerticalAlign.Center)
              .flexShrink(0)
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }

        if (this.comic.description !== '') {
          Text(this.comic.description)
            .fontSize(ThemeFonts.BODY_SMALL)
            .fontColor(ThemeColors.TEXT_SECONDARY)
            .lineHeight(CARD_TEXT_LAYOUT.descLineHeight)
            .width('100%')
            .maxLines(CARD_TEXT_LAYOUT.descMaxLines)
            .textOverflow({ overflow: CARD_TEXT_LAYOUT.overflow })
        }

        if (this.tagList().length > 0) {
          Row({ space: 6 }) {
            ForEach(this.tagList(), (tag: string) => {
              Text(tag)
                .fontSize(ThemeFonts.CAPTION)
                .fontColor(ThemeColors.TEXT_TERTIARY)
                .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                .backgroundColor(ThemeColors.CARD)
                .borderRadius(ThemeDims.RADIUS_TAG)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }, (tag: string) => tag)
          }
          .width('100%')
          .constraintSize({ minHeight: CARD_TEXT_LAYOUT.tagRowMinHeight })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .height(STABLE_LIST_INFO_HEIGHT)
      .clip(true)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(12)
    .backgroundColor(ThemeColors.SURFACE)
    .borderRadius(16)
    .borderWidth(0)
    .scale({ x: cardPressScale(this.isPressed), y: cardPressScale(this.isPressed) })
    .opacity(cardPressOpacity(this.isPressed))
    .animation({ curve: cardSpringCurve() })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.isPressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.isPressed = false;
      }
    })
    .onClick(() => {
      this.pageStack.pushPathByName('ComicDetail', this.comic.id);
    })
  }
}
