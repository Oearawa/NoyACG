/**
 * CommunityPostDetailPage.ets —— 社区帖子详情与楼中楼交互页（阶段 2）
 *
 * - 消费 NoyClient.postDetail / comments / replies / toggleLike / reply
 * - 顶栏：< 帖子详情 + 作者本人可见编辑入口（区分 data.uid 与 data.post.uid）
 * - 正文与多图：富文本（[pack:name] / NID<bid>）+ spoiler 遮罩解锁 + 大图预览
 * - 双层评论与楼中楼：顶层评论分页（严格依据 over）+ 内嵌子回复预览 + 楼中楼弹窗
 * - 底部悬浮沉浸光感回复输入栏（三层光学玻璃结构）
 */
import { HdsNavDestination } from '@kit.UIDesignKit';
import { uiMaterial } from '@kit.ArkUI';
import { NoyClient } from '../api/NoyClient';
import { CommunityComment, CommunityPost, resolveCommunityImageUrl } from '../models/NoyModels';
import {
  buildSpoilerSet,
  canEditPost,
  clonePostWithLike,
  formatCommunityTime,
  resolvePostImageUrls,
  resolveSpoilerBlurRadius,
  shouldOpenImageOnTap,
  toggleOptimisticLikeState
} from '../utils/CommunityFeedHelper';
import { CommunityViewerController } from '../utils/CommunityViewerController';
import { buildBarImmersiveMaterial, buildPanelImmersiveMaterial } from '../utils/ImmersiveMaterial';
import {
  resolveGlassCapsuleBorderColor,
  resolveGlassCapsuleShadowColor,
  resolveGlassCapsuleTintColor
} from '../utils/MaterialPolicy';
import { PageResult, PagedLoader } from '../utils/PagedLoader';
import { SafeAreaManager } from '../utils/SafeAreaManager';
import { ThemeColors, ThemeDims } from '../utils/Theme';
import { ThemeManager } from '../utils/ThemeManager';
import { LocalizationManager } from '../utils/LocalizationManager';
import { ViewportState } from '../utils/ViewportState';
import { CommunityEditPostSheet } from '../components/CommunityEditPostSheet';
import { CommunityRichText } from '../components/CommunityRichText';
import { MangaImage } from '../components/MangaImage';
import { EmptyState, ErrorState, LoadingState } from '../components/StatusViews';

@ComponentV2
export struct CommunityPostDetailPage {
  @Require @Param postIdParam: string = '';
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();

  @Local private postId: number = 0;
  @Local private currentUid: number = 0;
  @Local private commentCount: number = 0;
  @Local private post: CommunityPost = new CommunityPost();
  @Local private comments: CommunityComment[] = [];
  @Local private loading: boolean = true;
  @Local private loadingMoreComments: boolean = false;
  @Local private commentsOver: boolean = false;
  @Local private errorMessage: string = '';
  @Local private statusBarHeight: number = 36;
  @Local private bottomAvoidVp: number = ViewportState.getInstance().bottomVp;
  @Local private unlockedSpoilerIndices: number[] = [];
  @Local private replyText: string = '';
  @Local private replyTargetRid: number = -1;
  @Local private replyTargetName: string = '';
  @Local private sendingReply: boolean = false;
  @Local private replyFeedback: string = '';
  @Local private showEditSheet: boolean = false;

  // 楼中楼弹窗状态
  @Local private activeSubComment: CommunityComment | null = null;
  @Local private subReplies: CommunityComment[] = [];
  @Local private subLoading: boolean = false;
  @Local private subOver: boolean = false;
  @Local private subError: string = '';

  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();
  private readonly barMaterial: uiMaterial.Material | undefined = buildBarImmersiveMaterial();
  private readonly panelMaterial: uiMaterial.Material | undefined = buildPanelImmersiveMaterial();
  private likingPost: boolean = false;

  private commentLoader?: PagedLoader<CommunityComment>;
  private subReplyLoader?: PagedLoader<CommunityComment>;

  private readonly syncViewport = (): void => {
    const vp: ViewportState = ViewportState.getInstance();
    if (Math.abs(vp.bottomVp - this.bottomAvoidVp) >= 0.01) {
      this.bottomAvoidVp = vp.bottomVp;
    }
  };

  aboutToAppear(): void {
    const parsedId: number = Number(this.postIdParam);
    this.postId = Number.isInteger(parsedId) && parsedId > 0 ? parsedId : 0;
    SafeAreaManager.getStatusBarHeight().then((h: number): void => {
      this.statusBarHeight = h;
    });
    ViewportState.getInstance().addListener(this.syncViewport);
    this.commentLoader = new PagedLoader<CommunityComment>(
      async (page: number): Promise<PageResult<CommunityComment>> => {
        const resp = await NoyClient.getInstance().comments(this.postId, page);
        return {
          items: resp.data.comments,
          over: resp.data.over
        };
      },
      (c: CommunityComment): string => String(c.rid)
    );
    void this.loadAll();
  }

  aboutToDisappear(): void {
    ViewportState.getInstance().removeListener(this.syncViewport);
  }

  private async loadAll(): Promise<void> {
    if (this.postId <= 0) {
      this.loading = false;
      this.errorMessage = this.lm.getString($r('app.string.community_detail_invalid_id'), '无效的帖子 ID');
      return;
    }
    this.loading = true;
    this.errorMessage = '';
    try {
      const detailResp = await NoyClient.getInstance().postDetail(this.postId);
      this.currentUid = detailResp.data.uid;
      this.post = detailResp.data.post;
      this.commentCount = detailResp.data.comment_count > 0
        ? detailResp.data.comment_count
        : detailResp.data.post.reply;
      if (this.commentLoader !== undefined) {
        await this.commentLoader.refresh();
        this.comments = this.commentLoader.items.slice();
        this.commentsOver = this.commentLoader.over;
      }
    } catch (e) {
      this.errorMessage = e instanceof Error
        ? e.message : this.lm.getString($r('app.string.community_detail_load_failed'), '加载帖子详情失败');
    } finally {
      this.loading = false;
    }
  }

  private async loadMoreComments(): Promise<void> {
    if (this.commentLoader === undefined || this.loadingMoreComments || this.commentsOver) {
      return;
    }
    this.loadingMoreComments = true;
    try {
      await this.commentLoader.loadMore();
      this.comments = this.commentLoader.items.slice();
      this.commentsOver = this.commentLoader.over;
    } catch (_e) {
      // 保留已有列表
    } finally {
      this.loadingMoreComments = false;
    }
  }

  private async openSubReplies(comment: CommunityComment): Promise<void> {
    this.activeSubComment = comment;
    this.subReplies = [];
    this.subOver = false;
    this.subError = '';
    this.subLoading = true;
    const rid: number = comment.rid;
    this.subReplyLoader = new PagedLoader<CommunityComment>(
      async (page: number): Promise<PageResult<CommunityComment>> => {
        const resp = await NoyClient.getInstance().replies(this.postId, rid, page);
        return {
          items: resp.data.replies,
          over: resp.data.over
        };
      },
      (c: CommunityComment): string => String(c.rid)
    );
    try {
      await this.subReplyLoader.refresh();
      this.subReplies = this.subReplyLoader.items.slice();
      this.subOver = this.subReplyLoader.over;
    } catch (e) {
      this.subError = e instanceof Error
        ? e.message : this.lm.getString($r('app.string.community_detail_sub_failed'), '加载楼中楼失败');
    } finally {
      this.subLoading = false;
    }
  }

  private async loadMoreSubReplies(): Promise<void> {
    if (this.subReplyLoader === undefined || this.subLoading || this.subOver) {
      return;
    }
    this.subLoading = true;
    try {
      await this.subReplyLoader.loadMore();
      this.subReplies = this.subReplyLoader.items.slice();
      this.subOver = this.subReplyLoader.over;
    } catch (_e) {
      // 忽略增量失败
    } finally {
      this.subLoading = false;
    }
  }

  private async handleTogglePostLike(): Promise<void> {
    if (this.likingPost || this.post.id <= 0) {
      return;
    }
    this.likingPost = true;
    const prevLiked: boolean = this.post.is_like;
    const prevCount: number = this.post.like;
    const opt = toggleOptimisticLikeState(prevLiked, prevCount);
    this.post = clonePostWithLike(this.post, opt.is_like, opt.like);
    try {
      const serverLiked: boolean = await NoyClient.getInstance().toggleLike(this.post.id);
      if (serverLiked !== opt.is_like) {
        const reconciledCount: number = Math.max(0, prevCount + (serverLiked ? 1 : -1));
        this.post = clonePostWithLike(this.post, serverLiked, reconciledCount);
      }
    } catch (_e) {
      this.post = clonePostWithLike(this.post, prevLiked, prevCount);
    } finally {
      this.likingPost = false;
    }
  }

  private async handleSendReply(): Promise<void> {
    const clean: string = this.replyText.trim();
    if (clean === '' || this.sendingReply || this.postId <= 0) {
      return;
    }
    this.sendingReply = true;
    this.replyFeedback = '';
    const targetRid: number = this.replyTargetRid;
    try {
      await NoyClient.getInstance().reply(this.postId, clean, targetRid);
      this.replyText = '';
      this.replyTargetRid = -1;
      this.replyTargetName = '';
      this.commentCount = this.commentCount + 1;
      if (this.commentLoader !== undefined) {
        await this.commentLoader.refresh();
        this.comments = this.commentLoader.items.slice();
        this.commentsOver = this.commentLoader.over;
      }
      if (this.activeSubComment !== null && this.subReplyLoader !== undefined) {
        await this.subReplyLoader.refresh();
        this.subReplies = this.subReplyLoader.items.slice();
        this.subOver = this.subReplyLoader.over;
      }
    } catch (e) {
      this.replyFeedback = e instanceof Error
        ? e.message : this.lm.getString($r('app.string.community_detail_reply_failed'), '发送回复失败');
    } finally {
      this.sendingReply = false;
    }
  }

  private isSpoilerTagged(idx: number): boolean {
    return buildSpoilerSet(this.post.spoiler).has(idx);
  }

  private isSpoilerRevealed(idx: number): boolean {
    if (!this.isSpoilerTagged(idx)) {
      return true;
    }
    return this.unlockedSpoilerIndices.indexOf(idx) >= 0;
  }

  private unlockSpoiler(idx: number): void {
    if (this.unlockedSpoilerIndices.indexOf(idx) < 0) {
      const next: number[] = this.unlockedSpoilerIndices.slice();
      next.push(idx);
      this.unlockedSpoilerIndices = next;
    }
  }

  private hideSpoiler(idx: number): void {
    const pos: number = this.unlockedSpoilerIndices.indexOf(idx);
    if (pos >= 0) {
      const next: number[] = this.unlockedSpoilerIndices.slice();
      next.splice(pos, 1);
      this.unlockedSpoilerIndices = next;
    }
  }

  private openBookDetail(bid: number): void {
    if (bid > 0) {
      this.pageStack.pushPathByName('ComicDetail', String(bid));
    }
  }

  build() {
    HdsNavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {
          this.TopNavBar()

          if (this.loading) {
            LoadingState({ message: this.lm.getString($r('app.string.community_detail_loading'), '正在加载帖子详情...') })
              .layoutWeight(1)
          } else if (this.errorMessage !== '') {
            ErrorState({
              message: this.errorMessage,
              retry: (): void => {
                void this.loadAll();
              }
            })
              .layoutWeight(1)
          } else {
            List({ space: 12 }) {
              ListItem() {
                this.PostBodyCard()
              }

              ListItem() {
                Row() {
                  Text(this.lm.getString(
                    $r('app.string.community_detail_all_comments_fmt'),
                    '全部评论 (%d)',
                    this.commentCount
                  ))
                    .fontSize(15)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(ThemeColors.TEXT)
                }
                .width('100%')
                .padding({ top: 4, bottom: 2 })
              }

              if (this.comments.length === 0) {
                ListItem() {
                  EmptyState({ title: this.lm.getString($r('app.string.community_detail_no_comments'), '暂无评论，快来抢沙发') })
                    .height(180)
                }
              } else {
                ForEach(this.comments, (comment: CommunityComment) => {
                  ListItem() {
                    this.CommentCard(comment)
                  }
                }, (comment: CommunityComment): string => `${comment.rid}_${comment.reply_num}_${comment.replies.length}`)
              }

              ListItem() {
                Column() {
                  if (this.loadingMoreComments) {
                    Text($r('app.string.community_detail_loading_comments'))
                      .fontSize(12)
                      .fontColor(ThemeColors.TEXT_MUTED)
                      .padding(12)
                  } else if (this.commentsOver && this.comments.length > 0) {
                    Text($r('app.string.community_detail_all_comments'))
                      .fontSize(12)
                      .fontColor(ThemeColors.TEXT_MUTED)
                      .padding(12)
                  }
                }
                .width('100%')
                .alignItems(HorizontalAlign.Center)
              }

              ListItem() {
                Column().width('100%').height(84 + this.bottomAvoidVp)
              }
            }
            .width('100%')
            .layoutWeight(1)
            .padding({ left: ThemeDims.PAGE_PADDING, right: ThemeDims.PAGE_PADDING, top: 8 })
            .edgeEffect(EdgeEffect.Spring)
            .onReachEnd((): void => {
              void this.loadMoreComments();
            })
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor(ThemeColors.BG)

        // 底部悬浮沉浸光感回复输入栏
        if (!this.loading && this.errorMessage === '') {
          this.FloatingReplyBar()
        }

        // 楼中楼弹窗
        if (this.activeSubComment !== null) {
          this.SubRepliesModal(this.activeSubComment)
        }

        // 作者编辑弹窗
        if (this.showEditSheet) {
          CommunityEditPostSheet({
            postId: this.post.id,
            initialTitle: this.post.title,
            initialContent: this.post.content,
            onClose: (): void => {
              this.showEditSheet = false;
            },
            onSaved: (): void => {
              this.showEditSheet = false;
              void this.loadAll();
            }
          })
        }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .onBackPressed((): boolean => {
      if (CommunityViewerController.getInstance().closeIfOpen()) {
        return true;
      }
      if (this.showEditSheet) {
        this.showEditSheet = false;
        return true;
      }
      if (this.activeSubComment !== null) {
        this.activeSubComment = null;
        return true;
      }
      return false;
    })
  }

  @Builder
  TopNavBar() {
    Row({ space: 8 }) {
      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(20)
          .fontColor([ThemeColors.TEXT])
        Text($r('app.string.community_detail_title'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.TEXT)
      }
      .height(40)
      .padding({ right: 12 })
      .onClick((): void => {
        this.pageStack.pop();
      })

      Blank()

      if (canEditPost(this.currentUid, this.post.uid)) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.square_and_pencil'))
            .fontSize(17)
            .fontColor([ThemeColors.PRIMARY])
          Text($r('app.string.common_edit'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.PRIMARY)
        }
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(14)
        .backgroundColor(ThemeColors.SURFACE)
        .onClick((): void => {
          this.showEditSheet = true;
        })
      }
    }
    .width('100%')
    .padding({
      top: this.statusBarHeight + 4,
      left: ThemeDims.PAGE_PADDING,
      right: ThemeDims.PAGE_PADDING,
      bottom: 8
    })
    .backgroundColor(ThemeColors.BG)
  }

  @Builder
  PostBodyCard() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Stack() {
          if (this.post.avatar !== '') {
            MangaImage({
              imageUrl: resolveCommunityImageUrl(this.post.avatar),
              coverFill: true,
              allowTapRetry: false,
              diagLabel: 'detail-avatar'
            })
          } else {
            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.person_fill'))
                .fontSize(20)
                .fontColor([ThemeColors.TEXT_MUTED])
            }
            .width('100%')
            .height('100%')
            .backgroundColor(ThemeColors.SURFACE)
          }
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .clip(true)

        Column({ space: 2 }) {
          Text(this.post.username !== '' ? this.post.username : `UID ${this.post.uid}`)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.TEXT)
          Text(formatCommunityTime(this.post.time, Date.now(), this.lm.effectiveLocale))
            .fontSize(12)
            .fontColor(ThemeColors.TEXT_MUTED)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      if (this.post.title !== '') {
        Text(this.post.title)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.TEXT)
          .width('100%')
      }

      if (this.post.content !== '') {
        CommunityRichText({
          content: this.post.content,
          fontSizeFp: 15,
          textColor: ThemeColors.TEXT,
          onOpenBook: (bid: number): void => {
            this.openBookDetail(bid);
          }
        })
      }

      if (this.post.image.length > 0) {
        Column({ space: 8 }) {
          ForEach(resolvePostImageUrls(this.post), (imgUrl: string, idx: number) => {
            Stack({ alignContent: Alignment.TopEnd }) {
              MangaImage({
                imageUrl: imgUrl,
                allowTapRetry: true,
                blurRadius: resolveSpoilerBlurRadius(
                  this.isSpoilerTagged(idx),
                  this.isSpoilerRevealed(idx)
                ),
                diagLabel: `detail-img-${this.post.id}-${idx}`
              })
                .width('100%')

              if (this.isSpoilerTagged(idx) && !this.isSpoilerRevealed(idx)) {
                Column({ space: 6 }) {
                  SymbolGlyph($r('sys.symbol.eye_slash'))
                    .fontSize(26)
                    .fontColor(['#FFFFFF'])
                  Text($r('app.string.community_spoiler_hint'))
                    .fontSize(12)
                    .fontColor('#FFFFFF')
                }
                .width('100%')
                .height('100%')
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor('#610F1218')
              } else if (this.isSpoilerTagged(idx)) {
                Stack({ alignContent: Alignment.Center }) {
                  SymbolGlyph($r('sys.symbol.eye_slash'))
                    .fontSize(14)
                    .fontColor(['#FFFFFF'])
                }
                .width(28)
                .height(28)
                .borderRadius(14)
                .backgroundColor('#80000000')
                .margin(8)
                .onClick((): void => {
                  this.hideSpoiler(idx);
                })
              }
            }
            .width('100%')
            .borderRadius(12)
            .clip(true)
            .onClick((): void => {
              const isSpoiler: boolean = this.isSpoilerTagged(idx);
              const isRevealed: boolean = this.isSpoilerRevealed(idx);
              if (!shouldOpenImageOnTap(isSpoiler, isRevealed)) {
                this.unlockSpoiler(idx);
              } else {
                CommunityViewerController.getInstance().open(imgUrl);
              }
            })
          }, (imgUrl: string, idx: number): string => `detail_${idx}_${imgUrl}`)
        }
        .width('100%')
      }

      Row({ space: 20 }) {
        Row({ space: 6 }) {
          SymbolGlyph(this.post.is_like ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
            .fontSize(18)
            .fontColor([this.post.is_like ? ThemeColors.ERROR : ThemeColors.TEXT_TERTIARY])
          Text(`${this.post.like}`)
            .fontSize(14)
            .fontColor(this.post.is_like ? ThemeColors.ERROR : ThemeColors.TEXT_TERTIARY)
        }
        .padding({ left: 10, right: 12, top: 6, bottom: 6 })
        .borderRadius(16)
        .backgroundColor(ThemeColors.SURFACE)
        .onClick((): void => {
          void this.handleTogglePostLike();
        })

        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.message'))
            .fontSize(17)
            .fontColor([ThemeColors.TEXT_TERTIARY])
          Text(`${this.commentCount}`)
            .fontSize(14)
            .fontColor(ThemeColors.TEXT_TERTIARY)
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(ThemeColors.CARD)
    .borderRadius(16)
    .border({
      width: 1,
      color: resolveGlassCapsuleBorderColor(this.theme.isDark)
    })
  }

  @Builder
  CommentCard(comment: CommunityComment) {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Stack() {
          if (comment.avatar !== '') {
            MangaImage({
              imageUrl: resolveCommunityImageUrl(comment.avatar),
              coverFill: true,
              allowTapRetry: false,
              diagLabel: 'comment-avatar'
            })
          } else {
            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.person_fill'))
                .fontSize(15)
                .fontColor([ThemeColors.TEXT_MUTED])
            }
            .width('100%')
            .height('100%')
            .backgroundColor(ThemeColors.SURFACE)
          }
        }
        .width(32)
        .height(32)
        .borderRadius(16)
        .clip(true)

        Column({ space: 1 }) {
          Text(comment.username !== '' ? comment.username : `UID ${comment.uid}`)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.TEXT)
          Text(formatCommunityTime(comment.time, Date.now(), this.lm.effectiveLocale))
            .fontSize(11)
            .fontColor(ThemeColors.TEXT_MUTED)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.message'))
            .fontSize(14)
            .fontColor([ThemeColors.TEXT_TERTIARY])
          Text($r('app.string.common_reply'))
            .fontSize(12)
            .fontColor(ThemeColors.TEXT_TERTIARY)
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(12)
        .backgroundColor(ThemeColors.SURFACE)
        .onClick((): void => {
          this.replyTargetRid = comment.rid;
          this.replyTargetName = comment.username !== '' ? comment.username : `UID ${comment.uid}`;
        })
      }
      .width('100%')

      CommunityRichText({
        content: comment.content,
        fontSizeFp: 14,
        textColor: ThemeColors.TEXT,
        onOpenBook: (bid: number): void => {
          this.openBookDetail(bid);
        }
      })

      // 内嵌子回复预览 + 楼中楼入口
      if (comment.replies.length > 0 || comment.reply_more || comment.reply_num > 0) {
        Column({ space: 6 }) {
          ForEach(comment.replies, (sub: CommunityComment) => {
            Row({ space: 4 }) {
              Text(sub.reply_username !== ''
                ? `${sub.username} ${this.lm.getString($r('app.string.common_reply'), '回复')} ${sub.reply_username}: `
                : `${sub.username}: `)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(ThemeColors.PRIMARY)
              Text(sub.content)
                .fontSize(12)
                .fontColor(ThemeColors.TEXT_SECONDARY)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }, (sub: CommunityComment): string => `sub_${comment.rid}_${sub.rid}`)

          if (comment.reply_more || comment.reply_num > comment.replies.length) {
            Text(comment.reply_num > 0
              ? this.lm.getString($r('app.string.community_detail_view_replies_count'), '查看全部 %d 条回复 >', comment.reply_num)
              : this.lm.getString($r('app.string.community_detail_view_replies'), '查看全部回复 >'))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemeColors.PRIMARY)
              .padding({ top: 2 })
          }
        }
        .width('100%')
        .padding(10)
        .borderRadius(10)
        .backgroundColor(ThemeColors.SURFACE)
        .onClick((): void => {
          void this.openSubReplies(comment);
        })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(ThemeColors.CARD)
    .borderRadius(14)
    .border({
      width: 1,
      color: resolveGlassCapsuleBorderColor(this.theme.isDark)
    })
  }

  @Builder
  FloatingReplyBar() {
    Column({ space: 6 }) {
      if (this.replyTargetRid > 0) {
        Row({ space: 8 }) {
          Text(`${this.lm.getString($r('app.string.common_reply'), '回复')} @${this.replyTargetName}`)
            .fontSize(12)
            .fontColor(ThemeColors.PRIMARY)
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(14)
            .fontColor([ThemeColors.TEXT_MUTED])
            .onClick((): void => {
              this.replyTargetRid = -1;
              this.replyTargetName = '';
            })
        }
        .width('100%')
        .padding({ left: 6, right: 6 })
      }

      if (this.replyFeedback !== '') {
        Text(this.replyFeedback)
          .fontSize(11)
          .fontColor(ThemeColors.ERROR)
          .width('100%')
          .padding({ left: 6, right: 6 })
      }

      Row({ space: 8 }) {
        TextInput({
          placeholder: this.replyTargetRid > 0
            ? this.lm.getString($r('app.string.community_detail_reply_to'), '回复 @%s...', this.replyTargetName)
            : this.lm.getString($r('app.string.community_detail_comment_ph'), '写下你的评论...'),
          text: this.replyText
        })
          .layoutWeight(1)
          .height(38)
          .fontSize(14)
          .fontColor(ThemeColors.TEXT)
          .backgroundColor(ThemeColors.SURFACE)
          .borderRadius(19)
          .padding({ left: 14, right: 14 })
          .onChange((val: string): void => {
            this.replyText = val;
          })

        Text(this.sendingReply ? $r('app.string.common_sending') : $r('app.string.common_send'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.ON_PRIMARY)
          .padding({ left: 14, right: 14, top: 9, bottom: 9 })
          .borderRadius(18)
          .backgroundColor(this.replyText.trim() !== '' && !this.sendingReply
            ? ThemeColors.PRIMARY
            : ThemeColors.TEXT_MUTED)
          .onClick((): void => {
            void this.handleSendReply();
          })
      }
      .width('100%')
    }
    .width('92%')
    .constraintSize({ maxWidth: 620 })
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .borderRadius(24)
    .backgroundColor(resolveGlassCapsuleTintColor(this.theme.isDark))
    .border({
      width: 1,
      color: resolveGlassCapsuleBorderColor(this.theme.isDark)
    })
    .shadow({
      radius: 24,
      color: resolveGlassCapsuleShadowColor(this.theme.isDark),
      offsetX: 0,
      offsetY: 6
    })
    .systemMaterial(this.barMaterial)
    .margin({ bottom: Math.max(12, this.bottomAvoidVp + 8) })
  }

  @Builder
  SubRepliesModal(rootComment: CommunityComment) {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick((): void => {
          this.activeSubComment = null;
        })

      Column({ space: 10 }) {
        Row() {
          Text($r('app.string.community_detail_sub_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.TEXT)
            .layoutWeight(1)

          Text($r('app.string.community_detail_reply_comment'))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.PRIMARY)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(12)
            .backgroundColor(ThemeColors.SURFACE)
            .margin({ right: 8 })
            .onClick((): void => {
              this.replyTargetRid = rootComment.rid;
              this.replyTargetName = rootComment.username !== '' ? rootComment.username : `UID ${rootComment.uid}`;
              this.activeSubComment = null;
            })

          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(18)
              .fontColor([ThemeColors.TEXT_SECONDARY])
          }
          .width(32)
          .height(32)
          .borderRadius(16)
          .backgroundColor(ThemeColors.SURFACE)
          .onClick((): void => {
            this.activeSubComment = null;
          })
        }
        .width('100%')

        // 原评论摘要
        Column({ space: 4 }) {
          Text(rootComment.username !== '' ? rootComment.username : `UID ${rootComment.uid}`)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.PRIMARY)
          Text(rootComment.content)
            .fontSize(13)
            .fontColor(ThemeColors.TEXT_SECONDARY)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(10)
        .borderRadius(12)
        .backgroundColor(ThemeColors.SURFACE)

        if (this.subLoading && this.subReplies.length === 0) {
          LoadingState({ message: this.lm.getString($r('app.string.community_detail_loading_replies'), '正在加载回复...') })
            .height(160)
        } else if (this.subError !== '' && this.subReplies.length === 0) {
          ErrorState({
            message: this.subError,
            retry: (): void => {
              void this.openSubReplies(rootComment);
            }
          })
            .height(160)
        } else {
          List({ space: 8 }) {
            ForEach(this.subReplies, (sub: CommunityComment) => {
              ListItem() {
                Column({ space: 4 }) {
                  Row({ space: 6 }) {
                    Text(sub.username !== '' ? sub.username : `UID ${sub.uid}`)
                      .fontSize(13)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(ThemeColors.TEXT)
                    if (sub.reply_username !== '') {
                      Text(`${this.lm.getString($r('app.string.common_reply'), '回复')} ${sub.reply_username}`)
                        .fontSize(12)
                        .fontColor(ThemeColors.PRIMARY)
                    }
                    Blank()
                    Text(formatCommunityTime(sub.time, Date.now(), this.lm.effectiveLocale))
                      .fontSize(11)
                      .fontColor(ThemeColors.TEXT_MUTED)
                  }
                  .width('100%')

                  CommunityRichText({
                    content: sub.content,
                    fontSizeFp: 13,
                    textColor: ThemeColors.TEXT_SECONDARY,
                    onOpenBook: (bid: number): void => {
                      this.openBookDetail(bid);
                    }
                  })
                }
                .width('100%')
                .padding(10)
                .borderRadius(10)
                .backgroundColor(ThemeColors.CARD)
              }
            }, (sub: CommunityComment): string => `sheet_sub_${sub.rid}`)

            if (this.subOver && this.subReplies.length > 0) {
              ListItem() {
                Text($r('app.string.community_detail_all_replies'))
                  .fontSize(12)
                  .fontColor(ThemeColors.TEXT_MUTED)
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding(8)
              }
            }
          }
          .width('100%')
          .layoutWeight(1)
          .onReachEnd((): void => {
            void this.loadMoreSubReplies();
          })
        }
      }
      .width('100%')
      .height('72%')
      .padding({
        left: 16,
        right: 16,
        top: 16,
        bottom: Math.max(16, this.bottomAvoidVp + 8)
      })
      .borderRadius({ topLeft: 24, topRight: 24 })
      .backgroundColor(resolveGlassCapsuleTintColor(this.theme.isDark))
      .border({
        width: 1,
        color: resolveGlassCapsuleBorderColor(this.theme.isDark)
      })
      .shadow({
        radius: 24,
        color: resolveGlassCapsuleShadowColor(this.theme.isDark),
        offsetX: 0,
        offsetY: -4
      })
      .systemMaterial(this.panelMaterial)
    }
    .width('100%')
    .height('100%')
  }
}

/** 系统路由表构建函数：与 route_map.json 的 "CommunityPostDetailPageBuilder" 对应 */
@Builder
export function CommunityPostDetailPageBuilder(name: string, param?: object) {
  CommunityPostDetailPage({ postIdParam: param === undefined ? '' : String(param) })
}
