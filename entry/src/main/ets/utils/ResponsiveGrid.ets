/**
 * ResponsiveGrid.ets —— 响应式网格列数纯函数（Phase 14-F）
 *
 * 不依赖任何 ArkUI 组件，仅做数值计算，便于单元测试。
 * 首页 / 书架 / 搜索三处瀑布流共用本文件，禁止各自复制一份逻辑。
 *
 * 列数规则（对齐任务书）：
 *   可用宽度 = 容器宽度 − 两侧水平内边距
 *   列数     = floor((可用宽度 + 间距) / (最小卡片宽度 + 间距))，再夹在 [minCols, maxCols]
 * 非法输入（0 / 负数 / NaN / 非有限）一律返回 minCols，不抛异常。
 */

/**
 * 计算响应式列数。
 * @param containerWidthVp 网格外层容器宽度（vp，来自 onAreaChange 实测）
 * @param minCardWidthVp  卡片最小合理宽度（vp）
 * @param gapVp           列间距 / 行间距（vp）
 * @param horizontalPaddingVp 网格容器左右内边距（vp，单侧）
 * @param minCols         最小列数（竖屏手机取 2）
 * @param maxCols         最大列数（宽屏上限）
 * @returns 计算出的列数（恒在 [minCols, maxCols] 内）
 */
export function computeColumns(
  containerWidthVp: number,
  minCardWidthVp: number,
  gapVp: number,
  horizontalPaddingVp: number,
  minCols: number,
  maxCols: number,
): number {
  // 容器宽度非法（0 / 负数 / NaN / 非有限）→ 最小列数兜底，绝不抛异常
  if (!Number.isFinite(containerWidthVp) || containerWidthVp <= 0) {
    return minCols;
  }
  // 卡片最小宽度非法 → 无法计算，兜底最小列数
  if (!Number.isFinite(minCardWidthVp) || minCardWidthVp <= 0) {
    return minCols;
  }
  const padding: number = Number.isFinite(horizontalPaddingVp) && horizontalPaddingVp >= 0
    ? horizontalPaddingVp : 0;
  const gap: number = Number.isFinite(gapVp) && gapVp >= 0 ? gapVp : 0;
  const available: number = containerWidthVp - padding * 2;
  if (available <= 0) {
    return minCols;
  }
  const columns: number = Math.floor((available + gap) / (minCardWidthVp + gap));
  const lower: number = Math.max(1, Math.floor(minCols));
  const upper: number = Math.max(lower, Math.floor(maxCols));
  return Math.max(lower, Math.min(upper, columns));
}

/**
 * 由列数生成均分模板字符串（1fr 均分，两侧留白对称）。
 * @param columns 列数（<1 时按 1 处理）
 * @returns 形如 '1fr 1fr 1fr' 的模板
 */
export function buildColumnsTemplate(columns: number): string {
  const n: number = Number.isFinite(columns) && columns >= 1 ? Math.floor(columns) : 1;
  let template: string = '1fr';
  for (let i = 1; i < n; i++) {
    template += ' 1fr';
  }
  return template;
}

/**
 * 计算单张卡片（瓦片）宽度（vp）。
 * 卡片宽 = (容器宽 − 两侧内边距 − (列数−1)×列间距) / 列数。
 * @param containerWidthVp 容器宽度（vp）
 * @param columns         列数
 * @param gapVp           列间距（vp）
 * @param hPaddingVp      容器左右内边距（vp，单侧）
 * @returns 卡片宽度（vp）；任一入参非法返回 0
 */
export function computeTileWidth(
  containerWidthVp: number,
  columns: number,
  gapVp: number,
  hPaddingVp: number,
): number {
  if (!Number.isFinite(containerWidthVp) || containerWidthVp <= 0) {
    return 0;
  }
  if (!Number.isFinite(columns) || columns <= 0) {
    return 0;
  }
  const cols: number = Math.floor(columns);
  const gap: number = Number.isFinite(gapVp) && gapVp >= 0 ? gapVp : 0;
  const pad: number = Number.isFinite(hPaddingVp) && hPaddingVp >= 0 ? hPaddingVp : 0;
  const available: number = containerWidthVp - pad * 2 - gap * (cols - 1);
  if (available <= 0) {
    return 0;
  }
  return available / cols;
}

/**
 * 由卡片宽计算封面高（vp）。
 * 封面高 = 卡片宽 / 封面宽高比（5:7 时高度 = 宽度 / 0.714）。
 * @param tileWidthVp 卡片宽度（vp）
 * @param coverRatio  封面宽高比（宽/高）
 * @returns 封面高度（vp）；任一入参非法返回 0
 */
export function computeCoverHeight(tileWidthVp: number, coverRatio: number): number {
  if (!Number.isFinite(tileWidthVp) || tileWidthVp <= 0) {
    return 0;
  }
  if (!Number.isFinite(coverRatio) || coverRatio <= 0) {
    return 0;
  }
  return tileWidthVp / coverRatio;
}
