/**
 * UserInfo.ets —— 用户资料与徽章实体（Phase 14-J1）
 *
 * 数据来源：
 * - 用户资料：POST /api/v3/userinfo（status=ok 时 userinfo）；
 * - 徽章：POST /api/badge（data 全部徽章 + show 佩戴中的徽章 ID）。
 *
 * 严格性：
 * - 只保留有真实接口证据的字段；`Integral`（积分）本阶段**不使用、不展示**；
 * - `Avatar` / `Bg` 是相对路径，最终 URL 由协议层结合图床 origin 解析并做域名校验；
 * - 徽章 `Id` 为数字，`show` 为字符串数组，匹配时统一转字符串。
 */
@ObservedV2
export class UserInfo {
  /** 用户 UID（数字或字符串，统一转字符串） */
  @Trace uid: string = '';
  /** 用户名（Username，兼容 Name） */
  @Trace username: string = '';
  /** 头像绝对地址（解析失败为空串，不渲染破图） */
  @Trace avatarUrl: string = '';
  /** 头像相对路径（原文，供图床 origin 变化后重新解析） */
  @Trace avatarPath: string = '';
  /** 背景图绝对地址（空串 = 无背景，用渐变兜底） */
  @Trace bgUrl: string = '';
  /** 背景图相对路径（原文） */
  @Trace bgPath: string = '';
  /** 账号创建时间（Time，Unix 秒 → YYYY-MM-DD；'' = 未提供） */
  @Trace createdAt: string = '';
  /** 评论数（CommentLen；仅存档，无明确展示需求） */
  @Trace commentCount: number = 0;

  constructor() {
  }
}

@ObservedV2
export class UserBadge {
  /** 徽章 ID（数字转字符串，用于与 show[] 匹配） */
  @Trace id: string = '';
  /** 徽章名称 */
  @Trace name: string = '';
  /** 徽章图片绝对地址 */
  @Trace img: string = '';
  /** 徽章小图绝对地址 */
  @Trace minImg: string = '';
  /** 徽章说明 */
  @Trace des: string = '';

  constructor() {
  }
}
