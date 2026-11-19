/**
 * ComicCardView.ets —— 通用漫画卡片组件（首页 / 书架 / 搜索三处网格共用）
 *
 * Phase 14-G 重构：卡片改为「显式尺寸」，封面高度与信息区高度均由外部计算传入，
 * 不再由图片固有尺寸或比例撑开（此前网格下封面被拉伸、卡片压叠的根因）。
 *
 * - 封面：MangaImage 调用处显式 width('100%') + height(coverHeight) + objectFit(Cover)；
 *   MangaImage 内部实现不变，仅调用处属性控制尺寸。
 * - 信息区：固定 height(ThemeDims.CARD_INFO_HEIGHT)，标题 / 作者 / 统计三级。
 * - 标签（tags）在网格卡片中移除：网格以「标题 + 作者 + 统计」为主，完整标签见详情页。
 * 点击跳转详情页（通过全局路由栈 @Consumer）。
 */
import { Comic } from '../model/Comic';
import { MangaImage } from './MangaImage';
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import { CARD_TEXT_LAYOUT } from '../utils/StableLayout';
import { ComicBadgeOverlay } from './ComicBadgeOverlay';
import { COVER_ASPECT_RATIO } from '../responsive/LayoutPolicy';
import { cardPressOpacity, cardPressScale, cardSpringCurve } from '../utils/SpringMotion';

@ComponentV2
export struct ComicCardView {
  /** 卡片数据 */
  @Require @Param comic: Comic;
  /** 兼容历史入参（封面实际高度由标准 3:4 比例自然撑开） */
  @Param coverHeight: number = 0;
  /** 全局路由栈：与 Index 的 @Provider('pageStack') 配对 */
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local private isPressed: boolean = false;

  /** 5 分制评分文案（ratingSum/2 保留 1 位小数；0 表示无评分，返回空串） */
  private ratingText(): string {
    if (this.comic.ratingSum <= 0) {
      return '';
    }
    return (this.comic.ratingSum / 2).toFixed(1);
  }

  /** 作者·年份 摘要（均缺失时返回空串） */
  private authorLine(): string {
    const year: string = this.comic.publishYear;
    const author: string = this.comic.author;
    if (author === '' && year === '') {
      return '';
    }
    return year === '' ? author : (author === '' ? year : `${author} · ${year}`);
  }

  /** 提取前 2 个核心标签 */
  private topTags(): string[] {
    if (this.comic.categories === '') {
      return [];
    }
    const raw: string[] = this.comic.categories.split(/\s+/);
    const out: string[] = [];
    for (let i = 0; i < raw.length && out.length < 2; i++) {
      const t: string = raw[i].trim();
      if (t !== '' && out.indexOf(t) < 0) {
        out.push(t);
      }
    }
    return out;
  }

  build() {
    Column() {
      // 封面：标准 3:4 竖版比例（aspectRatio 0.75）+ 圆角 8vp
      Stack({ alignContent: Alignment.TopStart }) {
        MangaImage({ imageUrl: this.comic.cover, coverFill: true })
          .width('100%')
          .height('100%')
        ComicBadgeOverlay({
          isCompleted: this.comic.isCompleted,
          tags: this.comic.ptag
        })
      }
      .width('100%')
      .aspectRatio(COVER_ASPECT_RATIO)
      .borderRadius(8)
      .clip(true)
      .backgroundColor(ThemeColors.SURFACE)

      // 紧贴封面的紧凑作品信息（标题 14fp Bold 最多 2 行 + 作者/星级/收藏统计 + 前 2 个核心标签胶囊）
      Column({ space: 4 }) {
        Text(this.comic.title)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.TEXT_STRONG)
          .width('100%')
          .maxLines(2)
          .lineHeight(18)
          .constraintSize({ minHeight: 36 })
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.authorLine() !== '' || this.ratingText() !== '' || this.comic.favorites > 0) {
          Row({ space: 6 }) {
            if (this.authorLine() !== '') {
              Text(this.authorLine())
                .fontSize(11)
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
                  .fontSize(11)
                  .fontColor(ThemeColors.RATING)
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
                Text(`${this.comic.favorites}`)
                  .fontSize(11)
                  .fontColor(ThemeColors.TEXT_SECONDARY)
              }
              .alignItems(VerticalAlign.Center)
              .flexShrink(0)
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }

        if (this.topTags().length > 0) {
          Row({ space: 4 }) {
            ForEach(this.topTags(), (tag: string) => {
              Text(tag)
                .fontSize(10)
                .fontColor(ThemeColors.TEXT_SECONDARY)
                .height(18)
                .padding({ left: 6, right: 6 })
                .borderRadius(9)
                .backgroundColor(ThemeColors.SURFACE)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: '48%' })
            }, (tag: string) => tag)
          }
          .width('100%')
        }
      }
      .width('100%')
      .padding(8)
      .alignItems(HorizontalAlign.Start)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .backgroundColor(ThemeColors.CARD)
    .borderRadius(ThemeDims.RADIUS_CARD)
    .clip(true)
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
      // 系统路由跳转：'ComicDetail' 对应 route_map.json 中注册的路由名
      this.pageStack.pushPathByName('ComicDetail', this.comic.id);
    })
  }
}
