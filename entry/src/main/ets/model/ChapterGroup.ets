/**
 * ChapterGroup.ets —— 章节分组实体（Phase 11 新增）
 *
 * 协议依据（API_PROTOCOL_AUDIT.md 附录 A.3）：
 * `chapters.categories: [{id,name}]` 定义分组顺序与标题，
 * `chapters.data[categoryId]: [{id,name,sort,count,created_at}]` 是该组的章节。
 * 首方 Web 端用 Tabs 按 categories 顺序渲染，组内默认按 `sort` 数值升序。
 *
 * 与既有 `Chapter` 的关系：不重复定义章节字段；
 * `ComicDetail.chapters` 仍是按「分组顺序 + 组内 sort」拍平的只读视图（向后兼容），
 * 本类保存分组结构供目录 UI 展开/折叠使用。
 */
import { Chapter } from './Chapter';

@ObservedV2
export class ChapterGroup {
  /** 分组 id（对应 categories[].id，同时是 data 的 key） */
  @Trace id: string = '';
  /** 分组名称（categories[].name）；服务端缺失时用「章節 #id」兜底，不编造名称 */
  @Trace name: string = '';
  /** 本组章节（已按 sort 升序；sort 缺失时保留服务端原始顺序） */
  @Trace chapters: Chapter[] = [];
  /** 是否展开（UI 状态；由 ComicDetailViewModel 统一管理） */
  @Trace isExpanded: boolean = true;

  constructor(id: string = '', name: string = '', chapters: Chapter[] = []) {
    this.id = id;
    this.name = name;
    this.chapters = chapters;
  }

  /** 本组章节数（不缓存，避免与 chapters 不同步） */
  get count(): number {
    return this.chapters.length;
  }
}
