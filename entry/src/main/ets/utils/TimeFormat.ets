/**
 * TimeFormat.ets —— 时间显示格式（Phase 14-K 新增）
 *
 * 背景：改造前「时间」被两个页面各写一份私有 formatTime：
 * - `HistoryPage`：`MM-DD HH:mm`
 * - `DownloadPage`：`YYYY-MM-DD`
 * 两处都无法配置，设置页也没有对应的真实开关（做只改选中态的选择器属于假设置）。
 *
 * 本文件把格式化收敛成**一个纯函数工具**，由设置页的「时间格式化」真实控制：
 * - 绝对时间（默认）：保持改造前的两种既有输出，避免视觉回归；
 * - 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前；超过 7 天回退为绝对时间（避免「1234 天前」这种无意义文案）。
 *
 * 纯函数无副作用、不依赖 Context，可直接被单元测试覆盖。
 */

/**
 * 相对时间文案组（Phase 14-L：文案来自资源系统，不在工具类写死）。
 * 由 LocalizationManager.timeTexts() 提供；测试可注入固定文案。
 */
export interface TimeTexts {
  /** 刚刚 */
  justNow: string;
  /** N 分钟前 */
  minutesAgo: (n: number) => string;
  /** N 小时前 */
  hoursAgo: (n: number) => string;
  /** N 天前 */
  daysAgo: (n: number) => string;
}

/** 绝对时间：按页面原有格式展示 */
export const TIME_FORMAT_ABSOLUTE: string = 'absolute';
/** 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前（>7 天回退绝对） */
export const TIME_FORMAT_RELATIVE: string = 'relative';
/** 全部合法取值（顺序即设置页选项顺序） */
export const TIME_FORMAT_VALUES: string[] = [TIME_FORMAT_ABSOLUTE, TIME_FORMAT_RELATIVE];

const MINUTE_MS: number = 60 * 1000;
const HOUR_MS: number = 60 * MINUTE_MS;
const DAY_MS: number = 24 * HOUR_MS;
/** 相对时间最多回溯天数，超过则回退绝对时间 */
const RELATIVE_MAX_DAYS: number = 7;

/** 归一化：非法值 / 空串回退绝对时间（绝不把脏值写进偏好） */
export function normalizeTimeFormat(mode: string): string {
  return mode === TIME_FORMAT_RELATIVE ? TIME_FORMAT_RELATIVE : TIME_FORMAT_ABSOLUTE;
}

/** 设置页展示文案 */
export function timeFormatLabel(mode: string): string {
  return normalizeTimeFormat(mode) === TIME_FORMAT_RELATIVE ? '相对时间' : '绝对时间';
}

/** 两位补零 */
function pad2(n: number): string {
  return n < 10 ? `0${n}` : String(n);
}

/** 绝对时间：MM-DD HH:mm（阅读历史原格式） */
export function absoluteDateTime(ms: number): string {
  if (ms <= 0) {
    return '';
  }
  const d: Date = new Date(ms);
  return `${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/** 绝对日期：YYYY-MM-DD（下载任务原格式） */
export function absoluteDate(ms: number): string {
  if (ms <= 0) {
    return '';
  }
  const d: Date = new Date(ms);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

/**
 * 相对时间文案；超过 7 天或时间戳非法时返回空串（由调用方回退绝对时间）。
 * @param ms 目标时间（毫秒）
 * @param now 当前时间（毫秒，测试可注入以获得确定性）
 */
export function relativeText(ms: number, now: number, texts: TimeTexts): string {
  if (ms <= 0 || now <= 0) {
    return '';
  }
  const diff: number = now - ms;
  if (diff < 0) {
    // 未来时间（时钟漂移 / 服务端时间超前）：不编造「N 分钟前」，交给绝对时间展示
    return '';
  }
  if (diff < MINUTE_MS) {
    return texts.justNow;
  }
  if (diff < HOUR_MS) {
    return texts.minutesAgo(Math.floor(diff / MINUTE_MS));
  }
  if (diff < DAY_MS) {
    return texts.hoursAgo(Math.floor(diff / HOUR_MS));
  }
  const days: number = Math.floor(diff / DAY_MS);
  if (days <= RELATIVE_MAX_DAYS) {
    return texts.daysAgo(days);
  }
  return '';
}

/**
 * 阅读历史时间：相对模式优先，无法相对化（>7 天 / 未来时间）回退 MM-DD HH:mm。
 * @param mode 时间格式偏好（TIME_FORMAT_*）
 * @param now  当前时间（毫秒，默认取系统时间；测试注入以保证确定性）
 */
export function formatHistoryTime(ms: number, mode: string, texts: TimeTexts,
  now: number = Date.now()): string {
  if (ms <= 0) {
    return '';
  }
  if (normalizeTimeFormat(mode) === TIME_FORMAT_RELATIVE) {
    const rel: string = relativeText(ms, now, texts);
    if (rel !== '') {
      return rel;
    }
  }
  return absoluteDateTime(ms);
}

/**
 * 下载任务时间：相对模式优先，无法相对化回退 YYYY-MM-DD。
 * @param mode 时间格式偏好（TIME_FORMAT_*）
 * @param now  当前时间（毫秒，默认取系统时间）
 */
export function formatDownloadTime(ms: number, mode: string, texts: TimeTexts,
  now: number = Date.now()): string {
  if (ms <= 0) {
    return '-';
  }
  if (normalizeTimeFormat(mode) === TIME_FORMAT_RELATIVE) {
    const rel: string = relativeText(ms, now, texts);
    if (rel !== '') {
      return rel;
    }
  }
  return absoluteDate(ms);
}
