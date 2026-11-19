/**
 * SectionHeader.ets —— 区块标题行（首页分区通用）
 *
 * Phase 14-H 新增：标题 + 可选「更多 >」入口，对齐原版 R1 榜单区标题行。
 * 「更多」入口仅在有对应列表/接口时由调用方传入，缺接口则不显示（不造假入口）。
 */
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';

@ComponentV2
export struct SectionHeader {
  /** 区块标题 */
  @Require @Param title: ResourceStr = '';
  /** 是否显示「更多 >」（默认不显示；仅当有对应列表入口时传 true） */
  @Param showMore: boolean = false;
  /** 更多入口文案 */
  @Param moreText: ResourceStr = $r('app.string.home_more');
  /** 左侧内边距（vp，横屏首页叠加 SideRail 安全宽度，使标题起始对齐且横向列表可向左穿透至 SideRail 下方） */
  @Param leadingPaddingVp: number = ThemeDims.PAGE_PADDING;
  /** 点击「更多」回调 */
  @Event onMore: () => void = () => {};

  build() {
    Row({ space: ThemeDims.SPACE_M }) {
      Text(this.title)
        .fontSize(ThemeFonts.TITLE_SECTION)
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.TEXT_STRONG)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      if (this.showMore) {
        Row({ space: 2 }) {
          Text(this.moreText)
            .fontSize(ThemeFonts.BODY_SMALL)
            .fontColor(ThemeColors.TEXT_TERTIARY)
          Text('>')
            .fontSize(ThemeFonts.BODY_SMALL)
            .fontColor(ThemeColors.TEXT_TERTIARY)
        }
        // 点击热区：整个「更多 >」胶囊（上下各扩 6vp，左侧扩 8vp），避免只有文字可点
        .padding({ left: 8, right: 2, top: 6, bottom: 6 })
        .margin({ left: ThemeDims.SPACE_M })
        .accessibilityText(typeof this.title === 'string' ? `${this.title}` : '')
        .onClick(() => this.onMore())
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: this.leadingPaddingVp,
      right: ThemeDims.PAGE_PADDING,
      top: ThemeDims.SPACE_L,
      bottom: ThemeDims.SPACE_M
    })
  }
}
