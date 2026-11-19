/**
 * HomeFeed.ets —— 首页聚合数据实体（POST /api/home）
 *
 * Phase 14-I 新增：首页不再只有「最新推荐」一个区块，接入服务端一次返回的聚合数据：
 * 公告、日收藏榜、日阅读榜、推荐位、高质量推荐、动画（stream）、标签。
 *
 * 字段语义严格依据首方实测文档（API-Collect docs/home.md，2026-10-27 实测）：
 * - `favDay` / `readDay` 是明确的两个榜单（日收藏榜 / 日阅读榜）；
 * - `fs` 为「推荐位」、`proportion` 为「高质/编辑推荐」，二者**排序规则未确认**，
 *   因此模型注释与 UI 文案均不把它们命名为确定的「排行榜类型」；
 * - `stream` 仅当请求体带 `v=3` 时返回；`tags` 随 allow-adult 分级变化，不可假设固定。
 */
import { Comic } from './Comic';

/** 顶部公告（首方 `bulletin`：`{ text, show }`） */
@ObservedV2
export class Bulletin {
  /** 公告文案（运营内容，可能频繁变更，不做字符串匹配） */
  @Trace text: string = '';
  /** 是否展示（首方前端目前隐藏该区域，本 App 尊重 `show` 字段） */
  @Trace show: boolean = false;

  constructor(text: string = '', show: boolean = false) {
    this.text = text;
    this.show = show;
  }
}

/**
 * 动画 / 流媒体推荐条目（首方 `stream[]`，仅 `v=3` 时存在）。
 * 注意：`Book` 用大写字段（`F`/`Views`），`Stream` 用小写（`f`/`views`），是服务端原样返回。
 */
@ObservedV2
export class StreamItem {
  /** 剧集 id（sid；封面走 stream CDN，路径用该 id） */
  @Trace id: string = '';
  /** 剧名 */
  @Trace title: string = '';
  /** 剧情简介（可能很长，含换行与版权声明） */
  @Trace description: string = '';
  /** 标签（逗号分隔，与 Book.Ptag 的空格分隔不同） */
  @Trace tags: string = '';
  /** 封面地址（客户端按 `stream.noyteam.online/{sid}/cover.webp` 拼装） */
  @Trace cover: string = '';
  /** 播放量（views） */
  @Trace views: number = 0;
  /** 收藏数（favorites） */
  @Trace favorites: number = 0;
  /** 总集数（count） */
  @Trace count: number = 0;
  /** 是否收藏（小写 `f`，当前用户） */
  @Trace favorited: boolean = false;
  /** 最后更新时间（up_time，unix 秒，客户端已格式化；'' = 未提供） */
  @Trace updatedAt: string = '';

  constructor() {
  }
}

/**
 * 首页聚合数据。
 * 各榜单条目数为服务端决定（`proportion` 甚至在同账号间 16~20 波动），
 * 因此**所有列表字段都允许为空数组**，绝不假设固定长度、绝不生成 Mock 内容。
 */
@ObservedV2
export class HomeFeed {
  /** 顶部公告 */
  @Trace bulletin: Bulletin = new Bulletin();
  /** 日收藏榜 */
  @Trace favDay: Comic[] = [];
  /** 日阅读榜 */
  @Trace readDay: Comic[] = [];
  /** 推荐位（排序规则未确认） */
  @Trace fs: Comic[] = [];
  /** 高质量推荐（规则未确认） */
  @Trace proportion: Comic[] = [];
  /** 动画 / 流媒体推荐（仅 v=3） */
  @Trace stream: StreamItem[] = [];
  /** 当前分级下可用标签 */
  @Trace tags: string[] = [];

  constructor() {
  }
}
