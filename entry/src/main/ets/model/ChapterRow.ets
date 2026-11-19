/**
 * ChapterRow.ets —— 章节目录的懒加载行模型（Phase 11 新增）
 *
 * 为什么需要：分组头 + 章节行共用一个 List + LazyForEach，
 * 才能做到「大量章节只创建可视区节点」；若外层 List 嵌套内层 List，
 * 会有滚动冲突且分组头无法随章节一起懒加载。
 *
 * 行类型是**判别联合**（kind 区分），不是把 Chapter 强转成头行：
 * - GROUP_HEADER：groupId / name / isExpanded / 章节数；
 * - CHAPTER：持有 Chapter 引用，点击时携带 bookId + chapterId 进入阅读器。
 *
 * key 生成规则：分组头 `g:{groupId}`，章节 `c:{groupId}/{chapterId}`，
 * 保证「不同分组之间的相同章节 id」不会互相冲突。
 */
import { Chapter } from './Chapter';

export enum ChapterRowKind {
  GROUP_HEADER = 'group_header',
  CHAPTER = 'chapter'
}

export class ChapterRow {
  readonly kind: ChapterRowKind;
  readonly groupId: string;
  readonly groupName: string;
  readonly chapter: Chapter | null;
  /** 分组是否展开（仅 GROUP_HEADER 有意义） */
  readonly isExpanded: boolean;
  /** 分组内章节总数（仅 GROUP_HEADER 有意义） */
  readonly groupCount: number;
  /** LazyForEach 的稳定唯一 key */
  readonly key: string;

  private constructor(kind: ChapterRowKind, groupId: string, groupName: string,
    chapter: Chapter | null, isExpanded: boolean, groupCount: number, key: string) {
    this.kind = kind;
    this.groupId = groupId;
    this.groupName = groupName;
    this.chapter = chapter;
    this.isExpanded = isExpanded;
    this.groupCount = groupCount;
    this.key = key;
  }

  /** 构造分组头行 */
  static header(groupId: string, name: string, isExpanded: boolean, count: number): ChapterRow {
    return new ChapterRow(ChapterRowKind.GROUP_HEADER, groupId, name, null,
      isExpanded, count, `g:${groupId}`);
  }

  /** 构造章节行（groupId 参与 key，避免跨分组 id 冲突） */
  static item(groupId: string, groupName: string, chapter: Chapter): ChapterRow {
    return new ChapterRow(ChapterRowKind.CHAPTER, groupId, groupName, chapter,
      false, 0, `c:${groupId}/${chapter.id}`);
  }
}
