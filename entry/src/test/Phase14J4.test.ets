/**
 * Phase14J4.test.ets —— 存储契约与离线占用三态回归测试
 *
 * 本文件在 Phase 14-K 双层重构后**收窄职责**：
 * 「哪个入口在哪一层」的结构断言已移交 Phase14K3.test.ets（第一层入口表），
 * 这里只保留与「存储」强相关、且跨版本都必须成立的不变量：
 *   1. 下载管理入口唯一，且仍指向原 DownloadPage；
 *   2. 离线占用三态（真实值 / 统计中 / 统计失败）—— 失败绝不能伪装成 0 B；
 *   3. 清理图片缓存不影响离线数据（两套目录/两套 Manager 独立）；
 *   4. 内容分级与阅读方向的协议契约不变；容量格式化不变。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import {
  DAILY_ACTIONS,
  ProfileMenuEntry,
  ROUTE_DOWNLOAD,
  allProfileEntries,
  findDailyAction
} from '../main/ets/model/ProfileMenu';
import { ContentRating, ReadDirection } from '../main/ets/utils/PreferenceManager';
import {
  RATING_LABELS,
  indexToRating,
  ratingLabel,
  ratingToIndex
} from '../main/ets/viewmodel/SettingsViewModel';
import { CacheViewModel } from '../main/ets/viewmodel/CacheViewModel';
import { CacheClearResult, CacheService } from '../main/ets/utils/CacheCleaner';
import { DownloadSizeProvider } from '../main/ets/download/DownloadPorts';

/** 文件系统桩：本测试只关心下载占用状态，缓存侧给可控实现 */
class FakeCacheService implements CacheService {
  size: number = 0;
  cleared: number = 0;

  async getCacheSize(): Promise<number> {
    return this.size;
  }

  async clearImageCache(): Promise<CacheClearResult> {
    this.cleared++;
    return new CacheClearResult(true, 1, this.size, 0, '');
  }
}

/** 下载占用桩：可控成功 / 失败 / 延迟 */
class FakeDownloadSize implements DownloadSizeProvider {
  bytes: number = 0;
  throwOnSize: boolean = false;
  delayMs: number = 0;

  async getDownloadSize(): Promise<number> {
    if (this.delayMs > 0) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, this.delayMs);
      });
    }
    if (this.throwOnSize) {
      throw new Error('download size stat failed');
    }
    return this.bytes;
  }
}

/** 统计某路由在用户中心入口表中出现的次数 */
function countRoute(route: string): number {
  const all: ProfileMenuEntry[] = allProfileEntries();
  let n: number = 0;
  for (let i = 0; i < all.length; i++) {
    if (all[i].route === route) {
      n++;
    }
  }
  return n;
}

export default function phase14j4Test() {
  describe('Phase14J4_StorageContracts', () => {
    it('downloadEntryIsSingleAndPointsToManager', 0, () => {
      // 下载管理唯一入口（第一层日常功能），目标仍是原 DownloadPage
      expect(countRoute(ROUTE_DOWNLOAD)).assertEqual(1);
      const entry: ProfileMenuEntry | null = findDailyAction('downloads');
      expect(entry !== null).assertTrue();
      if (entry !== null) {
        expect(entry.route).assertEqual(ROUTE_DOWNLOAD);
      }
      // 入口表里不得再出现独立的「离线下载」入口（存储统计在设置页内展示，不是导航入口）
      let offlineEntries: number = 0;
      for (let i = 0; i < DAILY_ACTIONS.length; i++) {
        if (DAILY_ACTIONS[i].title === '离线下载') {
          offlineEntries++;
        }
      }
      expect(offlineEntries).assertEqual(0);
    });

    it('storageStatisticsUseTwoIndependentSources', 0, async () => {
      // 图片缓存与离线数据由不同服务提供，互不影响（禁止合并成一个数字）
      const cache: FakeCacheService = new FakeCacheService();
      const downloads: FakeDownloadSize = new FakeDownloadSize();
      cache.size = 5 * 1024 * 1024;
      downloads.bytes = 1024;
      const vm: CacheViewModel = new CacheViewModel(cache, downloads);
      await vm.refresh();
      await vm.refreshDownloadSize();
      expect(vm.formattedSize()).assertEqual('5.00 MB');
      expect(vm.formattedDownloadSize()).assertEqual('1.0 KB');
    });
  });

  describe('Phase14J4_DownloadUsageStates', () => {
    let cache: FakeCacheService = new FakeCacheService();
    let downloads: FakeDownloadSize = new FakeDownloadSize();
    let vm: CacheViewModel = new CacheViewModel(cache, downloads);

    beforeEach(() => {
      cache = new FakeCacheService();
      downloads = new FakeDownloadSize();
      vm = new CacheViewModel(cache, downloads);
    });

    it('downloadUsageShowsRealValue', 0, async () => {
      downloads.bytes = 4096;
      await vm.refreshDownloadSize();
      expect(vm.downloadSizeText()).assertEqual('4.0 KB');
      expect(vm.downloadSizeError).assertFalse();
    });

    it('downloadUsageShowsCalculatingWhileInFlight', 0, async () => {
      downloads.bytes = 2048;
      downloads.delayMs = 5;
      const pending: Promise<void> = vm.refreshDownloadSize();
      expect(vm.downloadSizeText()).assertEqual('统计中...');
      await pending;
      expect(vm.downloadSizeText()).assertEqual('2.0 KB');
    });

    it('downloadUsageShowsStatFailedInsteadOfZero', 0, async () => {
      downloads.throwOnSize = true;
      await vm.refreshDownloadSize();
      expect(vm.downloadSizeText()).assertEqual('统计失败');
      expect(vm.downloadSizeError).assertTrue();
    });

    it('downloadUsageKeepsPreviousBytesOnFailure', 0, async () => {
      downloads.bytes = 8192;
      await vm.refreshDownloadSize();
      expect(vm.downloadSizeBytes).assertEqual(8192);
      downloads.throwOnSize = true;
      await vm.refreshDownloadSize();
      expect(vm.downloadSizeBytes).assertEqual(8192);
      expect(vm.downloadSizeText()).assertEqual('统计失败');
    });

    it('cacheCleanDoesNotTouchDownloadUsage', 0, async () => {
      cache.size = 3 * 1024 * 1024;
      downloads.bytes = 1024;
      await vm.refresh();
      await vm.refreshDownloadSize();
      await vm.clear();
      // 清理图片缓存后：缓存归零，下载占用与文案不受影响
      expect(cache.cleared).assertEqual(1);
      expect(vm.cacheSizeBytes).assertEqual(0);
      expect(vm.downloadSizeBytes).assertEqual(1024);
      expect(vm.downloadSizeText()).assertEqual('1.0 KB');
    });
  });

  describe('Phase14J4_Contracts', () => {
    it('contentRatingProtocolValuesUnchanged', 0, () => {
      expect(ContentRating.ALL_AGES).assertEqual('false');
      expect(ContentRating.ADULT).assertEqual('true');
      expect(ContentRating.BOTH).assertEqual('both');
      expect(ContentRating.VALUES.length).assertEqual(3);
      expect(ContentRating.VALUES[0]).assertEqual('false');
      expect(ContentRating.VALUES[1]).assertEqual('true');
      expect(ContentRating.VALUES[2]).assertEqual('both');
    });

    it('contentRatingLabelsUnchanged', 0, () => {
      // 内容分级已迁到 SettingsPage，但文案与映射仍来自同一份表
      expect(RATING_LABELS.length).assertEqual(3);
      expect(ratingLabel(ContentRating.ALL_AGES)).assertEqual('仅全年龄内容');
      expect(ratingLabel(ContentRating.ADULT)).assertEqual('仅限制级内容');
      expect(ratingLabel(ContentRating.BOTH)).assertEqual('显示全部内容');
      expect(ratingLabel('invalid')).assertEqual('仅全年龄内容');
    });

    it('ratingIndexMappingRoundTrips', 0, () => {
      for (let i = 0; i < ContentRating.VALUES.length; i++) {
        const value: string = ContentRating.VALUES[i];
        expect(indexToRating(ratingToIndex(value))).assertEqual(value);
      }
      expect(indexToRating(9)).assertEqual(ContentRating.ALL_AGES);
    });

    it('readDirectionEnumUnchanged', 0, () => {
      // 阅读方向只在阅读器内维护，枚举值是持久化契约，不得改动
      expect(ReadDirection.VERTICAL).assertEqual('vertical');
      expect(ReadDirection.HORIZONTAL).assertEqual('horizontal');
    });

    it('cacheSizeFormatContractUnchanged', 0, () => {
      expect(CacheViewModel.formatBytes(0)).assertEqual('0 B');
      expect(CacheViewModel.formatBytes(512)).assertEqual('512 B');
      expect(CacheViewModel.formatBytes(2048)).assertEqual('2.0 KB');
      expect(CacheViewModel.formatBytes(31_100_000)).assertEqual('29.66 MB');
    });
  });
}
