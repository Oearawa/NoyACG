/**
 * DownloadFactory.ets —— 生产装配（Phase 12）
 *
 * 这里是**唯一**把下载引擎与 NoyAcg 具体协议、真机 Kit 绑定起来的地方：
 * - ChapterImagePlanProvider ← NoyAcgSource（真实章节图片清单接口）
 * - DownloadImagePort ← RcpImageDownloader（API 26 流式 RCP + fileIo）
 * - DownloadFsPort ← SandboxDownloadFs（永久 filesDir/Downloads）
 * - DownloadRepositoryPort ← DatabaseManager（唯一数据库）
 *
 * DownloadManager / DownloadStorage / OfflineChapterSource 本身完全不 import 这些实现，
 * 因此可以用内存端口做无设备测试（Mock 只验证业务逻辑）。
 */
import { common } from '@kit.AbilityKit';
import { noyAcgSource } from '../source/NoyAcgSource';
import { NOY_WEB_ORIGIN } from '../api/HttpManager';
import { DatabaseManager } from '../utils/DatabaseManager';
import { Logger } from '../utils/Logger';
import {
  ChapterImagePlanProvider,
  DownloadError,
  DownloadRepositoryPort
} from './DownloadPorts';
import {
  DownloadStorage,
  SandboxDownloadFs
} from './DownloadStorage';
import { DownloadRepository } from './DownloadRepository';
import { DownloadManager } from './DownloadManager';
import { RcpImageDownloader } from './RcpImageDownloader';
import { OfflineChapterSource } from './OfflineChapterSource';

const TAG: string = 'DownloadFactory';

/** 章节图片清单适配器：唯一一处从 NoyAcg 协议取 URL 列表的代码 */
export class NoyAcgImagePlanAdapter implements ChapterImagePlanProvider {
  async getImageUrls(bookId: string, chapterId: string): Promise<string[]> {
    if (bookId.trim() === '' || chapterId.trim() === '') {
      throw new DownloadError('INVALID_ID', '下载章节需要 bookId 与 chapterId');
    }
    // 复用 Phase 11 已实现的真实接口 GET /api/v4/book/detail/{bid}/{cid}
    return await noyAcgSource.getChapterImages(bookId, chapterId);
  }
}

/** 图片防盗链请求头（与 ImageCacheManager 一致） */
function imageHeaders(): Record<string, string> {
  return {
    'referer': `${NOY_WEB_ORIGIN}/`,
    'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' +
      ' (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
  };
}

export class DownloadServices {
  readonly storage: DownloadStorage;
  readonly repository: DownloadRepository;
  readonly manager: DownloadManager;
  readonly offline: OfflineChapterSource;

  constructor(context: common.Context) {
    const fsPort: SandboxDownloadFs = new SandboxDownloadFs();
    this.storage = DownloadStorage.createDefault(context, fsPort);
    const db: DownloadRepositoryPort = DatabaseManager.getInstance();
    this.repository = new DownloadRepository(db, this.storage);
    this.offline = new OfflineChapterSource(this.storage, db);
    this.manager = new DownloadManager(
      new NoyAcgImagePlanAdapter(),
      new RcpImageDownloader(fsPort),
      this.storage,
      db,
      imageHeaders());
  }
}

export class DownloadFactory {
  private static services?: DownloadServices;

  /** EntryAbility.onCreate 调用一次；重复调用幂等（不在每次进页面时重建） */
  static init(context: common.Context): DownloadServices {
    if (DownloadFactory.services === undefined) {
      DownloadFactory.services = new DownloadServices(context);
      Logger.info(TAG, '下载子系统已初始化');
    }
    return DownloadFactory.services;
  }

  static get(): DownloadServices | undefined {
    return DownloadFactory.services;
  }

  /** 应用退出：停止调度（不改库状态，交给下次 recover 归位） */
  static shutdown(): void {
    if (DownloadFactory.services !== undefined) {
      DownloadFactory.services.manager.dispose();
      DownloadFactory.services = undefined;
      Logger.info(TAG, '下载子系统已释放');
    }
  }
}
