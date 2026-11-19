/**
 * CommentSection.ets —— 漫画详情评论区（官方置顶 + 用户评论只读分页 + 错误重试 + 底部安全区避让）
 */
import { ComicDetail as ComicDetailModel } from '../../model/ComicDetail';
import { BookComment } from '../../model/BookComment';
import { ComicDetailViewModel } from '../../viewmodel/ComicDetailViewModel';
import { ThemeColors } from '../../utils/Theme';
import { LocalizationManager } from '../../utils/LocalizationManager';

@ComponentV2
export struct CommentSection {
  @Require @Param detail: ComicDetailModel;
  @Require @Param vm: ComicDetailViewModel;
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();

  @Builder
  CommentItem(c: BookComment) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(c.isOfficial
          ? this.lm.getString($r('app.string.detail_official_notice'), '官方公告')
          : (c.username === ''
            ? this.lm.getString($r('app.string.detail_user_num_fmt'), '用户 #%d', c.uid)
            : c.username))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(c.isOfficial ? ThemeColors.PRIMARY : ThemeColors.TEXT)
        if (c.area !== '') {
          Text(c.area)
            .fontSize(11)
            .fontColor(ThemeColors.TEXT_MUTED)
        }
        Blank()
        if (c.time !== '') {
          Text(c.time)
            .fontSize(11)
            .fontColor(ThemeColors.TEXT_MUTED)
        }
      }
      .width('100%')

      Text(c.content)
        .fontSize(13)
        .fontColor(ThemeColors.TEXT_TERTIARY)
        .width('100%')

      if (c.replies.length > 0) {
        ForEach(c.replies, (r: BookComment) => {
          Row({ space: 6 }) {
            Text(r.username === ''
          ? this.lm.getString($r('app.string.detail_user_num_fmt'), '用户 #%d', r.uid)
          : r.username)
              .fontSize(12)
              .fontColor(ThemeColors.PRIMARY)
            Text(r.content)
              .fontSize(12)
              .fontColor(ThemeColors.TEXT_SECONDARY)
              .layoutWeight(1)
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding({ top: 4 })
        }, (r: BookComment) => `reply-${r.cid}`)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(ThemeColors.CARD)
    .borderRadius(6)
    .margin({ left: 12, right: 12, top: 4, bottom: 4 })
  }

  build() {
    Column({ space: 0 }) {
      Text(this.lm.getString($r('app.string.detail_comments_header_fmt'), '评论 (%d)', this.vm.visibleCommentCount()))
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemeColors.TEXT)
        .margin({ left: 16, right: 16, top: 18, bottom: 4 })

      // 评论独立加载/错误/空态
      if (this.vm.commentLoading && this.vm.comments.length === 0) {
        Row({ space: 8 }) {
          LoadingProgress().width(18).height(18)
          Text($r('app.string.detail_comments_loading'))
            .fontSize(12)
            .fontColor(ThemeColors.TEXT_MUTED)
        }
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      } else if (this.vm.commentError !== '' && this.vm.comments.length === 0) {
        Row({ space: 10 }) {
          Text(this.vm.commentError)
            .fontSize(12)
            .fontColor(ThemeColors.TEXT_SECONDARY)
            .layoutWeight(1)
          Button($r('app.string.common_retry'))
            .fontSize(12)
            .height(32)
            .backgroundColor(ThemeColors.SURFACE)
            .fontColor(ThemeColors.TEXT)
            .onClick(() => {
              this.vm.loadComments(false);
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      } else if (this.vm.comments.length === 0 && this.detail.comments.length === 0) {
        Text($r('app.string.detail_comments_empty'))
          .fontSize(12)
          .fontColor(ThemeColors.TEXT_MUTED)
          .padding({ left: 16, right: 16, top: 10, bottom: 12 })
      }

      // 用户评论（分页加载）
      ForEach(this.vm.comments, (c: BookComment) => {
        this.CommentItem(c)
      }, (c: BookComment) => c.cid)

      if (this.vm.commentError !== '' && this.vm.comments.length > 0) {
        Row({ space: 10 }) {
          Text(this.vm.commentError)
            .fontSize(12)
            .fontColor(ThemeColors.TEXT_SECONDARY)
          Button($r('app.string.detail_comments_retry_more'))
            .fontSize(12)
            .height(32)
            .backgroundColor(ThemeColors.SURFACE)
            .fontColor(ThemeColors.TEXT)
            .onClick(() => {
              this.vm.loadComments(true);
            })
        }
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      } else if (this.vm.commentHasMore) {
        Button(this.vm.commentLoading
          ? $r('app.string.message_loading')
          : $r('app.string.detail_comments_load_more'))
          .backgroundColor(ThemeColors.SURFACE)
          .fontColor(ThemeColors.TEXT)
          .fontSize(13)
          .height(40)
          .margin({ left: 16, right: 16, top: 8, bottom: 12 })
          .onClick(() => {
            this.vm.loadComments(true);
          })
      } else if (this.vm.comments.length > 0) {
        Text($r('app.string.detail_comments_end'))
          .fontSize(11)
          .fontColor(ThemeColors.TEXT_MUTED)
          .margin({ left: 16, right: 16, top: 8, bottom: 12 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
