/**
 * HomeRankSectionComponent.ets —— 首页横向榜单分区组件（@ComponentV2）
 *
 * 独立 @ComponentV2 子组件 + BasicDataSource<Comic> + LazyForEach，
 * 彻底消除父组件 @Builder 值传递参数在 ArkUI V2 下的状态更新盲区。
 */
import { Comic } from '../model/Comic';
import { BasicDataSource } from '../utils/BasicDataSource';
import { ThemeColors, ThemeDims } from '../utils/Theme';
import { ComicPosterCard } from './ComicPosterCard';
import { SectionHeader } from './SectionHeader';

@ComponentV2
export struct HomeRankSectionComponent {
  /** 分区标题 */
  @Require @Param title: string;
  /** 分区懒加载数据源 */
  @Require @Param dataSource: BasicDataSource<Comic>;
  /** 当前条目数（由 VM @Trace 驱动外层显隐） */
  @Require @Param itemCount: number;
  /** 卡片宽度（vp） */
  @Require @Param cardWidth: number;
  /** 卡片高度（vp） */
  @Require @Param cardHeight: number;
  /** 左侧起始内边距（vp，横屏叠加 SideRail 占位宽度，使横向列表向左滑动时卡片可滚入 SideRail 玻璃下方） */
  @Param leadingPaddingVp: number = ThemeDims.PAGE_PADDING;
  /** 是否处于冷启动首轮加载态（itemCount 为 0 时展示等高轻量占位骨架，消除顶栏下沉与首几帧跳闪） */
  @Param isLoading: boolean = false;
  /** 已提交的内容分级版本号（参与 LazyForEach keyGenerator，确保分级切换后强制重建卡片） */
  @Param ratingRevision: number = 0;
  /** 首页聚合数据版本号（参与 LazyForEach keyGenerator，确保刷新后重建卡片） */
  @Param feedRevision: number = 0;
  /** 点击「更多」回调 */
  @Event onMore: () => void = (): void => {};

  build() {
    if (this.itemCount > 0) {
      Column() {
        SectionHeader({
          title: this.title,
          showMore: true,
          leadingPaddingVp: this.leadingPaddingVp,
          onMore: this.onMore
        })
        List({ space: ThemeDims.GRID_GAP }) {
          LazyForEach(this.dataSource, (comic: Comic) => {
            ListItem() {
              ComicPosterCard({ comic: comic, cardWidth: this.cardWidth, cardHeight: this.cardHeight })
            }
            .width(this.cardWidth)
            .height(this.cardHeight)
          }, (comic: Comic): string => `${comic.id}_${this.ratingRevision}_${this.feedRevision}`)
        }
        .listDirection(Axis.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(2)
        .padding({ left: this.leadingPaddingVp, right: ThemeDims.PAGE_PADDING })
        .width('100%')
        .height(this.cardHeight)
      }
      .width('100%')
    } else if (this.isLoading) {
      Column() {
        SectionHeader({
          title: this.title,
          showMore: true,
          leadingPaddingVp: this.leadingPaddingVp,
          onMore: this.onMore
        })
        Row({ space: ThemeDims.GRID_GAP }) {
          ForEach([0, 1, 2], (idx: number) => {
            Column()
              .width(this.cardWidth)
              .height(this.cardHeight)
              .borderRadius(ThemeDims.RADIUS_CARD)
              .backgroundColor(ThemeColors.SURFACE)
          }, (idx: number) => `${idx}`)
        }
        .width('100%')
        .height(this.cardHeight)
        .padding({ left: this.leadingPaddingVp, right: ThemeDims.PAGE_PADDING })
        .clip(true)
      }
      .width('100%')
    }
  }
}
