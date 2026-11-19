/**
 * ProfileLayout.ets —— 用户中心 / 设置页列表行布局契约（Phase 14-J4.1）
 *
 * 纯数据规格，不依赖具体页面或组件；UI 统一读取，单元测试直接断言。
 * 目的：
 *   1. 防止 Column 默认居中导致「内容类型」辅助说明右漂到 Select 下方；
 *   2. 防止「关于」卡片长 Value 挤压标签、与标签黏连或溢出卡片；
 *   3. 统一 Icon + 双行 Text + Arrow/Badge 行的整体垂直居中。
 */
export interface ListRowLayoutSpec {
  verticalAlign: VerticalAlign;
  textColumnAlign: HorizontalAlign;
  textColumnWeight: number;
}

export const LIST_ROW_LAYOUT: ListRowLayoutSpec = {
  verticalAlign: VerticalAlign.Center,
  textColumnAlign: HorizontalAlign.Start,
  textColumnWeight: 1
};

export interface SettingsTextLayoutSpec {
  containerAlign: HorizontalAlign;
  hintWidth: string;
  hintTextAlign: TextAlign;
  hintMaxLines: number;
  hintOverflow: TextOverflow;
}

export const SETTINGS_TEXT_LAYOUT: SettingsTextLayoutSpec = {
  containerAlign: HorizontalAlign.Start,
  hintWidth: '100%',
  hintTextAlign: TextAlign.Start,
  hintMaxLines: 2,
  hintOverflow: TextOverflow.Ellipsis
};

export interface AboutRowLayoutSpec {
  verticalAlign: VerticalAlign;
  labelSeparator: string;
  valueWeight: number;
  valueTextAlign: TextAlign;
  valueMaxLines: number;
  valueOverflow: TextOverflow;
  valuePaddingStart: number;
}

export const ABOUT_ROW_LAYOUT: AboutRowLayoutSpec = {
  verticalAlign: VerticalAlign.Center,
  labelSeparator: '：',
  valueWeight: 1,
  valueTextAlign: TextAlign.End,
  valueMaxLines: 1,
  valueOverflow: TextOverflow.Ellipsis,
  valuePaddingStart: 8
};

/**
 * 设置页卡片尺寸契约（Phase 14-R）。
 *
 * 背景：设置页此前把 12 / 10 / 8 / 6 等数字散落在各 @Builder 中，
 * 导致「分组内边距」「行内边距」「分隔线缩进」三者互不一致 ——
 * 截图里可见分隔线比标题短、说明文字比标题多缩进 12vp。
 * 这里收敛成唯一来源，页面一律引用，不再写裸数字。
 */
export interface SettingsLayoutSpec {
  /** 卡片水平内边距（行内容左/右留白基准） */
  paddingHorizontal: number;
  /** 卡片上下内边距 */
  paddingVertical: number;
  /** 单行内容上下内边距 */
  rowPaddingVertical: number;
  /** 单行最小高度（触摸区） */
  rowMinHeight: number;
  /** 分隔线左右缩进（必须等于 paddingHorizontal，才能与行内容左缘对齐） */
  dividerInset: number;
  /** 分组之间的间距 */
  groupSpacing: number;
  /** 分组标题与卡片之间的间距 */
  titleGap: number;
  /** 卡片圆角 */
  cardRadius: number;
  /** 原生 Select 统一高度（保证背景块 / 文字 / 箭头共用同一基线） */
  selectHeight: number;
  /** 原生 Select 最大宽度（窄屏时受 layoutWeight 让位） */
  selectMaxWidth: number;
  /** 次级操作按钮圆角 */
  buttonRadius: number;
  /** 次级操作按钮内边距 */
  buttonPaddingH: number;
  buttonPaddingV: number;
}

export const SETTINGS_LAYOUT: SettingsLayoutSpec = {
  paddingHorizontal: 12,
  paddingVertical: 12,
  rowPaddingVertical: 8,
  rowMinHeight: 44,
  dividerInset: 12,
  groupSpacing: 12,
  titleGap: 6,
  cardRadius: 16,
  selectHeight: 32,
  selectMaxWidth: 168,
  buttonRadius: 14,
  buttonPaddingH: 12,
  buttonPaddingV: 6
};
