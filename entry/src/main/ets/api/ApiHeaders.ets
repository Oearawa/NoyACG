/**
 * ApiHeaders.ets —— 站内 API 请求头的纯函数（Phase 14-T 抽取）
 *
 * 把「是否注入 allow-adult / 注入什么值」从 HttpManager 里抽成纯函数，
 * 使「分级变化后新请求确实携带新分级」可以被单元测试直接证明，
 * 而不必起一个真实网络会话。
 *
 * 规则：
 * 1. 只对 NoyAcg 站内 API（`https://noymanga.com/api/`）注入 `allow-adult`；
 * 2. 图片 CDN / 图床 / 外部域名一律不注入（不向第三方泄漏分级偏好）；
 * 3. 取值来自 `ContentRatingPolicy.resolve()`（唯一真相源），调用时读取 → 每次请求都用最新值。
 */
import { ContentRatingPolicy } from '../utils/ContentRatingPolicy';

/** 站内 API 前缀（同源判断，忽略大小写） */
export const NOY_API_PREFIX: string = 'https://noymanga.com/api/';

/** 是否为 NoyAcg 站内 API 请求 */
export function isNoyApiUrl(url: string): boolean {
  return url.toLowerCase().startsWith(NOY_API_PREFIX);
}

/**
 * 计算某次请求应携带的最终头部（含统一注入的 allow-adult）。
 * @param url 完整请求 URL
 * @param headers 调用级头部（可能为 undefined）
 * @returns 未命中站内 API 时原样返回 headers；命中时返回注入后的新对象（不修改入参）
 */
export function resolveContentRatingHeader(url: string,
  headers?: Record<string, string>): Record<string, string> | undefined {
  if (!isNoyApiUrl(url)) {
    return headers;
  }
  const next: Record<string, string> = {};
  if (headers !== undefined) {
    const keys: string[] = Object.keys(headers);
    for (let i = 0; i < keys.length; i++) {
      next[keys[i]] = headers[keys[i]];
    }
  }
  if (next['allow-adult'] === undefined) {
    next['allow-adult'] = ContentRatingPolicy.getInstance().resolve();
  }
  return next;
}
