/**
 * LogSanitizer.ets —— 日志脱敏（纯函数，Phase 14-R）
 *
 * 诊断日志与网络日志都要落盘 / 可导出，因此**写入前**必须脱敏。
 * 设计原则：宁可过度打码，也不能把可用于恢复登录态的凭据写进文件。
 *
 * 处理对象：
 * - Cookie / NOY_SESSION / Authorization / Bearer / token / password / pwd / secret
 * - Cookie 元数据指纹（fp=/fnv=/fingerprint=）与 `name@host` 形式的 Cookie 名
 * - 邮箱（保留首字符与域名）
 * - 长随机串（>=32 位字母数字，典型 token / 指纹）
 * - URL 查询参数值（保留参数名，值一律 ***）
 * - UID（uid=12345 → uid=***）
 */

/** 打码后的占位符 */
export const MASK: string = '***';
/** 邮箱脱敏后的占位符 */
export const MASKED_EMAIL: string = '***@***';

/** 需要整体脱敏的键名（小写比较） */
const SECRET_KEYS: string[] = [
  'cookie', 'set-cookie', 'noy_session', 'authorization', 'token', 'access_token',
  'refresh_token', 'password', 'passwd', 'pwd', 'secret', 'session', 'sessionid',
  'fp', 'fnv', 'fingerprint'
];

/**
 * 纯文本脱敏：用于错误消息 / 日志正文。
 * 顺序敏感：先处理带键名的模式，再处理裸长串，最后处理邮箱。
 */
export function sanitizeText(raw: string | null | undefined): string {
  if (raw === null || raw === undefined || typeof raw !== 'string' || raw === '') {
    return '';
  }
  let text: string = raw;

  // 1) Bearer <token>：必须先处理，否则 `Authorization: Bearer x` 会先被下面的
  //    `authorization:` 规则吃成 `Authorization: ***`，把 Bearer 后面的 token 留在正文里。
  text = text.replace(/\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/gi, `Bearer ${MASK}`);

  // 2) `key=value` / `key: value` 形式的敏感键
  for (let i = 0; i < SECRET_KEYS.length; i++) {
    const key: string = SECRET_KEYS[i];
    // 值：非空白且非分隔符，长度至少 1
    const pattern: RegExp = new RegExp(`(${escapeRegExp(key)}\\s*[=:]\\s*)([^\\s;&,，。]+)`, 'gi');
    text = text.replace(pattern, `$1${MASK}`);
  }

  // 2b) Cookie 明细元数据：`name@host` 形式的 Cookie 名前段打码，保留 @ 后宿主（域名/路径）信息
  text = text.replace(/\b[A-Za-z0-9_\-]{1,64}@([A-Za-z0-9.\-]+)/g, `${MASK}@$1`);

  // 3) 邮箱：保留首字符 + 域名
  text = text.replace(/([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9.-]+\.[A-Za-z]{2,})/g,
    `$1${MASK}@$2`);

  // 4) uid=12345 / uid: 12345
  text = text.replace(/\b(uid|user_?id|uid_?no)\s*[=:]\s*\d+/gi, `$1=${MASK}`);

  // 5) 裸长随机串（token / 指纹）：32 位以上连续字母数字
  text = text.replace(/\b[A-Za-z0-9]{32,}\b/g, MASK);

  return text;
}

/**
 * URL 脱敏：保留 origin + path，查询参数只留键名。
 * 不删除整个 query —— 键名对排查「参数传错」有价值，值才可能含凭据。
 */
export function sanitizeUrl(url: string | null | undefined): string {
  if (url === null || url === undefined || typeof url !== 'string' || url === '') {
    return '';
  }
  const hashIndex: number = url.indexOf('#');
  const withoutHash: string = hashIndex >= 0 ? url.substring(0, hashIndex) : url;
  const queryIndex: number = withoutHash.indexOf('?');
  if (queryIndex < 0) {
    return withoutHash;
  }
  const base: string = withoutHash.substring(0, queryIndex);
  const query: string = withoutHash.substring(queryIndex + 1);
  const pairs: string[] = query.split('&');
  const parts: string[] = [];
  for (let i = 0; i < pairs.length; i++) {
    if (pairs[i] === '') {
      continue;
    }
    const eq: number = pairs[i].indexOf('=');
    const key: string = eq >= 0 ? pairs[i].substring(0, eq) : pairs[i];
    parts.push(`${key}=${MASK}`);
  }
  return parts.length === 0 ? base : `${base}?${parts.join('&')}`;
}

/**
 * 路径脱敏：只需要「哪一个接口、什么方法」，因此只保留 path 部分。
 * 相对路径（/api/home）原样返回；完整 URL 去掉 origin 与 query。
 */
export function sanitizePath(url: string | null | undefined): string {
  if (url === null || url === undefined || typeof url !== 'string' || url === '') {
    return '';
  }
  let path: string = url;
  const schemeIndex: number = path.indexOf('://');
  if (schemeIndex >= 0) {
    const afterScheme: string = path.substring(schemeIndex + 3);
    const slash: number = afterScheme.indexOf('/');
    path = slash >= 0 ? afterScheme.substring(slash) : '/';
  }
  const queryIndex: number = path.indexOf('?');
  if (queryIndex >= 0) {
    path = path.substring(0, queryIndex);
  }
  const hashIndex: number = path.indexOf('#');
  if (hashIndex >= 0) {
    path = path.substring(0, hashIndex);
  }
  return path === '' ? '/' : path;
}

/** 堆栈脱敏：按行截断 + 文本脱敏（避免超长堆栈把日志文件撑爆） */
export function sanitizeStack(raw: string | null | undefined, maxLines: number = 20): string {
  const text: string = sanitizeText(raw);
  if (text === '') {
    return '';
  }
  const lines: string[] = text.split('\n');
  const kept: string[] = lines.length > maxLines ? lines.slice(0, maxLines) : lines;
  return kept.join('\n');
}

/** 单行摘要：压平换行并限制长度（列表页展示用） */
export function summarize(raw: string | null | undefined, maxLength: number = 160): string {
  const text: string = sanitizeText(raw).replace(/[\r\n\t]+/g, ' ').trim();
  if (text.length <= maxLength) {
    return text;
  }
  return `${text.substring(0, maxLength)}…`;
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
