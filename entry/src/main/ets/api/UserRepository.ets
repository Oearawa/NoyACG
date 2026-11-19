/**
 * UserRepository.ets —— 用户资料 / 徽章 / 消息的数据访问层（Phase 14-J1）
 *
 * 遵循既有分层：本层只负责「发请求 + 交给协议层解析」，
 * 不直接操作 Cookie（由 HttpManager 的会话统一管理），不持有 UI 状态。
 *
 * 接口（NoyAcg 首方）：
 *   POST /api/v3/userinfo   （无 body）      → { status, userinfo }
 *   POST /api/badge         （无 body）      → { status, data[], show[] }
 *   POST /api/v4/msg/count  （无 body）      → { status, count{...} }
 *   POST /api/v3/get_msg    page&type&v=3    → { status, reply|community_reply|sysmsg }
 *
 * allow-adult 内容分级由 HttpManager 按全局策略自动注入，本层不重复传参。
 */
import { HttpManager } from './HttpManager';
import { UserInfo } from '../model/UserInfo';
import { MessageCount } from '../model/Message';
import {
  BadgeResult,
  MessagePageResult,
  RawBadgeEnvelope,
  RawMessageCountEnvelope,
  RawMessageEnvelope,
  RawSignInEnvelope,
  RawSignInRecordEnvelope,
  RawUserProfileEnvelope,
  SignInRecordResult,
  SignInResult,
  parseBadges,
  parseMessageCount,
  parseMessageList,
  parseSignInRecord,
  parseSignInResult,
  parseUserInfo
} from '../source/NoyAcgProtocol';

const PATH_USER_INFO: string = '/api/v3/userinfo';
const PATH_BADGE: string = '/api/badge';
const PATH_MSG_COUNT: string = '/api/v4/msg/count';
const PATH_GET_MSG: string = '/api/v3/get_msg';
const PATH_SIGNIN_RECORD: string = '/api/v4/signin/record';
const PATH_SIGNIN: string = '/api/v4/signin/sign';

export class UserRepository {
  private http: HttpManager = HttpManager.getInstance();

  /** 拉取用户资料（未登录 → 协议层抛 AuthRequiredError） */
  async fetchUserInfo(): Promise<UserInfo> {
    const resp: RawUserProfileEnvelope =
      await this.http.postForm<RawUserProfileEnvelope>(PATH_USER_INFO, {});
    return parseUserInfo(resp);
  }

  /** 拉取徽章（全部 + 已佩戴） */
  async fetchBadges(): Promise<BadgeResult> {
    const resp: RawBadgeEnvelope =
      await this.http.postForm<RawBadgeEnvelope>(PATH_BADGE, {});
    return parseBadges(resp);
  }

  /** 拉取未读消息计数 */
  async fetchMessageCount(): Promise<MessageCount> {
    const resp: RawMessageCountEnvelope =
      await this.http.postForm<RawMessageCountEnvelope>(PATH_MSG_COUNT, {});
    return parseMessageCount(resp);
  }

  /** 拉取某类消息分页（kind: reply / community_reply / sysmsg） */
  async fetchMessages(kind: string, page: number): Promise<MessagePageResult> {
    const form: Record<string, string> = { 'page': String(page), 'type': kind, 'v': '3' };
    const resp: RawMessageEnvelope =
      await this.http.postForm<RawMessageEnvelope>(PATH_GET_MSG, form);
    return parseMessageList(resp, kind);
  }

  /** 查询今日签到记录（POST /api/v4/signin/record，空表单） */
  async fetchSignInRecord(): Promise<SignInRecordResult> {
    const resp: RawSignInRecordEnvelope =
      await this.http.postForm<RawSignInRecordEnvelope>(PATH_SIGNIN_RECORD, {});
    return parseSignInRecord(resp);
  }

  /** 执行每日签到（POST /api/v4/signin/sign，空表单） */
  async signIn(): Promise<SignInResult> {
    const resp: RawSignInEnvelope =
      await this.http.postForm<RawSignInEnvelope>(PATH_SIGNIN, {});
    return parseSignInResult(resp);
  }
}
