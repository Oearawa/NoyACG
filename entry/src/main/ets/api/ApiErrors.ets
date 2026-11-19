/**
 * ApiErrors.ets —— 数据层统一异常类型（在 HttpError 之上细分业务语义）
 *
 * 为什么需要细分：
 * NoyAcg 的接口在**未登录时依然返回 HTTP 200**，只是 body 变成 `{"status":"login"}`。
 * 若不单独识别，UI 会把它当成「解析失败/网络错误」，用户看不到「需要登录」这个真实原因。
 *
 * 继承关系：AuthRequiredError / ProtocolError 都是 HttpError 的子类，
 * 因此既有 ViewModel 里 `e instanceof HttpError ? e.message : ...` 的分支无需改写即可拿到正确文案。
 */
import { HttpError } from './HttpManager';

/** 服务端要求登录（HTTP 200 + status=login），或登录态已失效 */
export class AuthRequiredError extends HttpError {
  constructor(message: string = '需要登录 NoyAcg 账号才能使用该功能') {
    super(-2, message);
    this.name = 'AuthRequiredError';
  }
}

/** 响应结构与已确认协议不符（字段缺失、类型异常、非 JSON 包装层） */
export class ProtocolError extends HttpError {
  constructor(message: string) {
    super(-3, message);
    this.name = 'ProtocolError';
  }
}

/**
 * 会话失效通知端口：生产实现是 AuthManager.notifySessionExpired，
 * 数据层只依赖这个函数签名，便于用桩验证「什么异常才会触发降级」。
 */
export type SessionExpiredNotifier = () => void;

/**
 * 仅当异常确为「服务端 HTTP 200 + status=login」对应的 AuthRequiredError 时触发通知。
 *
 * 严格排除以下情形（Phase 11 审计要求）：
 * - `ProtocolError`（结构不符 / 缺字段 / 非 JSON）→ 普通协议错误，不得降级；
 * - `HttpError(>=400 或 5xx)` → 服务端错误，不得退出登录；
 * - `HttpError(-1)`（JSON 解析失败）→ 解析错误，不得降级；
 * - `HttpError(-2)` 但**不是** AuthRequiredError 实例（如 BusinessError code=-2）→ 不得降级；
 * - 网络超时 / 连接失败等任意其它异常 → 绝不删除 Cookie。
 *
 * 判定用 `instanceof` 而非错误码，避免把同码异义的异常误判成会话失效。
 * @returns 是否触发了通知（供日志与回归测试使用）
 */
export function notifyIfSessionExpired(e: Object, notifier: SessionExpiredNotifier): boolean {
  if (!(e instanceof AuthRequiredError)) {
    return false;
  }
  notifier();
  return true;
}
