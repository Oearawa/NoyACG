/**
 * Message.ets —— 消息计数与消息条目实体（Phase 14-J1）
 *
 * 数据来源：
 * - 未读计数：POST /api/v4/msg/count（{ count: { all, sys_msg, community_reply, comment_reply } }）；
 * - 消息列表：POST /api/v3/get_msg（page + type + v=3），三类 type 结构不同：
 *     reply            → reply.comment
 *     community_reply  → community_reply.community_reply
 *     sysmsg           → sysmsg.msg
 *
 * 说明：消息条目的具体字段未取得真实成功样本，本模型的字段按首方常见命名做**防御式**读取，
 * 缺失一律留空/0，绝不编造内容。报告中标 NOT VERIFIED。
 */

/** 消息分类（UI 与请求 type 一致） */
export const MSG_TYPE_REPLY: string = 'reply';
export const MSG_TYPE_COMMUNITY_REPLY: string = 'community_reply';
export const MSG_TYPE_SYSMSG: string = 'sysmsg';

@ObservedV2
export class MessageCount {
  /** 全部未读 */
  @Trace all: number = 0;
  /** 系统消息未读 */
  @Trace sysMsg: number = 0;
  /** 社区回复未读 */
  @Trace communityReply: number = 0;
  /** 评论回复未读 */
  @Trace commentReply: number = 0;

  constructor() {
  }
}

@ObservedV2
export class MessageItem {
  /** 消息类型（reply / community_reply / sysmsg） */
  @Trace kind: string = '';
  /** 条目 id（尽力读取，缺失为空） */
  @Trace id: string = '';
  /** 标题 / 系统消息标题 */
  @Trace title: string = '';
  /** 正文（评论内容 / 回复内容 / 系统通知正文） */
  @Trace content: string = '';
  /** 时间（Unix 秒 → YYYY-MM-DD；'' = 未提供） */
  @Trace time: string = '';
  /** 关联封面（尽力读取，空 = 无） */
  @Trace cover: string = '';
  /** 关联书籍 id（评论/社区回复可能带；空 = 无） */
  @Trace bookId: string = '';
  /** 关联社区帖子 id（社区回复与官方公告带；空 = 无） */
  @Trace postId: string = '';
  /** 真实头像 URL（get_msg 返回的 avatarUrl 或官方账号头像） */
  @Trace avatarUrl: string = '';
  /** 是否为官方公告帖 */
  @Trace isOfficial: boolean = false;
  /** 角标标签（如「官方公告」） */
  @Trace tagLabel: string = '';

  constructor() {
  }
}
