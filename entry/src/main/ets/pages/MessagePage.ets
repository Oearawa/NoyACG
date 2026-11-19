import { HdsNavDestination } from '@kit.UIDesignKit';
import { hdsTitleBarStyle } from '../utils/HdsMaterialPolicy';
/**
 * MessagePage.ets —— 消息中心（Phase 14-J1）
 *
 * 三类消息：评论回复(reply) / 社区回复(community_reply) / 系统消息(sysmsg)。
 * 三类响应结构不同，由协议层 parseMessageList 按 type 独立取值（见 NoyAcgProtocol）。
 *
 * 约束：
 * - 进入页面才加载，不做后台预取 / 高频轮询（避免已读状态意外变化）；
 * - 未登录 status=login 统一走 AuthRequiredError → needsLogin 引导登录；
 * - 消息条目真实字段未取得完整样本，展示按防御式字段渲染，缺失留空（报告标 NOT VERIFIED）。
 */
import { NoyAuthError, NoyClient } from '../api/NoyClient';
import {
  CommunityListResp,
  MsgCommunityReplyResp,
  MsgReplyResp,
  MsgSysResp
} from '../models/NoyModels';
import { AuthManager } from '../utils/AuthManager';
import {
  mapCommunityReplyMessages,
  mapNativeSysMessages,
  mapOfficialPostsToSysMessages,
  mapReplyMessages,
  mergeSysMessages,
  OFFICIAL_ANNOUNCER_USERNAME
} from '../utils/MessageCenterHelper';
import { MessageItem, MSG_TYPE_COMMUNITY_REPLY, MSG_TYPE_REPLY, MSG_TYPE_SYSMSG } from '../model/Message';
import { HttpError } from '../api/HttpManager';
import { MangaImage } from '../components/MangaImage';
import { SegmentSelector } from '../components/SegmentSelector';
import { SafeAreaManager } from '../utils/SafeAreaManager';
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import { Logger } from '../utils/Logger';
import { LocalizationManager } from '../utils/LocalizationManager';

const TAG: string = 'MessagePage';
const KIND_TYPES: string[] = [MSG_TYPE_REPLY, MSG_TYPE_COMMUNITY_REPLY, MSG_TYPE_SYSMSG];

@ComponentV2
export struct MessagePage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();
  @Local kindIndex: number = 0;
  @Local messages: MessageItem[] = [];
  @Local page: number = 1;
  @Local over: boolean = true;
  @Local loading: boolean = false;
  @Local refreshing: boolean = false;
  @Local errorMessage: string = '';
  @Local needsLogin: boolean = false;
  /** 代际：切换分类时作废旧请求 */
  private generation: number = 0;
  private readonly msgSwiperController: SwiperController = new SwiperController();

  aboutToAppear(): void {
    this.reload();
  }

  private kind(): string {
    return KIND_TYPES[this.kindIndex];
  }

  private async fetchMessagePage(kind: string, page: number): Promise<boolean> {
    const client: NoyClient = NoyClient.getInstance();
    let mapped: MessageItem[] = [];
    let isOver: boolean = true;

    if (kind === MSG_TYPE_COMMUNITY_REPLY) {
      const resp: MsgCommunityReplyResp = await client.messagesCommunityReply(page);
      mapped = mapCommunityReplyMessages(resp);
      isOver = mapped.length === 0 || mapped.length < 20;
    } else if (kind === MSG_TYPE_SYSMSG) {
      if (page === 1) {
        const sysPromise: Promise<MsgSysResp> = client.messagesSys(1);
        const officialPromise: Promise<CommunityListResp> =
          client.listPosts(1, 'new', OFFICIAL_ANNOUNCER_USERNAME)
            .catch((): CommunityListResp => new CommunityListResp());
        const results: [MsgSysResp, CommunityListResp] = await Promise.all([sysPromise, officialPromise]);
        const sysItems: MessageItem[] = mapNativeSysMessages(results[0]);
        const officialItems: MessageItem[] = mapOfficialPostsToSysMessages(results[1].info);
        mapped = mergeSysMessages(officialItems, sysItems);
        isOver = sysItems.length === 0 || sysItems.length < 20;
      } else {
        const resp: MsgSysResp = await client.messagesSys(page);
        mapped = mapNativeSysMessages(resp);
        isOver = mapped.length === 0 || mapped.length < 20;
      }
    } else {
      const resp: MsgReplyResp = await client.messagesReply(page);
      mapped = mapReplyMessages(resp);
      isOver = mapped.length === 0 || mapped.length < 20;
    }

    if (page === 1) {
      this.messages = mapped;
    } else {
      this.messages = this.messages.concat(mapped);
    }
    return isOver;
  }

  private onSelectSegment(index: number): void {
    if (index === this.kindIndex) {
      return;
    }
    this.kindIndex = index;
    this.reload();
  }

  /** 从第 1 页重新加载当前分类 */
  private async reload(fromPull: boolean = false): Promise<void> {
    const gen: number = ++this.generation;
    if (!AuthManager.getInstance().isAuthenticated) {
      this.loading = false;
      this.refreshing = false;
      this.needsLogin = true;
      this.errorMessage = this.lm.getString($r('app.string.message_login_required'), '登录后才能查看消息');
      this.messages = [];
      return;
    }
    if (fromPull) {
      this.refreshing = true;
    } else {
      this.loading = true;
    }
    this.errorMessage = '';
    this.needsLogin = false;
    if (!fromPull) {
      this.messages = [];
    }
    this.page = 1;
    this.over = true;
    try {
      const nextOver: boolean = await this.fetchMessagePage(this.kind(), 1);
      if (gen !== this.generation) {
        return;
      }
      this.over = nextOver;
    } catch (e) {
      if (gen !== this.generation) {
        return;
      }
      this.handleError(e);
    } finally {
      if (gen === this.generation) {
        this.loading = false;
        this.refreshing = false;
      }
    }
  }

  /** 加载下一页并追加 */
  private async loadMore(): Promise<void> {
    if (this.loading || this.over) {
      return;
    }
    const gen: number = this.generation;
    const nextPage: number = this.page + 1;
    this.loading = true;
    try {
      const nextOver: boolean = await this.fetchMessagePage(this.kind(), nextPage);
      if (gen !== this.generation) {
        return;
      }
      this.page = nextPage;
      this.over = nextOver;
    } catch (e) {
      if (gen === this.generation) {
        this.handleError(e);
      }
    } finally {
      if (gen === this.generation) {
        this.loading = false;
      }
    }
  }

  private handleError(e: Object): void {
    if (e instanceof NoyAuthError) {
      this.needsLogin = true;
      this.errorMessage = this.lm.getString($r('app.string.message_login_required'), '登录后才能查看消息');
    } else if (e instanceof HttpError) {
      this.errorMessage = e.message;
    } else {
      this.errorMessage = e instanceof Error ? e.message : '消息加载失败，请稍后重试';
    }
    Logger.warn(TAG, `消息加载失败: ${(e as Error).message}`);
  }

  build() {
    HdsNavDestination() {
      Column() {
        Column() {
          SegmentSelector({
            labels: [
              this.lm.getString($r('app.string.message_kind_comment'), '评论回复'),
              this.lm.getString($r('app.string.message_kind_community'), '社区回复'),
              this.lm.getString($r('app.string.message_kind_system'), '系统消息')
            ],
            selectedIndex: this.kindIndex,
            onSelect: (index: number) => {
              this.msgSwiperController.changeIndex(index, true);
              this.onSelectSegment(index);
            }
          })
        }
        .width('100%')
        .padding({ left: ThemeDims.PAGE_PADDING, right: ThemeDims.PAGE_PADDING, bottom: 8 })

        Swiper(this.msgSwiperController) {
          ForEach([0, 1, 2], (tabIdx: number) => {
            Column() {
              if (tabIdx === this.kindIndex) {
                this.MessageTabBody()
              }
            }
            .width('100%')
            .height('100%')
          }, (tabIdx: number) => `${tabIdx}`)
        }
        .index(this.kindIndex)
        .loop(false)
        .indicator(false)
        .duration(220)
        .curve(Curve.FastOutSlowIn)
        .cachedCount(1)
        .layoutWeight(1)
        .width('100%')
        .onChange((index: number) => {
          this.onSelectSegment(index);
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemeColors.BG)
    }
    .withTheme({ enableThemeColorMode: true })
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      content: { title: { mainTitle: $r('app.string.message_title') } },
      style: hdsTitleBarStyle()
    })
    .backgroundColor(ThemeColors.BG)
  }

  @Builder
  MessageTabBody() {
    if (this.loading && this.messages.length === 0) {
      Column() {
        LoadingProgress().width(28).height(28).color(ThemeColors.PRIMARY)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else if (this.needsLogin) {
      this.CenterHint(
        this.lm.getString($r('app.string.message_login_prompt_title'), '请先登录'),
        this.lm.getString($r('app.string.message_login_prompt_desc'), '登录后可查看评论与社区回复'),
        this.lm.getString($r('app.string.common_go_login'), '去登录')
      )
    } else if (this.errorMessage !== '') {
      this.CenterHint(this.errorMessage, '', this.lm.getString($r('app.string.common_retry'), '重试'))
    } else if (this.messages.length === 0) {
      this.CenterHint(this.lm.getString($r('app.string.message_empty'), '暂无消息'), '', '')
    } else {
      Refresh({ refreshing: $$this.refreshing }) {
        List({ space: 8 }) {
          ForEach(this.messages, (item: MessageItem) => {
            ListItem() {
              this.MessageRow(item)
            }
          }, (item: MessageItem) => `${item.kind}_${item.id}`)

          if (!this.over) {
            ListItem() {
              Text(this.loading
                ? $r('app.string.message_loading')
                : $r('app.string.message_load_more'))
                .fontSize(ThemeFonts.BODY_SMALL)
                .fontColor(ThemeColors.PRIMARY)
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding(12)
                .onClick(() => {
                  this.loadMore();
                })
            }
          }
        }
        .width('100%')
        .height('100%')
        .padding({ left: ThemeDims.PAGE_PADDING, right: ThemeDims.PAGE_PADDING, bottom: 16 })
        .scrollBar(BarState.Off)
      }
      .layoutWeight(1)
      .onRefreshing((): void => {
        void this.reload(true);
      })
    }
  }


  @Builder
  CenterHint(title: string, subtitle: string, action: string) {
    Column({ space: 10 }) {
      Text(title)
        .fontSize(ThemeFonts.BODY)
        .fontColor(ThemeColors.TEXT_SECONDARY)
        .textAlign(TextAlign.Center)
      if (subtitle !== '') {
        Text(subtitle)
          .fontSize(ThemeFonts.BODY_SMALL)
          .fontColor(ThemeColors.TEXT_TERTIARY)
          .textAlign(TextAlign.Center)
      }
      if (action !== '') {
        Text(action)
          .fontSize(ThemeFonts.BODY_SMALL)
          .fontColor(ThemeColors.PRIMARY)
          .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          .borderWidth(1)
          .borderColor(ThemeColors.PRIMARY)
          .borderRadius(14)
          .onClick(() => {
            if (this.needsLogin) {
              this.pageStack.pushPathByName('LoginPage', null);
            } else {
              this.reload();
            }
          })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding(24)
  }

  @Builder
  MessageRow(item: MessageItem) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (item.avatarUrl !== '') {
          MangaImage({
            imageUrl: item.avatarUrl,
            coverFill: true,
            allowTapRetry: false,
            diagLabel: 'msg-avatar'
          })
        } else {
          SymbolGlyph(this.iconOf(item.kind))
            .fontSize(18)
            .fontColor([item.isOfficial ? ThemeColors.PRIMARY : ThemeColors.TEXT])
        }
      }
      .width(36)
      .height(36)
      .backgroundColor(ThemeColors.SURFACE)
      .borderRadius(item.avatarUrl !== '' ? 18 : 8)
      .clip(true)

      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(item.title !== '' ? item.title : [
            this.lm.getString($r('app.string.message_kind_comment'), '评论回复'),
            this.lm.getString($r('app.string.message_kind_community'), '社区回复'),
            this.lm.getString($r('app.string.message_kind_system'), '系统消息')
          ][this.kindIndex])
            .fontSize(ThemeFonts.BODY)
            .fontWeight(item.isOfficial ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(ThemeColors.TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          if (item.isOfficial && item.tagLabel !== '') {
            Row({ space: 3 }) {
              SymbolGlyph($r('sys.symbol.checkmark_shield_fill'))
                .fontSize(10)
                .fontColor([ThemeColors.ON_PRIMARY])
              Text(item.tagLabel)
                .fontSize(10)
                .fontWeight(FontWeight.Medium)
                .fontColor(ThemeColors.ON_PRIMARY)
            }
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(9)
            .backgroundColor(ThemeColors.PRIMARY)
          }
        }
        .width('100%')

        Text(item.content !== ''
          ? item.content
          : this.lm.getString($r('app.string.message_no_content'), '（无内容）'))
          .fontSize(ThemeFonts.BODY_SMALL)
          .fontColor(ThemeColors.TEXT_SECONDARY)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (item.time !== '') {
          Text(item.time)
            .fontSize(ThemeFonts.CAPTION)
            .fontColor(ThemeColors.TEXT_MUTED)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(10)
    .alignItems(VerticalAlign.Top)
    .backgroundColor(ThemeColors.CARD)
    .borderRadius(ThemeDims.RADIUS_CARD)
    .onClick((): void => {
      if (item.postId !== '') {
        this.pageStack.pushPathByName('CommunityPostDetailPage', item.postId);
      } else if (item.kind === MSG_TYPE_REPLY && item.bookId !== '') {
        this.pageStack.pushPathByName('ComicDetail', item.bookId);
      }
    })
  }

  private iconOf(kind: string): Resource {
    if (kind === MSG_TYPE_SYSMSG) {
      return $r('sys.symbol.bell');
    }
    if (kind === MSG_TYPE_COMMUNITY_REPLY) {
      return $r('sys.symbol.message');
    }
    return $r('sys.symbol.envelope');
  }
}

/** 系统路由表构建函数：与 route_map.json 的 "MessagePageBuilder" 对应 */
@Builder
export function MessagePageBuilder(name: string, param?: object) {
  MessagePage()
}
