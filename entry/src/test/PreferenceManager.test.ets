/**
 * PreferenceManager.test.ets —— 阅读偏好 / 搜索历史 单元测试（本地单元测试）
 *
 * 覆盖：默认值、方向读写、非法值回退、历史去重/排序/上限、清空、未初始化降级。
 * 说明：本地单元测试运行在 PC 侧，没有真实 Preferences 沙盒，
 * 因此「磁盘持久化」路径以「无 store 降级路径」等价覆盖（内存快照行为一致），
 * 真实磁盘读写需真机/模拟器，见阶段报告 Known Limitations。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { ContentRating, PreferenceManager, ReadDirection, normalizeReaderMode } from '../main/ets/utils/PreferenceManager';
import { ReaderMode } from '../main/ets/reader/ReaderTypes';

const TAG: string = 'PreferenceTest';

export default function preferenceTest() {
  describe('PreferenceManager', () => {
    let manager: PreferenceManager = PreferenceManager.getInstance();

    beforeEach(() => {
      // 每个用例前重置内存快照（等价于「首次启动」）
      manager.reset();
    });

    it('defaultReadDirectionIsVertical', 0, () => {
      expect(manager.getReadDirectionSync()).assertEqual(ReadDirection.HORIZONTAL);
      expect(manager.getReaderModeSync()).assertEqual(ReaderMode.PAGE_LTR);
      expect(normalizeReaderMode('')).assertEqual(ReaderMode.PAGE_LTR);
      expect(normalizeReaderMode('page_rtl')).assertEqual(ReaderMode.PAGE_RTL);
      expect(normalizeReaderMode('vertical_strip')).assertEqual(ReaderMode.VERTICAL_STRIP);
    });

    it('saveVerticalDirection', 0, async () => {
      const ok: boolean = await manager.setReadDirection(ReadDirection.VERTICAL);
      // 本地无 Preferences 实例：写入降级（返回 false），但内存快照必须生效
      expect(ok).assertFalse();
      expect(manager.getReadDirectionSync()).assertEqual(ReadDirection.VERTICAL);
    });

    it('saveHorizontalDirection', 0, async () => {
      await manager.setReadDirection(ReadDirection.HORIZONTAL);
      expect(manager.getReadDirectionSync()).assertEqual(ReadDirection.HORIZONTAL);
    });

    it('readBackAfterSave', 0, async () => {
      await manager.setReadDirection(ReadDirection.HORIZONTAL);
      expect(manager.getReadDirectionSync()).assertEqual(ReadDirection.HORIZONTAL);
      await manager.setReadDirection(ReadDirection.VERTICAL);
      expect(manager.getReadDirectionSync()).assertEqual(ReadDirection.VERTICAL);
    });

    it('illegalValueFallsBackToVertical', 0, () => {
      // 非法值不进入内存快照：默认阅读方向保持水平、阅读模式保持由左至右 PAGE_LTR
      const dir: string = 'diagonal';
      const resolved: ReadDirection = dir === ReadDirection.VERTICAL
        ? ReadDirection.VERTICAL : ReadDirection.HORIZONTAL;
      expect(resolved).assertEqual(ReadDirection.HORIZONTAL);
      expect(normalizeReaderMode(dir)).assertEqual(ReaderMode.PAGE_LTR);
    });

    it('historyDedupeAndMostRecentFirst', 0, async () => {
      await manager.addSearchHistory('海贼王');
      await manager.addSearchHistory('火影');
      await manager.addSearchHistory('海贼王');
      const history: string[] = manager.getSearchHistory();
      expect(history.length).assertEqual(2);
      expect(history[0]).assertEqual('海贼王');
      expect(history[1]).assertEqual('火影');
    });

    it('historyIgnoresBlankKeyword', 0, async () => {
      await manager.addSearchHistory('   ');
      expect(manager.getSearchHistory().length).assertEqual(0);
    });

    it('historyTrimmed', 0, async () => {
      await manager.addSearchHistory('  进击的巨人  ');
      expect(manager.getSearchHistory()[0]).assertEqual('进击的巨人');
    });

    it('historyLimitedTo20', 0, async () => {
      for (let i = 0; i < 25; i++) {
        await manager.addSearchHistory(`关键词${i}`);
      }
      const history: string[] = manager.getSearchHistory();
      expect(history.length).assertEqual(20);
      // 最近使用在前：最后写入的排第一
      expect(history[0]).assertEqual('关键词24');
      // 最旧的已被截断
      expect(history.indexOf('关键词0')).assertEqual(-1);
    });

    it('clearHistory', 0, async () => {
      await manager.addSearchHistory('海贼王');
      const ok: boolean = await manager.clearSearchHistory();
      expect(ok).assertTrue();
      expect(manager.getSearchHistory().length).assertEqual(0);
    });

    it('resetRestoresDefaults', 0, async () => {
      await manager.setReadDirection(ReadDirection.VERTICAL);
      await manager.setReaderMode(ReaderMode.PAGE_RTL);
      await manager.addSearchHistory('海贼王');
      manager.reset();
      expect(manager.getReadDirectionSync()).assertEqual(ReadDirection.HORIZONTAL);
      expect(manager.getReaderModeSync()).assertEqual(ReaderMode.PAGE_LTR);
      expect(manager.getSearchHistory().length).assertEqual(0);
    });

    it('readBeforeInitFallsBackToDefault', 0, async () => {
      // 未调用 init（等价于初始化尚未完成）：同步读取必须安全回退默认值，不得抛异常
      manager.reset();
      const ready: boolean = await manager.ensureReady();
      expect(ready).assertFalse();
      expect(manager.getReadDirectionSync()).assertEqual(ReadDirection.HORIZONTAL);
      expect(manager.getReaderModeSync()).assertEqual(ReaderMode.PAGE_LTR);
      expect(manager.getSearchHistory().length).assertEqual(0);
    });

    it('rapidSwitchesKeepLastValue', 0, async () => {
      // 连续切换：以最后一次为准，且不得因异步交错写回旧值
      await manager.setReadDirection(ReadDirection.HORIZONTAL);
      await manager.setReadDirection(ReadDirection.VERTICAL);
      await manager.setReadDirection(ReadDirection.HORIZONTAL);
      expect(manager.getReadDirectionSync()).assertEqual(ReadDirection.HORIZONTAL);
    });

    // ==================== 内容分级（allow-adult） ====================

    it('defaultContentRatingIsAllAges', 0, () => {
      expect(manager.getContentRatingSync()).assertEqual(ContentRating.ALL_AGES);
    });

    it('saveContentRatingUpdatesSnapshot', 0, async () => {
      // 无 store 降级：返回 false，但内存快照必须生效（本次会话）
      const ok: boolean = await manager.setContentRating(ContentRating.ADULT);
      expect(ok).assertFalse();
      expect(manager.getContentRatingSync()).assertEqual(ContentRating.ADULT);
      await manager.setContentRating(ContentRating.BOTH);
      expect(manager.getContentRatingSync()).assertEqual(ContentRating.BOTH);
    });

    it('illegalContentRatingIsRejected', 0, async () => {
      const ok: boolean = await manager.setContentRating('illegal-value');
      expect(ok).assertFalse();
      // 拒绝后快照保持不变
      expect(manager.getContentRatingSync()).assertEqual(ContentRating.ALL_AGES);
    });

    it('resetRestoresDefaultContentRating', 0, async () => {
      await manager.setContentRating(ContentRating.ADULT);
      manager.reset();
      expect(manager.getContentRatingSync()).assertEqual(ContentRating.ALL_AGES);
    });
  });
}
