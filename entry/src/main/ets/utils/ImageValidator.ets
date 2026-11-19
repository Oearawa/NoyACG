/**
 * ImageValidator.ets —— 图片 URL 解析校验与二进制魔数格式识别（纯函数，无 UI/网络依赖）
 *
 * 1. URL 校验：区分合法 http(s) / file:// 与空串、非法协议、畸形 URL；
 *    保留 query 与签名参数（绝不为了提高缓存命中率而剥离参数），
 *    不对已编码路径做重复编码；提供脱敏摘要与结构化诊断属性。
 * 2. 魔数识别：通过文件头字节识别真实图片格式（JPEG / PNG / WebP / GIF / AVIF），
 *    不轻信 URL 扩展名或 HTTP Content-Type；识别空响应、截断响应、HTML/JSON 错误页。
 */

export const IMAGE_FORMAT_JPEG: string = 'jpeg';
export const IMAGE_FORMAT_PNG: string = 'png';
export const IMAGE_FORMAT_WEBP: string = 'webp';
export const IMAGE_FORMAT_GIF: string = 'gif';
export const IMAGE_FORMAT_AVIF: string = 'avif';
export const IMAGE_FORMAT_EMPTY: string = 'empty';
export const IMAGE_FORMAT_TRUNCATED: string = 'truncated';
export const IMAGE_FORMAT_TEXT: string = 'text';
export const IMAGE_FORMAT_UNKNOWN: string = 'unknown';

export const MIN_IMAGE_BYTES: number = 12;

export class ParsedImageUrl {
  readonly valid: boolean;
  readonly reason: string;
  readonly normalizedUrl: string;
  readonly scheme: string;
  readonly host: string;
  readonly path: string;
  readonly hasQuery: boolean;
  readonly isLocalFile: boolean;

  constructor(
    valid: boolean,
    reason: string,
    normalizedUrl: string,
    scheme: string,
    host: string,
    path: string,
    hasQuery: boolean,
    isLocalFile: boolean
  ) {
    this.valid = valid;
    this.reason = reason;
    this.normalizedUrl = normalizedUrl;
    this.scheme = scheme;
    this.host = host;
    this.path = path;
    this.hasQuery = hasQuery;
    this.isLocalFile = isLocalFile;
  }
}

/**
 * 校验并解析图片 URL：
 * - 允许 `file://` 本地沙盒 URI 与 `http://` / `https://` 远程 URL；
 * - 拒绝空串、空白、相对路径（无 host）、`javascript:` / `data:` 等非法或不支持的协议；
 * - 保留原始 query/签名参数，不做任何参数裁剪或二次百分号编码。
 */
export function validateImageUrl(raw: string): ParsedImageUrl {
  if (typeof raw !== 'string') {
    return new ParsedImageUrl(false, 'not-string', '', '', '', '', false, false);
  }
  const trimmed: string = raw.trim();
  if (trimmed === '') {
    return new ParsedImageUrl(false, 'empty', '', '', '', '', false, false);
  }
  if (trimmed.indexOf(' ') >= 0 || trimmed.indexOf('\n') >= 0 || trimmed.indexOf('\r') >= 0) {
    return new ParsedImageUrl(false, 'whitespace-in-url', '', '', '', '', false, false);
  }
  if (trimmed.startsWith('file://')) {
    const pathPart: string = trimmed.substring(7);
    if (pathPart === '') {
      return new ParsedImageUrl(false, 'empty-file-path', '', 'file', '', '', false, true);
    }
    return new ParsedImageUrl(true, 'ok', trimmed, 'file', '', pathPart, false, true);
  }
  const lowerPrefix: string = trimmed.toLowerCase();
  if (!lowerPrefix.startsWith('http://') && !lowerPrefix.startsWith('https://')) {
    return new ParsedImageUrl(false, 'unsupported-scheme', '', '', '', '', false, false);
  }
  const schemeEnd: number = trimmed.indexOf('://');
  const scheme: string = trimmed.substring(0, schemeEnd).toLowerCase();
  const rest: string = trimmed.substring(schemeEnd + 3);
  if (rest === '') {
    return new ParsedImageUrl(false, 'missing-host', '', scheme, '', '', false, false);
  }
  // 分离 authority 与 path/query/hash
  let authorityEnd: number = rest.length;
  const slashIdx: number = rest.indexOf('/');
  const queryIdx: number = rest.indexOf('?');
  const hashIdx: number = rest.indexOf('#');
  if (slashIdx >= 0 && slashIdx < authorityEnd) {
    authorityEnd = slashIdx;
  }
  if (queryIdx >= 0 && queryIdx < authorityEnd) {
    authorityEnd = queryIdx;
  }
  if (hashIdx >= 0 && hashIdx < authorityEnd) {
    authorityEnd = hashIdx;
  }
  const authority: string = rest.substring(0, authorityEnd);
  if (authority === '') {
    return new ParsedImageUrl(false, 'missing-host', '', scheme, '', '', false, false);
  }
  // 去掉可选 userinfo 与端口，提取 host
  const atIdx: number = authority.lastIndexOf('@');
  const hostPort: string = atIdx >= 0 ? authority.substring(atIdx + 1) : authority;
  let host: string = hostPort;
  if (hostPort.startsWith('[')) {
    const closeBracket: number = hostPort.indexOf(']');
    if (closeBracket < 0) {
      return new ParsedImageUrl(false, 'malformed-host', '', scheme, '', '', false, false);
    }
    host = hostPort.substring(0, closeBracket + 1).toLowerCase();
  } else {
    const colonIdx: number = hostPort.indexOf(':');
    if (colonIdx >= 0) {
      const portStr: string = hostPort.substring(colonIdx + 1);
      if (portStr === '' || !/^\d+$/.test(portStr)) {
        return new ParsedImageUrl(false, 'malformed-port', '', scheme, '', '', false, false);
      }
      host = hostPort.substring(0, colonIdx);
    }
    host = host.toLowerCase();
  }
  if (host === '') {
    return new ParsedImageUrl(false, 'missing-host', '', scheme, '', '', false, false);
  }
  const tail: string = rest.substring(authorityEnd);
  const tailHashIdx: number = tail.indexOf('#');
  const noHash: string = tailHashIdx >= 0 ? tail.substring(0, tailHashIdx) : tail;
  const tailQueryIdx: number = noHash.indexOf('?');
  const path: string = tailQueryIdx >= 0
    ? (noHash.substring(0, tailQueryIdx) === '' ? '/' : noHash.substring(0, tailQueryIdx))
    : (noHash === '' ? '/' : noHash);
  const hasQuery: boolean = tailQueryIdx >= 0 && tailQueryIdx < noHash.length - 1;
  // 保留原始 trimmed URL，避免任何归一化改写破坏签名参数或已编码路径
  return new ParsedImageUrl(true, 'ok', trimmed, scheme, host, path, hasQuery, false);
}

/**
 * 脱敏 URL（用于日志与诊断输出）：仅保留 scheme + host + path，剥离 query 与片段，
 * 绝不把签名参数、Token 或敏感查询串写入日志。
 */
export function redactImageUrl(raw: string): string {
  const parsed: ParsedImageUrl = validateImageUrl(raw);
  if (!parsed.valid) {
    return raw.trim() === '' ? '<empty>' : `<invalid:${parsed.reason}>`;
  }
  if (parsed.isLocalFile) {
    const slashIdx: number = parsed.path.lastIndexOf('/');
    const fileName: string = slashIdx >= 0 ? parsed.path.substring(slashIdx + 1) : parsed.path;
    return `file://.../${fileName}`;
  }
  const suffix: string = parsed.hasQuery ? '?<redacted>' : '';
  return `${parsed.scheme}://${parsed.host}${parsed.path}${suffix}`;
}

/**
 * 脱敏 URL（保留参数键名、剥离参数值）：`scheme://host/path?k1&k2`。
 * 绝不记录明文签名值、Token 或密码。
 */
export function redactImageUrlWithParamKeys(raw: string): string {
  const parsed: ParsedImageUrl = validateImageUrl(raw);
  if (!parsed.valid || parsed.isLocalFile) {
    return redactImageUrl(raw);
  }
  const base: string = `${parsed.scheme}://${parsed.host}${parsed.path}`;
  if (!parsed.hasQuery) {
    return base;
  }
  const qIdx: number = parsed.normalizedUrl.indexOf('?');
  if (qIdx < 0) {
    return base;
  }
  const hashIdx: number = parsed.normalizedUrl.indexOf('#', qIdx);
  const queryStr: string = hashIdx >= 0
    ? parsed.normalizedUrl.substring(qIdx + 1, hashIdx)
    : parsed.normalizedUrl.substring(qIdx + 1);
  if (queryStr === '') {
    return base;
  }
  const pairs: string[] = queryStr.split('&');
  const keys: string[] = [];
  for (let i = 0; i < pairs.length; i++) {
    const eqIdx: number = pairs[i].indexOf('=');
    const key: string = (eqIdx >= 0 ? pairs[i].substring(0, eqIdx) : pairs[i]).trim();
    if (key !== '') {
      keys.push(key);
    }
  }
  return keys.length > 0 ? `${base}?${keys.join('&')}` : `${base}?<redacted>`;
}

/**
 * 格式化脱敏图片诊断记录（仅限 IS_DEBUG_BUILD=true 时输出）。
 */
export function formatImageDiagRecord(
  categoryLabel: string,
  rawUrl: string,
  cacheStatus: string,
  httpStatus: number,
  contentType: string,
  byteLength: number,
  decodeErrorCode: string,
  retryOrCancelNote: string
): string {
  const label: string = categoryLabel.trim() !== '' ? categoryLabel.trim() : '-';
  const safeUrl: string = redactImageUrlWithParamKeys(rawUrl);
  const ct: string = contentType.trim() !== '' ? contentType.trim() : '-';
  const err: string = decodeErrorCode.trim() !== '' ? decodeErrorCode.trim() : 'none';
  const note: string = retryOrCancelNote.trim() !== '' ? retryOrCancelNote.trim() : '-';
  return `[${label}] | [${safeUrl}] | [${cacheStatus}] | [${httpStatus}] | [${ct}] | [${byteLength}] | [${err}] | [${note}]`;
}

/**
 * 是否属于需要防盗链 Referer 的一/第三方域名（如 img.noymanga.com）。
 * 此类 URL 禁止降级为系统 Image(url) 无 Referer 直连（实测必返回 HTTP 403）。
 */
export function requiresAntiLeechReferer(raw: string): boolean {
  const parsed: ParsedImageUrl = validateImageUrl(raw);
  if (!parsed.valid || parsed.isLocalFile) {
    return false;
  }
  const host: string = parsed.host;
  return host === 'noymanga.com' || host.endsWith('.noymanga.com') ||
    host === 'noyteam.online' || host.endsWith('.noyteam.online');
}

/**
 * 通过二进制文件头魔数识别图片真实格式（不依赖扩展名或 Content-Type）。
 */
export function detectImageFormat(bytes: Uint8Array): string {
  if (bytes.byteLength === 0) {
    return IMAGE_FORMAT_EMPTY;
  }
  if (bytes.byteLength < MIN_IMAGE_BYTES) {
    return IMAGE_FORMAT_TRUNCATED;
  }
  // JPEG: FF D8 FF
  if (bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF) {
    return IMAGE_FORMAT_JPEG;
  }
  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E && bytes[3] === 0x47 &&
    bytes[4] === 0x0D && bytes[5] === 0x0A && bytes[6] === 0x1A && bytes[7] === 0x0A) {
    return IMAGE_FORMAT_PNG;
  }
  // WebP: RIFF .... WEBP
  if (bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
    bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) {
    return IMAGE_FORMAT_WEBP;
  }
  // GIF: GIF87a / GIF89a
  if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x38 &&
    (bytes[4] === 0x37 || bytes[4] === 0x39) && bytes[5] === 0x61) {
    return IMAGE_FORMAT_GIF;
  }
  // AVIF / HEIF: .... ftyp (avif / avis / heic / mif1)
  if (bytes[4] === 0x66 && bytes[5] === 0x74 && bytes[6] === 0x79 && bytes[7] === 0x70) {
    return IMAGE_FORMAT_AVIF;
  }
  // 常见文本错误页（HTML '<'、JSON '{' / '['、HTTP 错误文本）
  let i: number = 0;
  while (i < bytes.byteLength && i < 32 &&
    (bytes[i] === 0x20 || bytes[i] === 0x09 || bytes[i] === 0x0A || bytes[i] === 0x0D)) {
    i++;
  }
  if (i < bytes.byteLength) {
    const first: number = bytes[i];
    if (first === 0x3C || first === 0x7B || first === 0x5B) {
      return IMAGE_FORMAT_TEXT;
    }
  }
  return IMAGE_FORMAT_UNKNOWN;
}

export function isSupportedImageFormat(format: string): boolean {
  return format === IMAGE_FORMAT_JPEG ||
    format === IMAGE_FORMAT_PNG ||
    format === IMAGE_FORMAT_WEBP ||
    format === IMAGE_FORMAT_GIF ||
    format === IMAGE_FORMAT_AVIF;
}

/**
 * 检查 HTTP Content-Type 与真实格式是否冲突。
 * 明确拒绝 text/*、application/json、application/xml 等非图片响应；
 * image/* 或缺失 Content-Type（部分图床省略）则交由魔数最终裁定。
 */
export function isMimeCompatibleWithImage(contentType: string | undefined, detectedFormat: string): boolean {
  if (!isSupportedImageFormat(detectedFormat)) {
    return false;
  }
  if (contentType === undefined || contentType.trim() === '') {
    return true;
  }
  const lower: string = contentType.split(';')[0].trim().toLowerCase();
  if (lower === '' || lower === 'application/octet-stream' || lower === 'binary/octet-stream') {
    return true;
  }
  if (lower.startsWith('image/')) {
    return true;
  }
  return false;
}

/** 根据魔数格式返回规范扩展名（含前导点），未知格式回退 URL 扩展名。 */
export function extensionForFormat(format: string): string {
  if (format === IMAGE_FORMAT_JPEG) {
    return '.jpg';
  }
  if (format === IMAGE_FORMAT_PNG) {
    return '.png';
  }
  if (format === IMAGE_FORMAT_WEBP) {
    return '.webp';
  }
  if (format === IMAGE_FORMAT_GIF) {
    return '.gif';
  }
  if (format === IMAGE_FORMAT_AVIF) {
    return '.avif';
  }
  return '';
}
