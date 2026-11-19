/**
 * 应用级错误报告过滤规则。
 *
 * 仅保留真正需要排查的应用级异常（未捕获运行时异常、存储/数据库/文件损坏、
 * 严重 5xx / 接口契约错误、非预期异常堆栈），过滤常规警告、预期网络波动、
 * 取消操作、图片加载失败与登录态跳转（status:"login"）等噪音。
 */

const NOISE_PATTERNS: string[] = [
  'status:"login"',
  'status: "login"',
  'status=login',
  'not logged in',
  'need login',
  '未登录',
  '登录已过期',
  '会话过期',
  'unauthorized',
  'etimedout',
  'econnrefused',
  'econnreset',
  'enotfound',
  'ehostunreach',
  'enetunreach',
  'timed out',
  'timeout',
  '超时',
  'network error',
  'network unavailable',
  'http request failed',
  '无网络',
  '网络异常',
  '网络不可用',
  '网络错误',
  'dns',
  'tls',
  'ssl',
  'handshake',
  'connection closed',
  'cancelled',
  'canceled',
  'aborted',
  '用户取消',
  '已取消',
  '图片加载失败',
  '加载图片失败',
  '封面加载失败',
  'image load failed',
  'decode image',
  'http 401',
  'http 403',
  'http 404',
  'http 429',
  'status=401',
  'status=403',
  'status=404',
  'status=429',
  'too many requests'
];

const NOISE_MODULES: string[] = [
  'imagecache',
  'imageloader',
  'coverloader',
  'networkmonitor',
  'networkdiag'
];

const ACTIONABLE_PATTERNS: string[] = [
  'uncaught',
  'unhandled',
  'typeerror',
  'referenceerror',
  'syntaxerror',
  'rangeerror',
  'fatal',
  'crash',
  '崩溃',
  '未捕获',
  'rdb',
  'sqlite',
  'database',
  '数据库',
  'preferences',
  'corrupt',
  '损坏',
  'fileio',
  'disk',
  'json.parse',
  'parse error',
  'deserialize',
  'schema',
  'contract',
  '契约',
  'invalid response',
  '500',
  '502',
  '503',
  '504',
  'internal server error',
  'bad gateway',
  'service unavailable'
];

function containsAny(haystack: string, needles: string[]): boolean {
  for (let i = 0; i < needles.length; i++) {
    if (haystack.indexOf(needles[i]) >= 0) {
      return true;
    }
  }
  return false;
}

/**
 * 判断一条日志是否属于可上报的应用级错误。
 */
export function isReportableAppError(
  level: string,
  module: string,
  message: string,
  stack?: string
): boolean {
  if (level.trim().toLowerCase() !== 'error') {
    return false;
  }
  const msgLower: string = message.trim().toLowerCase();
  if (msgLower === '') {
    return false;
  }
  const modLower: string = module.trim().toLowerCase();
  if (containsAny(modLower, NOISE_MODULES)) {
    return false;
  }
  const stackLower: string = stack !== undefined ? stack.trim().toLowerCase() : '';
  const combined: string = `${modLower} ${msgLower} ${stackLower}`;
  if (containsAny(combined, NOISE_PATTERNS)) {
    return false;
  }
  if (stackLower !== '') {
    return true;
  }
  return containsAny(combined, ACTIONABLE_PATTERNS);
}
