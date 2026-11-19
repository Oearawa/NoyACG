/**
 * CacheViewModel.test.ets —— 缓存视图模型单元测试
 *
 * 用桩服务（FakeCacheService）注入 CacheService，覆盖：
 * 初始态、统计成功 / 失败、重复清理防重入、清理成功回写占用、清理失败保留错误、格式化。
 * ViewModel 侧的状态机被真实执行，桩只替代「文件系统」这一外部依赖。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { CacheClearResult, CacheService } from '../main/ets/utils/CacheCleaner';
import { CacheViewModel } from '../main/ets/viewmodel/CacheViewModel';

const MB: number = 1024 * 1024;

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

class FakeCacheService implements CacheService {
  size: number = 0;
  clearResult: CacheClearResult = new CacheClearResult(true, 0, 0, 0, '');
  delayMs: number = 0;
  sizeCalls: number = 0;
  clearCalls: number = 0;
  throwOnSize: boolean = false;
  throwOnClear: boolean = false;

  async getCacheSize(): Promise<number> {
    this.sizeCalls++;
    if (this.delayMs > 0) {
      await sleep(this.delayMs);
    }
    if (this.throwOnSize) {
      throw new Error('fs stat failed');
    }
    return this.size;
  }

  async clearImageCache(): Promise<CacheClearResult> {
    this.clearCalls++;
    if (this.delayMs > 0) {
      await sleep(this.delayMs);
    }
    if (this.throwOnClear) {
      throw new Error('unlink failed');
    }
    return this.clearResult;
  }
}

export default function cacheViewModelTest() {
  describe('CacheViewModel', () => {
    let service: FakeCacheService = new FakeCacheService();
    let vm: CacheViewModel = new CacheViewModel(service);

    beforeEach(() => {
      service = new FakeCacheService();
      vm = new CacheViewModel(service);
    });

    it('initialStateIsZero', 0, () => {
      expect(vm.cacheSizeBytes).assertEqual(0);
      expect(vm.cacheSizeMB).assertEqual(0);
      expect(vm.hasCalculated).assertFalse();
      expect(vm.formattedSize()).assertEqual('0 B');
    });

    it('refreshUpdatesSize', 0, async () => {
      service.size = 5 * MB;
      await vm.refresh();
      expect(vm.cacheSizeBytes).assertEqual(5 * MB);
      expect(vm.cacheSizeMB).assertEqual(5);
      expect(vm.hasCalculated).assertTrue();
      expect(vm.isCalculating).assertFalse();
      expect(vm.formattedSize()).assertEqual('5.00 MB');
    });

    it('refreshFailureKeepsError', 0, async () => {
      service.throwOnSize = true;
      await vm.refresh();
      expect(vm.errorMessage.indexOf('fs stat failed') >= 0).assertTrue();
      expect(vm.isCalculating).assertFalse();
      expect(vm.cacheSizeBytes).assertEqual(0);
    });

    it('clearSuccessSubtractsFreedBytes', 0, async () => {
      service.size = 3 * MB;
      await vm.refresh();
      service.clearResult = new CacheClearResult(true, 4, 2 * MB, 0, '');
      const result: CacheClearResult | null = await vm.clear();
      expect(result !== null).assertTrue();
      expect(result!.success).assertTrue();
      expect(vm.cacheSizeBytes).assertEqual(1 * MB);
      expect(vm.isClearing).assertFalse();
    });

    it('clearFailureKeepsRealError', 0, async () => {
      service.clearResult = new CacheClearResult(false, 0, 0, 0, '缓存目录不可访问');
      const result: CacheClearResult | null = await vm.clear();
      expect(result !== null).assertTrue();
      expect(result!.success).assertFalse();
      expect(vm.errorMessage).assertEqual('缓存目录不可访问');
    });

    it('clearReentryIgnored', 0, async () => {
      service.size = MB;
      service.delayMs = 40;
      const first: Promise<CacheClearResult | null> = vm.clear();
      const second: Promise<CacheClearResult | null> = vm.clear();
      const firstResult: CacheClearResult | null = await first;
      const secondResult: CacheClearResult | null = await second;
      expect(firstResult !== null).assertTrue();
      expect(secondResult === null).assertTrue(); // 重入直接忽略
      expect(service.clearCalls).assertEqual(1);
    });

    it('refreshReentryIgnoredWhileCalculating', 0, async () => {
      service.size = MB;
      service.delayMs = 30;
      const first: Promise<void> = vm.refresh();
      const second: Promise<void> = vm.refresh();
      await first;
      await second;
      expect(service.sizeCalls).assertEqual(1);
    });

    it('clearExceptionSetsError', 0, async () => {
      service.throwOnClear = true;
      const result: CacheClearResult | null = await vm.clear();
      expect(result === null).assertTrue();
      expect(vm.errorMessage.indexOf('unlink failed') >= 0).assertTrue();
      expect(vm.isClearing).assertFalse();
    });

    it('formatBytesUnits', 0, () => {
      expect(CacheViewModel.formatBytes(0)).assertEqual('0 B');
      expect(CacheViewModel.formatBytes(512)).assertEqual('512 B');
      expect(CacheViewModel.formatBytes(2048)).assertEqual('2.0 KB');
      expect(CacheViewModel.formatBytes(3 * MB)).assertEqual('3.00 MB');
      expect(CacheViewModel.formatBytes(Math.round(1.5 * MB))).assertEqual('1.50 MB');
    });
  });
}
