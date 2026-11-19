/**
 * DownloadViewModel.ets —— 下载管理页视图模型（Phase 12，状态管理 V2）
 *
 * 职责：把任务状态、占用统计、操作反馈封装成 UI 可观察状态；
 * **页面不直接操作文件系统或数据库**，一切经由 DownloadControlPort。
 * - disposed 守卫：页面销毁后不再回写 @Trace 状态；
 * - 监听 Manager 变化自动刷新，任务进度实时可见；
 * - 所有异常都落到 errorMessage，绝不静默当作成功。
 */
import { DownloadStatus, DownloadTask } from '../model/DownloadTask';
import {
  DownloadControlPort,
  DownloadRecoveryPort,
  DownloadRecoveryReport,
  NoopDownloadControl
} from '../download/DownloadPorts';
import { DownloadFactory, DownloadServices } from '../download/DownloadFactory';
import { CacheViewModel } from './CacheViewModel';
import { Logger } from '../utils/Logger';

const TAG: string = 'DownloadViewModel';

/** 未初始化时的空恢复端口 */
export class NoopDownloadRecovery implements DownloadRecoveryPort {
  async recover(): Promise<DownloadRecoveryReport> {
    return new DownloadRecoveryReport(0, 0, 0, 0, 0);
  }
}

@ObservedV2
export class DownloadViewModel {
  /** 全部任务（Manager 内存状态优先） */
  @Trace tasks: DownloadTask[] = [];
  /** 加载/刷新中 */
  @Trace isLoading: boolean = false;
  /** 永久下载占用（字节），与图片缓存占用**分别统计** */
  @Trace downloadSizeBytes: number = 0;
  /** 最近一次错误（成功时清空） */
  @Trace errorMessage: string = '';
  /** 最近一次操作反馈（如「已恢复」「已删除」） */
  @Trace notice: string = '';
  /** 是否已完成启动恢复 */
  @Trace isRecovered: boolean = false;

  private control: DownloadControlPort;
  private recovery: DownloadRecoveryPort | null;
  private disposed: boolean = false;
  private readonly listener: () => void;

  constructor(control?: DownloadControlPort, recovery?: DownloadRecoveryPort) {
    const services: DownloadServices | undefined = DownloadFactory.get();
    this.control = control ?? (services === undefined
      ? new NoopDownloadControl() : services.manager);
    if (recovery !== undefined) {
      this.recovery = recovery;
    } else {
      this.recovery = services === undefined
        ? new NoopDownloadRecovery() : services.repository;
    }
    this.listener = (): void => {
      this.refresh();
    };
    this.control.addListener(this.listener);
  }

  /** 页面 onReady 调用：先做一次重启恢复，再刷新列表（幂等，不每次重复初始化数据库） */
  async initialize(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (!this.isRecovered && this.recovery !== null) {
      try {
        await this.recovery.recover();
        this.isRecovered = true;
      } catch (e) {
        this.errorMessage = `下载任务恢复失败: ${(e as Error).message}`;
        Logger.error(TAG, this.errorMessage);
      }
    }
    await this.refresh();
  }

  async refresh(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isLoading = true;
    try {
      const tasks: DownloadTask[] = await this.control.listTasks();
      const size: number = await this.control.getDownloadSize();
      if (this.disposed) {
        return;
      }
      this.tasks = tasks;
      this.downloadSizeBytes = size;
      this.errorMessage = '';
    } catch (e) {
      if (!this.disposed) {
        this.errorMessage = `读取下载任务失败: ${(e as Error).message}`;
      }
    } finally {
      if (!this.disposed) {
        this.isLoading = false;
      }
    }
  }

  /** 人类可读的下载占用（复用缓存模块的格式化，但数值来源完全独立） */
  formattedDownloadSize(): string {
    return CacheViewModel.formatBytes(this.downloadSizeBytes);
  }

  // ==================== 分组视图 ====================

  get queuedTasks(): DownloadTask[] {
    return this.filter(DownloadStatus.QUEUED);
  }

  get activeTasks(): DownloadTask[] {
    const result: DownloadTask[] = [];
    for (let i = 0; i < this.tasks.length; i++) {
      const s: DownloadStatus = this.tasks[i].status;
      if (s === DownloadStatus.PREPARING || s === DownloadStatus.DOWNLOADING) {
        result.push(this.tasks[i]);
      }
    }
    return result;
  }

  get pausedTasks(): DownloadTask[] {
    return this.filter(DownloadStatus.PAUSED);
  }

  get failedTasks(): DownloadTask[] {
    return this.filter(DownloadStatus.FAILED);
  }

  get incompleteTasks(): DownloadTask[] {
    return this.filter(DownloadStatus.INCOMPLETE);
  }

  get completedTasks(): DownloadTask[] {
    return this.filter(DownloadStatus.COMPLETED);
  }

  get canceledTasks(): DownloadTask[] {
    return this.filter(DownloadStatus.CANCELED);
  }

  private filter(status: DownloadStatus): DownloadTask[] {
    const result: DownloadTask[] = [];
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].status === status) {
        result.push(this.tasks[i]);
      }
    }
    return result;
  }

  // ==================== 操作 ====================

  async pause(task: DownloadTask): Promise<void> {
    if (this.control.pauseTask !== undefined) {
      await this.control.pauseTask(task.bookId, task.chapterId);
    } else {
      this.control.pause(task.bookId, task.chapterId);
    }
    this.notice = '已暂停';
    await this.refresh();
  }

  async resume(task: DownloadTask): Promise<void> {
    if (this.disposed) {
      return;
    }
    const ok: boolean = await this.control.resume(task.bookId, task.chapterId);
    this.notice = ok ? '已继续下载' : '任务已在运行或已完成';
    await this.refresh();
  }

  async retry(task: DownloadTask): Promise<void> {
    if (this.disposed) {
      return;
    }
    const ok: boolean = await this.control.retry(task.bookId, task.chapterId);
    this.notice = ok ? '已重新加入队列' : '任务已在运行';
    await this.refresh();
  }

  async cancel(task: DownloadTask): Promise<void> {
    if (this.control.cancelTask !== undefined) {
      await this.control.cancelTask(task.bookId, task.chapterId);
    } else {
      this.control.cancel(task.bookId, task.chapterId);
    }
    this.notice = '已取消并移出队列';
    await this.refresh();
  }

  async cancelAll(): Promise<void> {
    const count: number = this.control.cancelAllPendingTasks !== undefined
      ? await this.control.cancelAllPendingTasks()
      : this.control.cancelAllPending();
    this.notice = count > 0 ? `已取消 ${count} 个任务` : '没有待取消的任务';
    await this.refresh();
  }

  async pauseAll(): Promise<void> {
    if (this.control.pauseAllTasks !== undefined) {
      const count: number = await this.control.pauseAllTasks();
      this.notice = count > 0 ? `已暂停 ${count} 个任务` : '没有可暂停的任务';
      await this.refresh();
      return;
    }
    if (this.control.pauseAll === undefined) {
      return;
    }
    const count: number = this.control.pauseAll();
    this.notice = count > 0 ? `已暂停 ${count} 个任务` : '没有可暂停的任务';
    await this.refresh();
  }

  async resumeAll(): Promise<void> {
    if (this.disposed || this.control.resumeAll === undefined) {
      return;
    }
    try {
      const count: number = await this.control.resumeAll();
      this.notice = count > 0 ? `已恢复 ${count} 个任务` : '没有可恢复的任务';
      this.errorMessage = '';
    } catch (e) {
      this.errorMessage = `恢复失败: ${(e as Error).message}`;
    }
    await this.refresh();
  }

  async repair(task: DownloadTask): Promise<void> {
    if (this.disposed || this.control.repairChapter === undefined) {
      return;
    }
    try {
      const ok: boolean = await this.control.repairChapter(task.bookId, task.chapterId);
      this.notice = ok ? '已触发缺图校验与补下载' : '任务正在运行中';
      this.errorMessage = '';
    } catch (e) {
      this.errorMessage = `修复失败: ${(e as Error).message}`;
    }
    await this.refresh();
  }

  async deleteBook(bookId: string): Promise<void> {
    if (this.disposed || this.control.deleteBook === undefined) {
      return;
    }
    try {
      const removed: number = await this.control.deleteBook(bookId);
      this.notice = `已清理该漫画 ${removed} 个章节的离线缓存`;
      this.errorMessage = '';
    } catch (e) {
      this.errorMessage = `清理整部漫画失败: ${(e as Error).message}`;
    }
    await this.refresh();
  }

  /** 删除：deleteFiles=false 只删记录；true 同时删文件（UI 必须二次确认） */
  async deleteChapter(task: DownloadTask, deleteFiles: boolean): Promise<void> {
    if (this.disposed) {
      return;
    }
    try {
      await this.control.deleteChapter(task.bookId, task.chapterId, deleteFiles);
      this.notice = deleteFiles ? '已删除任务记录与下载文件' : '已删除任务记录（文件保留）';
      this.errorMessage = '';
    } catch (e) {
      this.errorMessage = `删除失败: ${(e as Error).message}`;
    }
    await this.refresh();
  }

  async clearFinished(): Promise<void> {
    if (this.disposed) {
      return;
    }
    const count: number = await this.control.clearFinishedRecords();
    this.notice = `已清除 ${count} 条已完成/已取消记录（文件未删除）`;
    await this.refresh();
  }

  async deleteAllOffline(): Promise<void> {
    if (this.disposed || this.control.deleteAllOfflineResources === undefined) {
      return;
    }
    try {
      const freed: number = await this.control.deleteAllOfflineResources();
      this.notice = `已清空全部离线资源（释放 ${CacheViewModel.formatBytes(freed)}）`;
      this.errorMessage = '';
    } catch (e) {
      this.errorMessage = `清空离线资源失败: ${(e as Error).message}`;
    }
    await this.refresh();
  }

  /** 页面销毁：注销监听，不再回写 UI 状态（下载任务本身由全局 Manager 继续） */
  dispose(): void {
    this.disposed = true;
    this.control.removeListener(this.listener);
  }
}
