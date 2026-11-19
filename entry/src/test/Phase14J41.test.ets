/**
 * Phase14J41.test.ets —— 用户中心 / 设置页 UI 文本布局契约回归
 *
 * ArkUI 布局属性无法在纯单元测试里直接渲染，因此把本阶段修复的布局决策抽成
 * `utils/ProfileLayout.ets` 的纯数据规格：UI 统一读取，测试直接断言，避免只测字符串。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  ABOUT_ROW_LAYOUT,
  LIST_ROW_LAYOUT,
  SETTINGS_TEXT_LAYOUT
} from '../main/ets/utils/ProfileLayout';

export default function phase14j41Test() {
  describe('Phase14J41_SettingsHintLayout', () => {
    it('hintContainerUsesStartAlignmentAndFullWidth', 0, () => {
      expect(SETTINGS_TEXT_LAYOUT.containerAlign).assertEqual(HorizontalAlign.Start);
      expect(SETTINGS_TEXT_LAYOUT.hintWidth).assertEqual('100%');
      expect(SETTINGS_TEXT_LAYOUT.hintTextAlign).assertEqual(TextAlign.Start);
      expect(SETTINGS_TEXT_LAYOUT.hintOverflow).assertEqual(TextOverflow.Ellipsis);
      expect(SETTINGS_TEXT_LAYOUT.hintMaxLines >= 1).assertTrue();
    });

    it('selectRowsReserveTextColumnAndCenterVertically', 0, () => {
      expect(LIST_ROW_LAYOUT.textColumnAlign).assertEqual(HorizontalAlign.Start);
      expect(LIST_ROW_LAYOUT.textColumnWeight).assertEqual(1);
      expect(LIST_ROW_LAYOUT.verticalAlign).assertEqual(VerticalAlign.Center);
    });
  });

  describe('Phase14J41_AboutRowLayout', () => {
    it('aboutLabelsHaveColonSeparatorAndGap', 0, () => {
      expect(ABOUT_ROW_LAYOUT.labelSeparator).assertEqual('：');
      expect(ABOUT_ROW_LAYOUT.labelSeparator !== '').assertTrue();
      expect(ABOUT_ROW_LAYOUT.valuePaddingStart > 0).assertTrue();
    });

    it('aboutValuesAreRightAlignedAndEllipsized', 0, () => {
      expect(ABOUT_ROW_LAYOUT.verticalAlign).assertEqual(VerticalAlign.Center);
      expect(ABOUT_ROW_LAYOUT.valueWeight).assertEqual(1);
      expect(ABOUT_ROW_LAYOUT.valueTextAlign).assertEqual(TextAlign.End);
      expect(ABOUT_ROW_LAYOUT.valueMaxLines).assertEqual(1);
      expect(ABOUT_ROW_LAYOUT.valueOverflow).assertEqual(TextOverflow.Ellipsis);
    });
  });

  describe('Phase14J41_LayoutContractStability', () => {
    it('layoutSpecsUseConcreteWeightsAndAlignments', 0, () => {
      expect(SETTINGS_TEXT_LAYOUT.containerAlign).assertEqual(HorizontalAlign.Start);
      expect(LIST_ROW_LAYOUT.verticalAlign).assertEqual(VerticalAlign.Center);
      expect(LIST_ROW_LAYOUT.textColumnWeight).assertEqual(1);
      expect(ABOUT_ROW_LAYOUT.valueWeight).assertEqual(1);
      expect(ABOUT_ROW_LAYOUT.valueTextAlign).assertEqual(TextAlign.End);
    });
  });
}
