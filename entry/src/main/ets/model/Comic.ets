/**
 * Comic.ets —— 漫画简略信息实体
 *
 * 用于首页列表、搜索结果、分类列表等「列表场景」的轻量展示单元。
 * 使用状态管理 V2：@ObservedV2 + @Trace，
 * 保证数据被 ViewModel 更新时，UI（LazyForEach 的列表项）能够自动刷新。
 */
/**
 * 作品形态（服务端 `Mode`）：与首方前端 `e.Mode === 1` 判定同源。
 * 只有 `1`（多章节）才有「连载状态」语义；`0` 是单本无章节。
 */
export const COMIC_MODE_UNKNOWN: number = -1;
/** 单本无章节（首方用 cid=0 直接阅读） */
export const COMIC_MODE_SINGLE: number = 0;
/** 多章节（首方详情页/封面卡在此形态下才展示连载状态） */
export const COMIC_MODE_CHAPTERS: number = 1;

@ObservedV2
export class Comic {
  /** 漫画唯一标识（对应源站的专辑/作品 id） */
  @Trace id: string = '';
  /** 漫画标题 */
  @Trace title: string = '';
  /** 封面图 URL（可能带防盗链，加载时需配合 HttpManager 的 Header 注入） */
  @Trace cover: string = '';
  /** 作者名 */
  @Trace author: string = '';
  /** 分类/标签摘要（以空格分隔的原始串，由 UI 层再拆分渲染） */
  @Trace categories: string = '';
  /** 最新章节标题（列表页常带字段，用于展示「更新至 xx」） */
  @Trace latestChapter: string = '';
  /** 最后更新时间（保留源站原始字符串，由 UI 层统一格式化） */
  @Trace updatedAt: string = '';
  /** 评分和（源站 RatingSUM，展示时 /2 得到 5 分制；0 = 无评分，不显示） */
  @Trace ratingSum: number = 0;
  /** 浏览量（源站 Views；0 = 未知） */
  @Trace views: number = 0;
  /** 收藏量（源站 Favorites；0 = 未知） */
  @Trace favorites: number = 0;
  /** 出版年份（源站 publish_year；空串 = 未知） */
  @Trace publishYear: string = '';
  /** 页数（源站 Len；0 = 未知） */
  @Trace pageCount: number = 0;
  /** 简介（源站 Description；空串 = 未知。列表页 2 行省略展示用） */
  @Trace description: string = '';
  /**
   * 作品形态（源站 `Mode`）：0 = 单本无章节、1 = 多章节、-1 = 未提供/无法识别。
   * 状态角标的**必要条件**：只有 1 才允许出现「连载中 / 已完结」。
   * 证据（首方生产 bundle 2026-11）：
   * - `content-card-*.js`：`e.mode===1 && <StatusBadge status={e.status}/>`
   * - `stream-card-*.js`：`topRight: e.Mode===1 ? (e.Status===0 ? '連載中' : '已完結') : undefined`
   */
  @Trace mode: number = COMIC_MODE_UNKNOWN;
  /**
   * 完整标签列表（源站 `Ptag`，**不做 6 个截断**）。
   * 只用于「重口 / NTR / 大叔」关键词角标的精确匹配；
   * 展示用的标签摘要请用 `categories`（Ptag + Otag，最多 6 个）。
   *
   * 为什么必须与 categories 分开：
   * 1. 截断会漏掉第 7 个及之后的标签（关键词角标误判为「没有」）；
   * 2. `categories` 混入了 Otag（原作名），可能把「原作叫 NTR」误当成题材标签。
   * 首方前端同样只用 `Ptag` 生成警示角标：`warningTags: n(e.Ptag)`。
   */
  @Trace ptag: string[] = [];
  /**
   * 连载状态：`true` = 已完结、`false` = 连载中、`null` = 未知。
   *
   * 由协议层在「`Mode === 1` 且 `Status` 为明确 0/1」时才写入布尔值，
   * 其余一切情况（含 Mode 非 1）都必须是 `null`。
   * UI 层**禁止**用 `isCompleted !== null` 之外的规则反推状态。
   */
  @Trace isCompleted: boolean | null = null;

  constructor(id: string = '', title: string = '', cover: string = '',
    author: string = '', categories: string = '',
    latestChapter: string = '', updatedAt: string = '') {
    this.id = id;
    this.title = title;
    this.cover = cover;
    this.author = author;
    this.categories = categories;
    this.latestChapter = latestChapter;
    this.updatedAt = updatedAt;
  }
}
