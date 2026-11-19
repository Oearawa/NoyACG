/**
 * DownloadManager.ets —— 下载任务队列与全局并发调度（Phase 12）
 *
 * ★ 与 NoyAcg 数据协议完全解耦：本文件只依赖 `ChapterImagePlanProvider`
 *   （返回有序图片 URL 列表），不 import NoyAcgSource / NoyAcgProtocol / HttpManager。
 *   生产适配器在 DownloadFactory 里注入；测试注入任意桩。
 *
 * 调度模型（任务书 Step 5）：
 * - **有界 worker 池**：全局最多 `concurrency` 个图片作业在途（默认 3，可配置 1–6）；
 *   用 `pump()` 从「所有章节共享的待办队列」轮询取作业，绝不 `Promise.all` 一次性铺开；
 * - **可停止**：每个章节一个 DownloadToken；暂停/取消时先置标记 → 清空该章节待办 →
 *   触发 `rcp.Session.cancel(request)` 取消在途请求 → 已发出的作业结束后才最终定态；
 * - **故障隔离**：单张图片失败只记入该章节的 failedIndexes，不影响其他章节任务；
 * - **去重**：同一 `${bookId}/${chapterId}` 在内存 runs 与 Repository 双层去重。
 *
 * 状态转换统一走 `canTransit()`；只有「全部图片原子提交成功」才置 COMPLETED。
 */
import {
  DownloadStatus,
  DownloadTask,
  canTransit,
  downloadTaskKey,
  isRecoverable
} from '../model/DownloadTask';
import {
  DEFAULT_CHAPTER_CONCURRENCY,
  DEFAULT_IMAGE_CONCURRENCY,
  DownloadControlPort,
  DownloadError,
  DownloadImagePort,
  DownloadInterrupted,
  DownloadRepositoryPort,
  DownloadToken,
  MAX_IMAGE_CONCURRENCY,
  MIN_FREE_SPACE_BYTES,
  MIN_IMAGE_CONCURRENCY,
  ChapterImagePlanProvider
} from './DownloadPorts';
import { DownloadStorage } from './DownloadStorage';
import { Logger } from '../utils/Logger';

const TAG: string = 'DownloadManager';

/** 加入队列的结果（UI 据此提示「已下载 / 已在队列 / 已恢复」） */
export class EnqueueResult {
  readonly task: DownloadTask;
  readonly created: boolean;
  readonly reason: string;

  constructor(task: DownloadTask, created: boolean, reason: string) {
    this.task = task;
    this.created = created;
    this.reason = reason;
  }
}

/** 单个图片作业 */
class DownloadJob {
  readonly taskId: string;
  readonly index: number;
  readonly url: string;

  constructor(taskId: string, index: number, url: string) {
    this.taskId = taskId;
    this.index = index;
    this.url = url;
  }
}

/** 单个章节的运行上下文（内存态；重启后由 DownloadRepository.recover 重建） */
class ChapterRun {
  readonly task: DownloadTask;
  readonly token: DownloadToken;
  imageUrls: string[] = [];
  pending: number[] = [];
  active: number = 0;
  failedIndexes: number[] = [];
  preparing: boolean = false;
  /** PREPARING 阶段失败：finalize 不得覆盖其真实失败原因 */
  prepareFailed: boolean = false;
  stopped: boolean = false;
  /** 是否已定态并持久化（防止在途作业结束后重复改写状态） */
  finalized: boolean = false;
  /** 停止后要落到的状态（PAUSED / CANCELED） */
  targetStatus: DownloadStatus = DownloadStatus.PAUSED;

  constructor(task: DownloadTask, token: DownloadToken) {
    this.task = task;
    this.token = token;
  }
}

export class DownloadManager implements DownloadControlPort {
  private planProvider: ChapterImagePlanProvider;
  private fetcher: DownloadImagePort;
  private storage: DownloadStorage;
  private repo: DownloadRepositoryPort;
  private headers: Record<string, string>;
  private concurrency: number = DEFAULT_IMAGE_CONCURRENCY;
  private chapterConcurrency: number = DEFAULT_CHAPTER_CONCURRENCY;
  private minFreeSpaceBytes: number = MIN_FREE_SPACE_BYTES;

  /** 内存运行态：taskKey → run（同时是「在途任务」的去重集合） */
  private runs: Map<string, ChapterRun> = new Map<string, ChapterRun>();
  /** 当前在途图片作业数（全局，跨章节） */
  private running: number = 0;
  /** 防止 pump 重入 */
  private pumping: boolean = false;
  /** 轮询游标，保证多章节公平共享同一队列 */
  private roundRobin: number = 0;
  /** 应用是否已 dispose */
  private disposed: boolean = false;
  private listeners: (() => void)[] = [];
  /** 串行化的持久化链：避免多个图片作业并发写同一任务行，且 listTasks() 一定读到最新状态 */
  private persistChain: Promise<void> = Promise.resolve();
  /** 最近一次数据库写入失败原因（不谎报成功） */
  lastPersistError: string = '';

  constructor(planProvider: ChapterImagePlanProvider, fetcher: DownloadImagePort,
    storage: DownloadStorage, repo: DownloadRepositoryPort,
    headers?: Record<string, string>, concurrency?: number,
    chapterConcurrency?: number, minFreeSpaceBytes?: number) {
    this.planProvider = planProvider;
    this.fetcher = fetcher;
    this.storage = storage;
    this.repo = repo;
    this.headers = headers ?? {};
    if (concurrency !== undefined) {
      this.setConcurrency(concurrency);
    }
    if (chapterConcurrency !== undefined) {
      this.chapterConcurrency = Math.max(1, Math.floor(chapterConcurrency));
    }
    if (minFreeSpaceBytes !== undefined) {
      this.minFreeSpaceBytes = Math.max(0, Math.floor(minFreeSpaceBytes));
    }
  }

  // ==================== 配置与订阅 ====================

  setConcurrency(value: number): void {
    const clamped: number = Math.max(MIN_IMAGE_CONCURRENCY,
      Math.min(MAX_IMAGE_CONCURRENCY, Math.floor(value)));
    this.concurrency = clamped;
    Logger.info(TAG, `图片下载并发上限 = ${clamped}`);
    this.pump();
  }

  getConcurrency(): number {
    return this.concurrency;
  }

  addListener(listener: () => void): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  removeListener(listener: () => void): void {
    const i: number = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }

  private notify(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      try {
        this.listeners[i]();
      } catch (e) {
        Logger.warn(TAG, `监听器异常: ${(e as Error).message}`);
      }
    }
  }

  // ==================== 任务入队与去重 ====================

  /**
   * 加入下载队列。重复添加规则（任务书 §三）：
   * - 已完成 → 返回已有任务（提示已下载），不重复创建；
   * - 正在下载/排队 → 返回现有任务，不重复创建；
   * - 暂停 → 恢复；失败/不完整 → 重试；已取消 → 重新创建。
   */
  async enqueue(bookId: string, chapterId: string, bookTitle: string,
    chapterTitle: string): Promise<EnqueueResult> {
    if (this.disposed) {
      throw new DownloadError('DISPOSED', '下载管理器已释放');
    }
    const key: string = downloadTaskKey(bookId, chapterId);
    const live: ChapterRun | undefined = this.runs.get(key);
    if (live !== undefined) {
      return new EnqueueResult(live.task, false, '该章节已在下载队列中');
    }
    const stored: DownloadTask | null = await this.repo.get(bookId, chapterId);
    if (stored !== null) {
      if (stored.status === DownloadStatus.COMPLETED && stored.isComplete) {
        return new EnqueueResult(stored, false, '该章节已下载完成');
      }
      if (stored.status === DownloadStatus.PAUSED) {
        await this.resume(bookId, chapterId);
        return new EnqueueResult(stored, false, '已恢复暂停的任务');
      }
      if (!(await this.storage.hasEnoughDiskSpace(this.minFreeSpaceBytes))) {
        throw new DownloadError('INSUFFICIENT_SPACE', '磁盘可用空间不足（需保留至少 200MB 安全余量）');
      }
      // FAILED / INCOMPLETE / CANCELED / COMPLETED 但文件已失效 → 重新入队
      const reused: DownloadTask = new DownloadTask(bookId, chapterId,
        bookTitle === '' ? stored.bookTitle : bookTitle,
        chapterTitle === '' ? stored.chapterTitle : chapterTitle);
      reused.createdAt = stored.createdAt > 0 ? stored.createdAt : Date.now();
      reused.totalImages = 0;
      reused.completedImages = 0;
      reused.failedImages = 0;
      reused.lastError = '';
      this.startRun(reused);
      return new EnqueueResult(reused, true, '已重新加入下载队列');
    }
    if (!(await this.storage.hasEnoughDiskSpace(this.minFreeSpaceBytes))) {
      throw new DownloadError('INSUFFICIENT_SPACE', '磁盘可用空间不足（需保留至少 200MB 安全余量）');
    }
    const task: DownloadTask = new DownloadTask(bookId, chapterId, bookTitle, chapterTitle);
    task.createdAt = Date.now();
    task.updatedAt = task.createdAt;
    task.status = DownloadStatus.QUEUED;
    this.startRun(task);
    return new EnqueueResult(task, true, '已加入下载队列');
  }

  /**
   * `DownloadControlPort` 入口：详情页通过 VM 调用，返回可直接展示的文案。
   * 与 `enqueue()` 共用同一套去重规则，不绕过状态机。
   */
  async enqueueChapter(bookId: string, chapterId: string, bookTitle: string,
    chapterTitle: string): Promise<string> {
    const result: EnqueueResult = await this.enqueue(bookId, chapterId,
      bookTitle, chapterTitle);
    return result.reason;
  }

  /** 启动（或重启）一个章节运行上下文，受章节并发上限控制 */
  private startRun(task: DownloadTask): void {
    const key: string = task.taskId;
    task.status = DownloadStatus.QUEUED;
    task.updatedAt = Date.now();
    task.lastError = '';
    const run: ChapterRun = new ChapterRun(task, new DownloadToken(key));
    this.runs.set(key, run);
    this.persist(task);
    this.notify();
    this.pumpChapters();
  }

  /** FIFO 调度排队章节，保证同时处于 PREPARING/DOWNLOADING 的章节数 <= chapterConcurrency */
  private pumpChapters(): void {
    if (this.disposed) {
      return;
    }
    let activeChapters: number = 0;
    this.runs.forEach((run: ChapterRun): void => {
      if (!run.stopped && !run.finalized &&
        (run.task.status === DownloadStatus.PREPARING || run.task.status === DownloadStatus.DOWNLOADING)) {
        activeChapters++;
      }
    });
    if (activeChapters >= this.chapterConcurrency) {
      return;
    }
    const keys: string[] = Array.from(this.runs.keys());
    for (let i = 0; i < keys.length && activeChapters < this.chapterConcurrency; i++) {
      const run: ChapterRun | undefined = this.runs.get(keys[i]);
      if (run !== undefined && !run.stopped && !run.finalized &&
        run.task.status === DownloadStatus.QUEUED && !run.preparing) {
        activeChapters++;
        void this.prepare(run);
      }
    }
  }

  // ==================== 准备阶段 ====================

  /** 向解耦的图片清单端口询问 URL 列表，并跳过磁盘上已完整保存的图片 */
  private async prepare(run: ChapterRun): Promise<void> {
    run.preparing = true;
    this.setStatus(run, DownloadStatus.PREPARING);
    try {
      const urls: string[] = await this.planProvider.getImageUrls(
        run.task.bookId, run.task.chapterId);
      if (run.stopped) {
        return;
      }
      if (urls.length === 0) {
        throw new DownloadError('EMPTY_PLAN', '章节图片清单为空，无法下载');
      }
      run.imageUrls = urls;
      run.task.totalImages = urls.length;
      const pending: number[] = [];
      let existing: number = 0;
      for (let i = 0; i < urls.length; i++) {
        if (await this.storage.hasImage(run.task.bookId, run.task.chapterId, i)) {
          existing++;
        } else {
          pending.push(i);
        }
      }
      run.pending = pending;
      run.task.completedImages = existing;
      run.failedIndexes = [];
      run.task.failedImages = 0;
      this.setStatus(run, DownloadStatus.DOWNLOADING);
      await this.persist(run.task);
      Logger.info(TAG, `章节就绪 ${run.task.taskId}: 共${urls.length}张, ` +
        `已有${existing}张, 待下载${pending.length}张`);
    } catch (e) {
      if (!run.stopped) {
        const reason: string = (e as Error).message;
        run.prepareFailed = true;
        run.task.lastError = `获取章节图片清单失败: ${reason}`;
        this.setStatus(run, DownloadStatus.FAILED);
        await this.persist(run.task);
      }
    } finally {
      run.preparing = false;
      this.pump();
      this.maybeFinalize(run);
    }
  }

  // ==================== 有界并发调度 ====================

  /**
   * 从所有章节共享的待办队列里公平取下一个作业。
   * 轮询游标避免「一个章节占满全部并发槽」。
   */
  private nextJob(): DownloadJob | null {
    const keys: string[] = Array.from(this.runs.keys());
    const total: number = keys.length;
    if (total === 0) {
      return null;
    }
    for (let scanned = 0; scanned < total; scanned++) {
      const idx: number = (this.roundRobin + scanned) % total;
      const run: ChapterRun | undefined = this.runs.get(keys[idx]);
      if (run === undefined || run.stopped || run.pending.length === 0) {
        continue;
      }
      const imageIndex: number = run.pending.shift()!;
      this.roundRobin = (idx + 1) % total;
      return new DownloadJob(run.task.taskId, imageIndex, run.imageUrls[imageIndex]);
    }
    return null;
  }

  /** 填充并发槽；不使用 Promise.all，每个作业独立结束并回调 pump */
  private pump(): void {
    if (this.disposed || this.pumping) {
      return;
    }
    this.pumping = true;
    try {
      while (this.running < this.concurrency) {
        const job: DownloadJob | null = this.nextJob();
        if (job === null) {
          break;
        }
        const run: ChapterRun | undefined = this.runs.get(job.taskId);
        if (run === undefined) {
          continue;
        }
        run.active++;
        this.running++;
        this.runJob(job, run); // 有意不 await：作业完成自行回调 pump
      }
    } finally {
      this.pumping = false;
    }
  }

  private async runJob(job: DownloadJob, run: ChapterRun): Promise<void> {
    try {
      await this.storage.saveImage(job.url, run.task.bookId, run.task.chapterId,
        job.index, this.fetcher, run.token, this.headers);
      if (!run.stopped && !run.token.isCanceled) {
        run.task.completedImages++;
      }
    } catch (e) {
      if (!(e instanceof DownloadInterrupted) && !run.stopped && !run.token.isCanceled) {
        run.failedIndexes.push(job.index);
        run.task.failedImages = run.failedIndexes.length;
        run.task.lastError = (e as Error).message;
        Logger.warn(TAG, `图片失败 ${run.task.taskId}#${job.index + 1}: ${run.task.lastError}`);
      }
    } finally {
      run.active = Math.max(run.active - 1, 0);
      this.running = Math.max(this.running - 1, 0);
      this.notify();
      this.maybeFinalize(run);
      this.pump();
    }
  }

  /** 所有作业结束后才定态：写入过程中绝不标记完成 */
  private maybeFinalize(run: ChapterRun): void {
    if (run.finalized) {
      return;
    }
    if (run.preparing || run.active > 0 || run.pending.length > 0) {
      return;
    }
    if (run.prepareFailed && !run.stopped) {
      // 保留 PREPARING 阶段的真实失败原因（如「图片清单为空」），不覆盖成笼统文案
      run.finalized = true;
      this.persist(run.task);
      this.runs.delete(run.task.taskId);
      this.notify();
      return;
    }
    if (run.stopped) {
      this.setStatus(run, run.targetStatus);
    } else if (run.failedIndexes.length > 0) {
      run.task.lastError = run.task.lastError === ''
        ? `${run.failedIndexes.length} 张图片下载失败` : run.task.lastError;
      this.setStatus(run, DownloadStatus.FAILED);
    } else if (run.task.totalImages > 0
      && run.task.completedImages >= run.task.totalImages) {
      run.task.lastError = '';
      this.setStatus(run, DownloadStatus.COMPLETED);
    } else {
      run.task.lastError = '章节图片总数未知，无法确认完成';
      this.setStatus(run, DownloadStatus.FAILED);
    }
    run.finalized = true;
    this.persist(run.task);
    this.runs.delete(run.task.taskId);
    this.notify();
    this.pumpChapters();
    Logger.info(TAG, `章节结束 ${run.task.taskId}: ${run.task.status}, ` +
      `${run.task.completedImages}/${run.task.totalImages} 张`);
  }

  // ==================== 控制操作 ====================

  /** 暂停单个章节：清待办 + 取消在途 RCP 请求，等在途作业结束后定态 PAUSED */
  pause(bookId: string, chapterId: string): boolean {
    return this.stop(bookId, chapterId, DownloadStatus.PAUSED);
  }

  /** 取消单个章节（保留已完成的图片文件，可重新创建任务） */
  cancel(bookId: string, chapterId: string): boolean {
    return this.stop(bookId, chapterId, DownloadStatus.CANCELED);
  }

  /**
   * 立即定态并退出调度：
   * 1. 清空待办；
   * 2. `token.cancel()` 触发 rcp.Session.cancel(request) 取消**已发出**的请求；
   * 3. **马上**把状态写成目标态并持久化，不让 UI 等到在途作业结束才看到变化；
   * 4. `finalized` 守卫让随后结束的在途作业不再改写状态（幂等）。
   */
  private stopRun(run: ChapterRun, target: DownloadStatus): void {
    if (run.finalized) {
      return;
    }
    run.stopped = true;
    run.targetStatus = target;
    run.pending = [];
    run.token.cancel();
    this.setStatus(run, target);
    run.finalized = true;
    this.persist(run.task);
    this.runs.delete(run.task.taskId);
    this.pumpChapters();
  }

  private stop(bookId: string, chapterId: string, target: DownloadStatus): boolean {
    const key: string = downloadTaskKey(bookId, chapterId);
    const run: ChapterRun | undefined = this.runs.get(key);
    if (run === undefined) {
      return false;
    }
    this.stopRun(run, target);
    this.notify();
    return true;
  }

  /** 取消全部待处理任务（含在途） */
  cancelAllPending(): number {
    const keys: string[] = Array.from(this.runs.keys());
    for (let i = 0; i < keys.length; i++) {
      const run: ChapterRun | undefined = this.runs.get(keys[i]);
      if (run !== undefined) {
        this.stopRun(run, DownloadStatus.CANCELED);
      }
    }
    this.notify();
    return keys.length;
  }

  /** 异步暂停单个任务（覆盖在途与持久化队列） */
  async pauseTask(bookId: string, chapterId: string): Promise<boolean> {
    if (this.stop(bookId, chapterId, DownloadStatus.PAUSED)) {
      return true;
    }
    await this.persistChain;
    const stored: DownloadTask | null = await this.repo.get(bookId, chapterId);
    if (stored === null) {
      return false;
    }
    if (stored.status === DownloadStatus.QUEUED || stored.status === DownloadStatus.PREPARING ||
      stored.status === DownloadStatus.DOWNLOADING) {
      stored.status = DownloadStatus.PAUSED;
      stored.updatedAt = Date.now();
      await this.repo.upsert(stored);
      this.notify();
      return true;
    }
    return false;
  }

  /** 异步取消单个未完成任务：中止下载、清理未完成文件并从队列移除 */
  async cancelTask(bookId: string, chapterId: string): Promise<boolean> {
    const hadRun: boolean = this.stop(bookId, chapterId, DownloadStatus.CANCELED);
    await this.persistChain;
    const stored: DownloadTask | null = await this.repo.get(bookId, chapterId);
    if (stored === null && !hadRun) {
      return false;
    }
    if (stored === null || stored.status !== DownloadStatus.COMPLETED) {
      await this.storage.deleteChapter(bookId, chapterId);
      await this.repo.remove(bookId, chapterId);
    }
    this.notify();
    return true;
  }

  /** 异步取消全部未完成任务（涵盖在途、等待、暂停、不完整、失败）并清理未完成文件 */
  async cancelAllPendingTasks(): Promise<number> {
    const handledKeys: Set<string> = new Set<string>();
    const activeKeys: string[] = Array.from(this.runs.keys());
    let canceled: number = 0;
    for (let i = 0; i < activeKeys.length; i++) {
      const run: ChapterRun | undefined = this.runs.get(activeKeys[i]);
      if (run !== undefined) {
        handledKeys.add(run.task.taskId);
        const bId: string = run.task.bookId;
        const cId: string = run.task.chapterId;
        this.stopRun(run, DownloadStatus.CANCELED);
        await this.storage.deleteChapter(bId, cId);
        await this.repo.remove(bId, cId);
        canceled++;
      }
    }
    await this.persistChain;
    const tasks: DownloadTask[] = await this.repo.list();
    for (let i = 0; i < tasks.length; i++) {
      const t: DownloadTask = tasks[i];
      if (handledKeys.has(t.taskId)) {
        continue;
      }
      if (t.status !== DownloadStatus.COMPLETED && t.status !== DownloadStatus.CANCELED) {
        await this.storage.deleteChapter(t.bookId, t.chapterId);
        await this.repo.remove(t.bookId, t.chapterId);
        canceled++;
      }
    }
    this.notify();
    return canceled;
  }

  /** 恢复暂停任务 / 重试失败或不完整任务 */
  async resume(bookId: string, chapterId: string): Promise<boolean> {
    const key: string = downloadTaskKey(bookId, chapterId);
    if (this.runs.has(key)) {
      return false; // 已在运行
    }
    const stored: DownloadTask | null = await this.repo.get(bookId, chapterId);
    if (stored === null) {
      return false;
    }
    if (stored.status === DownloadStatus.COMPLETED) {
      return false; // 已完成无需恢复
    }
    if (!isRecoverable(stored.status) && stored.status !== DownloadStatus.CANCELED) {
      return false;
    }
    if (!(await this.storage.hasEnoughDiskSpace(this.minFreeSpaceBytes))) {
      throw new DownloadError('INSUFFICIENT_SPACE', '磁盘可用空间不足（需保留至少 200MB 安全余量）');
    }
    this.startRun(stored);
    return true;
  }

  /** 缺图补下载 / 完整性修复：校验本地已有页并仅重下缺失或损坏页 */
  async repairChapter(bookId: string, chapterId: string): Promise<boolean> {
    const key: string = downloadTaskKey(bookId, chapterId);
    if (this.runs.has(key)) {
      return false;
    }
    const stored: DownloadTask | null = await this.repo.get(bookId, chapterId);
    if (stored === null) {
      return false;
    }
    if (!(await this.storage.hasEnoughDiskSpace(this.minFreeSpaceBytes))) {
      throw new DownloadError('INSUFFICIENT_SPACE', '磁盘可用空间不足（需保留至少 200MB 安全余量）');
    }
    stored.lastError = '';
    stored.failedImages = 0;
    this.startRun(stored);
    return true;
  }

  /** 全部暂停（同步内存版，兼容既有测试） */
  pauseAll(): number {
    const keys: string[] = Array.from(this.runs.keys());
    for (let i = 0; i < keys.length; i++) {
      const run: ChapterRun | undefined = this.runs.get(keys[i]);
      if (run !== undefined) {
        this.stopRun(run, DownloadStatus.PAUSED);
      }
    }
    this.notify();
    return keys.length;
  }

  /** 异步全部暂停（覆盖内存与持久化等待队列） */
  async pauseAllTasks(): Promise<number> {
    const handledKeys: Set<string> = new Set<string>();
    const keys: string[] = Array.from(this.runs.keys());
    let paused: number = 0;
    for (let i = 0; i < keys.length; i++) {
      const run: ChapterRun | undefined = this.runs.get(keys[i]);
      if (run !== undefined) {
        handledKeys.add(run.task.taskId);
        this.stopRun(run, DownloadStatus.PAUSED);
        paused++;
      }
    }
    await this.persistChain;
    const tasks: DownloadTask[] = await this.repo.list();
    for (let i = 0; i < tasks.length; i++) {
      const t: DownloadTask = tasks[i];
      if (handledKeys.has(t.taskId)) {
        continue;
      }
      if (t.status === DownloadStatus.QUEUED || t.status === DownloadStatus.PREPARING ||
        t.status === DownloadStatus.DOWNLOADING) {
        t.status = DownloadStatus.PAUSED;
        t.updatedAt = Date.now();
        await this.repo.upsert(t);
        paused++;
      }
    }
    this.notify();
    return paused;
  }

  /** 全部继续：恢复所有暂停/等待/失败/不完整章节 */
  async resumeAll(): Promise<number> {
    await this.persistChain;
    const tasks: DownloadTask[] = await this.repo.list();
    let resumed: number = 0;
    for (let i = 0; i < tasks.length; i++) {
      const t: DownloadTask = tasks[i];
      if (t.status === DownloadStatus.PAUSED || t.status === DownloadStatus.QUEUED ||
        t.status === DownloadStatus.PREPARING || t.status === DownloadStatus.FAILED ||
        t.status === DownloadStatus.INCOMPLETE) {
        if (await this.resume(t.bookId, t.chapterId)) {
          resumed++;
        }
      }
    }
    return resumed;
  }

  /** 统计单部漫画离线占用字节数 */
  async getBookSize(bookId: string): Promise<number> {
    return await this.storage.getBookSize(bookId);
  }

  /** 级联删除整部漫画的全部离线文件与数据库记录 */
  async deleteBook(bookId: string): Promise<number> {
    const tasks: DownloadTask[] = await this.repo.list();
    let removed: number = 0;
    for (let i = 0; i < tasks.length; i++) {
      if (tasks[i].bookId === bookId) {
        this.stop(bookId, tasks[i].chapterId, DownloadStatus.CANCELED);
        await this.repo.remove(bookId, tasks[i].chapterId);
        removed++;
      }
    }
    await this.storage.deleteBook(bookId);
    this.notify();
    return removed;
  }

  /** 重试（语义同 resume，语义更明确） */
  async retry(bookId: string, chapterId: string): Promise<boolean> {
    return await this.resume(bookId, chapterId);
  }

  /**
   * 删除章节：`deleteFiles=false` 只删记录，`true` 同时删文件。
   * 两者严格区分，UI 删除文件必须二次确认。
   */
  async deleteChapter(bookId: string, chapterId: string,
    deleteFiles: boolean): Promise<void> {
    this.stop(bookId, chapterId, DownloadStatus.CANCELED);
    if (deleteFiles) {
      await this.storage.deleteChapter(bookId, chapterId);
    }
    await this.repo.remove(bookId, chapterId);
    this.notify();
  }

  /** 清除已完成/已取消的**记录**（不动文件） */
  async clearFinishedRecords(): Promise<number> {
    const count: number = await this.repo.clearFinished();
    this.notify();
    return count;
  }

  /** 一键删除全部离线下载资源与全部任务记录，返回释放字节数 */
  async deleteAllOfflineResources(): Promise<number> {
    const activeKeys: string[] = Array.from(this.runs.keys());
    for (let i = 0; i < activeKeys.length; i++) {
      const run: ChapterRun | undefined = this.runs.get(activeKeys[i]);
      if (run !== undefined) {
        this.stopRun(run, DownloadStatus.CANCELED);
      }
    }
    await this.persistChain;
    const beforeBytes: number = await this.storage.getTotalSize();
    const tasks: DownloadTask[] = await this.repo.list();
    for (let i = 0; i < tasks.length; i++) {
      await this.repo.remove(tasks[i].bookId, tasks[i].chapterId);
    }
    await this.storage.deleteAll();
    this.notify();
    return beforeBytes;
  }

  /** 永久下载占用（与图片缓存统计独立） */
  async getDownloadSize(): Promise<number> {
    return await this.storage.getTotalSize();
  }

  /** 合并「内存最新状态」与库中其它任务，供 UI 展示 */
  async listTasks(): Promise<DownloadTask[]> {
    // 等待所有已排队的持久化完成，避免 UI 在任务刚定态时读到上一版数据库状态
    await this.persistChain;
    const stored: DownloadTask[] = await this.repo.list();
    const result: DownloadTask[] = [];
    for (let i = 0; i < stored.length; i++) {
      const live: ChapterRun | undefined = this.runs.get(stored[i].taskId);
      result.push(live === undefined ? stored[i] : live.task);
    }
    // 内存中存在但尚未落盘的新任务（persist 异步）也要展示
    this.runs.forEach((run: ChapterRun, key: string): void => {
      let found: boolean = false;
      for (let i = 0; i < result.length; i++) {
        if (result[i].taskId === key) {
          found = true;
          break;
        }
      }
      if (!found) {
        result.push(run.task);
      }
    });
    return result;
  }

  /**
   * 应用退出：停止调度、取消在途请求、移除监听。
   * **不**把 DOWNLOADING 改成 PAUSED —— 保留「异常终止」的真实状态，
   * 由下次启动的 DownloadRepository.recover() 归位为 INCOMPLETE。
   */
  dispose(): void {
    this.disposed = true;
    const keys: string[] = Array.from(this.runs.keys());
    for (let i = 0; i < keys.length; i++) {
      const run: ChapterRun | undefined = this.runs.get(keys[i]);
      if (run !== undefined) {
        // 关键：必须阻止在途作业结束后的 maybeFinalize 改写状态。
        // 否则 runJob 的 finally 会把「异常终止」的任务误判为 FAILED/COMPLETED，
        // 违背「保留 DOWNLOADING 交 recover() 归位 INCOMPLETE」的设计意图。
        run.stopped = true;
        run.finalized = true;
        run.pending = [];
        run.token.cancel();
      }
    }
    this.runs.clear();
    this.listeners = [];
    Logger.info(TAG, 'DownloadManager 已释放（在途请求已请求取消）');
  }

  // ==================== 内部工具 ====================

  private setStatus(run: ChapterRun, to: DownloadStatus): void {
    const from: DownloadStatus = run.task.status;
    if (!canTransit(from, to)) {
      Logger.warn(TAG, `非法状态转换 ${run.task.taskId}: ${from} → ${to}，已忽略`);
      return;
    }
    run.task.status = to;
    run.task.updatedAt = Date.now();
  }

  /**
   * 数据库写入串行化：多个图片作业可能同时完成，直接并发 upsert 同一行会互相覆盖计数。
   * 写入失败如实记录到 lastPersistError，绝不静默当作成功。
   */
  private async persist(task: DownloadTask): Promise<void> {
    const snapshot: DownloadTask = task.snapshot();
    const next: Promise<void> = this.persistChain.then(async (): Promise<void> => {
      await this.repo.upsert(snapshot);
      this.lastPersistError = '';
    }).catch((e: Error): void => {
      this.lastPersistError = `下载任务保存失败: ${e.message}`;
      Logger.error(TAG, this.lastPersistError);
    });
    this.persistChain = next;
    await next;
  }
}
