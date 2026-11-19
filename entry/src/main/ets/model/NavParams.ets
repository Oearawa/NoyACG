/**
 * NavParams.ets —— 路由参数载体与搜索范围常量（Phase 14-J3）
 *
 * 为什么单独抽文件：
 * - 系统路由（route_map.json + pushPathByName）的参数是 `object`，接收端必须做
 *   `instanceof` 类型收窄。把参数类型集中定义，避免首页 / 搜索页各自造一份结构。
 * - 搜索范围 `mode` 的协议取值来自首方前端搜索页的下拉选项
 *   （官方 bundle `search-*.js`：`[{value:'default',label:'預設'},{value:'tag',label:'標籤'},
 *   {value:'author',label:'作者'}]`），官方标签卡片跳转形如
 *   `/search?q=<tag>&mode=tag`。本文件只登记**已证据确认**的取值，不做推测扩展。
 */
import { Comic } from './Comic';

/** 搜索范围：默认（按标题等综合匹配） */
export const SEARCH_MODE_DEFAULT: string = 'default';
/** 搜索范围：按标签匹配（首页关键词 Chips 点击后使用） */
export const SEARCH_MODE_TAG: string = 'tag';
/** 搜索范围：按作者匹配（当前暂无入口，保留协议取值） */
export const SEARCH_MODE_AUTHOR: string = 'author';

/**
 * 归一化搜索范围取值：只接受 default/tag/author，其余（含空串、脏值）回退 default。
 * 绝不把未在协议中确认的取值范围发往服务端。
 */
export function normalizeSearchMode(mode: string): string {
  if (mode === SEARCH_MODE_TAG || mode === SEARCH_MODE_AUTHOR || mode === SEARCH_MODE_DEFAULT) {
    return mode;
  }
  return SEARCH_MODE_DEFAULT;
}

/**
 * 搜索页路由参数。
 * - `keyword` 为**完整关键词**（首页标签原样传入，不按空格拆分，避免复合标签被切碎）；
 * - `mode` 为搜索范围，见上方常量。
 */
export class SearchParam {
  /** 预填关键词（空串 = 打开搜索页后不自动搜索） */
  keyword: string = '';
  /** 搜索范围（default/tag/author） */
  mode: string = SEARCH_MODE_DEFAULT;

  constructor(keyword: string = '', mode: string = SEARCH_MODE_DEFAULT) {
    this.keyword = keyword;
    this.mode = normalizeSearchMode(mode);
  }
}

/** 构造标签搜索参数：关键词原样保留（仅去首尾空白），不拆分空格分段 */
export function buildTagSearchParam(tag: string): SearchParam {
  return new SearchParam(tag.trim(), SEARCH_MODE_TAG);
}

/**
 * 排行榜路由参数（Phase 14-Q）。
 *
 * 首页四个聚合区块的「更多」需要精确落到对应榜单状态：
 *   readDay    → kind=reading,  period=day
 *   favDay     → kind=favorite, period=day
 *   proportion → kind=quality
 * `fs` 不走这里（→ PersonalizedPage）。
 *
 * 这里只承载字符串枚举，取值白名单与归一化在 LeaderboardViewModel 内完成，
 * 避免参数层重复一份协议常量。
 */
export class RankPageParam {
  /** 榜单类型：reading | favorite | quality */
  kind: string = '';
  /** 周期：day | week | moon（quality 忽略） */
  period: string = '';

  constructor(kind: string = '', period: string = '') {
    this.kind = kind;
    this.period = period;
  }
}

/**
 * 首页区块「更多」列表页参数。
 *
 * 数据完全来自 `/api/home` 已返回的数组（readDay / favDay / fs / proportion），
 * 因此列表页**不做分页、不请求新接口**：服务端未提供这些榜单的独立分页接口，
 * 虚构下一页/排序参数会产生「看起来能翻页但其实是假数据」的欺骗性 UI。
 */
export class SectionListParam {
  /** 区块标题（沿用首页已确认的区块名） */
  title: string = '';
  /** 区块内容（保持服务端排序，原样传递，不去重不重排） */
  comics: Comic[] = [];

  constructor(title: string = '', comics: Comic[] = []) {
    this.title = title;
    this.comics = comics;
  }
}
