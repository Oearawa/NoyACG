/**
 * OfflineBooksHelper.ets —— 离线阅读书架双源聚合（任务元数据 + 磁盘目录）与清理工具
 */
import { DownloadStatus, DownloadTask } from '../model/DownloadTask';
import { DownloadManager } from '../download/DownloadManager';
import { DownloadStorage, OfflineImageEntry } from '../download/DownloadStorage';

export interface OfflineBookChapter {
  chapterId: string;
  chapterTitle: string;
  totalImages: number;
  completedImages: number;
  updatedAt: number;
}

export interface OfflineBookGroup {
  bookId: string;
  bookTitle: string;
  coverUrl: string;
  chapters: OfflineBookChapter[];
  totalBytes: number;
  latestUpdatedAt: number;
}

export interface DiskOfflineChapter {
  chapterId: string;
  imageCount: number;
  firstImageUri: string;
  sizeBytes: number;
}

export interface DiskOfflineBook {
  bookId: string;
  totalBytes: number;
  chapters: DiskOfflineChapter[];
}

/**
 * 扫描磁盘离线根目录下的全部漫画文件夹与章节图片（不依赖任务数据库）。
 */
export async function scanDiskOfflineBooks(storage: DownloadStorage): Promise<DiskOfflineBook[]> {
  const bookIds: string[] = await storage.listDiskBookIds();
  const books: DiskOfflineBook[] = [];
  for (let i = 0; i < bookIds.length; i++) {
    const bookId: string = bookIds[i];
    if (bookId === '') {
      continue;
    }
    const chapterIds: string[] = await storage.listDiskChapterIds(bookId);
    const chapters: DiskOfflineChapter[] = [];
    for (let j = 0; j < chapterIds.length; j++) {
      const chId: string = chapterIds[j];
      if (chId === '') {
        continue;
      }
      const images: OfflineImageEntry[] = await storage.listDiskChapterImages(bookId, chId);
      if (images.length === 0) {
        continue;
      }
      const chSize: number = await storage.getChapterSize(bookId, chId);
      chapters.push({
        chapterId: chId,
        imageCount: images.length,
        firstImageUri: images[0].uri,
        sizeBytes: chSize
      });
    }
    const bookBytes: number = await storage.getBookSize(bookId);
    if (chapters.length > 0 || bookBytes > 0) {
      books.push({
        bookId,
        totalBytes: bookBytes,
        chapters
      });
    }
  }
  return books;
}

/**
 * 双源聚合：同时融合 DownloadManager 任务元数据与磁盘物理目录扫描结果。
 * 即使任务记录已被清除，只要磁盘目录中存在有效图片文件，仍完整聚合进离线书架。
 */
export function aggregateOfflineBooksWithDisk(
  tasks: DownloadTask[],
  diskBooks: DiskOfflineBook[],
  coverByBook?: Record<string, string>
): OfflineBookGroup[] {
  const taskMapByKey: Map<string, DownloadTask> = new Map<string, DownloadTask>();
  const bookTitleMap: Map<string, string> = new Map<string, string>();
  const groupMap: Map<string, OfflineBookGroup> = new Map<string, OfflineBookGroup>();

  for (let i = 0; i < tasks.length; i++) {
    const task: DownloadTask = tasks[i];
    if (task.bookId === '') {
      continue;
    }
    taskMapByKey.set(`${task.bookId}/${task.chapterId}`, task);
    if (task.bookTitle !== '' && !bookTitleMap.has(task.bookId)) {
      bookTitleMap.set(task.bookId, task.bookTitle);
    }
  }

  for (let i = 0; i < diskBooks.length; i++) {
    const diskBook: DiskOfflineBook = diskBooks[i];
    if (diskBook.chapters.length === 0) {
      continue;
    }
    const resolvedTitle: string = bookTitleMap.get(diskBook.bookId) ?? `离线漫画 #${diskBook.bookId}`;
    let cover: string = coverByBook !== undefined && typeof coverByBook[diskBook.bookId] === 'string'
      ? coverByBook[diskBook.bookId] : '';
    const chapters: OfflineBookChapter[] = [];
    let latestTs: number = 0;

    for (let j = 0; j < diskBook.chapters.length; j++) {
      const diskCh: DiskOfflineChapter = diskBook.chapters[j];
      if (cover === '' && diskCh.firstImageUri !== '') {
        cover = diskCh.firstImageUri;
      }
      const meta: DownloadTask | undefined = taskMapByKey.get(`${diskBook.bookId}/${diskCh.chapterId}`);
      const chTitle: string = meta !== undefined && meta.chapterTitle !== ''
        ? meta.chapterTitle : `第 ${j + 1} 话`;
      const updatedAt: number = meta !== undefined ? meta.updatedAt : j;
      if (updatedAt > latestTs) {
        latestTs = updatedAt;
      }
      chapters.push({
        chapterId: diskCh.chapterId,
        chapterTitle: chTitle,
        totalImages: diskCh.imageCount,
        completedImages: diskCh.imageCount,
        updatedAt
      });
    }

    chapters.sort((a: OfflineBookChapter, b: OfflineBookChapter) => a.updatedAt - b.updatedAt);
    groupMap.set(diskBook.bookId, {
      bookId: diskBook.bookId,
      bookTitle: resolvedTitle,
      coverUrl: cover,
      chapters,
      totalBytes: diskBook.totalBytes,
      latestUpdatedAt: latestTs
    });
  }

  // 兜底：补充任务中标记 COMPLETED 但磁盘列表尚未命中的记录
  for (let i = 0; i < tasks.length; i++) {
    const task: DownloadTask = tasks[i];
    if (task.status !== DownloadStatus.COMPLETED || task.bookId === '') {
      continue;
    }
    if (!groupMap.has(task.bookId)) {
      const cover: string = coverByBook !== undefined && typeof coverByBook[task.bookId] === 'string'
        ? coverByBook[task.bookId] : '';
      groupMap.set(task.bookId, {
        bookId: task.bookId,
        bookTitle: task.bookTitle !== '' ? task.bookTitle : `离线漫画 #${task.bookId}`,
        coverUrl: cover,
        chapters: [{
          chapterId: task.chapterId,
          chapterTitle: task.chapterTitle !== '' ? task.chapterTitle : `章节 #${task.chapterId}`,
          totalImages: task.totalImages,
          completedImages: task.completedImages,
          updatedAt: task.updatedAt
        }],
        totalBytes: 0,
        latestUpdatedAt: task.updatedAt
      });
    }
  }

  const result: OfflineBookGroup[] = [];
  groupMap.forEach((group: OfflineBookGroup) => {
    result.push(group);
  });
  result.sort((a: OfflineBookGroup, b: OfflineBookGroup) => b.latestUpdatedAt - a.latestUpdatedAt);
  return result;
}

/** 兼容旧签名的纯任务聚合函数 */
export function aggregateOfflineBooks(
  tasks: DownloadTask[],
  sizeByBook: Record<string, number>,
  coverByBook?: Record<string, string>
): OfflineBookGroup[] {
  const groupMap: Map<string, OfflineBookGroup> = new Map<string, OfflineBookGroup>();
  for (let i = 0; i < tasks.length; i++) {
    const task: DownloadTask = tasks[i];
    if (task.status !== DownloadStatus.COMPLETED || task.bookId === '') {
      continue;
    }
    let group: OfflineBookGroup | undefined = groupMap.get(task.bookId);
    if (group === undefined) {
      const cover: string = coverByBook !== undefined && typeof coverByBook[task.bookId] === 'string'
        ? coverByBook[task.bookId] : '';
      const bytes: number = typeof sizeByBook[task.bookId] === 'number'
        ? sizeByBook[task.bookId] : 0;
      group = {
        bookId: task.bookId,
        bookTitle: task.bookTitle !== '' ? task.bookTitle : `离线漫画 #${task.bookId}`,
        coverUrl: cover,
        chapters: [],
        totalBytes: bytes,
        latestUpdatedAt: task.updatedAt
      };
      groupMap.set(task.bookId, group);
    }
    group.chapters.push({
      chapterId: task.chapterId,
      chapterTitle: task.chapterTitle !== '' ? task.chapterTitle : `章节 #${task.chapterId}`,
      totalImages: task.totalImages,
      completedImages: task.completedImages,
      updatedAt: task.updatedAt
    });
    if (task.updatedAt > group.latestUpdatedAt) {
      group.latestUpdatedAt = task.updatedAt;
    }
  }
  const result: OfflineBookGroup[] = [];
  groupMap.forEach((group: OfflineBookGroup) => {
    group.chapters.sort((a: OfflineBookChapter, b: OfflineBookChapter) => a.updatedAt - b.updatedAt);
    result.push(group);
  });
  result.sort((a: OfflineBookGroup, b: OfflineBookGroup) => b.latestUpdatedAt - a.latestUpdatedAt);
  return result;
}

export function sumOfflineBooksBytes(groups: OfflineBookGroup[]): number {
  let total: number = 0;
  for (let i = 0; i < groups.length; i++) {
    total += Math.max(0, groups[i].totalBytes);
  }
  return total;
}

export async function deleteAllOfflineResources(manager: DownloadManager): Promise<number> {
  return await manager.deleteAllOfflineResources();
}

export async function deleteOfflineBook(manager: DownloadManager, bookId: string): Promise<void> {
  await manager.deleteBook(bookId);
}
