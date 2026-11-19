/**
 * CommunityComponent.ets —— 社区帖子列表页（阶段 2）
 *
 * - 顶栏：左侧「社区」标题 + 搜索触发 + 未读消息红点铃铛（前台 >= 60s 轮询）
 * - 三层沉浸光感分段器：最新发布 (new) | 最新回复 (latest) | 最多点赞 (like)
 * - 帖子卡片：头像（bucket + Referer）、昵称、时间、置顶徽标、标题、摘要、
 *   图片网格（支持 spoiler 点击解锁 + 大图预览）、乐观点赞与评论入口
 * - 分页：严格依据 resp.over !== true，绝不使用会漂移的 len
 * - 右下角三层沉浸光感悬浮「发帖」按钮（阶段 3 接入完整发帖器）
 */
import { uiMaterial } from '@kit.ArkUI';
import { NoyClient } from '../api/NoyClient';
import { CommunityPost, resolveCommunityImageUrl } from '../models/NoyModels';
import { AuthManager } from '../utils/AuthManager';
import { mainTabBottomClearanceVp } from '../utils/BottomInset';
import {
  buildSpoilerSet,
  COMMUNITY_SORT_OPTIONS,
  communitySortOptions,
  clonePostWithLike,
  formatCommunityTime,
  isPostPinned,
  isUnreadPollDue,
  resolvePostImageUrls,
  resolveSpoilerBlurRadius,
  shouldOpenImageOnTap,
  toggleOptimisticLikeState
} from '../utils/CommunityFeedHelper';
import { BackInterceptRegistry } from '../utils/BackInterceptRegistry';
import { CommunityViewerController } from '../utils/CommunityViewerController';
import { buildPillImmersiveMaterial } from '../utils/ImmersiveMaterial';
import {
  springPressCurve,
  springPressOpacity,
  springPressScale
} from '../utils/SpringMotion';
import { Logger } from '../utils/Logger';
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
import { CommunityCreatePostSheet } from './CommunityCreatePostSheet';
import { CommunityRichText } from './CommunityRichText';
import { MangaImage } from './MangaImage';
import { SegmentSelector } from './SegmentSelector';
import { EmptyState, ErrorState, LoadingState } from './StatusViews';

const TAG: string = 'CommunityComponent';

@ComponentV2
export struct CommunityComponent {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Param active: boolean = true;
  @Param isTopRoute: boolean = true;
  @Event onOpenComposer: () => void = (): void => {};

  @Local private statusBarHeight: number = 36;
  @Local private sortIndex: number = 0;
  @Local private searchOpen: boolean = false;
  @Local private searchInput: string = '';
  @Local private appliedFilter: string = '';
  @Local private posts: CommunityPost[] = [];
  @Local private hasTopPost: boolean = false;
  @Local private loading: boolean = false;
  @Local private loadingMore: boolean = false;
  @Local private refreshing: boolean = false;
  @Local private over: boolean = false;
  @Local private errorMessage: string = '';
  @Local private loadMoreError: string = '';
  @Local private unreadCount: number = 0;
  @Local private unlockedSpoilerKeys: string[] = [];
  @Local private showComposerSheet: boolean = false;
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();

  private readonly pillMaterial: uiMaterial.Material | undefined = buildPillImmersiveMaterial();
  private lastUnreadPollMs: number = 0;
  private likingPostIds: Set<number> = new Set<number>();
  private loader: PagedLoader<CommunityPost> = new PagedLoader<CommunityPost>(
    async (page: number): Promise<PageResult<CommunityPost>> => {
      const sortType: string = COMMUNITY_SORT_OPTIONS[this.sortIndex].value;
      const resp = await NoyClient.getInstance().listPosts(page, sortType, this.appliedFilter);
      if (page === 1) {
        this.hasTopPost = resp.top;
      }
      return {
        items: resp.info,
        over: resp.over
      };
    },
    (post: CommunityPost): string => String(post.id)
  );

  aboutToAppear(): void {
    SafeAreaManager.getStatusBarHeight().then((h: number): void => {
      this.statusBarHeight = h;
    });
    BackInterceptRegistry.getInstance().register('community_overlays', (): boolean => {
      if (this.showComposerSheet) {
        this.showComposerSheet = false;
        return true;
      }
      if (this.searchOpen) {
        this.clearSearch();
        return true;
      }
      return false;
    });
    void this.refreshFeed();
    void this.maybePollUnread();
  }

  aboutToDisappear(): void {
    BackInterceptRegistry.getInstance().unregister('community_overlays');
  }

  @Monitor('active', 'isTopRoute')
  onVisibilityChanged(): void {
    if (this.active && this.isTopRoute) {
      void this.maybePollUnread();
    }
  }
  @Local private pressedKey: string = '';

  private navEndInset(): number {
    const vp: ViewportState = ViewportState.getInstance();
    return mainTabBottomClearanceVp(ThemeDims.BOTTOM_BAR_HEIGHT, vp.isBottomNav(), vp.bottomVp);
  }

  private async maybePollUnread(): Promise<void> {
    if (!this.active || !this.isTopRoute) {
      return;
    }
    if (!AuthManager.getInstance().isAuthenticated) {
      this.unreadCount = 0;
      return;
    }
    const now: number = Date.now();
    if (!isUnreadPollDue(this.lastUnreadPollMs, now)) {
      return;
    }
    this.lastUnreadPollMs = now;
    try {
      const resp = await NoyClient.getInstance().unreadCount();
      this.unreadCount = resp.count.all;
    } catch (e) {
      Logger.debug(TAG, 'unreadCount poll skipped');
    }
  }

  private async refreshFeed(fromPull: boolean = false): Promise<void> {
    if (fromPull) {
      this.refreshing = true;
    } else if (this.posts.length === 0) {
      this.loading = true;
    }
    this.errorMessage = '';
    this.loadMoreError = '';
    this.hasTopPost = false;
    try {
      await this.loader.refresh();
      this.posts = this.loader.items.slice();
      this.over = this.loader.over;
    } catch (e) {
      const msg: string = e instanceof Error
        ? e.message : this.lm.getString($r('app.string.community_load_failed'), '加载社区帖子失败');
      if (this.posts.length === 0) {
        this.errorMessage = msg;
      } else {
        this.loadMoreError = msg;
      }
    } finally {
      this.loading = false;
      this.refreshing = false;
    }
  }

  private async loadMoreFeed(): Promise<void> {
    if (this.loading || this.refreshing || this.loadingMore || this.over) {
      return;
    }
    this.loadingMore = true;
    this.loadMoreError = '';
    try {
      await this.loader.loadMore();
      this.posts = this.loader.items.slice();
      this.over = this.loader.over;
    } catch (e) {
      this.loadMoreError = e instanceof Error
        ? e.message : this.lm.getString($r('app.string.community_load_more_failed'), '加载更多失败，点击重试');
    } finally {
      this.loadingMore = false;
    }
  }

  private onSelectSort(index: number): void {
    if (index < 0 || index >= COMMUNITY_SORT_OPTIONS.length || index === this.sortIndex) {
      return;
    }
    this.sortIndex = index;
    void this.refreshFeed();
  }

  private submitSearch(): void {
    const clean: string = this.searchInput.trim();
    if (clean === this.appliedFilter) {
      return;
    }
    this.appliedFilter = clean;
    void this.refreshFeed();
  }

  private clearSearch(): void {
    this.searchInput = '';
    if (this.appliedFilter !== '') {
      this.appliedFilter = '';
      void this.refreshFeed();
    }
    this.searchOpen = false;
  }

  private spoilerKey(postId: number, idx: number): string {
    return `${postId}_${idx}`;
  }

  private isSpoilerTagged(post: CommunityPost, idx: number): boolean {
    return buildSpoilerSet(post.spoiler).has(idx);
  }

  private isSpoilerRevealed(post: CommunityPost, idx: number): boolean {
    if (!this.isSpoilerTagged(post, idx)) {
      return true;
    }
    const key: string = this.spoilerKey(post.id, idx);
    return this.unlockedSpoilerKeys.indexOf(key) >= 0;
  }

  private unlockSpoiler(postId: number, idx: number): void {
    const key: string = this.spoilerKey(postId, idx);
    if (this.unlockedSpoilerKeys.indexOf(key) < 0) {
      const next: string[] = this.unlockedSpoilerKeys.slice();
      next.push(key);
      this.unlockedSpoilerKeys = next;
    }
  }

  private hideSpoiler(postId: number, idx: number): void {
    const key: string = this.spoilerKey(postId, idx);
    const pos: number = this.unlockedSpoilerKeys.indexOf(key);
    if (pos >= 0) {
      const next: string[] = this.unlockedSpoilerKeys.slice();
      next.splice(pos, 1);
      this.unlockedSpoilerKeys = next;
    }
  }

  private replacePostAt(index: number, next: CommunityPost): void {
    if (index < 0 || index >= this.posts.length) {
      return;
    }
    const copy: CommunityPost[] = this.posts.slice();
    copy[index] = next;
    this.posts = copy;
  }

  private async handleToggleLike(index: number, post: CommunityPost): Promise<void> {
    if (this.likingPostIds.has(post.id)) {
      return;
    }
    this.likingPostIds.add(post.id);
    const prevLiked: boolean = post.is_like;
    const prevCount: number = post.like;
    const opt = toggleOptimisticLikeState(prevLiked, prevCount);
    this.replacePostAt(index, clonePostWithLike(post, opt.is_like, opt.like));
    try {
      const serverLiked: boolean = await NoyClient.getInstance().toggleLike(post.id);
      if (serverLiked !== opt.is_like) {
        const reconciledCount: number = Math.max(0, prevCount + (serverLiked ? 1 : -1));
        this.replacePostAt(index, clonePostWithLike(post, serverLiked, reconciledCount));
      }
    } catch (_e) {
      this.replacePostAt(index, clonePostWithLike(post, prevLiked, prevCount));
    } finally {
      this.likingPostIds.delete(post.id);
    }
  }

  private openPostDetail(postId: number): void {
    if (postId <= 0) {
      return;
    }
    this.pageStack.pushPathByName('CommunityPostDetailPage', String(postId));
  }

  private openBookDetail(bid: number): void {
    if (bid <= 0) {
      return;
    }
    this.pageStack.pushPathByName('ComicDetail', String(bid));
  }

  private sortLabels(): string[] {
    const opts = communitySortOptions(this.lm.effectiveLocale);
    const out: string[] = [];
    for (let i = 0; i < opts.length; i++) {
      out.push(opts[i].label);
    }
    return out;
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        this.HeaderBar()

        if (this.loading && this.posts.length === 0) {
          LoadingState({ message: this.lm.getString($r('app.string.community_loading'), '正在加载社区帖子...') })
            .layoutWeight(1)
        } else if (this.errorMessage !== '' && this.posts.length === 0) {
          ErrorState({
            message: this.errorMessage,
            retry: (): void => {
              void this.refreshFeed();
            }
          })
            .layoutWeight(1)
        } else if (this.posts.length === 0) {
          EmptyState({
            title: this.appliedFilter !== ''
              ? this.lm.getString($r('app.string.community_empty_search'), '没有找到相关帖子')
              : this.lm.getString($r('app.string.community_empty'), '暂无社区帖子')
          })
            .layoutWeight(1)
        } else {
          Refresh({ refreshing: $$this.refreshing }) {
            List({ space: 10 }) {
              ForEach(this.posts, (post: CommunityPost, index: number) => {
                ListItem() {
                  this.PostCard(post, index)
                }
              }, (post: CommunityPost): string => `${post.id}_${post.like}_${post.is_like}_${post.reply}`)

              ListItem() {
                this.FooterStatus()
              }

              ListItem() {
                Column().width('100%').height(this.navEndInset() + 68)
              }
            }
            .width('100%')
            .height('100%')
            .padding({ left: ThemeDims.PAGE_PADDING, right: ThemeDims.PAGE_PADDING, top: 8 })
            .edgeEffect(EdgeEffect.Spring)
            .onReachEnd((): void => {
              void this.loadMoreFeed();
            })
          }
          .layoutWeight(1)
          .onRefreshing((): void => {
            void this.refreshFeed(true);
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemeColors.BG)

      // 右下角无边框三层沉浸光感悬浮发帖按钮（接入非线性弹簧按压动效）
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(18)
          .fontColor([this.theme.accent])
        Text($r('app.string.community_new_post'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textPrimary)
      }
      .height(44)
      .padding({ left: 16, right: 18 })
      .borderRadius(22)
      .backgroundColor(resolveGlassCapsuleTintColor(this.theme.isDark))
      .borderWidth(0)
      .shadow({
        radius: 20,
        color: resolveGlassCapsuleShadowColor(this.theme.isDark),
        offsetX: 0,
        offsetY: 6
      })
      .systemMaterial(this.pillMaterial)
      .scale({
        x: springPressScale(this.pressedKey === 'fab'),
        y: springPressScale(this.pressedKey === 'fab')
      })
      .opacity(springPressOpacity(this.pressedKey === 'fab'))
      .animation({ curve: springPressCurve(this.pressedKey === 'fab') })
      .margin({ right: 16, bottom: this.navEndInset() + 14 })
      .onTouch((event: TouchEvent): void => {
        if (event.type === TouchType.Down) {
          this.pressedKey = 'fab';
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressedKey = '';
        }
      })
      .onClick((): void => {
        this.onOpenComposer();
        if (!AuthManager.getInstance().isAuthenticated) {
          this.pageStack.pushPathByName('LoginPage', null);
          return;
        }
        this.showComposerSheet = true;
      })

      if (this.showComposerSheet) {
        CommunityCreatePostSheet({
          onClose: (): void => {
            this.showComposerSheet = false;
          },
          onCreated: (): void => {
            this.showComposerSheet = false;
            void this.refreshFeed(false);
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  HeaderBar() {
    Column({ space: 6 }) {
      Row() {
        Text($r('app.string.community_title'))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme.textPrimary)
          .layoutWeight(1)

        Row({ space: 10 }) {
          // 关键词搜索触发器（36vp 无勾边圆形 + 弹簧动效）
          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(18)
              .fontColor([this.searchOpen || this.appliedFilter !== '' ? this.theme.accent : this.theme.textPrimary])
          }
          .width(36)
          .height(36)
          .borderRadius(18)
          .backgroundColor(this.theme.isDark ? '#252A36' : '#EEF2F6')
          .borderWidth(0)
          .scale({
            x: springPressScale(this.pressedKey === 'search'),
            y: springPressScale(this.pressedKey === 'search')
          })
          .opacity(springPressOpacity(this.pressedKey === 'search'))
          .animation({ curve: springPressCurve(this.pressedKey === 'search') })
          .onTouch((event: TouchEvent): void => {
            if (event.type === TouchType.Down) {
              this.pressedKey = 'search';
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.pressedKey = '';
            }
          })
          .onClick((): void => {
            this.searchOpen = !this.searchOpen;
          })

          // 未读消息红点铃铛入口（36vp 无勾边圆形 + 弹簧动效）
          Stack({ alignContent: Alignment.TopEnd }) {
            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.bell'))
                .fontSize(18)
                .fontColor([this.theme.textPrimary])
            }
            .width(36)
            .height(36)
            .borderRadius(18)
            .backgroundColor(this.theme.isDark ? '#252A36' : '#EEF2F6')
            .borderWidth(0)

            if (this.unreadCount > 0) {
              Stack({ alignContent: Alignment.Center }) {
                Text(this.unreadCount > 99 ? '99+' : `${this.unreadCount}`)
                  .fontSize(9)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')
              }
              .constraintSize({ minWidth: 16, minHeight: 16 })
              .padding({ left: 4, right: 4 })
              .borderRadius(8)
              .backgroundColor(ThemeColors.ERROR)
              .offset({ x: 2, y: -2 })
            }
          }
          .width(36)
          .height(36)
          .scale({
            x: springPressScale(this.pressedKey === 'bell'),
            y: springPressScale(this.pressedKey === 'bell')
          })
          .opacity(springPressOpacity(this.pressedKey === 'bell'))
          .animation({ curve: springPressCurve(this.pressedKey === 'bell') })
          .onTouch((event: TouchEvent): void => {
            if (event.type === TouchType.Down) {
              this.pressedKey = 'bell';
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.pressedKey = '';
            }
          })
          .onClick((): void => {
            this.pageStack.pushPathByName('MessagePage', null);
          })
        }
      }
      .width('100%')
      .height(52)

      if (this.searchOpen) {
        Row({ space: 8 }) {
          TextInput({ placeholder: this.lm.getString($r('app.string.community_search_hint'), '搜索社区帖子关键词...'), text: this.searchInput })
            .layoutWeight(1)
            .height(36)
            .fontSize(14)
            .fontColor(ThemeColors.TEXT)
            .backgroundColor(ThemeColors.SURFACE)
            .borderRadius(18)
            .padding({ left: 14, right: 14 })
            .enterKeyType(EnterKeyType.Search)
            .onChange((val: string): void => {
              this.searchInput = val;
            })
            .onSubmit((): void => {
              this.submitSearch();
            })

          Text($r('app.string.common_search'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.ON_PRIMARY)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .borderRadius(16)
            .backgroundColor(ThemeColors.PRIMARY)
            .onClick((): void => {
              this.submitSearch();
            })

          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(15)
              .fontColor([ThemeColors.TEXT_SECONDARY])
          }
          .width(32)
          .height(32)
          .borderRadius(16)
          .backgroundColor(ThemeColors.SURFACE)
          .onClick((): void => {
            this.clearSearch();
          })
        }
        .width('100%')
      }

      SegmentSelector({
        labels: this.sortLabels(),
        selectedIndex: this.sortIndex,
        onSelect: (index: number): void => {
          this.onSelectSort(index);
        }
      })
    }
    .width('100%')
    .padding({
      top: this.statusBarHeight,
      left: 16,
      right: 16,
      bottom: 10
    })
    .backgroundColor(ThemeColors.BG)
  }

  @Builder
  PostCard(post: CommunityPost, index: number) {
    Column({ space: 10 }) {
      // 1. 作者头像 + 昵称 + 时间 + 置顶徽标
      Row({ space: 10 }) {
        Stack() {
          if (post.avatar !== '') {
            MangaImage({
              imageUrl: resolveCommunityImageUrl(post.avatar),
              coverFill: true,
              allowTapRetry: false,
              diagLabel: 'community-avatar'
            })
          } else {
            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.person_fill'))
                .fontSize(18)
                .fontColor([ThemeColors.TEXT_MUTED])
            }
            .width('100%')
            .height('100%')
            .backgroundColor(ThemeColors.SURFACE)
          }
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .clip(true)

        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(post.username !== '' ? post.username : `UID ${post.uid}`)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemeColors.TEXT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            if (isPostPinned(index, this.hasTopPost)) {
              Row({ space: 3 }) {
                SymbolGlyph($r('sys.symbol.pin_fill'))
                  .fontSize(11)
                  .fontColor([ThemeColors.ON_PRIMARY])
                Text($r('app.string.community_pinned'))
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(ThemeColors.ON_PRIMARY)
              }
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .borderRadius(10)
              .backgroundColor(ThemeColors.PRIMARY)
            }
          }
          .width('100%')

          if (post.time > 0) {
            Text(formatCommunityTime(post.time, Date.now(), this.lm.effectiveLocale))
              .fontSize(11)
              .fontColor(ThemeColors.TEXT_MUTED)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      // 2. 帖子标题（16fp Bold 最多 2 行）与正文摘要（14fp 最多 3 行）
      if (post.title !== '') {
        Text(post.title)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.TEXT)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      if (post.content !== '') {
        CommunityRichText({
          content: post.content,
          fontSizeFp: 14,
          textColor: ThemeColors.TEXT_SECONDARY,
          maxLinesCount: 3,
          onOpenBook: (bid: number): void => {
            this.openBookDetail(bid);
          }
        })
      }

      // 3. 图片缩略图网格（支持 spoiler 遮罩点击解锁 + 大图预览）
      if (post.image.length > 0) {
        this.PostImageGrid(post)
      }

      // 4. 底部互动栏：点赞 + 评论数
      Row({ space: 20 }) {
        Row({ space: 5 }) {
          SymbolGlyph(post.is_like ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
            .fontSize(17)
            .fontColor([post.is_like ? ThemeColors.ERROR : ThemeColors.TEXT_TERTIARY])
          Text(`${post.like}`)
            .fontSize(13)
            .fontColor(post.is_like ? ThemeColors.ERROR : ThemeColors.TEXT_TERTIARY)
        }
        .padding({ top: 4, bottom: 4, right: 8 })
        .onClick((): void => {
          void this.handleToggleLike(index, post);
        })

        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.message'))
            .fontSize(16)
            .fontColor([ThemeColors.TEXT_TERTIARY])
          Text(`${post.reply}`)
            .fontSize(13)
            .fontColor(ThemeColors.TEXT_TERTIARY)
        }
        .padding({ top: 4, bottom: 4, right: 8 })
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
    .onClick((): void => {
      this.openPostDetail(post.id);
    })
  }

  @Builder
  PostImageGrid(post: CommunityPost) {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(resolvePostImageUrls(post).slice(0, 9), (imgUrl: string, imgIdx: number) => {
        Stack({ alignContent: Alignment.TopEnd }) {
          MangaImage({
            imageUrl: imgUrl,
            coverFill: true,
            allowTapRetry: true,
            blurRadius: resolveSpoilerBlurRadius(
              this.isSpoilerTagged(post, imgIdx),
              this.isSpoilerRevealed(post, imgIdx)
            ),
            diagLabel: `community-thumb-${post.id}`
          })
            .width('100%')
            .height('100%')

          if (this.isSpoilerTagged(post, imgIdx) && !this.isSpoilerRevealed(post, imgIdx)) {
            Column({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.eye_slash'))
                .fontSize(20)
                .fontColor(['#FFFFFF'])
              Text($r('app.string.community_spoiler_hint'))
                .fontSize(10)
                .fontColor('#FFFFFF')
                .textAlign(TextAlign.Center)
                .padding({ left: 4, right: 4 })
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor('#610F1218')
          } else if (this.isSpoilerTagged(post, imgIdx)) {
            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.eye_slash'))
                .fontSize(12)
                .fontColor(['#FFFFFF'])
            }
            .width(24)
            .height(24)
            .borderRadius(12)
            .backgroundColor('#80000000')
            .margin(4)
            .onClick((): void => {
              this.hideSpoiler(post.id, imgIdx);
            })
          }
        }
        .width('31%')
        .aspectRatio(1)
        .margin({ right: imgIdx % 3 === 2 ? 0 : '3.5%', bottom: 6 })
        .borderRadius(10)
        .clip(true)
        .onClick((): void => {
          const isSpoiler: boolean = this.isSpoilerTagged(post, imgIdx);
          const isRevealed: boolean = this.isSpoilerRevealed(post, imgIdx);
          if (!shouldOpenImageOnTap(isSpoiler, isRevealed)) {
            this.unlockSpoiler(post.id, imgIdx);
          } else {
            CommunityViewerController.getInstance().open(imgUrl);
          }
        })
      }, (imgUrl: string, imgIdx: number): string => `${post.id}_${imgIdx}_${imgUrl}`)
    }
    .width('100%')
  }

  @Builder
  FooterStatus() {
    Column() {
      if (this.loadingMore) {
        Text($r('app.string.common_loading_more'))
          .fontSize(12)
          .fontColor(ThemeColors.TEXT_MUTED)
          .padding(12)
      } else if (this.loadMoreError !== '') {
        Text(this.loadMoreError)
          .fontSize(12)
          .fontColor(ThemeColors.PRIMARY)
          .padding(12)
          .onClick((): void => {
            void this.loadMoreFeed();
          })
      } else if (this.over && this.posts.length > 0) {
        Text($r('app.string.common_no_more'))
          .fontSize(12)
          .fontColor(ThemeColors.TEXT_MUTED)
          .padding(12)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
