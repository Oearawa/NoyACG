/**
 * DownloadTask.ets —— 下载任务实体与状态机（Phase 12）
 *
 * 设计依据（任务书 §三）：
 * - 唯一键 `${bookId}/${chapterId}`，**不得只用 chapterId**（不同漫画章节 id 可能相同）；
 * - 状态显式枚举，转换规则集中在 `canTransit()`，UI/Manager 不得随意写 status；
 * - 所有计数都是「已确认落盘」的图片数，不在写入过程中提前标记完成。
 */
export enum DownloadStatus {
  /** 已入队，等待调度 */
  QUEUED = 'queued',
  /** 正在向数据源询问该章节的图片清单 */
  PREPARING = 'preparing',
  /** 正在下载图片 */
  DOWNLOADING = 'downloading',
  /** 用户暂停（在途请求会被取消，可恢复） */
  PAUSED = 'paused',
  /** 全部图片已落盘并通过完整性检查 */
  COMPLETED = 'completed',
  /** 本次下载失败（可重试） */
  FAILED = 'failed',
  /** 用户取消（记录保留，可重新创建） */
  CANCELED = 'canceled',
  /** 重启恢复时发现已完成图片缺失/损坏（可恢复） */
  INCOMPLETE = 'incomplete'
}

/** 构造任务唯一键：bookId + chapterId，禁止只用 chapterId */
export function downloadTaskKey(bookId: string, chapterId: string): string {
  return `${bookId}/${chapterId}`;
}

/** 是否为「可恢复」状态（重启恢复 / 重试入口） */
export function isRecoverable(status: DownloadStatus): boolean {
  return status === DownloadStatus.PAUSED || status === DownloadStatus.FAILED
    || status === DownloadStatus.INCOMPLETE || status === DownloadStatus.QUEUED;
}

/** 是否为「活跃」状态（占用并发槽） */
export function isActive(status: DownloadStatus): boolean {
  return status === DownloadStatus.QUEUED || status === DownloadStatus.PREPARING
    || status === DownloadStatus.DOWNLOADING;
}

/**
 * 状态转换规则（唯一真相源）：
 * QUEUED → PREPARING / CANCELED
 * PREPARING → DOWNLOADING / FAILED / PAUSED / CANCELED
 * DOWNLOADING → COMPLETED / FAILED / PAUSED / CANCELED / INCOMPLETE
 * PAUSED → QUEUED / CANCELED
 * FAILED → QUEUED / CANCELED
 * INCOMPLETE → QUEUED / CANCELED
 * COMPLETED → QUEUED（仅「重新下载」显式允许）/ CANCELED
 * CANCELED → QUEUED（重新创建任务）
 */
export function canTransit(from: DownloadStatus, to: DownloadStatus): boolean {
  if (from === to) {
    return false;
  }
  if (to === DownloadStatus.CANCELED) {
    return from !== DownloadStatus.CANCELED;
  }
  if (to === DownloadStatus.QUEUED) {
    return true; // 恢复 / 重试 / 重新创建都回到队列
  }
  switch (from) {
    case DownloadStatus.QUEUED:
      return to === DownloadStatus.PREPARING;
    case DownloadStatus.PREPARING:
      return to === DownloadStatus.DOWNLOADING || to === DownloadStatus.FAILED
        || to === DownloadStatus.PAUSED;
    case DownloadStatus.DOWNLOADING:
      return to === DownloadStatus.COMPLETED || to === DownloadStatus.FAILED
        || to === DownloadStatus.PAUSED || to === DownloadStatus.INCOMPLETE;
    default:
      return false;
  }
}

@ObservedV2
export class DownloadTask {
  /** `${bookId}/${chapterId}` */
  @Trace taskId: string = '';
  @Trace bookId: string = '';
  @Trace chapterId: string = '';
  @Trace bookTitle: string = '';
  @Trace chapterTitle: string = '';
  @Trace status: DownloadStatus = DownloadStatus.QUEUED;
  /** 该章节图片总数（PREPARING 阶段由数据源给出；0 = 尚未确定） */
  @Trace totalImages: number = 0;
  /** 已成功落盘并完成原子提交的图片数 */
  @Trace completedImages: number = 0;
  /** 本轮失败的图片数（重试成功后清零） */
  @Trace failedImages: number = 0;
  @Trace createdAt: number = 0;
  @Trace updatedAt: number = 0;
  /** 最近一次失败原因（成功时清空，不含敏感信息） */
  @Trace lastError: string = '';

  constructor(bookId: string = '', chapterId: string = '', bookTitle: string = '',
    chapterTitle: string = '') {
    this.bookId = bookId;
    this.chapterId = chapterId;
    this.bookTitle = bookTitle;
    this.chapterTitle = chapterTitle;
    this.taskId = downloadTaskKey(bookId, chapterId);
  }

  /** 0–100 的展示进度；总数未知时返回 0（不伪造进度） */
  get progressPercent(): number {
    if (this.totalImages <= 0) {
      return 0;
    }
    const pct: number = Math.floor(this.completedImages * 100 / this.totalImages);
    return Math.max(0, Math.min(pct, 100));
  }

  /** 是否全部完成（必须有明确的正数图片总数） */
  get isComplete(): boolean {
    return this.status === DownloadStatus.COMPLETED && this.totalImages > 0
      && this.completedImages >= this.totalImages;
  }

  /** 复制为普通快照（Repository 落盘时使用，避免把 @ObservedV2 实例直接写库） */
  snapshot(): DownloadTask {
    const copy: DownloadTask = new DownloadTask(this.bookId, this.chapterId,
      this.bookTitle, this.chapterTitle);
    copy.status = this.status;
    copy.totalImages = this.totalImages;
    copy.completedImages = this.completedImages;
    copy.failedImages = this.failedImages;
    copy.createdAt = this.createdAt;
    copy.updatedAt = this.updatedAt;
    copy.lastError = this.lastError;
    return copy;
  }
}
