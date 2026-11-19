/**
 * BookComment.ets —— 书籍评论实体 + 评论分页容器
 *
 * Phase 14-I 新增。来源：
 * - 首屏评论：`GET /api/v4/book/{bid}` 响应内联的 `comment.data`；
 * - 评论分页：`GET /api/v4/comment/book/{bid}/comments?page={page}`。
 *
 * 关键约定（首方实测）：
 * - 书籍评论的**主键字段叫 `cid`**（社区帖子评论才是 `rid`），不得混用；
 * - `uid=0` 是官方置顶公告（`area: "官方公告"`），**不计入** `comment.count`；
 * - 每条评论自带 `replies`（楼中楼），`reply_more` 表示是否还有更多回复；
 * - 分页用 `data.over` 判断是否到底（true = 最后一页），不自行用条数推断。
 */
@ObservedV2
export class BookComment {
  /** 评论主键（cid，int/string 归一化为字符串） */
  @Trace cid: string = '';
  /** 作者 uid（'0' 表示官方） */
  @Trace uid: string = '';
  /** 作者昵称 */
  @Trace username: string = '';
  /** 正文（表情包为代码文本，如 `[noygirl:yeah]`） */
  @Trace content: string = '';
  /** 地区（服务端按 IP 判定，如 `China mainland` / `官方公告`） */
  @Trace area: string = '';
  /** 发送时间（unix 秒，客户端已格式化；'' = 未提供） */
  @Trace time: string = '';
  /** 是否官方置顶（uid=0） */
  @Trace isOfficial: boolean = false;
  /** 楼中楼回复总数（reply_num） */
  @Trace replyCount: number = 0;
  /** 楼中楼是否还有更多（reply_more） */
  @Trace hasMoreReplies: boolean = false;
  /** 楼中楼回复（可能只内联前几条） */
  @Trace replies: BookComment[] = [];

  constructor() {
  }
}

/** 评论分页结果（`data.over` 是唯一「到底」判据） */
export class CommentPage {
  /** 当前页评论 */
  readonly comments: BookComment[];
  /** 当前页码（从 1 开始） */
  readonly page: number;
  /** 是否已到最后一页 */
  readonly over: boolean;

  constructor(comments: BookComment[], page: number, over: boolean) {
    this.comments = comments;
    this.page = page;
    this.over = over;
  }

  /** 是否还有下一页 */
  get hasMore(): boolean {
    return !this.over;
  }
}
