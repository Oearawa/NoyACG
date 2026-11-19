/**
 * StatusViews.ets —— 统一加载 / 空数据 / 错误状态组件（Phase 14-D）
 *
 * 三个公共状态视图，供首页 / 书架 / 搜索 / 详情等页面复用，
 * 样式收敛到 Theme 规范，避免各页面各自维护一套相似但不一致的状态 UI。
 *
 * - LoadingState：居中加载圈（可指定提示文字）；
 * - EmptyState：图标 + 主标题 + 可选说明（空书架 / 空结果等）；
 * - ErrorState：标题 + 错误信息 + 重试按钮 + 可选次要操作（如「去登录」）。
 *
 * 全部为纯展示组件：业务回调通过事件传入，不包含任何业务逻辑。
 */
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';

/** 居中加载态 */
@ComponentV2
export struct LoadingState {
  /** 可选提示文字（空串则只显示加载圈） */
  @Param message: string = '';

  build() {
    Column({ space: ThemeDims.SPACE_M }) {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(ThemeColors.PRIMARY)
      if (this.message !== '') {
        Text(this.message)
          .fontSize(ThemeFonts.BODY_SMALL)
          .fontColor(ThemeColors.TEXT_SECONDARY)
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(ThemeColors.BG)
  }
}

/** 空数据态 */
@ComponentV2
export struct EmptyState {
  /** 空态图标（系统符号资源，Phase 15-R2 起不再使用 emoji） */
  @Param icon: Resource = $r('sys.symbol.doc_plaintext');
  /** 主标题 */
  @Param title: ResourceStr = $r('app.string.state_empty_default');
  /** 可选说明文字 */
  @Param message: string = '';

  build() {
    Column({ space: 10 }) {
      SymbolGlyph(this.icon)
        .fontSize(40)
        .fontColor([ThemeColors.PLACEHOLDER])
      Text(this.title)
        .fontSize(15)
        .fontColor(ThemeColors.TEXT)
      if (this.message !== '') {
        Text(this.message)
          .fontSize(ThemeFonts.BODY_SMALL)
          .fontColor(ThemeColors.TEXT_SECONDARY)
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: ThemeDims.PAGE_PADDING, right: ThemeDims.PAGE_PADDING })
    .backgroundColor(ThemeColors.BG)
  }
}

/** 错误态（标题 + 信息 + 重试 + 可选次要操作） */
@ComponentV2
export struct ErrorState {
  /** 错误标题 */
  @Param title: ResourceStr = $r('app.string.state_error_default');
  /** 错误信息（来自 ViewModel，可空） */
  @Param message: string = '';
  /** 主操作文案 */
  @Param retryText: ResourceStr = $r('app.string.common_retry');
  /** 主操作回调（重试） */
  @Event retry: () => void = () => {};
  /** 是否显示次要操作（如「去登录」） */
  @Param showSecondary: boolean = false;
  /** 次要操作文案 */
  @Param secondaryText: string = '';
  /** 次要操作回调 */
  @Event secondary: () => void = () => {};

  build() {
    Column({ space: 12 }) {
      Text(this.title)
        .fontSize(16)
        .fontColor(ThemeColors.TEXT)
      if (this.message !== '') {
        Text(this.message)
          .fontSize(ThemeFonts.BODY_SMALL)
          .fontColor(ThemeColors.TEXT_SECONDARY)
          .textAlign(TextAlign.Center)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Row({ space: 10 }) {
        Button(this.retryText)
          .backgroundColor(ThemeColors.PRIMARY)
          .fontColor(ThemeColors.BG)
          .onClick(() => this.retry())
        if (this.showSecondary) {
          Button(this.secondaryText)
            .backgroundColor(ThemeColors.SURFACE)
            .fontColor(ThemeColors.TEXT)
            .onClick(() => this.secondary())
        }
      }
      .margin({ top: ThemeDims.SPACE_M })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 32, right: 32 })
    .backgroundColor(ThemeColors.BG)
  }
}
