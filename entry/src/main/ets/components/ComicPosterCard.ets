/**
 * ComicPosterCard.ets —— 海报卡片（首页横向推荐行 / 榜单行通用）
 *
 * Phase 14-H 新增：对齐原版 R1 海报卡片结构——
 * - 5:7 封面（宽高显式设置，不走比例属性撑开）；
 * - 右上角状态徽标：连载中 / 已完结；仅当服务端 Mode=1 且 Status 明确时显示（Phase 14-T）；
 * - 底部渐变遮罩叠加标题（2 行省略）、作者、浏览数（👁）、点赞数（❤，即收藏量）；
 * - 外层 clip(true) 圆角裁切。
 *
 * 数据真实性：全部字段来自 Comic（书单协议已映射），浏览/点赞数字经 formatCount 缩写；
 * 状态徽标依赖「Mode=1 + Status 明确」，其余一律隐藏，不编造连载/完结状态。
 *
 * Phase 14-K：颜色全部收敛到 ThemeColors（封面白字 / 遮罩端点 / 状态徽标），
 * 与网格卡片 ComicCardView 的「徽标尺寸、圆角、字号层级」保持一致。
 */
import { Comic } from '../model/Comic';
import { MangaImage } from './MangaImage';
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import { formatCount } from '../utils/Format';
import { CARD_TEXT_LAYOUT } from '../utils/StableLayout';
import { ComicBadgeOverlay } from './ComicBadgeOverlay';
import { COVER_ASPECT_RATIO } from '../responsive/LayoutPolicy';
import { cardPressOpacity, cardPressScale, cardSpringCurve } from '../utils/SpringMotion';

@ComponentV2
export struct ComicPosterCard {
  /** 海报数据 */
  @Require @Param comic: Comic;
  /** 卡片宽度（vp，由外部按窗口类别传入；避免与通用 width 属性重名故命名 cardWidth） */
  @Require @Param cardWidth: number;
  /** 可选固定卡片高度（vp；未传时按 3:4 比例计算） */
  @Param cardHeight: number = 0;
  /** 全局路由栈：点击进入详情页 */
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local private isPressed: boolean = false;

  /** 解析后的固定封面高度 */
  private resolvedHeight(): number {
    return this.cardHeight > 0 ? this.cardHeight : Math.round(this.cardWidth / COVER_ASPECT_RATIO);
  }

  build() {
    Stack() {
      // 封面：显式固定像素宽高 + coverFill 填满，避免旋转期间二次测量
      MangaImage({ imageUrl: this.comic.cover, coverFill: true })
        .width(this.cardWidth)
        .height(this.resolvedHeight())

      // Phase 14-T：角标统一由 ComicBadgeOverlay 渲染（关键词左上=完整 Ptag / 状态右上=Mode 1 + 明确 Status）
      ComicBadgeOverlay({
        isCompleted: this.comic.isCompleted,
        tags: this.comic.ptag
      })

      // 信息层：底部渐变遮罩 + 文字
      Column() {
        Blank()

        // 底部：渐变遮罩 + 标题 / 作者 / 统计
        Column({ space: 2 }) {
          Text(this.comic.title)
            .fontSize(ThemeFonts.TITLE_CARD)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.ON_COVER)
            .width('100%')
            .maxLines(CARD_TEXT_LAYOUT.titleMaxLines)
            .lineHeight(CARD_TEXT_LAYOUT.titleLineHeight)
            .textOverflow({ overflow: CARD_TEXT_LAYOUT.overflow })

          if (this.comic.author !== '') {
            Text(this.comic.author)
              .fontSize(ThemeFonts.CAPTION + 1)
              .fontColor(ThemeColors.ON_COVER_SUB)
              .width('100%')
              .maxLines(CARD_TEXT_LAYOUT.metaMaxLines)
              .lineHeight(CARD_TEXT_LAYOUT.metaLineHeight)
              .textOverflow({ overflow: CARD_TEXT_LAYOUT.overflow })
          }

          if (this.comic.views > 0 || this.comic.favorites > 0) {
            Row({ space: 10 }) {
              if (this.comic.views > 0) {
                Row({ space: 3 }) {
                  SymbolGlyph($r('sys.symbol.eye'))
                    .fontSize(12)
                    .fontColor([ThemeColors.ON_COVER_SUB])
                    .renderingStrategy(SymbolRenderingStrategy.SINGLE)
                  Text(formatCount(this.comic.views))
                    .fontSize(ThemeFonts.CAPTION)
                    .fontColor(ThemeColors.ON_COVER_SUB)
                }
                .alignItems(VerticalAlign.Center)
                .flexShrink(0)
              }
              if (this.comic.favorites > 0) {
                Row({ space: 3 }) {
                  SymbolGlyph($r('sys.symbol.heart_fill'))
                    .fontSize(12)
                    .fontColor([ThemeColors.ON_COVER_SUB])
                    .renderingStrategy(SymbolRenderingStrategy.SINGLE)
                  Text(formatCount(this.comic.favorites))
                    .fontSize(ThemeFonts.CAPTION)
                    .fontColor(ThemeColors.ON_COVER_SUB)
                }
                .alignItems(VerticalAlign.Center)
                .flexShrink(0)
              }
            }
            .width('100%')
          }
        }
        .width('100%')
        .constraintSize({ minHeight: CARD_TEXT_LAYOUT.posterInfoMinHeight })
        .padding({ left: 8, right: 8, top: 18, bottom: 8 })
        .alignItems(HorizontalAlign.Start)
        .linearGradient({
          angle: 180,
          colors: [[ThemeColors.SCRIM_FROM, 0], [ThemeColors.SCRIM_TO, 1]]
        })
      }
      .width(this.cardWidth)
      .height(this.resolvedHeight())
    }
    .width(this.cardWidth)
    .height(this.resolvedHeight())
    .borderRadius(ThemeDims.RADIUS_CARD)
    .clip(true)
    .backgroundColor(ThemeColors.SURFACE)
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
