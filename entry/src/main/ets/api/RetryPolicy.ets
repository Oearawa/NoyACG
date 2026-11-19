/**
 * RetryPolicy.ets —— 幂等 GET 自动重试策略（纯函数，I-000004）
 *
 * Architect 契约事实（已裁定）：
 * - maxAttempts = 3（1 次原始尝试 + 至多 2 次重试）；base = 500ms；退避 ×2 + 抖动；
 * - 仅幂等 GET 可重试；POST 写操作一律不自动重试（防重复提交）；
 * - 可重试：超时 / 5xx / 网络不可达；不可重试：4xx（408、429 单独评估）、
 *   业务错误、取消、解析失败。
 *
 * 本文件刻意不 import HttpManager / rcp 类型：
 * 分类基于 HttpError 的结构字段（statusCode / retryHint）做鸭子类型判定，
 * 避免与 HttpManager 形成循环依赖，也让本模块可被单测直接验证。
 *
 * retryHint 约定（由 HttpManager 在抛出点标注）：
 * - 'http'    HTTP 状态码失败（statusCode >= 0 为真实状态码）
 * - 'network' rcp 本地网络异常（连接失败 / 超时 / 网络不可达）
 * - 'cancel'  rcp 取消码归一化而来（1007900992）
 * - 'parse'   JSON 解析失败
 * - ''        未标注（外部构造，如业务层 -2 / -3 —— 视为业务错误，不重试）
 */
export const RETRY_MAX_ATTEMPTS: number = 3;
export const RETRY_BASE_DELAY_MS: number = 500;
/** 退避上限（不含抖动），防止指数退避过长 */
export const RETRY_MAX_DELAY_MS: number = 8000;
/** 服务端 Retry-After 尊重上限（毫秒），防止异常大值阻塞队列 */
export const RETRY_AFTER_CAP_MS: number = 15000;
/** 抖动上限：+0 ~ +99ms，避免多个请求同时重试形成惊群 */
export const RETRY_JITTER_MAX_MS: number = 100;

/** 结构化分类结果 */
export class RetryDecision {
  readonly retryable: boolean;
  readonly reason: string;

  constructor(retryable: boolean, reason: string) {
    this.retryable = retryable;
    this.reason = reason;
  }
}

/** HttpError 的分类视角（鸭子类型；不在本文件 import HttpManager） */
interface RetryClassifiable {
  statusCode?: number;
  retryHint?: string;
  retryAfterMs?: number;
}

/** 重试退避：attempt 为第几次重试（1 起）；delay = min(MAX, base * 2^(attempt-1)) + [0, JITTER) */
export function nextRetryDelayMs(attempt: number): number {
  let exp: number = 1;
  for (let i = 1; i < attempt; i++) {
    exp *= 2;
  }
  const base: number = Math.min(RETRY_MAX_DELAY_MS, RETRY_BASE_DELAY_MS * exp);
  const jitter: number = Math.floor(Math.random() * RETRY_JITTER_MAX_MS);
  return base + jitter;
}

/**
 * 解析 HTTP `Retry-After` 头（秒数或 HTTP 日期），返回有界毫秒值；无效/过期返回 undefined。
 */
export function parseRetryAfterMs(headerValue: string | undefined,
  maxCapMs: number = RETRY_AFTER_CAP_MS): number | undefined {
  if (headerValue === undefined || headerValue === null) {
    return undefined;
  }
  const text: string = headerValue.trim();
  if (text === '') {
    return undefined;
  }
  if (/^\d+$/.test(text)) {
    const seconds: number = Number(text);
    if (!Number.isFinite(seconds) || seconds < 0) {
      return undefined;
    }
    return Math.min(maxCapMs, seconds * 1000);
  }
  const dateMs: number = Date.parse(text);
  if (!Number.isFinite(dateMs)) {
    return undefined;
  }
  const delta: number = dateMs - Date.now();
  if (delta <= 0) {
    return 0;
  }
  return Math.min(maxCapMs, delta);
}

/** 若错误携带了有界 Retry-After 且大于本地退避，则取二者较大值（仍受 cap 限制）。 */
export function resolveRetryDelayMs(e: Object | undefined, fallbackDelayMs: number): number {
  if (e === undefined || e === null || !(e instanceof Error)) {
    return fallbackDelayMs;
  }
  const err: RetryClassifiable = e as RetryClassifiable;
  const retryAfter: number | undefined = err.retryAfterMs;
  if (retryAfter !== undefined && Number.isFinite(retryAfter) && retryAfter > 0) {
    const capped: number = Math.min(RETRY_AFTER_CAP_MS, retryAfter);
    return Math.max(fallbackDelayMs, capped);
  }
  return fallbackDelayMs;
}

/** 判断异常是否可重试（幂等 GET 语境；POST 由 RequestGate 直接短路，不经此函数） */
export function classifyRetry(e: Object | undefined): RetryDecision {
  if (e === undefined || e === null || !(e instanceof Error)) {
    return new RetryDecision(false, 'not-error');
  }
  const err: RetryClassifiable = e as RetryClassifiable;
  const code: number = err.statusCode ?? -999;
  const hint: string = err.retryHint ?? '';
  if (hint === 'cancel') {
    return new RetryDecision(false, 'canceled');
  }
  if (hint === 'parse') {
    return new RetryDecision(false, 'parse-error');
  }
  if (hint === 'business' || code === -2 || code === -3) {
    return new RetryDecision(false, 'business-error');
  }
  if (code >= 500) {
    return new RetryDecision(true, `http-${code}`);
  }
  if (code === 408 || code === 429) {
    return new RetryDecision(true, `http-${code}-retryable`);
  }
  if (code >= 400 && code < 500) {
    return new RetryDecision(false, `http-${code}`);
  }
  if (hint === 'network') {
    return new RetryDecision(true, 'network');
  }
  if (code < 0) {
    // 未标注的本地负值：保守不重试（宁可少重试，不可重复提交 / 放大故障）
    return new RetryDecision(false, 'local-negative-unclassified');
  }
  return new RetryDecision(false, 'unexpected');
}

/** 仅在幂等 GET 上启用重试（RequestGate 的入口判断） */
export function isRetryableMethod(method: string): boolean {
  return method === 'GET';
}
