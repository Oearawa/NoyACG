/**
 * AuthTypes.ets —— 认证领域类型与端口定义
 *
 * 设计要点：
 * 1. 状态机显式化：UNKNOWN → CHECKING → AUTHENTICATED / UNAUTHENTICATED / ERROR；
 *    登录另有 LOGGING_IN / LOGIN_FAILED，退出有 LOGGING_OUT。
 *    「Cookie 存在」绝不等于「已登录」——最终状态一律以服务端 /v3/userinfo 为准。
 * 2. 端口化：AuthRepository 只依赖 AuthHttpPort / AuthCookiePort 两个接口，
 *    生产实现是 HttpManager（真实 rcp + CookieRepository），单元测试注入桩实现，
 *    从而在无设备环境下也能验证登录状态机、错误映射与清理顺序。
 * 3. 不保存明文密码：本文件与仓储层都不提供任何持久化字段。
 */

/** 认证状态 */
export enum AuthStatus {
  /** 尚未完成初始化 */
  UNKNOWN = 'unknown',
  /** 正在校验会话（启动恢复 / 手动刷新） */
  CHECKING = 'checking',
  /** 已登录（服务端认可） */
  AUTHENTICATED = 'authenticated',
  /** 未登录（无 Cookie 或服务端返回 status=login） */
  UNAUTHENTICATED = 'unauthenticated',
  /** 登录请求进行中 */
  LOGGING_IN = 'logging_in',
  /** 登录失败（凭据/网络/协议） */
  LOGIN_FAILED = 'login_failed',
  /** 退出中 */
  LOGGING_OUT = 'logging_out',
  /** 会话校验被网络/服务端异常阻断（不清除本地 Cookie，可重试） */
  ERROR = 'error'
}

/** 登录失败原因（用于 UI 文案与统计，不包含敏感信息） */
export enum AuthErrorKind {
  /** 账号或密码错误（服务端 status=error） */
  INVALID_CREDENTIALS = 'invalid_credentials',
  /** 输入包含不允许的内容（服务端 status=danger） */
  FORBIDDEN_INPUT = 'forbidden_input',
  /** 网络异常/超时 */
  NETWORK = 'network',
  /** 响应结构不符（非 JSON、缺字段） */
  PROTOCOL = 'protocol',
  /** 登录接口成功但未落地任何 Cookie */
  COOKIE_MISSING = 'cookie_missing',
  /** Cookie 已建立但服务端校验失败 */
  SESSION_REJECTED = 'session_rejected',
  /** 服务端其它拒绝（未知 status） */
  SERVER = 'server',
  /** 未知错误 */
  UNKNOWN = 'unknown'
}

/** 认证失败异常（携带可区分的原因） */
export class AuthFailure extends Error {
  readonly kind: AuthErrorKind;

  constructor(kind: AuthErrorKind, message: string) {
    super(message);
    this.name = 'AuthFailure';
    this.kind = kind;
  }
}

/** 已登录用户（仅保留展示所需的最小字段，不缓存敏感信息） */
export class AuthUser {
  readonly uid: string;
  readonly name: string;

  constructor(uid: string, name: string) {
    this.uid = uid;
    this.name = name;
  }
}

/** HTTP 端口：只需表单 POST（登录/用户信息/退出均为 form-urlencoded） */
export interface AuthHttpPort {
  postForm<T>(path: string, form: Record<string, string>,
    headers?: Record<string, string>): Promise<T>;
}

/** Cookie 端口：只暴露「计数 / 清理本站 / 触发持久化」三个最小能力 */
export interface AuthCookiePort {
  /** 当前 CookieRepository 中的 Cookie 数量（用于判断登录是否落地） */
  countCookies(): Promise<number>;
  /** 删除属于 NoyAcg 站点的 Cookie，并触发持久化 */
  clearSiteCookies(): Promise<void>;
  /** 触发 CookieRepository 立即落盘 */
  persistCookies(): Promise<void>;
}

// ==================== 原始响应结构（依据首方前端使用方式） ====================

/** POST /api/login 的响应：成功无明确字段（前端只判 error/danger），失败为 status=error|danger */
export interface RawLoginResponse {
  status?: string;
}

/** /api/v3/userinfo 的响应：status=ok 时带 userinfo；未登录为 status=login */
export interface RawUserInfoEnvelope {
  status?: string;
  userinfo?: RawUserInfo;
}

/**
 * 用户信息：首方前端以 `Uid` 作为主键、`ne(e)` 派生展示名。
 * 展示名字段在不同响应中可能是 Name/Username，这里做兼容读取；
 * 未取得真实成功响应，字段名以「首方用法 + 兼容」为准（见 LOGIN_PROTOCOL_AUDIT.md）。
 */
export interface RawUserInfo {
  Uid?: number | string;
  UID?: number | string;
  uid?: number | string;
  Name?: string;
  name?: string;
  Username?: string;
  username?: string;
  Nickname?: string;
  nickname?: string;
}

/** 当前响应是否表示「未登录」 */
export function isLoginStatus(status: string | undefined): boolean {
  return status === 'login';
}
