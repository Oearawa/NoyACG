/**
 * ReaderParam.ets —— 阅读器路由参数实体
 *
 * 阶段六引入：阅读器保存历史需要「漫画 ID + 章节 ID + 章节标题」，
 * 且断点续传需要起始页码，纯字符串 chapterId 已不满足，升级为结构化参数。
 * （ComicReaderBuilder 保留对旧字符串参数的兼容分支）
 */
import { ReaderChapterItem } from '../reader/ReaderTypes';

export class ComicReaderParam {
  /** 所属漫画 id（历史记录主键） */
  readonly comicId: string;
  /** 章节 id */
  readonly chapterId: string;
  /** 章节标题（历史记录展示用） */
  readonly chapterTitle: string;
  /** 断点续传起始页（1 起；默认 1 = 从头阅读） */
  readonly startPage: number;
  /** 可选章节目录（供阅读器章节抽屉与上一话/下一话切换） */
  readonly chapters: ReaderChapterItem[];

  constructor(
    comicId: string,
    chapterId: string,
    chapterTitle: string,
    startPage: number = 1,
    chapters: ReaderChapterItem[] = []
  ) {
    this.comicId = comicId;
    this.chapterId = chapterId;
    this.chapterTitle = chapterTitle;
    this.startPage = startPage;
    this.chapters = chapters;
  }
}
