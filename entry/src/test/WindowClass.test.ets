/**
 * WindowClass.test.ets —— 窗口尺寸分类纯函数单测（Phase 14-H）
 * 覆盖边界 599 / 600 / 839 / 840，以及 NaN / 负数 / 0 → COMPACT。
 */
import { describe, it, expect } from '@ohos/hypium';
import { classifyWidth, WindowSizeClass } from '../main/ets/utils/WindowClass';

export default function windowClassTest() {
  describe('WindowClass', () => {
    it('classifyWidth_compactBelow600', 0, () => {
      expect(classifyWidth(320)).assertEqual(WindowSizeClass.COMPACT);
      expect(classifyWidth(440)).assertEqual(WindowSizeClass.COMPACT);
      expect(classifyWidth(599)).assertEqual(WindowSizeClass.COMPACT);
    });

    it('classifyWidth_boundary600toMedium', 0, () => {
      expect(classifyWidth(600)).assertEqual(WindowSizeClass.MEDIUM);
      expect(classifyWidth(720)).assertEqual(WindowSizeClass.MEDIUM);
      expect(classifyWidth(839)).assertEqual(WindowSizeClass.MEDIUM);
    });

    it('classifyWidth_boundary840toExpanded', 0, () => {
      expect(classifyWidth(840)).assertEqual(WindowSizeClass.EXPANDED);
      expect(classifyWidth(1024)).assertEqual(WindowSizeClass.EXPANDED);
      expect(classifyWidth(2000)).assertEqual(WindowSizeClass.EXPANDED);
    });

    it('classifyWidth_invalidInput_returnsCompact', 0, () => {
      expect(classifyWidth(0)).assertEqual(WindowSizeClass.COMPACT);
      expect(classifyWidth(-100)).assertEqual(WindowSizeClass.COMPACT);
      expect(classifyWidth(NaN)).assertEqual(WindowSizeClass.COMPACT);
    });
  });
}
