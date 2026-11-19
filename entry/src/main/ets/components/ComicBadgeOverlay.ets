/**
 * ComicBadgeOverlay.ets —— 漫画封面角标层（Phase 14-S 建立，Phase 14-T 收敛规则）
 *
 * 所有封面（海报卡 / 列表项 / 网格卡 / 详情相关推荐）共用本组件，避免各写一套判断。
 *
 * 允许的角标只有两类（任务书 §3.4）：
 *   A. 状态角标（右上）：**仅**当 `isCompleted === true / false` 时出现。
 *      `isCompleted` 由协议层 `resolveCompletion()` 产生，其前提是服务端
 *      `Mode === 1`（多章节）且 `Status` 明确为 0/1；未知一律 null → 不显示。
 *   B. 关键词角标（左上）：仅匹配漫画自身完整标签（Ptag）中的
 *      重口 / 重口味、NTR、大叔，固定顺序、去重。
 *
 * 已移除（Phase 14-T）：
 * - 排行榜名次角标（`rank`）—— 首方榜单页也不显示名次，且该参数从未被任何页面传入；
 * - 评分角标 —— 评分改为卡片信息区的文本，不再占用封面。
 *
 * 性能与交互：
 * - Stack 覆盖层 `.hitTestBehavior(HitTestMode.None)`：角标不吃点击，封面点击照常进入详情；
 * - 不改变封面宽高（宽高 100% 贴合父 Stack），因此不影响图片比例、占位与列表稳定高度；
 * - 只读 @Param，不引入额外状态，不会触发列表项重建。
 *
 * 文案：一律来自 `$r('app.string.*')`，无硬编码中文。
 */
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import {
  BADGE_KEYWORD_KINKY,
  BADGE_KEYWORD_NTR,
  BADGE_KEYWORD_UNCLE,
  BADGE_STATUS_COMPLETED,
  ComicBadgeSet,
  ComicBadgeSpec,
  resolveComicBadgesFromTags
} from '../utils/ComicBadges';

@ComponentV2
export struct ComicBadgeOverlay {
  /**
   * 已确认的完结状态：true = 已完结、false = 连载中、null = 未知。
   * 未知时**不显示**状态角标（绝不默认「连载中」）。
   */
  @Param isCompleted: boolean | null = null;
  /** 当前漫画自身的完整标签列表（服务端 Ptag）；空数组 = 没有标签数据 */
  @Param tags: string[] = [];

  private badges(): ComicBadgeSet {
    return resolveComicBadgesFromTags(this.isCompleted, this.tags);
  }

  /** 关键词角标文案（资源随系统语言解析） */
  private keywordText(spec: ComicBadgeSpec): Resource {
    if (spec.id === BADGE_KEYWORD_KINKY) {
      return $r('app.string.badge_kw_kinky');
    }
    if (spec.id === BADGE_KEYWORD_NTR) {
      return $r('app.string.badge_kw_ntr');
    }
    if (spec.id === BADGE_KEYWORD_UNCLE) {
      return $r('app.string.badge_kw_uncle');
    }
    return $r('app.string.badge_kw_kinky');
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 左上：关键词角标（横向，固定顺序）
      if (this.badges().keywords.length > 0) {
        Row({ space: 4 }) {
          ForEach(this.badges().keywords, (spec: ComicBadgeSpec) => {
            Text(this.keywordText(spec))
              .fontSize(ThemeDims.BADGE_FONT + 1)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemeColors.ON_COVER)
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .borderRadius(ThemeDims.RADIUS_TAG)
              .backgroundColor(ThemeColors.OVERLAY)
              .borderWidth(1)
              .borderColor(ThemeColors.ON_COVER_SUB)
          }, (spec: ComicBadgeSpec) => spec.id)
        }
        .margin({ left: 4, right: 4, top: 4, bottom: 4 })
        .align(Alignment.TopStart)
      }

      // 右上：状态角标（仅当协议层已确认 Mode=1 且 Status 明确时出现）
      if (this.badges().status !== null) {
        Text(this.badges().status!.id === BADGE_STATUS_COMPLETED
          ? $r('app.string.badge_status_completed') : $r('app.string.badge_status_ongoing'))
          .fontSize(ThemeDims.BADGE_FONT + 1)
          .fontColor(ThemeColors.ON_COVER)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(ThemeDims.RADIUS_TAG)
          .backgroundColor(this.badges().status!.id === BADGE_STATUS_COMPLETED
            ? ThemeColors.STATUS_COMPLETED : ThemeColors.STATUS_ONGOING)
          .margin(4)
          .align(Alignment.TopEnd)
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }
}
