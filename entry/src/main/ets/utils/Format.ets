/**
 * Format.ets —— 数字格式化纯函数（无任何 ArkUI 依赖，便于单测）
 *
 * Phase 14-H：把浏览数 / 收藏数 / 点赞数等大数字缩写成「876 / 9.18k / 1.43k / x.xxM」，
 * 对齐原版 NoyAcg 海报卡片与列表项的展示（参考图 R1/R3）。
 *
 * 规则（以下取整 / 去零方式均为**假设**，最终以用户真机对照为准）：
 * - 小于 1000：原样输出整数（876→"876"、999→"999"、0→"0"）；
 * - 1000 ~ 999999：除以 1000，最多保留 2 位小数，去掉末尾 0 和多余小数点，加 "k"
 *   （1000→"1k"、1430→"1.43k"、9180→"9.18k"）；
 * - ≥ 1e6：除以 1e6，最多保留 2 位小数，同样去末尾 0，加 "M"（参考图未出现，采用 x.xxM）。
 * - 负数按 0 处理、NaN/Infinity 返回 "0"。
 */

/**
 * 去掉小数部分末尾的 0 与多余小数点：
 * "1.00"→"1"、"1.43"→"1.43"、"9.18"→"9.18"、"1.10"→"1.1"。
 */
function trimTrailingZero(text: string): string {
  let result: string = text;
  if (result.indexOf('.') >= 0) {
    // 去末尾 0
    while (result.length > 0 && result.charAt(result.length - 1) === '0') {
      result = result.substring(0, result.length - 1);
    }
    // 去多余小数点
    if (result.charAt(result.length - 1) === '.') {
      result = result.substring(0, result.length - 1);
    }
  }
  return result;
}

/** 把数字缩写成「876 / 9.18k / x.99M」形式 */
export function formatCount(value: number): string {
  if (!Number.isFinite(value) || value <= 0) {
    return '0';
  }
  const n: number = Math.floor(value);
  if (n < 1000) {
    return String(n);
  }
  if (n < 1000000) {
    return trimTrailingZero((n / 1000).toFixed(2)) + 'k';
  }
  return trimTrailingZero((n / 1000000).toFixed(2)) + 'M';
}
