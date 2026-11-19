/**
 * ComicDetail.ets —— 漫画详情实体
 *
 * 继承 Comic（列表展示字段），额外携带简介、章节与 Phase 11 补齐的详情元数据。
 *
 * 严格性（任务书 §四）：所有新增字段都对应首方详情分包中**实际读取**的字段
 * （见 API_PROTOCOL_AUDIT.md 附录 A.2）。字段缺失时用「明确的未知值」表达，
 * 绝不把缺失转成 0 分、已完结、空章节等虚假成功数据：
 * - 数值型未知用 -1；布尔/枚举型未知用 null / -1；字符串未知用 ''。
 */
import { Comic, COMIC_MODE_CHAPTERS, COMIC_MODE_SINGLE, COMIC_MODE_UNKNOWN } from './Comic';
import { Chapter } from './Chapter';
import { ChapterGroup } from './ChapterGroup';
import { BookRecommend } from './BookRecommend';
import { BookComment } from './BookComment';

/** 详情数值字段的「未提供」哨兵（与真实的 0 区分） */
export const DETAIL_VALUE_UNKNOWN: number = -1;
/** `Mode` 未知（服务端未给或非 0/1） */
export const BOOK_MODE_UNKNOWN: number = COMIC_MODE_UNKNOWN;
/** `Mode===0`：单本无章节，首方用 cid=0 直接阅读 */
export const BOOK_MODE_SINGLE: number = COMIC_MODE_SINGLE;
/** `Mode===1`：多章节，目录按 categories 分组 */
export const BOOK_MODE_CHAPTERS: number = COMIC_MODE_CHAPTERS;

@ObservedV2
export class ComicDetail extends Comic {
  /** 作品简介 */
  @Trace description: string = '';
  /**
   * 章节列表：按「分组顺序 + 组内 sort 升序」拍平的只读视图。
   * 保留它是为了兼容 Phase 7–10 已接入的 UI 与测试；分组结构看 `groups`。
   */
  @Trace chapters: Chapter[] = [];
  /** 章节分组（空数组 = 该漫画没有章节目录，UI 进入 EMPTY / 单本模式） */
  @Trace groups: ChapterGroup[] = [];

  /** 评分数（首方 RatingSUM，0–10 制，展示时 /2 换算 5 星）；-1 = 未提供 */
  @Trace rating: number = DETAIL_VALUE_UNKNOWN;
  /** 评分人数（RatingCount）；-1 = 未提供 */
  @Trace ratingCount: number = DETAIL_VALUE_UNKNOWN;
  /** 收藏数（Favorites）；-1 = 未提供 */
  @Trace favorites: number = DETAIL_VALUE_UNKNOWN;
  /** 别名（alias）；'' = 未提供 */
  @Trace alias: string = '';
  /** 连载状态：true=已完结 false=连载中 null=未提供（仅在 Mode===1 时有意义） */
  @Trace isCompleted: boolean | null = null;
  /** 出版年份（publish_year，保留源站原始值） */
  @Trace publishYear: string = '';
  /** 作品形态：0=单本无章节 / 1=多章节 / -1=未知 */
  @Trace mode: number = BOOK_MODE_UNKNOWN;
  /** Time 原始时间戳（0 = 未提供）；updatedAt 是它的客户端格式化结果 */
  @Trace updatedAtRaw: number = 0;

  /** 標籤（Ptag） */
  @Trace tags: string[] = [];
  /** 角色（Pname） */
  @Trace characters: string[] = [];
  /** 原作（Otag） */
  @Trace originals: string[] = [];

  /** 本地收藏标记（本地数据库状态，非服务端收藏接口） */
  @Trace isFavorite: boolean = false;

  /** 服务端收藏标记（首方 `F`：当前用户是否已收藏）；null = 未提供（独立于本地 isFavorite） */
  @Trace favorited: boolean | null = null;

  /** 相关推荐（详情响应 `book.recommend[]`，小写下划线字段） */
  @Trace recommend: BookRecommend[] = [];

  /** 首屏评论（详情响应 `comment.data`；官方置顶也在其中） */
  @Trace comments: BookComment[] = [];

  /** 评论总数（`comment.count`，**不含**官方置顶评论） */
  @Trace commentCount: number = 0;

  /** 阅读所需积分（`points.book_price`，字符串，免费书为 "0"）；'' = 未提供 */
  @Trace bookPrice: string = '';

  /** 当前用户积分余额（`points.user_balance`，明文；展示前打码，不写日志）；'' = 未提供 */
  @Trace userBalance: string = '';

  constructor(id: string = '', title: string = '', cover: string = '') {
    super(id, title, cover);
  }

  /** 是否存在可展示的章节目录 */
  get hasChapters(): boolean {
    return this.chapters.length > 0;
  }

  /** 是否「单本无章节」形态（首方 Mode===0 时用 cid=0 阅读） */
  get isSingleBook(): boolean {
    return this.mode === BOOK_MODE_SINGLE;
  }
}
