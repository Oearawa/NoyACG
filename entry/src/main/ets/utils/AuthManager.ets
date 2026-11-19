/**
 * AuthManager.ets —— 全局认证状态机（单例 · @ObservedV2）
 *
 * 职责：
 * 1. 唯一认证真相源：UI 只读这里的 @Trace 状态，不各自持有登录标记；
 * 2. 启动会话恢复：有 Cookie 才向服务端校验，绝不以「Cookie 存在」判定已登录；
 * 3. 登录/退出串行化：同一时刻只允许一个进行中的认证操作，防重复提交；
 * 4. 失败分级：凭据错误 / 网络异常 / 协议异常 / Cookie 缺失 / 会话被拒 / 会话过期。
 *
 * 与 HttpManager 的关系：
 * HttpManager 负责 rcp 会话与 CookieRepository（自动收 Cookie、自动携带、自动落盘）；
 * AuthManager 只通过「端口」调用它，因此可用桩实现在无设备环境下测试状态机。
 */
import { AuthRepository } from '../api/AuthRepository';
import { AuthErrorKind, AuthFailure, AuthStatus, AuthUser } from '../api/AuthTypes';
import { HttpManager } from '../api/HttpManager';
import { Logger } from './Logger';
import { sanitizeText } from './LogSanitizer';
import { PreferenceManager } from './PreferenceManager';

const TAG: string = 'AuthManager';

@ObservedV2
export class AuthManager {
  private static instance?: AuthManager;

  /** 当前认证状态 */
  @Trace status: AuthStatus = AuthStatus.UNKNOWN;
  /** 已登录用户（未登录为 null） */
  @Trace user: AuthUser | null = null;
  /** 最近一次失败提示（成功时清空） */
  @Trace errorMessage: string = '';
  /** 最近一次失败原因分类 */
  @Trace errorKind: AuthErrorKind | null = null;

  private repo: AuthRepository;
  /** 进行中的会话恢复任务（并发调用共享同一 Promise，避免重复请求） */
  private restoreTask?: Promise<void>;

  constructor(repo?: AuthRepository) {
    this.repo = repo ?? new AuthRepository(HttpManager.getInstance(), HttpManager.getInstance());
  }

  static getInstance(): AuthManager {
    if (AuthManager.instance === undefined) {
      AuthManager.instance = new AuthManager();
    }
    return AuthManager.instance;
  }

  /** 是否已登录（服务端认可） */
  get isAuthenticated(): boolean {
    return this.status === AuthStatus.AUTHENTICATED;
  }

  /** 是否有认证操作进行中（UI 用于禁用按钮） */
  get isBusy(): boolean {
    return this.status === AuthStatus.CHECKING
      || this.status === AuthStatus.LOGGING_IN
      || this.status === AuthStatus.LOGGING_OUT;
  }

  /**
   * 应用启动调用：非阻塞地触发一次会话恢复。
   * 重复调用安全（状态已确定时直接返回）。
   */
  initialize(): void {
    if (this.status !== AuthStatus.UNKNOWN) {
      return;
    }
    this.restoreSession();
  }

  /**
   * 会话恢复：
   * - 无 Cookie → 未登录（不发请求）；
   * - 有 Cookie → 调 /v3/userinfo 校验，服务端认可才算登录；
   * - 网络/协议异常 → ERROR（**保留 Cookie**，可重试，不误判为未登录）。
   */
  async restoreSession(force: boolean = false): Promise<void> {
    if (this.restoreTask !== undefined) {
      return this.restoreTask;
    }
    if (this.status === AuthStatus.LOGGING_IN || this.status === AuthStatus.LOGGING_OUT) {
      return;
    }
    if (!force && this.status === AuthStatus.AUTHENTICATED) {
      return;
    }
    this.restoreTask = this.doRestore();
    try {
      await this.restoreTask;
    } finally {
      this.restoreTask = undefined;
    }
  }

  /**
   * 统一写入口（Phase 14-R）：账号状态变化时同步「标签黑名单作用域」。
   * 所有 user 赋值都必须走这里，否则会出现「A 用户的屏蔽规则留给 B 用户」。
   */
  private setUser(next: AuthUser | null): void {
    this.user = next;
    PreferenceManager.getInstance().applyBlockedTagScope(next === null ? '' : next.uid);
  }

  private async doRestore(): Promise<void> {
    this.status = AuthStatus.CHECKING;
    this.errorMessage = '';
    this.errorKind = null;
    try {
      const hasCookies: boolean = await this.repo.hasCookies();
      if (!hasCookies) {
        this.setUser(null);
        this.status = AuthStatus.UNAUTHENTICATED;
        Logger.info(TAG, '无会话 Cookie，进入未登录状态');
        return;
      }
      const user: AuthUser | null = await this.repo.fetchUser();
      if (user === null) {
        // 诊断：区分「自动携带失效」与「Cookie 值失效」。
        // 探针仅用于诊断，必须与状态判定隔离：探针失败只记录日志，
        // 不得把「服务端不认可 → UNAUTHENTICATED」翻转成 ERROR。
        // 仅 debug 构建执行（I-000005）：release 构建**不调用、不输出**任何探针诊断。
        if (HttpManager.diagnosticEnabled()) {
          try {
            const probe: string = await HttpManager.getInstance().probeUserinfoWithExplicitCookie();
            Logger.warn(TAG, `诊断：显式携带 Cookie 的 userinfo status=${sanitizeText(probe)}`);
          } catch (e) {
            Logger.warn(TAG, `诊断探针失败（不影响状态判定）: ${(e as Error).message}`);
          }
        }
        // Cookie 存在但服务端不认可（过期/被吊销）：判未登录，Cookie 交由下次登录覆盖
        this.setUser(null);
        this.status = AuthStatus.UNAUTHENTICATED;
        Logger.info(TAG, '会话 Cookie 未被服务端认可，进入未登录状态');
        return;
      }
      this.setUser(user);
      this.status = AuthStatus.AUTHENTICATED;
      Logger.info(TAG, '会话恢复成功');
    } catch (e) {
      // 网络/协议异常：不清除 Cookie、不判未登录，保留可重试状态
      const failure: AuthFailure = e as AuthFailure;
      this.errorKind = failure instanceof AuthFailure ? failure.kind : AuthErrorKind.UNKNOWN;
      this.errorMessage = failure instanceof AuthFailure
        ? failure.message : '会话校验失败，请稍后重试';
      this.status = AuthStatus.ERROR;
      Logger.warn(TAG, `会话恢复失败(${this.errorKind}): ${sanitizeText(this.errorMessage)}`);
    }
  }

  /**
   * 登录（含服务端会话校验）。
   * @returns true = 已登录；false = 失败（原因见 errorKind / errorMessage）
   */
  async login(user: string, password: string): Promise<boolean> {
    if (this.status === AuthStatus.LOGGING_IN) {
      return false; // 防重复提交
    }
    this.status = AuthStatus.LOGGING_IN;
    this.errorMessage = '';
    this.errorKind = null;
    try {
      const account: AuthUser = await this.repo.login(user, password);
      this.setUser(account);
      this.status = AuthStatus.AUTHENTICATED;
      Logger.info(TAG, '登录成功');
      return true;
    } catch (e) {
      const failure: AuthFailure = e as AuthFailure;
      this.setUser(null);
      this.status = AuthStatus.LOGIN_FAILED;
      this.errorKind = failure instanceof AuthFailure ? failure.kind : AuthErrorKind.UNKNOWN;
      this.errorMessage = failure instanceof AuthFailure
        ? failure.message : '登录失败，请稍后重试';
      Logger.warn(TAG, `登录失败(${this.errorKind}): ${sanitizeText(this.errorMessage)}`);
      return false;
    }
  }

  /**
   * 退出登录：服务端退出（尽力而为）+ 删除本站 Cookie + 重置本地状态。
   * @returns true = 本地 Cookie 已清理；false = 清理失败（状态仍置为未登录，但已提示）
   */
  async logout(): Promise<boolean> {
    if (this.status === AuthStatus.LOGGING_OUT) {
      return false;
    }
    this.status = AuthStatus.LOGGING_OUT;
    let cleared: boolean = false;
    try {
      cleared = await this.repo.logout();
    } catch (e) {
      Logger.error(TAG, `退出异常: ${(e as Error).message}`);
    }
    this.setUser(null);
    this.status = AuthStatus.UNAUTHENTICATED;
    this.errorKind = null;
    this.errorMessage = cleared ? '' : '本地会话清理失败，请重试退出';
    return cleared;
  }

  /**
   * 严格登出（个人中心抽屉使用）：仅在服务端 ack 后才清理本地会话。
   * - 服务端失败 / 未知状态 → 保持登录态、返回 false（不假装登出成功）；
   * - 服务端 ack → 清 Cookie；本地清理失败如实返回 false。
   */
  async logoutWithServerAck(): Promise<boolean> {
    if (this.status === AuthStatus.LOGGING_OUT) {
      return false;
    }
    this.status = AuthStatus.LOGGING_OUT;
    this.errorMessage = '';
    this.errorKind = null;
    let ack: boolean = false;
    try {
      ack = await this.repo.requestLogout();
    } catch (e) {
      ack = false;
    }
    if (!ack) {
      this.status = this.user !== null ? AuthStatus.AUTHENTICATED : AuthStatus.UNAUTHENTICATED;
      this.errorMessage = '服务端登出失败，请检查网络后重试';
      this.errorKind = AuthErrorKind.NETWORK;
      Logger.warn(TAG, '严格登出：服务端未确认，保持登录态');
      return false;
    }
    let cleared: boolean = false;
    try {
      cleared = await this.repo.clearLocalSession();
    } catch (e) {
      cleared = false;
    }
    this.setUser(null);
    this.status = AuthStatus.UNAUTHENTICATED;
    this.errorKind = null;
    this.errorMessage = cleared ? '' : '服务端已登出，但本地会话清理失败';
    return cleared;
  }

  /**
   * 业务请求发现会话失效（HTTP 200 + status=login）时调用：
   * 只有当前确实是「已登录」才降级，避免并发请求互相踩状态。
   */
  notifySessionExpired(): void {
    if (this.status !== AuthStatus.AUTHENTICATED) {
      return;
    }
    this.setUser(null);
    this.status = AuthStatus.UNAUTHENTICATED;
    this.errorKind = AuthErrorKind.SESSION_REJECTED;
    this.errorMessage = '登录状态已过期，请重新登录';
    Logger.info(TAG, '业务请求返回未登录，认证状态降级');
  }

  /** 供测试/调试重置（不触达网络） */
  resetForTest(): void {
    this.status = AuthStatus.UNKNOWN;
    this.setUser(null);
    this.errorMessage = '';
    this.errorKind = null;
    this.restoreTask = undefined;
  }
}
