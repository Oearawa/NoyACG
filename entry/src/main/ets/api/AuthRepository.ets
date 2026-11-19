/**
 * AuthRepository.ets —— 登录 / 会话校验 / 退出的协议实现
 *
 * 协议来源（详见 LOGIN_PROTOCOL_AUDIT.md）：
 * - 登录：POST /api/login，form `user` / `pass`（首方 auth-*.js 的 `i(r)`）；
 *   失败：status=error（账号或密码错误）/ status=danger（内容含不允许字符）；成功无显式字段；
 * - 会话校验：POST /api/v3/userinfo，status=ok + userinfo（首方 `X(e)`）；
 * - 退出：POST /api/logout（首方 `Hl()`，前端是 fire-and-forget）。
 *
 * 严格性：登录接口返回非 error/danger **不等于**已登录 —— 必须再做一次 userinfo 校验，
 * 且要求 Cookie 已落地；任一步失败都返回明确原因，绝不把半完成状态当成登录成功。
 */
import {
  AuthCookiePort,
  AuthErrorKind,
  AuthFailure,
  AuthHttpPort,
  AuthUser,
  RawLoginResponse,
  RawUserInfo,
  RawUserInfoEnvelope,
  isLoginStatus
} from './AuthTypes';
import { HttpError } from './HttpManager';
import { LocalizationManager } from '../utils/LocalizationManager';
import { Logger } from '../utils/Logger';

const TAG: string = 'AuthRepository';

const PATH_LOGIN: string = '/api/login';
const PATH_USER_INFO: string = '/api/v3/userinfo';
const PATH_LOGOUT: string = '/api/logout';

export class AuthRepository {
  private http: AuthHttpPort;
  private cookies: AuthCookiePort;

  constructor(http: AuthHttpPort, cookies: AuthCookiePort) {
    this.http = http;
    this.cookies = cookies;
  }

  /**
   * 登录：发请求 → 校验业务状态 → 确认 Cookie 落地 → 服务端会话校验。
   * @throws AuthFailure（kind 区分凭据错误/网络/协议/Cookie 缺失/会话被拒）
   */
  async login(user: string, password: string): Promise<AuthUser> {
    const lm: LocalizationManager = LocalizationManager.getInstance();
    const username: string = user.trim();
    if (username === '' || password === '') {
      throw new AuthFailure(
        AuthErrorKind.INVALID_CREDENTIALS,
        lm.getString($r('app.string.auth_err_empty'), '请输入账号与密码')
      );
    }

    let resp: RawLoginResponse;
    try {
      resp = await this.http.postForm<RawLoginResponse>(PATH_LOGIN, {
        'user': username,
        'pass': password
      }, { 'referer': 'https://noymanga.com/login' });
    } catch (e) {
      throw this.mapTransportError(e, lm.getString($r('app.string.auth_err_network'), '网络连接异常，请稍后重试'));
    }

    const status: string | undefined = resp === undefined ? undefined : resp.status;
    if (status === 'error') {
      throw new AuthFailure(
        AuthErrorKind.INVALID_CREDENTIALS,
        lm.getString($r('app.string.auth_err_invalid_credentials'), '账号或密码错误')
      );
    }
    if (status === 'danger') {
      throw new AuthFailure(
        AuthErrorKind.FORBIDDEN_INPUT,
        lm.getString($r('app.string.auth_err_forbidden'), '输入内容包含不允许的字符')
      );
    }
    if (isLoginStatus(status)) {
      // 登录接口返回 login 属于异常契约：不能当成成功
      throw new AuthFailure(
        AuthErrorKind.SERVER,
        lm.getString($r('app.string.auth_err_server'), '登录未生效，请稍后重试')
      );
    }

    // 登录响应必须落地会话 Cookie，否则后续请求仍是匿名
    let cookieCount: number = 0;
    try {
      cookieCount = await this.cookies.countCookies();
      await this.cookies.persistCookies(); // 主动落盘，避免进程被杀丢失会话
    } catch (e) {
      Logger.warn(TAG, `读取/保存 Cookie 失败: ${(e as Error).message}`);
    }
    if (cookieCount <= 0) {
      throw new AuthFailure(
        AuthErrorKind.COOKIE_MISSING,
        lm.getString($r('app.string.auth_err_cookie_missing'), '登录成功但未建立会话 Cookie，请检查网络后重试')
      );
    }

    // 以服务端认可的会话校验结果为准
    const verifiedUser: AuthUser | null = await this.fetchUser();
    if (verifiedUser === null) {
      throw new AuthFailure(
        AuthErrorKind.SESSION_REJECTED,
        lm.getString($r('app.string.auth_err_session_rejected'), '会话校验失败（Cookie 已建立但服务端未认可）')
      );
    }
    Logger.info(TAG, `登录成功 uid=${this.maskUid(verifiedUser.uid)}`);
    return verifiedUser;
  }

  /**
   * 拉取用户信息（会话校验）。
   * @returns 已登录返回用户；未登录返回 null
   * @throws AuthFailure NETWORK / PROTOCOL（不代表未登录，调用方不应清除会话）
   */
  async fetchUser(): Promise<AuthUser | null> {
    let resp: RawUserInfoEnvelope;
    try {
      resp = await this.http.postForm<RawUserInfoEnvelope>(PATH_USER_INFO, {});
    } catch (e) {
      throw this.mapTransportError(e, '会话校验失败');
    }
    if (resp === undefined || resp === null) {
      throw new AuthFailure(AuthErrorKind.PROTOCOL, '会话校验响应为空');
    }
    if (isLoginStatus(resp.status)) {
      return null; // 明确未登录
    }
    if (resp.status !== 'ok') {
      throw new AuthFailure(AuthErrorKind.PROTOCOL,
        `会话校验返回未知状态: ${resp.status ?? '(空)'}`);
    }
    const info: RawUserInfo | undefined = resp.userinfo;
    if (info === undefined) {
      throw new AuthFailure(AuthErrorKind.PROTOCOL, '会话校验响应缺少 userinfo');
    }
    return new AuthUser(this.pickUid(info), this.pickName(info));
  }

  /**
   * 退出：先请求服务端（失败忽略，不阻断本地清理），再删除本站 Cookie。
   * @returns 是否成功完成「本地 Cookie 清理」（服务端退出结果不伪造）
   */
  async logout(): Promise<boolean> {
    await this.requestLogout();
    return this.clearLocalSession();
  }

  /**
   * 仅请求服务端登出并判定 ack（**不清本地**）。
   * `status=logout` / `ok` → 成功；`status=login`（会话已失效，等价已登出）→ 成功；
   * 网络/协议异常或未知状态 → false（调用方据此决定是否清本地）。
   */
  async requestLogout(): Promise<boolean> {
    try {
      const resp: RawLoginResponse = await this.http.postForm<RawLoginResponse>(PATH_LOGOUT, {});
      const status: string | undefined = resp === undefined || resp === null ? undefined : resp.status;
      if (status === 'logout' || status === 'ok') {
        Logger.info(TAG, '服务端登出成功');
        return true;
      }
      if (isLoginStatus(status)) {
        Logger.info(TAG, '服务端会话已失效，视为已登出');
        return true;
      }
      Logger.warn(TAG, `服务端登出返回未知状态: ${status ?? '(空)'}`);
      return false;
    } catch (e) {
      Logger.warn(TAG, `服务端登出请求失败: ${(e as Error).message}`);
      return false;
    }
  }

  /** 清理本地会话 Cookie 并落盘（不请求网络） */
  async clearLocalSession(): Promise<boolean> {
    try {
      await this.cookies.clearSiteCookies();
      await this.cookies.persistCookies();
      Logger.info(TAG, '本地会话 Cookie 已清理并持久化');
      return true;
    } catch (e) {
      Logger.error(TAG, `本地 Cookie 清理失败: ${(e as Error).message}`);
      return false;
    }
  }

  /** 当前是否持有任何 Cookie（仅用于判断是否需要发起校验，不作为登录依据） */
  async hasCookies(): Promise<boolean> {
    try {
      return await this.cookies.countCookies() > 0;
    } catch (e) {
      Logger.warn(TAG, `Cookie 读取失败: ${(e as Error).message}`);
      return false;
    }
  }

  /** 传输层异常 → 认证异常（区分网络与协议，便于 UI 与状态机处理） */
  private mapTransportError(e: Object, prefix: string): AuthFailure {
    if (e instanceof HttpError) {
      // -1 = JSON 解析失败（HttpManager 约定），按协议异常处理
      if (e.statusCode === -1) {
        return new AuthFailure(AuthErrorKind.PROTOCOL, `${prefix}：响应不是合法 JSON`);
      }
      return new AuthFailure(AuthErrorKind.NETWORK, `${prefix}：${e.message}`);
    }
    return new AuthFailure(AuthErrorKind.NETWORK, `${prefix}：${(e as Error).message}`);
  }

  /** UID 兼容 Uid/UID/uid 三种写法 */
  private pickUid(info: RawUserInfo): string {
    const raw: number | string | undefined = info.Uid ?? info.UID ?? info.uid;
    return raw === undefined ? '' : String(raw);
  }

  /** 展示名兼容 Name/name/Username/username/Nickname/nickname */
  private pickName(info: RawUserInfo): string {
    return info.Name ?? info.name ?? info.Username ?? info.username
      ?? info.Nickname ?? info.nickname ?? '';
  }

  /** 日志脱敏：只保留 uid 前 4 位 */
  private maskUid(uid: string): string {
    if (uid.length <= 4) {
      return '***';
    }
    return `${uid.substring(0, 4)}***`;
  }
}
