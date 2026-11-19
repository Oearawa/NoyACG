/**
 * DetailHeader.ets —— 漫画详情头部与核心操作区
 *
 * 响应式布局：
 * - 宽屏/横屏（compactCover=true，width >= 600vp）：左侧固定 168×240vp 封面 + 右侧完整元数据、标签胶囊与主操作按钮，
 *   消除横屏封面过高及右侧大面积空白；
 * - 竖屏（compactCover=false，width < 600vp）：经典上下流式布局。
 */
import { curves, uiMaterial } from '@kit.ArkUI';
import { ComicDetail as ComicDetailModel, BOOK_MODE_CHAPTERS } from '../../model/ComicDetail';
import { ComicReaderParam } from '../../model/ReaderParam';
import { ROUTE_SEARCH } from '../../model/DiscoveryRoutes';
import { SEARCH_MODE_AUTHOR, SearchParam, buildTagSearchParam } from '../../model/NavParams';
import { ComicDetailViewModel } from '../../viewmodel/ComicDetailViewModel';
import { MangaImage } from '../MangaImage';
import { ThemeColors } from '../../utils/Theme';
import { ThemeManager } from '../../utils/ThemeManager';
import { LocalizationManager } from '../../utils/LocalizationManager';
import { buildPillImmersiveMaterial } from '../../utils/ImmersiveMaterial';
import {
  SPATIAL_PRESS_SCALE,
  resolveSettingsPillBorderColor,
  resolveSettingsPillSurfaceColor
} from '../../utils/MaterialPolicy';
import {
  DETAIL_CHAPTER_TOUCH_TARGET_VP,
  DETAIL_WIDE_COVER_HEIGHT_VP,
  DETAIL_WIDE_COVER_WIDTH_VP
} from '../../utils/ComicDetailLayout';

const HERO_COVER_WIDTH_VP: number = 114;
const HERO_COVER_HEIGHT_VP: number = 152;
const HERO_BACKDROP_HEIGHT_VP: number = 180;

@ComponentV2
export struct DetailHeader {
  @Require @Param detail: ComicDetailModel;
  @Require @Param vm: ComicDetailViewModel;
  @Param compactCover: boolean = false;
  @Param inCard: boolean = false;
  @Event onOpenReader: (param: ComicReaderParam | null) => void = (_p: ComicReaderParam | null): void => {};
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();
  @Local private isFavoritePressed: boolean = false;
  private readonly pillMaterial: uiMaterial.Material | undefined = buildPillImmersiveMaterial();

  private openAuthorSearch(): void {
    const author: string = this.detail.author.trim();
    if (author === '') {
      return;
    }
    this.pageStack.pushPathByName(ROUTE_SEARCH, new SearchParam(author, SEARCH_MODE_AUTHOR));
  }

  private openTagSearch(tag: string): void {
    const clean: string = tag.trim();
    if (clean === '') {
      return;
    }
    this.pageStack.pushPathByName(ROUTE_SEARCH, buildTagSearchParam(clean));
  }

  @Builder
  TagLine(label: string, tags: string[]) {
    Row({ space: 6 }) {
      Text(`${label}:`)
        .fontSize(12)
        .lineHeight(22)
        .fontColor(ThemeColors.TEXT_SECONDARY)
        .width(38)
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(tags, (tag: string) => {
          Text(tag)
            .fontSize(11)
            .fontColor(ThemeColors.TEXT_TERTIARY)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor(ThemeColors.CARD)
            .border({
              width: 1,
              color: resolveSettingsPillBorderColor(this.theme.isDark)
            })
            .borderRadius(10)
            .margin({ right: 5, bottom: 5 })
            .onClick(() => {
              this.openTagSearch(tag);
            })
        }, (tag: string) => tag)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ top: 6 })
  }

  @Builder
  TitleAndFavoriteRow() {
    Row({ space: 8 }) {
      Text(this.detail.title)
        .fontSize(18)
        .lineHeight(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.TEXT_STRONG)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Column() {
        SymbolGlyph(this.vm.isFavorite ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
          .fontSize(19)
          .fontColor([this.vm.isFavorite ? ThemeColors.RATING : ThemeColors.TEXT_STRONG])
          .opacity(this.vm.isFavoritePending ? 0.4 : 1)
      }
      .width(34)
      .height(34)
      .borderRadius(17)
      .backgroundColor(resolveSettingsPillSurfaceColor(this.theme.isDark, this.isFavoritePressed))
      .border({
        width: 1,
        color: resolveSettingsPillBorderColor(this.theme.isDark)
      })
      .systemMaterial(this.pillMaterial)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .scale({
        x: this.isFavoritePressed ? SPATIAL_PRESS_SCALE : 1.0,
        y: this.isFavoritePressed ? SPATIAL_PRESS_SCALE : 1.0
      })
      .animation({ curve: curves.springMotion(0.24, 0.82) })
      .responseRegion({ x: -6, y: -6, width: DETAIL_CHAPTER_TOUCH_TARGET_VP, height: DETAIL_CHAPTER_TOUCH_TARGET_VP })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.isFavoritePressed = true;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.isFavoritePressed = false;
        }
      })
      .onClick(() => {
        this.vm.toggleFavorite();
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  CoreMetaBlock() {
    Column({ space: 4 }) {
      if (this.detail.author !== '') {
        Row({ space: 4 }) {
          Text(this.detail.author)
            .fontSize(12)
            .fontColor(ThemeColors.PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .backgroundColor(resolveSettingsPillSurfaceColor(this.theme.isDark, false))
        .border({
          width: 1,
          color: resolveSettingsPillBorderColor(this.theme.isDark)
        })
        .borderRadius(10)
        .onClick(() => {
          this.openAuthorSearch();
        })
      }

      if (this.detail.rating >= 0) {
        Text(this.lm.getString($r('app.string.detail_rating_fmt'), '评分: %1$s / 5',
          (this.detail.rating / 2).toFixed(1)) +
          (this.detail.ratingCount >= 0
            ? ' ' + this.lm.getString($r('app.string.detail_rating_count_fmt'), '(%d 人评分)', this.detail.ratingCount)
            : ''))
          .fontSize(12)
          .fontColor(ThemeColors.RATING)
      }

      if (this.detail.mode === BOOK_MODE_CHAPTERS && this.detail.isCompleted !== null) {
        Text(this.detail.isCompleted
          ? $r('app.string.badge_status_completed')
          : $r('app.string.badge_status_ongoing'))
          .fontSize(12)
          .fontColor(ThemeColors.TEXT_TERTIARY)
      }

      if (this.detail.publishYear !== '') {
        Text(this.lm.getString($r('app.string.detail_year_fmt'), '出版年份: %s', this.detail.publishYear))
          .fontSize(11)
          .fontColor(ThemeColors.TEXT_SECONDARY)
      }

      if (this.detail.updatedAt !== '') {
        Text(this.lm.getString($r('app.string.detail_updated_fmt'), '最近更新: %s', this.detail.updatedAt))
          .fontSize(11)
          .fontColor(ThemeColors.TEXT_SECONDARY)
      }

      if (this.detail.favorites >= 0) {
        Text(this.lm.getString($r('app.string.detail_favorites_fmt'), '收藏数: %d', this.detail.favorites))
          .fontSize(11)
          .fontColor(ThemeColors.TEXT_SECONDARY)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  TagsAndDescriptionBlock() {
    Column({ space: 0 }) {
      if (this.vm.favoriteNotice !== '') {
        Text(this.vm.favoriteNotice)
          .fontSize(11)
          .fontColor(ThemeColors.TEXT_SECONDARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6 })
      }

      if (this.detail.alias !== '') {
        Text(this.lm.getString($r('app.string.detail_alias_fmt'), '别名: %s', this.detail.alias))
          .fontSize(12)
          .fontColor(ThemeColors.TEXT_SECONDARY)
          .margin({ top: 8 })
      }

      if (this.detail.tags.length > 0) {
        this.TagLine(this.lm.getString($r('app.string.detail_tag_tags'), '标签'), this.detail.tags)
      }
      if (this.detail.characters.length > 0) {
        this.TagLine(this.lm.getString($r('app.string.detail_tag_characters'), '角色'), this.detail.characters)
      }
      if (this.detail.originals.length > 0) {
        this.TagLine(this.lm.getString($r('app.string.detail_tag_originals'), '原作'), this.detail.originals)
      }

      if (this.detail.description !== '') {
        if (this.vm.isDescriptionExpanded) {
          Text(this.detail.description)
            .fontSize(13)
            .fontColor(ThemeColors.TEXT_TERTIARY)
            .lineHeight(20)
            .margin({ top: 10 })
        } else {
          Text(this.detail.description)
            .fontSize(13)
            .fontColor(ThemeColors.TEXT_TERTIARY)
            .lineHeight(20)
            .maxLines(4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 10 })
        }
        Row({ space: 4 }) {
          Text(this.vm.isDescriptionExpanded
            ? $r('app.string.detail_collapse')
            : $r('app.string.detail_expand'))
            .fontSize(12)
            .fontColor(ThemeColors.PRIMARY)
          SymbolGlyph(this.vm.isDescriptionExpanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
            .fontSize(12)
            .fontColor([ThemeColors.PRIMARY])
        }
        .alignItems(VerticalAlign.Center)
        .padding({ top: 6, bottom: 6, right: 12 })
        .onClick(() => {
          this.vm.toggleDescription();
        })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  ActionButtonsBlock() {
    Column({ space: 0 }) {
      if (this.vm.historyChapterId !== '') {
        Text(this.lm.getString($r('app.string.detail_last_read_fmt'), '上次阅读到：%s',
          this.vm.historyChapterTitle === ''
            ? `#${this.vm.historyChapterId}`
            : this.vm.historyChapterTitle))
          .fontSize(11)
          .fontColor(ThemeColors.TEXT_MUTED)
          .margin({ top: 10, bottom: 6 })
      }

      Row({ space: 10 }) {
        Button(this.detail.isSingleBook
          ? $r('app.string.detail_start_reading')
          : $r('app.string.detail_read_from_start'))
          .backgroundColor(ThemeColors.PRIMARY)
          .fontColor(ThemeColors.BG)
          .height(42)
          .layoutWeight(1)
          .onClick(() => {
            this.onOpenReader(this.vm.startReading());
          })
        if (this.vm.hasValidHistory) {
          Button(this.lm.getString($r('app.string.detail_continue_page_fmt'), '继续阅读 · 第 %d 页', this.vm.historyPageIndex))
            .backgroundColor(ThemeColors.SURFACE)
            .fontColor(ThemeColors.TEXT)
            .height(42)
            .layoutWeight(1)
            .onClick(() => {
              this.onOpenReader(this.vm.continueReading());
            })
        }
      }
      .width('100%')
      .margin({ top: this.vm.historyChapterId !== '' ? 0 : 10 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  private coverWidthVp(): number {
    return this.compactCover ? DETAIL_WIDE_COVER_WIDTH_VP : HERO_COVER_WIDTH_VP;
  }

  private coverHeightVp(): number {
    return this.compactCover ? DETAIL_WIDE_COVER_HEIGHT_VP : HERO_COVER_HEIGHT_VP;
  }

  private backdropEndColor(): string {
    if (this.inCard) {
      return this.theme.isDark ? '#1C1E24' : '#FFFFFF';
    }
    return this.theme.isDark ? '#121214' : '#F4F5F8';
  }

  @Builder
  BackdropLayer() {
    Stack() {
      MangaImage({
        imageUrl: this.detail.cover,
        coverFill: true,
        diagLabel: `backdrop:${this.detail.id}`
      })
        .width('100%')
        .height(HERO_BACKDROP_HEIGHT_VP)
        .opacity(0.22)

      Column()
        .width('100%')
        .height(HERO_BACKDROP_HEIGHT_VP)
        .linearGradient({
          angle: 180,
          colors: [
            [this.theme.isDark ? '#66121214' : '#40F4F5F8', 0.0],
            [this.theme.isDark ? '#CC1C1E24' : '#CCF4F5F8', 0.65],
            [this.backdropEndColor(), 1.0]
          ]
        })
    }
    .width('100%')
    .height(HERO_BACKDROP_HEIGHT_VP)
    .clip(true)
  }

  build() {
    Column({ space: 0 }) {
      // 仅头部封面+标题元信息区承载固定 180vp 半透明封面背景并严格裁剪，绝不向下撑满或溢出
      Stack({ alignContent: Alignment.TopStart }) {
        this.BackdropLayer()

        Row({ space: 12 }) {
          Stack() {
            MangaImage({
              imageUrl: this.detail.cover,
              coverFill: true,
              diagLabel: `detail:${this.detail.id}`
            })
              .width(this.coverWidthVp())
              .height(this.coverHeightVp())
          }
          .width(this.coverWidthVp())
          .height(this.coverHeightVp())
          .borderRadius(8)
          .clip(true)
          .backgroundColor(ThemeColors.SURFACE)

          Column({ space: 4 }) {
            this.TitleAndFavoriteRow()
            this.CoreMetaBlock()
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .alignItems(VerticalAlign.Top)
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 10 })
      }
      .width('100%')
      .clip(true)

      Column({ space: 10 }) {
        this.TagsAndDescriptionBlock()
        this.ActionButtonsBlock()
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 12 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
