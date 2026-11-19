/**
 * NoyClient.ets —— 社区业务客户端封装（阶段 1）
 *
 * 设计约束：
 * - 单一会话与传输源：传输、Cookie（NOY_SESSION）与 RequestGate 全部委托 HttpManager；
 *   会话认证状态全部委托 AuthManager（不引入独立 SessionStore，不保存密码）；
 * - 成人内容开关：复用 ContentRatingPolicy + PreferenceManager.communityAdultConfirmed；
 *   用户显式开启并年龄确认前，社区请求一律传 allow-adult: false；
 * - 串行节流：保留 400ms 最小请求间隔，防止触发站内限流；
 * - 统一 status 处理：status='login' 时降级 AuthManager、触发 onSessionExpired 跳转登录页并抛 NoyAuthError；
 *   status='error' 时抛 NoyApiError；写操作绝不自动重试；
 * - 零敏感日志：Cookie、邮箱、密码、token 均不进日志。
 */
import { rcp } from '@kit.RemoteCommunicationKit';
import { HttpManager, NOY_WEB_ORIGIN } from './HttpManager';
import { isLoginStatus, RawUserInfoEnvelope } from './AuthTypes';
import { AuthManager } from '../utils/AuthManager';
import { ContentRatingPolicy } from '../utils/ContentRatingPolicy';
import { ContentRating, PreferenceManager } from '../utils/PreferenceManager';
import { Logger } from '../utils/Logger';
import {
  CommentRepliesResp,
  CommunityListResp,
  MsgCommunityReplyResp,
  MsgCountResp,
  MsgReplyResp,
  MsgSysResp,
  NOY_BUCKET_ORIGIN,
  PostCommentsResp,
  PostDetailResp,
  parseCommentRepliesResp,
  parseCommunityListResp,
  parseMsgCommunityReplyResp,
  parseMsgCountResp,
  parseMsgReplyResp,
  parseMsgSysResp,
  parsePostCommentsResp,
  parsePostDetailResp
} from '../models/NoyModels';

const TAG: string = 'NoyClient';

export type Platform = 'web' | 'android';

/** 会话缺失或过期（status: "login"），调用方应引导重新登录 */
export class NoyAuthError extends Error {
  constructor(msg: string = '会话已过期，请重新登录') {
    super(msg);
    this.name = 'NoyAuthError';
  }
}

/** 社区业务失败（status: "error"）或响应非合法 JSON */
export class NoyApiError extends Error {
  constructor(msg: string) {
    super(msg);
    this.name = 'NoyApiError';
  }
}

interface BaseResp {
  status?: string | number;
}

interface TokenResp {
  status?: string;
  token?: string;
}

interface UploadResp {
  status?: string;
  file?: string;
}

interface LikeResp {
  status?: string;
  is_like?: boolean;
}

/** 社区传输端口（默认委托 HttpManager，单测可注入内存桩） */
export interface NoyHttpTransport {
  postFormText(path: string, form: Record<string, string>,
    headers?: Record<string, string>): Promise<string>;
  clearSiteCookies(): Promise<void>;
}

/** 会话与分级策略端口（默认委托 AuthManager / ContentRatingPolicy / PreferenceManager，单测可注入桩） */
export interface NoyClientDeps {
  isAuthenticated(): boolean;
  notifySessionExpired(): void;
  resolveContentRating(): string;
  isCommunityAdultConfirmed(): boolean;
}

/** 计算社区请求应携带的 allow-adult 请求头（未显式确认前一律返回 'false'） */
export function resolveCommunityAllowAdult(policyRating: string, adultConfirmed: boolean): string {
  if (!adultConfirmed) {
    return ContentRating.ALL_AGES;
  }
  if (policyRating === ContentRating.ADULT || policyRating === ContentRating.BOTH) {
    return policyRating;
  }
  return ContentRating.ALL_AGES;
}

class DefaultHttpTransport implements NoyHttpTransport {
  postFormText(path: string, form: Record<string, string>,
    headers?: Record<string, string>): Promise<string> {
    return HttpManager.getInstance().postFormText(path, form, headers);
  }

  clearSiteCookies(): Promise<void> {
    return HttpManager.getInstance().clearSiteCookies();
  }
}

class DefaultClientDeps implements NoyClientDeps {
  isAuthenticated(): boolean {
    return AuthManager.getInstance().isAuthenticated;
  }

  notifySessionExpired(): void {
    AuthManager.getInstance().notifySessionExpired();
  }

  resolveContentRating(): string {
    return ContentRatingPolicy.getInstance().resolve();
  }

  isCommunityAdultConfirmed(): boolean {
    return PreferenceManager.getInstance().getCommunityAdultConfirmedSync();
  }
}

export class NoyClient {
  private static instance?: NoyClient;

  private readonly transport: NoyHttpTransport;
  private readonly deps: NoyClientDeps;
  private readonly bucketUrl: string = NOY_BUCKET_ORIGIN;
  private readonly platform: Platform = 'web';
  private minIntervalMs: number = 400;
  private onSessionExpired?: () => void;
  private lastRequestAt: number = 0;
  private chain: Promise<void> = Promise.resolve();

  constructor(
    transport?: NoyHttpTransport,
    deps?: NoyClientDeps,
    minIntervalMs: number = 400
  ) {
    this.transport = transport ?? new DefaultHttpTransport();
    this.deps = deps ?? new DefaultClientDeps();
    this.minIntervalMs = minIntervalMs >= 0 ? minIntervalMs : 400;
  }

  static getInstance(): NoyClient {
    if (NoyClient.instance === undefined) {
      NoyClient.instance = new NoyClient();
    }
    return NoyClient.instance;
  }

  setOnSessionExpired(handler?: () => void): void {
    this.onSessionExpired = handler;
  }

  /** 解析当前社区请求应使用的 allow-adult 值 */
  currentAllowAdult(): string {
    return resolveCommunityAllowAdult(
      this.deps.resolveContentRating(),
      this.deps.isCommunityAdultConfirmed()
    );
  }

  /** 串行队列 + 最小请求间隔节流 */
  private schedule<T>(fn: () => Promise<T>): Promise<T> {
    const run = async (): Promise<T> => {
      const wait: number = this.lastRequestAt + this.minIntervalMs - Date.now();
      if (wait > 0) {
        await new Promise<void>((resolve: () => void): void => {
          setTimeout((): void => resolve(), wait);
        });
      }
      try {
        return await fn();
      } finally {
        this.lastRequestAt = Date.now();
      }
    };
    const p: Promise<T> = this.chain.then(run);
    this.chain = p.then((): void => {}, (): void => {});
    return p;
  }

  private async handleSessionExpired(path: string): Promise<void> {
    Logger.warn(TAG, `社区请求会话失效: ${path}`);
    this.deps.notifySessionExpired();
    try {
      await this.transport.clearSiteCookies();
    } catch (_e) {
      // 忽略清理异常，不阻断登录跳转
    }
    const cb: (() => void) | undefined = this.onSessionExpired;
    if (cb !== undefined) {
      cb();
    }
  }

  /**
   * 社区业务请求统一入口：
   * - 走 HttpManager（自动带 NOY_SESSION Cookie）；
   * - 显式传社区 allow-adult（确认前恒为 'false'）；
   * - 统一处理 status='login' / 'error'。
   */
  async postText(path: string, form?: Record<string, string | number>): Promise<string> {
    return this.schedule<string>(async (): Promise<string> => {
      const stringForm: Record<string, string> = {};
      if (form !== undefined) {
        const keys: string[] = Object.keys(form);
        for (let i = 0; i < keys.length; i++) {
          const k: string = keys[i];
          stringForm[k] = String(form[k]);
        }
      }
      const headers: Record<string, string> = {
        'allow-adult': this.currentAllowAdult()
      };
      const text: string = await this.transport.postFormText(path, stringForm, headers);

      let base: BaseResp = {};
      try {
        base = JSON.parse(text) as BaseResp;
      } catch (_e) {
        throw new NoyApiError(`响应不是合法 JSON @ ${path}`);
      }
      const statusText: string | undefined = typeof base.status === 'string' ? base.status : undefined;
      if (isLoginStatus(statusText)) {
        await this.handleSessionExpired(path);
        throw new NoyAuthError();
      }
      if (base.status === 'error') {
        throw new NoyApiError(`业务错误 @ ${path}`);
      }
      return text;
    });
  }

  // ---------- 会话探活（只读，绝不记录邮箱/Cookie） ----------
  async userInfo(): Promise<RawUserInfoEnvelope> {
    const text: string = await this.postText('/api/v3/userinfo');
    return JSON.parse(text) as RawUserInfoEnvelope;
  }

  // ---------- 读 ----------
  async listPosts(page: number = 1, type: string = 'new', filter: string = ''): Promise<CommunityListResp> {
    const text: string = await this.postText('/api/v3/community_list', {
      'page': page,
      'type': type,
      'filter': filter
    });
    return parseCommunityListResp(text);
  }

  async postDetail(id: number): Promise<PostDetailResp> {
    const text: string = await this.postText(`/api/v4/community/post/${id}`);
    return parsePostDetailResp(text);
  }

  async comments(id: number, page: number = 1): Promise<PostCommentsResp> {
    const text: string = await this.postText(`/api/v4/community/post/${id}/comments`, { 'page': page });
    return parsePostCommentsResp(text);
  }

  async replies(id: number, rid: number, page: number = 1): Promise<CommentRepliesResp> {
    const text: string = await this.postText(`/api/v4/community/post/${id}/comment/${rid}/replies`, {
      'page': page
    });
    return parseCommentRepliesResp(text);
  }

  // ---------- 写（写操作绝不自动重试） ----------
  async reply(id: number, text: string, replyTo: number = -1): Promise<void> {
    await this.postText(`/api/v4/community/post/${id}/reply`, {
      'reply_id': replyTo,
      'text': text,
      'platform': this.platform,
      'hide_ip': 'false'
    });
  }

  async createPost(title: string, content: string, imageFiles: string[] = []): Promise<void> {
    const form: Record<string, string | number> = {
      'title': title,
      'content': content,
      'platform': this.platform
    };
    if (imageFiles.length > 0) {
      const imgs: string[] = [];
      for (let i = 0; i < imageFiles.length; i++) {
        const f: string = imageFiles[i];
        imgs.push(f.startsWith('image/') ? f : `image/${f}`);
      }
      form['image'] = JSON.stringify(imgs);
    }
    await this.postText('/api/v3/send_community', form);
  }

  async editPost(id: number, title: string, content: string): Promise<void> {
    await this.postText('/api/v3/edit_community_post', {
      'id': id,
      'title': title,
      'content': content
    });
  }

  async toggleLike(cid: number): Promise<boolean> {
    const text: string = await this.postText('/api/v3/community_like', { 'cid': cid });
    const r: LikeResp = JSON.parse(text) as LikeResp;
    return r.is_like === true;
  }

  /**
   * 上传图片到图床（使用不绑定 CookieRepository 的独立 rcp.Session，确保绝不向图床发送 NOY_SESSION）。
   */
  async uploadImage(filePath: string, contentType: string = 'image/webp'): Promise<string> {
    const tokenText: string = await this.postText('/api/get_image_bucket_token');
    const tokenResp: TokenResp = JSON.parse(tokenText) as TokenResp;
    if (tokenResp.token === undefined || tokenResp.token === '') {
      throw new NoyApiError('没有拿到图床 token');
    }
    const token: string = tokenResp.token;

    return this.schedule<string>(async (): Promise<string> => {
      const uploadUrl: string = `${this.bucketUrl}/api/upload_image`;
      const session: rcp.Session = rcp.createSession();
      try {
        const multipart: rcp.MultipartForm = new rcp.MultipartForm({
          'token': token,
          'file': {
            contentOrPath: filePath,
            contentType: contentType
          }
        });
        const req: rcp.Request = new rcp.Request(uploadUrl, 'POST', {
          'origin': NOY_WEB_ORIGIN,
          'referer': `${NOY_WEB_ORIGIN}/`,
          'allow-adult': this.currentAllowAdult()
        }, multipart);
        const resp: rcp.Response = await session.fetch(req);
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw new NoyApiError(`图床 HTTP ${resp.statusCode}`);
        }
        const bodyText: string = resp.toString() ?? '';
        const parsed: UploadResp = JSON.parse(bodyText) as UploadResp;
        if (parsed.file === undefined || parsed.file === '') {
          throw new NoyApiError(`上传失败：${parsed.status ?? 'unknown'}`);
        }
        return parsed.file;
      } finally {
        session.close();
      }
    });
  }

  // ---------- 消息 / 签到 ----------
  async unreadCount(): Promise<MsgCountResp> {
    const text: string = await this.postText('/api/v4/msg/count');
    return parseMsgCountResp(text);
  }

  async messagesReply(page: number = 1): Promise<MsgReplyResp> {
    const text: string = await this.postText('/api/v3/get_msg', {
      'page': page,
      'type': 'reply',
      'v': 3
    });
    return parseMsgReplyResp(text);
  }

  async messagesCommunityReply(page: number = 1): Promise<MsgCommunityReplyResp> {
    const text: string = await this.postText('/api/v3/get_msg', {
      'page': page,
      'type': 'community_reply',
      'v': 3
    });
    return parseMsgCommunityReplyResp(text);
  }

  async messagesSys(page: number = 1): Promise<MsgSysResp> {
    const text: string = await this.postText('/api/v3/get_msg', {
      'page': page,
      'type': 'sysmsg',
      'v': 3
    });
    return parseMsgSysResp(text);
  }

  async signIn(): Promise<boolean> {
    const text: string = await this.postText('/api/v4/signin/sign');
    const r: BaseResp = JSON.parse(text) as BaseResp;
    return r.status === 200;
  }
}
