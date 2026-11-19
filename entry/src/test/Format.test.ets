/**
 * Format.test.ets —— 数字缩写 formatCount 单测（Phase 14-H）
 * 覆盖任务书指定样例与边界：876/9180/1430/0/999/1000，及 1e6 以上 M 规则。
 */
import { describe, it, expect } from '@ohos/hypium';
import { formatCount } from '../main/ets/utils/Format';

export default function formatTest() {
  describe('Format', () => {
    it('formatCount_belowThousand_returnsRaw', 0, () => {
      expect(formatCount(0)).assertEqual('0');
      expect(formatCount(876)).assertEqual('876');
      expect(formatCount(999)).assertEqual('999');
    });

    it('formatCount_thousand_returnsK', 0, () => {
      expect(formatCount(1000)).assertEqual('1k');
      expect(formatCount(1430)).assertEqual('1.43k');
      expect(formatCount(9180)).assertEqual('9.18k');
      expect(formatCount(999000)).assertEqual('999k');
    });

    it('formatCount_million_returnsM', 0, () => {
      expect(formatCount(1000000)).assertEqual('1M');
      expect(formatCount(1500000)).assertEqual('1.5M');
      expect(formatCount(999000000)).assertEqual('999M');
    });

    it('formatCount_invalidInput_returnsZero', 0, () => {
      expect(formatCount(-1)).assertEqual('0');
      expect(formatCount(NaN)).assertEqual('0');
      expect(formatCount(Number.POSITIVE_INFINITY)).assertEqual('0');
    });
  });
}
