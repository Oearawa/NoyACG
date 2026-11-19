import { describe, it, expect } from '@ohos/hypium';
import { isReportableAppError } from '../main/ets/utils/ErrorFilter';
import { DiagnosticLogManager } from '../main/ets/utils/DiagnosticLogManager';
import { Logger } from '../main/ets/utils/Logger';
import { ThemeManager } from '../main/ets/utils/ThemeManager';
import { CacheViewModel } from '../main/ets/viewmodel/CacheViewModel';
import { CacheClearResult, CacheService } from '../main/ets/utils/CacheCleaner';
import { DownloadSizeProvider } from '../main/ets/download/DownloadPorts';

class StubCacheService implements CacheService {
  private readonly mode: string;

  constructor(mode: string) {
    this.mode = mode;
  }

  async getCacheSize(): Promise<number> {
    if (this.mode === 'hang') {
      return await new Promise<number>(() => {
        // 模拟底层文件系统遍历挂起
      });
    }
    if (this.mode === 'throw') {
      throw new Error('disk io failure');
    }
    return 0;
  }

  async clearImageCache(): Promise<CacheClearResult> {
    return new CacheClearResult(true, 0, 0, 0, '');
  }
}

class StubDownloadSizeProvider implements DownloadSizeProvider {
  private readonly mode: string;

  constructor(mode: string) {
    this.mode = mode;
  }

  async getDownloadSize(): Promise<number> {
    if (this.mode === 'hang') {
      return await new Promise<number>(() => {
        // 模拟下载目录统计挂起
      });
    }
    if (this.mode === 'throw') {
      throw new Error('download dir error');
    }
    return 1024;
  }
}

export default function errorFilterAndSettingsReactivityTest() {
  describe('ErrorFilterAndSettingsReactivityTest', () => {
    it('keeps_actionable_app_errors_and_filters_noise', 0, () => {
      expect(isReportableAppError('error', 'AppRuntime', 'Uncaught TypeError: Cannot read property x')).assertTrue();
      expect(isReportableAppError('error', 'RdbStore', 'SQLite database corrupt while reading')).assertTrue();
      expect(isReportableAppError('error', 'CommunityApi', 'HTTP 502 Bad Gateway contract mismatch')).assertTrue();
      expect(isReportableAppError('error', 'Parser', 'Unexpected token', 'at Parser.ets:12')).assertTrue();

      expect(isReportableAppError('warn', 'RdbStore', 'SQLite database corrupt')).assertFalse();
      expect(isReportableAppError('error', 'HttpManager', 'status:"login" redirect required')).assertFalse();
      expect(isReportableAppError('error', 'HttpManager', 'ETIMEDOUT network timeout', 'at Http.ets:44')).assertFalse();
      expect(isReportableAppError('error', 'ImageCache', '图片加载失败 404')).assertFalse();
      expect(isReportableAppError('error', 'DownloadTask', '用户取消下载 canceled')).assertFalse();
    });

    it('diagnostic_manager_filters_noisy_records', 0, () => {
      const mgr: DiagnosticLogManager = DiagnosticLogManager.getInstance();
      mgr.injectForTest([]);
      Logger.warn('General', 'just a warning');
      Logger.error('HttpManager', 'status:"login" session expired');
      Logger.error('ImageCache', '封面加载失败 timeout');
      expect(mgr.count()).assertEqual(0);

      Logger.error('Storage', 'SQLite database corrupt detected');
      expect(mgr.count()).assertEqual(1);
      mgr.injectForTest([]);
    });

    it('theme_manager_updates_accent_synchronously', 0, () => {
      const tm: ThemeManager = ThemeManager.getInstance();
      tm.applyAccent('celadon_sage');
      expect(tm.accentId).assertEqual('celadon_sage');
      expect(tm.accent !== '').assertTrue();
      tm.applyAccent('slate_blue');
      expect(tm.accentId).assertEqual('slate_blue');
      tm.applyAccent('celadon_sage');
    });

    it('cache_viewmodel_never_hangs_on_empty_or_timeout', 0, async () => {
      const emptyVm: CacheViewModel = new CacheViewModel(
        new StubCacheService('empty'),
        new StubDownloadSizeProvider('ok')
      );
      await emptyVm.refresh(50);
      await emptyVm.refreshDownloadSize(50);
      expect(emptyVm.isCalculating).assertFalse();
      expect(emptyVm.hasCalculated).assertTrue();
      expect(emptyVm.formattedSize()).assertEqual('0 B');
      expect(emptyVm.isDownloadCalculating).assertFalse();
      expect(emptyVm.formattedDownloadSize()).assertEqual('1.0 KB');

      const hangVm: CacheViewModel = new CacheViewModel(
        new StubCacheService('hang'),
        new StubDownloadSizeProvider('hang')
      );
      await hangVm.refresh(30);
      await hangVm.refreshDownloadSize(30);
      expect(hangVm.isCalculating).assertFalse();
      expect(hangVm.hasCalculated).assertTrue();
      expect(hangVm.isDownloadCalculating).assertFalse();

      const errVm: CacheViewModel = new CacheViewModel(
        new StubCacheService('throw'),
        new StubDownloadSizeProvider('throw')
      );
      await errVm.refresh(30);
      await errVm.refreshDownloadSize(30);
      expect(errVm.isCalculating).assertFalse();
      expect(errVm.isDownloadCalculating).assertFalse();
      expect(errVm.downloadSizeError).assertTrue();
    });
  });
}
