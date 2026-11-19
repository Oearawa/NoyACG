/**
 * DownloadRepository.ets —— 下载任务业务仓储与重启恢复（Phase 12）
 *
 * 分工：DatabaseManager 是唯一的数据库实现（不引入第二套数据库），本类负责
 * 「读任务 → 异常终止状态归位 → 校验文件 → 统计可续传图片 → 提供恢复入口」。
 *
 * 任务书 Step 4 的 6 条要求逐项落实：
 * 1. 读取已有任务：`recover()` → `store.list()`
 * 2. 上次 DOWNLOADING/PREPARING → INCOMPLETE（可恢复，不伪装完成）
 * 3. 验证已完成图片文件：`storage.verifyChapter()` 逐序号检查
 * 4. 统计未完成图片：`completedImages` 回写为**实际有效文件数**
 * 5. 恢复入口：任务保留在库中，UI 显示「继续」
 * 6. 不重复下载已完整保存的图片：`DownloadStorage.saveImage()` 的重复检测
 */
import { DownloadStatus, DownloadTask, isRecoverable } from '../model/DownloadTask';
import {
  DownloadRecoveryPort,
  DownloadRecoveryReport,
  DownloadRepositoryPort
} from './DownloadPorts';
import { ChapterVerifyResult, DownloadStorage } from './DownloadStorage';
import { Logger } from '../utils/Logger';

const TAG: string = 'DownloadRepository';

export class DownloadRepository implements DownloadRecoveryPort {
  private store: DownloadRepositoryPort;
  private storage: DownloadStorage;

  constructor(store: DownloadRepositoryPort, storage: DownloadStorage) {
    this.store = store;
    this.storage = storage;
  }

  /** 应用启动（或下载页首次进入）时调用，幂等 */
  async recover(): Promise<DownloadRecoveryReport> {
    const tasks: DownloadTask[] = await this.store.list();
    let interrupted: number = 0;
    let completedVerified: number = 0;
    let incomplete: number = 0;
    let resumable: number = 0;

    for (let i = 0; i < tasks.length; i++) {
      const task: DownloadTask = tasks[i];
      let changed: boolean = false;

      if (task.status === DownloadStatus.DOWNLOADING
        || task.status === DownloadStatus.PREPARING) {
        task.status = DownloadStatus.INCOMPLETE;
        task.lastError = '上次下载被中断，可继续下载';
        interrupted++;
        changed = true;
      }

      // 统计磁盘上真实有效的图片数（不能用旧的内存计数冒充已完成）
      const verify: ChapterVerifyResult = await this.storage.verifyChapter(
        task.bookId, task.chapterId, task.totalImages);
      const validCount: number = verify.entries.length;
      if (task.completedImages !== validCount) {
        task.completedImages = validCount;
        changed = true;
      }

      if (task.status === DownloadStatus.COMPLETED) {
        if (verify.complete && validCount === task.totalImages && task.totalImages > 0) {
          completedVerified++;
        } else {
          // 文件被外部删除/损坏：绝不允许「已完成」状态继续指向不存在的路径
          task.status = DownloadStatus.INCOMPLETE;
          task.lastError = verify.message === '' ? '章节文件不完整' : verify.message;
          incomplete++;
          changed = true;
        }
      }

      if (isRecoverable(task.status) || task.status === DownloadStatus.INCOMPLETE) {
        resumable++;
      }
      if (changed) {
        task.updatedAt = Date.now();
        await this.store.upsert(task);
      }
    }
    Logger.info(TAG, `下载任务恢复完成: 总数=${tasks.length}, 中断=${interrupted}, ` +
      `校验通过=${completedVerified}, 不完整=${incomplete}, 可恢复=${resumable}`);
    return new DownloadRecoveryReport(tasks.length, interrupted,
      completedVerified, incomplete, resumable);
  }

  /** 已完成章节（供离线章节列表使用；仍需在读取时做文件校验） */
  async listCompleted(): Promise<DownloadTask[]> {
    const all: DownloadTask[] = await this.store.list();
    const result: DownloadTask[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].status === DownloadStatus.COMPLETED && all[i].isComplete) {
        result.push(all[i]);
      }
    }
    return result;
  }

  async upsert(task: DownloadTask): Promise<void> {
    await this.store.upsert(task);
  }

  async get(bookId: string, chapterId: string): Promise<DownloadTask | null> {
    return await this.store.get(bookId, chapterId);
  }

  async list(): Promise<DownloadTask[]> {
    return await this.store.list();
  }

  /** 仅删除任务**记录**（文件由调用方按需删除，二者严格区分） */
  async removeRecord(bookId: string, chapterId: string): Promise<void> {
    await this.store.remove(bookId, chapterId);
  }

  async clearFinishedRecords(): Promise<number> {
    return await this.store.clearFinished();
  }
}
