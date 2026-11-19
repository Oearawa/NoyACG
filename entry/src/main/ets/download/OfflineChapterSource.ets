/**
 * OfflineChapterSource.ets —— 本地章节数据源（Phase 12）
 *
 * 与远程数据源保持清晰边界：
 * - 远程 `IComicSource.getChapterImages()` 返回 https URL 列表；
 * - 本类返回 `file://${沙盒路径}` 列表（工程 Phase 7 起已验证的 ArkUI Image 用法）；
 * - 两者都产出**同一种模型** `string[]`（按页码顺序），由 ChapterImageProvider
 *   统一包装成 ChapterImageSet，阅读器不感知来源差异。
 *
 * 严格性：
 * - 不完整章节**不返回部分图片**（缺图不静默跳过），只返回明确的不完整状态；
 * - 删除文件后 verify 立即失败，Reader 不会再拿到失效路径；
 * - 不联网、不检查登录状态，离线阅读不受会话影响。
 */
import { DownloadRepositoryPort } from './DownloadPorts';
import { ChapterVerifyResult, DownloadStorage } from './DownloadStorage';
import { DownloadStatus, DownloadTask } from '../model/DownloadTask';
import { Logger } from '../utils/Logger';

const TAG: string = 'OfflineChapterSource';

/** 本地章节查询结果 */
export class OfflineChapterLookup {
  /** 是否存在本地下载记录/文件 */
  readonly exists: boolean;
  /** 是否完整可离线阅读 */
  readonly complete: boolean;
  /** 完整时的图片 URI 列表（按序号升序） */
  readonly images: string[];
  /** 不完整/不存在时的明确说明 */
  readonly message: string;

  constructor(exists: boolean, complete: boolean, images: string[], message: string) {
    this.exists = exists;
    this.complete = complete;
    this.images = images;
    this.message = message;
  }

  static missing(): OfflineChapterLookup {
    return new OfflineChapterLookup(false, false, [], '该章节未下载到本地');
  }
}

export class OfflineChapterSource {
  private storage: DownloadStorage;
  private repo: DownloadRepositoryPort;

  constructor(storage: DownloadStorage, repo: DownloadRepositoryPort) {
    this.storage = storage;
    this.repo = repo;
  }

  /**
   * 查找本地章节：
   * 1. 无任务记录 / 记录不是已完成态 → 视为未下载（走在线来源）；
   * 2. 有已完成记录 → 必须重新校验磁盘文件（删除/损坏会立即暴露）；
   * 3. 校验通过才返回按序号升序的 file:// 列表。
   */
  async lookup(bookId: string, chapterId: string): Promise<OfflineChapterLookup> {
    const task: DownloadTask | null = await this.repo.get(bookId, chapterId);
    if (task !== null && task.status === DownloadStatus.COMPLETED && task.totalImages > 0) {
      const verify: ChapterVerifyResult = await this.storage.verifyChapter(
        bookId, chapterId, task.totalImages);
      if (!verify.complete) {
        Logger.warn(TAG, `本地章节不可用 ${bookId}/${chapterId}: ${verify.message}`);
        return new OfflineChapterLookup(true, false, [], verify.message);
      }
      const images: string[] = [];
      for (let i = 0; i < verify.entries.length; i++) {
        images.push(verify.entries[i].uri);
      }
      return new OfflineChapterLookup(true, true, images, '');
    }
    // 任务记录被清除时，直接兜底扫描磁盘物理章节目录
    const diskEntries = await this.storage.listDiskChapterImages(bookId, chapterId);
    if (diskEntries.length === 0) {
      return OfflineChapterLookup.missing();
    }
    const diskUris: string[] = [];
    for (let i = 0; i < diskEntries.length; i++) {
      diskUris.push(diskEntries[i].uri);
    }
    return new OfflineChapterLookup(true, true, diskUris, '');
  }

  /** 便捷方法：完整章节返回 URI 列表，否则返回空数组（调用方须先看 lookup 的 message） */
  async getLocalImageUris(bookId: string, chapterId: string): Promise<string[]> {
    const found: OfflineChapterLookup = await this.lookup(bookId, chapterId);
    return found.complete ? found.images : [];
  }

  async isComplete(bookId: string, chapterId: string): Promise<boolean> {
    const found: OfflineChapterLookup = await this.lookup(bookId, chapterId);
    return found.complete;
  }
}
