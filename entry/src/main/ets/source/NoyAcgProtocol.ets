/**
 * NoyAcgProtocol.ets —— NoyAcg 数据协议层（纯函数：字段映射 / 分页判定 / 鉴权识别）
 *
 * 分层目的：
 *   NoyAcgSource（传输编排） → 本文件（协议映射） → model（UI 模型）
 * 本文件不发起任何网络请求，也不依赖 UI，因此可以用真实/派生 Fixture 做纯解析测试，
 * 不必为了测试去 mock HttpManager。
 *
 * 协议证据（详见 API_PROTOCOL_AUDIT.md）：
 * - 搜索：POST /api/v4/search/fetch，表单 value/mode/sort/type/page/finished，
 *   响应 { data: [...], count: N }，条目字段为**小写下划线**（id/name/rating_sum/...）；
 * - 书单：POST /api/b1/booklist，表单 page/sort/finished，
 *   响应 { info: [...], len: N }，条目字段为**帕斯卡命名**（Bid/Bookname/RatingSUM/...）；
 * - 未登录：HTTP 200 + { "status": "login" }（已用真实请求复现）。
 *
 * 两个列表接口的字段命名不同是实测结论，不能合并成同一套字段猜测。
 */
import { Comic, COMIC_MODE_CHAPTERS, COMIC_MODE_SINGLE, COMIC_MODE_UNKNOWN } from '../model/Comic';
import {
  ComicDetail,
  DETAIL_VALUE_UNKNOWN
} from '../model/ComicDetail';
import { Chapter } from '../model/Chapter';
import { ChapterGroup } from '../model/ChapterGroup';
import { PageInfo } from '../model/PageInfo';
import { Bulletin, HomeFeed, StreamItem } from '../model/HomeFeed';
import { AdItem } from '../model/AdItem';
import { BookRecommend } from '../model/BookRecommend';
import { BookComment, CommentPage } from '../model/BookComment';
import { UserBadge, UserInfo } from '../model/UserInfo';
import { LocalizationManager } from '../utils/LocalizationManager';
import { FavoriteClass } from '../model/FavoriteClass';
import {
  MSG_TYPE_COMMUNITY_REPLY,
  MSG_TYPE_REPLY,
  MSG_TYPE_SYSMSG,
  MessageCount,
  MessageItem
} from '../model/Message';
import { AuthRequiredError, ProtocolError } from '../api/ApiErrors';
import { Logger } from '../utils/Logger';
import {
  BigTagItem,
  SERVER_LEN_UNKNOWN,
  bigTagKey,
  buildBigTagQuery,
  normalizeServerLen,
  serverTotalPages
} from '../model/LeaderboardModels';

const TAG: string = 'NoyAcgProtocol';

/** 图片 CDN（封面 / 内页同源，实测匿名可访问） */
export const NOY_IMG_ORIGIN: string = 'https://img.noymanga.com';
/** 动画（stream）封面 CDN */
export const NOY_STREAM_ORIGIN: string = 'https://stream.noyteam.online';
/** 列表接口固定分页大小（Web 端常量 X=20） */
export const NOY_PAGE_SIZE: number = 20;

/**
 * allow-adult 内容分级取值（首方请求头，Phase 14-I 起首页/广告/搜索/详情统一显式传递）。
 * 首方实测（2026-10-26）：false/true 是**两套互斥内容池**（榜单零交集），both 是并集；
 * `/api/home` **不传头等同 true（默认返回 R18）**，因此本 App 必须显式传，默认 false（全年龄）。
 */
export const ALLOW_ADULT_FALSE: string = 'false';
export const ALLOW_ADULT_TRUE: string = 'true';
export const ALLOW_ADULT_BOTH: string = 'both';
/** 应用默认内容分级：全年龄（安全默认，可由 PreferenceManager.contentRating 覆盖） */
export const ALLOW_ADULT_DEFAULT: string = ALLOW_ADULT_FALSE;

/**
 * 书单排序值（审计文档「API 协议」booklist 表：sort 参数）。
 * 只暴露审计已记录的值，不新增未验证的排序维度（如「最近上传」无对应值 → 缺失）。
 */
export const BOOKLIST_SORT_NEW: string = 'new';
export const BOOKLIST_SORT_VIEWS: string = 'views';
export const BOOKLIST_SORT_FAVORITES: string = 'favorites';
export const BOOKLIST_SORT_RATING: string = 'rating';

/** 书单完结筛选（finished 参数）：空=全部 / true=已完结 / false=连载中 */
export const BOOKLIST_FINISHED_ALL: string = '';
export const BOOKLIST_FINISHED_COMPLETED: string = 'true';
export const BOOKLIST_FINISHED_ONGOING: string = 'false';

/**
 * 构造书单请求表单（page/sort/finished）。
 * 独立纯函数便于对「排序 / 筛选 → 表单字段」映射做无网络单测。
 * 非法 sort/finished 一律回退到安全默认值（new / ''），不把未验证值发给服务端。
 */
export function buildBookListForm(page: number, sort?: string, finished?: string): Record<string, string> {
  const validSort: string[] =
    [BOOKLIST_SORT_NEW, BOOKLIST_SORT_VIEWS, BOOKLIST_SORT_FAVORITES, BOOKLIST_SORT_RATING];
  const s: string = sort !== undefined && validSort.indexOf(sort) >= 0 ? sort : BOOKLIST_SORT_NEW;
  const validFinished: string[] =
    [BOOKLIST_FINISHED_ALL, BOOKLIST_FINISHED_COMPLETED, BOOKLIST_FINISHED_ONGOING];
  const f: string = finished !== undefined && validFinished.indexOf(finished) >= 0
    ? finished : BOOKLIST_FINISHED_ALL;
  return {
    'page': String(page),
    'sort': s,
    'finished': f
  };
}

/** 未登录标记：服务端用 HTTP 200 + 该字段表达，而不是 401 */
const STATUS_LOGIN: string = 'login';

// ==================== 原始响应结构 ====================

/** 搜索条目：字段来源 search-*.js 中 Y(e) 映射函数 */
export interface RawSearchItem {
  id?: number | string;
  name?: string;
  author?: string;
  description?: string;
  tags?: string[];
  pname?: string[];
  otag?: string[];
  views?: number;
  favorites?: number;
  rating_sum?: number;
  adult?: boolean;
  /** 搜索条目的形态字段是小写（首方 search-*.js：`mode: e.mode`），类型可能为数字或字符串 */
  mode?: number | string;
  status?: number | string;
  publish_year?: number | string;
  source?: string;
}

/** 搜索响应：{ status?, data: [], count } */
export interface RawSearchEnvelope {
  status?: string;
  data?: RawSearchItem[];
  count?: number;
}

/** 书单条目：字段来源 book-list-*.js 中 m(e) 映射函数（帕斯卡命名）。Ptag/Pname/Otag 兼容空格分隔字符串与数组两种形态。 */
export interface RawBookListItem {
  Bid?: number | string;
  Bookname?: string;
  Author?: string;
  Description?: string;
  Ptag?: string | string[];
  Pname?: string | string[];
  Otag?: string | string[];
  Views?: number;
  Favorites?: number;
  RatingSUM?: number;
  Adult?: boolean | number | string;
  /** 作品形态：0 = 单本、1 = 多章节；服务端可能以数字或数字字符串返回 */
  Mode?: number | string;
  Status?: boolean | number | string;
  publish_year?: number | string;
  Len?: number;
}

/** 书单响应：{ status?, info: [], len } */
export interface RawBookListEnvelope {
  status?: string;
  info?: RawBookListItem[];
  len?: number;
}

// ==================== 鉴权与校验 ====================

/**
 * 识别「需要登录」：NoyAcg 用 200 + status=login 表达未登录/登录失效。
 * 命中即抛出 AuthRequiredError，让 UI 能给出明确提示而非「解析失败」。
 */
export function ensureAuthorized(status: string | undefined): void {
  if (status === STATUS_LOGIN) {
    throw new AuthRequiredError(LocalizationManager.getInstance().getString(
      $r('app.string.auth_session_required'),
      '登录已失效或未登录：NoyAcg 需要账号会话才能读取数据'
    ));
  }
}

/** 数值字段兼容 number / 数字字符串（服务端不同接口返回类型不一致） */
function toNumber(value: number | string | undefined): number {
  if (typeof value === 'number') {
    return value;
  }
  if (typeof value === 'string') {
    const parsed: number = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

/** id 类字段兼容 number / string，统一为字符串；空值返回 ''（由调用方决定是否跳过） */
function toId(value: number | string | undefined): string {
  if (value === undefined || value === null) {
    return '';
  }
  return String(value);
}

/**
 * 严格数值解析：只接受有限数值或纯数字字符串，缺失/脏值返回 undefined。
 * 与 `toNumber`（脏值→0）区分：详情元数据必须能表达「未提供」，不能伪装成 0 分 / 0 人。
 */
function toFiniteNumber(value: number | string | undefined): number | undefined {
  if (typeof value === 'number') {
    return Number.isFinite(value) ? value : undefined;
  }
  if (typeof value === 'string' && value.trim() !== '') {
    const parsed: number = Number(value);
    return Number.isFinite(parsed) ? parsed : undefined;
  }
  return undefined;
}

/** 严格文本：非字符串一律视为「未提供」，避免把对象/数组渲染成 [object Object] */
function toText(value: string | number | boolean | undefined): string {
  return typeof value === 'string' ? value : '';
}

/**
 * 时间戳归一化（首方 `kt(e)`：`e < 0xe8d4a51000 ? e*1000 : e`），再转 `YYYY-MM-DD`。
 * 这是**客户端展示格式**，不是服务端字段；无法解析时返回空串（不编造日期）。
 */
function formatTimestamp(value: number | string | undefined): string {
  const raw: number | undefined = toFiniteNumber(value);
  if (raw === undefined || raw <= 0) {
    return '';
  }
  const ms: number = raw < 1e11 ? raw * 1000 : raw;
  let date: Date;
  try {
    date = new Date(ms);
  } catch (e) {
    return '';
  }
  const year: number = date.getFullYear();
  const month: number = date.getMonth() + 1;
  const day: number = date.getDate();
  if (!Number.isFinite(year) || year <= 1970) {
    return '';
  }
  const mm: string = month < 10 ? `0${month}` : String(month);
  const dd: string = day < 10 ? `0${day}` : String(day);
  return `${year}-${mm}-${dd}`;
}

/** 标签数组归一化：兼容 string（空格分隔）与 string[] 两种形态，非预期类型返回空数组 */
function toStringArray(value: string | string[] | undefined): string[] {
  let parts: string[] = [];
  if (typeof value === 'string') {
    parts = value.split(/\s+/);
  } else if (Array.isArray(value)) {
    parts = value;
  } else {
    return [];
  }
  const result: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    const tag: string = typeof parts[i] === 'string' ? parts[i].trim() : '';
    if (tag !== '') {
      result.push(tag);
    }
  }
  return result;
}

/**
 * 封面地址规则（与 Web 端一致）：
 * 1. source === 'stream' → 动画封面走 stream CDN，且路径使用 id 的相反数；
 * 2. source 本身是 http(s) 地址 → 直接用；
 * 3. 其余 → `${IMG}/${id}/m1.webp`（实测可匿名访问，返回 image/webp）。
 */
export function buildCoverUrl(id: string, source?: string): string {
  const trimmed: string = typeof id === 'string' ? id.trim() : '';
  if (trimmed === '') {
    return '';
  }
  if (source === 'stream') {
    const numeric: number = toNumber(trimmed);
    if (numeric === 0) {
      return '';
    }
    const streamId: number = numeric > 0 ? -numeric : numeric;
    return `${NOY_STREAM_ORIGIN}/${streamId}/cover.webp`;
  }
  if (source !== undefined && (source.startsWith('http://') || source.startsWith('https://'))) {
    return source;
  }
  if (trimmed === '0' || trimmed.startsWith('-')) {
    return '';
  }
  return `${NOY_IMG_ORIGIN}/${trimmed}/m1.webp`;
}

/** 标签摘要：tags + otag 去重后最多 6 个，空格分隔（与 Web 端展示密度一致） */
function buildCategories(tags?: string | string[], otag?: string | string[]): string {
  const merged: string[] = [];
  const append = (value?: string | string[]): void => {
    if (value === undefined || value === null) {
      return;
    }
    // 首方实测：榜单/详情响应里的 Ptag/Otag 是**空格分隔字符串**（不是数组）；
    // 历史派生 fixture 曾按数组建模，因此这里同时兼容 string 与 string[] 两种形态。
    let parts: string[] = [];
    if (typeof value === 'string') {
      parts = value.split(/\s+/);
    } else if (Array.isArray(value)) {
      parts = value;
    } else {
      return; // 其它类型（对象/数字）一律忽略，不伪造标签
    }
    for (let i = 0; i < parts.length; i++) {
      const tag: string = typeof parts[i] === 'string' ? parts[i].trim() : '';
      if (tag !== '' && merged.indexOf(tag) < 0) {
        merged.push(tag);
      }
    }
  };
  append(tags);
  append(otag);
  return merged.slice(0, 6).join(' ');
}

// ==================== 映射与分页 ====================

/**
 * 作品形态映射（Phase 14-T）：`Mode === 1` 才视为「多章节」。
 *
 * 证据（首方生产 bundle，2026-11 实取）：
 * - `stream-card-*.js`：`topRight: e.Mode===1 ? (e.Status===0 ? '連載中' : '已完結') : undefined`
 * - `content-card-*.js`：`e.mode===1 && <StatusBadge status={e.status} />`
 * - `manga-detail-*.js`：`W.Mode===1 && '連載狀態: ' + (W.Status ? '已完結' : '連載中')`
 *
 * 也就是说「连载状态」只在多章节作品上有业务含义；单本（0）与缺失/脏值一律不参与判定。
 * 数字与数字字符串等价（服务端不同接口类型不一致，历史审计已记录）。
 */
export function parseComicMode(value: number | string | undefined): number {
  if (typeof value === 'number') {
    if (value === 0) {
      return COMIC_MODE_SINGLE;
    }
    if (value === 1) {
      return COMIC_MODE_CHAPTERS;
    }
    return COMIC_MODE_UNKNOWN;
  }
  if (typeof value === 'string') {
    const normalized: string = value.trim();
    if (normalized === '0') {
      return COMIC_MODE_SINGLE;
    }
    if (normalized === '1') {
      return COMIC_MODE_CHAPTERS;
    }
  }
  return COMIC_MODE_UNKNOWN;
}

/**
 * 统一的「连载状态」写入入口（Phase 14-T，全工程唯一）。
 *
 * 规则：**先看 Mode，再看 Status**。
 * - Mode 不是 1（单本 / 未提供 / 无法识别）→ `null`，任何 Status 都不采信；
 * - Mode 是 1 且 Status 为明确 0/1 → `false`（连载中）/ `true`（已完结）；
 * - 其余（缺失 / 空串 / 2 / 'ongoing' / 布尔以外的脏值）→ `null`。
 *
 * 这样 `isCompleted` 一旦非 null，就必然同时满足「多章节 + 明确状态」两个服务端前提，
 * UI 层不需要、也不允许再自行推导。
 */
export function resolveCompletion(mode: number, status: boolean | number | string | undefined): boolean | null {
  if (mode !== COMIC_MODE_CHAPTERS) {
    return null;
  }
  return mapCompletionStatus(status);
}

/** 搜索条目 → Comic（缺 id 视为脏数据，由调用方过滤） */
export function mapSearchItem(raw: RawSearchItem): Comic {
  const id: string = toId(raw.id);
  const comic: Comic = new Comic();
  comic.id = id;
  comic.title = raw.name ?? '';
  comic.author = raw.author ?? '';
  comic.cover = buildCoverUrl(id, raw.source);
  comic.categories = buildCategories(raw.tags, raw.otag);
  // Phase 14-T：搜索条目的形态/状态字段是**小写**（mode/status），
  // 与书单的 Status 一样只承认「Mode === 1 且 Status 明确 0/1」。
  comic.mode = parseComicMode(raw.mode);
  comic.isCompleted = resolveCompletion(comic.mode, raw.status);
  // 关键词角标只读完整 Ptag（搜索接口里叫 tags），不读 Otag / 标题 / 简介
  comic.ptag = toStringArray(raw.tags);
  // latestChapter / updatedAt：搜索响应未提供可信字段，保持空串，不做猜测
  return comic;
}

/** 书单条目 → Comic */
export function mapBookListItem(raw: RawBookListItem): Comic {
  const id: string = toId(raw.Bid);
  const comic: Comic = new Comic();
  comic.id = id;
  comic.title = raw.Bookname ?? '';
  comic.author = raw.Author ?? '';
  comic.cover = buildCoverUrl(id);
  comic.categories = buildCategories(raw.Ptag, raw.Otag);
  comic.ratingSum = toNumber(raw.RatingSUM);
  comic.views = toNumber(raw.Views);
  comic.favorites = toNumber(raw.Favorites);
  comic.publishYear = raw.publish_year === undefined || raw.publish_year === null
    ? '' : String(raw.publish_year);
  comic.pageCount = toNumber(raw.Len);
  // Phase 14-H：映射简介（列表项 2 行省略展示；字段来自书单响应 Description，审计已记录）
  comic.description = typeof raw.Description === 'string' ? raw.Description : '';
  // Phase 14-T：形态 + 状态必须成对解析（首方封面卡 `e.Mode===1` 才渲染状态角标）。
  // 旧实现直接映射 Status，导致单本（Mode=0）与未提供 Mode 的条目也显示「连载中/已完结」。
  comic.mode = parseComicMode(raw.Mode);
  comic.isCompleted = resolveCompletion(comic.mode, raw.Status);
  // 关键词角标只读完整 Ptag（不截断、不混入 Otag）
  comic.ptag = toStringArray(raw.Ptag);
  return comic;
}

/** 计算总页数：count 未知时返回 -1（由调用方按本页条数判定是否还有下一页） */
export function totalPagesOf(total: number): number {
  if (total < 0) {
    return -1;
  }
  return Math.ceil(total / NOY_PAGE_SIZE);
}

/** 由「总数 + 页码 + 本页条数」推导 hasMore，避免服务端不给总页数时死循环 */
function resolveHasMore(page: number, totalPages: number, itemCount: number): boolean {
  if (totalPages > 0) {
    return page < totalPages;
  }
  // 总数未知：以「本页是否满 20 条」作为乐观判断，下一页为空则由 ViewModel 终止
  return itemCount >= NOY_PAGE_SIZE;
}

/**
 * 解析搜索结果。
 * @param envelope 已 JSON.parse 的响应体
 * @param page 本次请求页码（从 1 开始）
 * @throws AuthRequiredError 未登录
 * @throws ProtocolError 结构不符（data 不是数组 / 条目全部缺少 id）
 */
export function parseSearchPage(envelope: RawSearchEnvelope | undefined, page: number): PageInfo<Comic> {
  if (envelope === undefined || envelope === null) {
    throw new ProtocolError('搜索响应为空');
  }
  ensureAuthorized(envelope.status);
  const list: RawSearchItem[] | undefined = envelope.data;
  if (list === undefined) {
    throw new ProtocolError('搜索响应缺少 data 字段');
  }
  if (!Array.isArray(list)) {
    throw new ProtocolError('搜索响应 data 不是数组');
  }
  const comics: Comic[] = [];
  for (let i = 0; i < list.length; i++) {
    const item: RawSearchItem = list[i];
    if (item === undefined || item === null) {
      continue;
    }
    const comic: Comic = mapSearchItem(item);
    if (comic.id === '') {
      continue; // 无 id 无法作为列表 key，直接丢弃
    }
    comics.push(comic);
  }
  if (list.length > 0 && comics.length === 0) {
    throw new ProtocolError('搜索响应条目全部缺少 id，无法渲染列表');
  }
  const total: number = toNumber(envelope.count);
  const totalPages: number = envelope.count === undefined ? -1 : totalPagesOf(total);
  return new PageInfo<Comic>(page, totalPages, comics,
    resolveHasMore(page, totalPages, comics.length));
}

/**
 * 解析书单（最新/分类）结果。
 * 注意响应包装是 { info, len }，与搜索的 { data, count } 不同。
 */
export function parseBookListPage(envelope: RawBookListEnvelope | undefined, page: number): PageInfo<Comic> {
  if (envelope === undefined || envelope === null) {
    throw new ProtocolError('书单响应为空');
  }
  ensureAuthorized(envelope.status);
  const list: RawBookListItem[] | undefined = envelope.info;
  if (list === undefined) {
    throw new ProtocolError('书单响应缺少 info 字段');
  }
  if (!Array.isArray(list)) {
    throw new ProtocolError('书单响应 info 不是数组');
  }
  const comics: Comic[] = [];
  for (let i = 0; i < list.length; i++) {
    const item: RawBookListItem = list[i];
    if (item === undefined || item === null) {
      continue;
    }
    const comic: Comic = mapBookListItem(item);
    if (comic.id === '') {
      continue;
    }
    comics.push(comic);
  }
  if (list.length > 0 && comics.length === 0) {
    throw new ProtocolError('书单响应条目全部缺少 Bid，无法渲染列表');
  }
  const total: number = toNumber(envelope.len);
  const totalPages: number = envelope.len === undefined ? -1 : totalPagesOf(total);
  return new PageInfo<Comic>(page, totalPages, comics,
    resolveHasMore(page, totalPages, comics.length));
}


// ==================== 榜单 / 推荐 / 分类（Phase 14-Q） ====================

/**
 * 榜单 / 个性化推荐响应：`{ status, info: Book[], len }`。
 * 证据：首方 rankings-CYXAJkYb.js / proportion-*.js / recommend-*.js 均消费 `.info` 与 `.len`。
 * `len` 可能是 number 或数字字符串（未取得登录态响应，故两种都兼容并按严格规则校验）。
 */
export interface RawLeaderboardEnvelope {
  status?: string;
  info?: RawBookListItem[];
  len?: number | string | null;
}

/** 分类目录条目：`{ tag, search, cover }`；cover 是漫画 Bid（不是分类 ID）。 */
export interface RawBigTagItem {
  tag?: string;
  search?: string[] | string | null;
  cover?: number | string | null;
}

/** 分类目录响应：`{ status, data: [...] }`。 */
export interface RawBigTagEnvelope {
  status?: string;
  data?: RawBigTagItem[];
}

/** 分类 search 字段兼容 string[] 与空格分隔字符串；其余类型忽略。 */
function normalizeTagSearch(value: string[] | string | null | undefined): string[] {
  if (value === undefined || value === null) {
    return [];
  }
  const parts: string[] = [];
  const push = (raw: string): void => {
    const text: string = raw.trim();
    if (text !== '' && parts.indexOf(text) < 0) {
      parts.push(text);
    }
  };
  if (typeof value === 'string') {
    const split: string[] = value.split(/\s+/);
    for (let i = 0; i < split.length; i++) {
      push(split[i]);
    }
    return parts;
  }
  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i++) {
      const item: string = typeof value[i] === 'string' ? value[i] : '';
      push(item);
    }
  }
  return parts;
}

/** cover → 漫画 Bid；非正整数（含 0）一律视为缺失（返回 -1），不伪造封面。 */
function normalizeCoverBid(value: number | string | null | undefined): number {
  const parsed: number = normalizeServerLen(value);
  return parsed <= 0 ? SERVER_LEN_UNKNOWN : parsed;
}

/**
 * 解析榜单 / 个性化推荐分页。
 *
 * 与 `parseBookListPage` 的区别：
 * - `len` 走严格解析（`normalizeServerLen`），无法解析时置为「未知」，**不静默当 0 条**；
 * - 总页数按首方规则 `Math.max(1, ceil(len / 20))`；
 * - `PageInfo.totalCount` 承载服务端总量，供 PaginationBar 以 serverTotal 口径展示。
 *
 * @throws AuthRequiredError status=login
 * @throws ProtocolError 响应为空 / info 结构不符 / 条目全部缺少 Bid
 */
export function parseLeaderboardPage(envelope: RawLeaderboardEnvelope | undefined,
  page: number): PageInfo<Comic> {
  if (envelope === undefined || envelope === null) {
    throw new ProtocolError('榜单响应为空');
  }
  ensureAuthorized(envelope.status);
  const list: RawBookListItem[] | undefined = envelope.info;
  if (list === undefined) {
    throw new ProtocolError('榜单响应缺少 info 字段');
  }
  if (!Array.isArray(list)) {
    throw new ProtocolError('榜单响应 info 不是数组');
  }
  const comics: Comic[] = [];
  for (let i = 0; i < list.length; i++) {
    const item: RawBookListItem = list[i];
    if (item === undefined || item === null) {
      continue;
    }
    const comic: Comic = mapBookListItem(item);
    if (comic.id === '') {
      continue;
    }
    comics.push(comic);
  }
  if (list.length > 0 && comics.length === 0) {
    throw new ProtocolError('榜单响应条目全部缺少 Bid，无法渲染列表');
  }
  const totalCount: number = normalizeServerLen(envelope.len);
  const totalPages: number = totalCount === SERVER_LEN_UNKNOWN
    ? -1 : serverTotalPages(totalCount, NOY_PAGE_SIZE);
  const hasMore: boolean = totalPages > 0 ? page < totalPages : comics.length >= NOY_PAGE_SIZE;
  return new PageInfo<Comic>(page, totalPages, comics, hasMore, totalCount);
}

/**
 * 解析分类目录。
 * - tag 缺失/为空 → 跳过该条目（不伪造分类名）；
 * - search 缺失/为空 → 点击时退回 tag；
 * - cover 缺失/非法 → 无封面（UI 显示占位），不拼虚构 URL；
 * - 重复条目（同 tag 且同 Bid）跳过，保留服务端原始顺序。
 *
 * @throws AuthRequiredError status=login
 * @throws ProtocolError data 不是数组
 */
export function parseBigTagList(envelope: RawBigTagEnvelope | undefined): BigTagItem[] {
  if (envelope === undefined || envelope === null) {
    throw new ProtocolError('分类响应为空');
  }
  ensureAuthorized(envelope.status);
  const data: RawBigTagItem[] | undefined = envelope.data;
  if (data === undefined) {
    throw new ProtocolError('分类响应缺少 data 字段');
  }
  if (!Array.isArray(data)) {
    throw new ProtocolError('分类响应 data 不是数组');
  }
  const result: BigTagItem[] = [];
  const seen: string[] = [];
  for (let i = 0; i < data.length; i++) {
    const raw: RawBigTagItem = data[i];
    if (raw === undefined || raw === null) {
      continue;
    }
    const tag: string = typeof raw.tag === 'string' ? raw.tag.trim() : '';
    if (tag === '') {
      Logger.debug(TAG, `分类目录第${i}条缺少 tag，已跳过`);
      continue;
    }
    const search: string[] = normalizeTagSearch(raw.search);
    const coverBid: number = normalizeCoverBid(raw.cover);
    const key: string = bigTagKey(tag, coverBid);
    if (seen.indexOf(key) >= 0) {
      continue;
    }
    seen.push(key);
    const query: string = buildBigTagQuery(search, tag);
    const cover: string = coverBid > 0 ? buildCoverUrl(String(coverBid)) : '';
    const item: BigTagItem = new BigTagItem(tag, search, coverBid, cover);
    // query 由 search/tag 决定，这里只校验非空，避免产出「点了没反应」的卡片
    if (query === '') {
      continue;
    }
    result.push(item);
  }
  return result;
}


// ==================== 章节图片（/v4/book/detail/{bid}/{cid}） ====================

/**
 * 章节摘要：实际页数在 chapter.this.count，兜底为 data.count。
 * `name` 是首方 `De=U?.name??S?.data.author??''` 中的章节名（⛔ 字段完整结构未验证）。
 */
export interface RawChapterSummary {
  count?: number | string;
  name?: string;
}

export interface RawChapterDetailBody {
  this?: RawChapterSummary;
  next?: RawChapterSummary;
  last?: RawChapterSummary;
}

/** 读图响应的 data：除 count 外首方还读 name（书名）、author（作者） */
export interface RawChapterDataBody {
  count?: number | string;
  name?: string;
  author?: string;
}

export interface RawChapterEnvelope {
  status?: string;
  chapter?: RawChapterDetailBody;
  data?: RawChapterDataBody;
}

/**
 * 读图接口的图片基址（首方 `ct(bid,cid)`，见 API_PROTOCOL_AUDIT.md 附录 A.4）：
 *   `cid !== '0'` → `${img}/{bid}/{cid}/{n}.webp`
 *   `cid === '0'` → `${img}/{bid}/{n}.webp`（**少一级目录**，对应 Mode=0 单本）
 *
 * 单独的导出纯函数，便于对「特殊章节」路径规则做回归测试。
 */
export function buildChapterImageUrl(bid: string, cid: string, page: number): string {
  const base: string = cid === '0'
    ? `${NOY_IMG_ORIGIN}/${bid}`
    : `${NOY_IMG_ORIGIN}/${bid}/${cid}`;
  return `${base}/${page}.webp`;
}

/**
 * 解析章节图片地址列表。
 *
 * 协议依据（首方 `reader-DNCR68yN.js`）：
 * - 页数：`chapter.this.count ?? data.count ?? 0`；
 * - 单页模式图片编号从 **1** 连续递增到页数（首方 `rt()` 的 `o+1<=r` 分支）；
 * - 双页模式（本 App 不实现）才使用 `2k-1 / 2k`；
 * - 路径无签名、无 query 参数。
 *
 * ⚠ 不根据任何 URL 示例推断「完整图片数量」：页数**只**来自响应的 count 字段。
 * ⛔ 成功响应的 count 与真实可访问图片数是否一致，未经真机/账号验证。
 *
 * @throws AuthRequiredError 未登录
 * @throws ProtocolError 参数缺失 / 结构不符
 */
export function parseChapterImages(envelope: RawChapterEnvelope | undefined,
  bookId: string, chapterId: string): string[] {
  const bid: string = bookId.trim();
  const cid: string = chapterId.trim();
  if (bid === '' || cid === '') {
    throw new ProtocolError('读取章节图片需要「书籍 id + 章节 id」两个参数');
  }
  if (envelope === undefined || envelope === null) {
    throw new ProtocolError('章节响应为空');
  }
  ensureAuthorized(envelope.status);
  const chapterCount: number | string | undefined = envelope.chapter === undefined
    ? undefined : (envelope.chapter.this === undefined ? undefined : envelope.chapter.this.count);
  const dataCount: number | string | undefined = envelope.data === undefined
    ? undefined : envelope.data.count;
  const raw: number | string | undefined = chapterCount ?? dataCount;
  const parsed: number | undefined = toFiniteNumber(raw);
  // 页数缺失/非有限值 → 0 张（明确空结果），绝不凭 URL 猜页数
  const count: number = parsed === undefined ? 0 : Math.max(0, Math.floor(parsed));
  const images: string[] = [];
  for (let n = 1; n <= count; n++) {
    images.push(buildChapterImageUrl(bid, cid, n));
  }
  return images;
}

// ==================== JSON 入口（供测试与调试直接喂原始响应） ====================

/**
 * 从原始 JSON 文本解析搜索结果。
 * 非 JSON（例如网关返回 HTML 错误页）统一转 ProtocolError，保留前 120 字符便于定位。
 */
export function parseSearchJson(text: string, page: number): PageInfo<Comic> {
  let envelope: RawSearchEnvelope;
  try {
    envelope = JSON.parse(text) as RawSearchEnvelope;
  } catch (e) {
    throw new ProtocolError(`搜索响应不是合法 JSON: ${text.substring(0, 120)}`);
  }
  try {
    return parseSearchPage(envelope, page);
  } catch (e) {
    Logger.debug(TAG, `搜索响应解析异常: ${(e as Error).message}`);
    throw e as Error; // 保持 AuthRequiredError / ProtocolError 类型语义
  }
}

/** 从原始 JSON 文本解析书单结果 */
export function parseBookListJson(text: string, page: number): PageInfo<Comic> {
  let envelope: RawBookListEnvelope;
  try {
    envelope = JSON.parse(text) as RawBookListEnvelope;
  } catch (e) {
    throw new ProtocolError(`书单响应不是合法 JSON: ${text.substring(0, 120)}`);
  }
  try {
    return parseBookListPage(envelope, page);
  } catch (e) {
    Logger.debug(TAG, `书单响应解析异常: ${(e as Error).message}`);
    throw e as Error;
  }
}

/** 从原始 JSON 文本解析书籍详情 */
export function parseBookDetailJson(text: string, fallbackId: string): ComicDetail {
  let envelope: RawBookDetailEnvelope;
  try {
    envelope = JSON.parse(text) as RawBookDetailEnvelope;
  } catch (e) {
    throw new ProtocolError(`详情响应不是合法 JSON: ${text.substring(0, 120)}`);
  }
  try {
    return parseBookDetail(envelope, fallbackId);
  } catch (e) {
    Logger.debug(TAG, `详情响应解析异常: ${(e as Error).message}`);
    throw e as Error;
  }
}

// ==================== 书籍详情（/v4/book/{id}） ====================

/**
 * 章节信息：详情页按 categories 分组，组内 data 是「分类 id → 章节数组」。
 * 字段来源 manga-detail-CEvtaj1F.js：
 * `categories[].{id,name}`、`data[id][].{id,name,sort,count,created_at}`。
 * 字段类型放宽为「可能的脏值」，由解析器严格判定，避免非预期类型直接流到 UI。
 */
export interface RawChapterInfo {
  id?: number | string;
  name?: string | number;
  sort?: number | string;
  count?: number | string;
  created_at?: string | number;
}

/** 章节分组：{ categories: [{id,name}], data: { [categoryId]: RawChapterInfo[] } } */
export interface RawChapterGroup {
  categories?: RawChapterInfo[];
  data?: Record<string, RawChapterInfo[]>;
}

/**
 * 书籍基础信息（**帕斯卡命名**，与书单条目同实体；搜索条目是小写，三套解析器不可混用）。
 * 字段清单逐项对应首方 `W=f.book.info` 的实际读取（附录 A.2）。
 */
export interface RawBookInfo {
  Bid?: number | string;
  Bookname?: string | number;
  Author?: string | number;
  Description?: string | number;
  alias?: string | number;
  Ptag?: string | string[];
  Pname?: string | string[];
  Otag?: string | string[];
  F?: boolean | number | string;
  Favorites?: number | string;
  RatingSUM?: number | string;
  RatingCount?: number | string;
  RatingBayes?: number | string;
  Mode?: number | string;
  Status?: boolean | number | string;
  publish_year?: number | string;
  Time?: number | string;
  Len?: number | string;
}

/** 相关推荐条目（详情 `book.recommend[]`，小写下划线命名，mode/status 是布尔） */
export interface RawBookRecommend {
  bid?: number | string;
  bookname?: string;
  author?: string;
  tags?: string;
  views?: number | string;
  favorites?: number | string;
  mode?: boolean | number | string;
  status?: boolean | number | string;
}

/**
 * 书籍评论原始结构。字段取「首屏评论」与「评论分页」两种响应的并集：
 * - 主键 `cid`（int/string），`uid` 可能为 int 或 string（官方置顶为 `0`）；
 * - `replies` 是楼中楼（可能只内联前几条），`reply_more` 表示是否还有更多；
 * - `reply`/`reply_text`/`su` 在两种响应里类型不一致，一律按脏值宽容处理。
 */
export interface RawBookComment {
  cid?: number | string;
  uid?: number | string;
  bid?: number | string;
  username?: string;
  avatar?: string;
  avatarUrl?: string;
  su?: number | string;
  content?: string;
  reply_id?: number | string;
  root_id?: number | string;
  reply_uid?: number | string;
  reply_username?: string;
  reply?: number | string;
  reply_text?: string;
  area?: string;
  time?: number | string;
  updated_at?: number | string;
  platform?: string;
  show_badge?: string;
  replies?: RawBookComment[];
  reply_more?: boolean | number | string;
  reply_num?: number | string;
}

/** 评论分页响应 body：{ comments, page, over, top_count } */
export interface RawCommentPageBody {
  comments?: RawBookComment[];
  page?: number | string;
  over?: boolean | number | string;
  top_count?: number | string;
}

/** 评论分页响应包装：{ data: RawCommentPageBody, status } */
export interface RawCommentEnvelope {
  status?: string;
  data?: RawCommentPageBody;
}

/** 首屏评论块：{ count, data }（count 不含官方置顶评论） */
export interface RawCommentBlock {
  count?: number | string;
  data?: RawBookComment[];
}

/** 阅读积分（points）：book_price / user_balance 均为字符串（user_balance 为明文余额，展示前打码） */
export interface RawPoints {
  book_price?: string | number;
  user_balance?: string | number;
}

/** 详情响应：{ status?, uid?, book: { info, recommend, translate }, chapters, comment, points } */
export interface RawBookDetailEnvelope {
  status?: string;
  uid?: number | string;
  book?: RawBookDetailResponseBody;
  chapters?: RawChapterGroup;
  comment?: RawCommentBlock;
  points?: RawPoints;
}

export interface RawBookDetailResponseBody {
  info?: RawBookInfo;
  /** 相关推荐列表（首方 `f.book.recommend.map`） */
  recommend?: RawBookRecommend[];
  /** 用途未知（首方实测恒为空串），本阶段不消费 */
  translate?: string;
}

/**
 * 连载状态映射（Phase 14-I 语义修正，2026-10 首方实测确认；Phase 14-S 收紧）：
 * `Status` 是**整数**：`0` = 连载中、`1` = 已完结；布尔 `false`/`true` 同义。
 *
 * Phase 14-S 修正的缺陷：旧实现把**空字符串**也映射成 `false`（= 连载中），
 * 于是「服务端没给状态」被显示成「连载中」。现在：
 * - 空串 / 纯空白 / 未识别字符串 → `null`（未知，UI 不显示状态角标）；
 * - 只接受数字形态的字符串 `'0'` / `'1'`（与整数协议同源）；
 * - 其它任何取值（2、'ongoing'、'finished'、脏值）→ `null`。
 *
 * 约束：绝不用 `value !== completed` 之类的判断推导「连载中」。
 */
export function mapCompletionStatus(value: boolean | number | string | undefined): boolean | null {
  if (value === undefined || value === null) {
    return null;
  }
  if (typeof value === 'boolean') {
    return value;
  }
  if (typeof value === 'number') {
    return value === 0 ? false : (value === 1 ? true : null);
  }
  if (typeof value === 'string') {
    const normalized: string = value.trim();
    if (normalized === '0') {
      return false;
    }
    if (normalized === '1') {
      return true;
    }
  }
  return null;
}

/** 作品形态：与列表/搜索共用同一解析入口（Phase 14-T 收敛为 `parseComicMode`） */
function mapBookMode(value: number | string | undefined): number {
  return parseComicMode(value);
}

/** 装饰项：保存服务端原始下标，用于 sort 相同时的稳定排序 */
interface IndexedRawChapter {
  raw: RawChapterInfo;
  index: number;
  sort: number | undefined;
}

/**
 * 组内稳定排序：**只按服务端 `sort` 数值升序**。
 * - 绝不使用章节标题字符串排序（避免「第 10 话」排到「第 2 话」前）；
 * - sort 缺失/非数值/相同时，按服务端原始下标保留顺序；
 * - 不假设 sort 连续、不重编号。
 */
function stableSortByServerSort(list: RawChapterInfo[]): RawChapterInfo[] {
  const indexed: IndexedRawChapter[] = [];
  for (let i = 0; i < list.length; i++) {
    const raw: RawChapterInfo = list[i];
    indexed.push({
      raw: raw,
      index: i,
      sort: raw === undefined || raw === null ? undefined : toFiniteNumber(raw.sort)
    });
  }
  indexed.sort((a: IndexedRawChapter, b: IndexedRawChapter): number => {
    const sa: number | undefined = a.sort;
    const sb: number | undefined = b.sort;
    if (sa !== undefined && sb !== undefined && sa !== sb) {
      return sa - sb;
    }
    return a.index - b.index;
  });
  const result: RawChapterInfo[] = [];
  for (let i = 0; i < indexed.length; i++) {
    result.push(indexed[i].raw);
  }
  return result;
}

/**
 * 解析章节分组（导出纯函数，便于只喂 `chapters` 片段做分组/排序回归测试）。
 *
 * 严格性：
 * - categories 非数组 / data 非对象 / 组内非数组 → 该部分为空，**不伪造分组或章节**；
 * - 分组缺 id → 无法定位 data，跳过该分组；
 * - 分组缺 name → 用「分組 #id」客户端兜底文案（明确不是服务端字段）；
 * - 章节缺 id → 跳过（无 id 不能作为阅读器参数与 LazyForEach key）；
 * - 章节缺 name → 用首方 `At()` 的「章節 #id」兜底；
 * - 跨分组同章节 id 允许存在（key 由 groupId+cid 组成，见 ChapterRow）。
 */
export function parseChapterGroups(group: RawChapterGroup | undefined): ChapterGroup[] {
  const result: ChapterGroup[] = [];
  if (group === undefined || group === null) {
    return result;
  }
  const categories: RawChapterInfo[] = Array.isArray(group.categories) ? group.categories : [];
  let data: Record<string, RawChapterInfo[]> = {};
  if (group.data !== undefined && group.data !== null && typeof group.data === 'object') {
    data = group.data;
  }
  for (let i = 0; i < categories.length; i++) {
    const category: RawChapterInfo = categories[i];
    if (category === undefined || category === null) {
      continue;
    }
    const groupId: string = toId(category.id);
    if (groupId === '') {
      continue;
    }
    const groupName: string = toText(category.name) !== ''
      ? toText(category.name) : `分組 #${groupId}`;
    const rawList: RawChapterInfo[] = Array.isArray(data[groupId]) ? data[groupId] : [];
    const sorted: RawChapterInfo[] = stableSortByServerSort(rawList);
    const chapters: Chapter[] = [];
    for (let j = 0; j < sorted.length; j++) {
      const raw: RawChapterInfo = sorted[j];
      if (raw === undefined || raw === null) {
        continue;
      }
      const chapterId: string = toId(raw.id);
      if (chapterId === '') {
        continue;
      }
      const chapterTitle: string = toText(raw.name) !== ''
        ? toText(raw.name) : `章節 #${chapterId}`;
      const count: number | undefined = toFiniteNumber(raw.count);
      // Phase 14-I 语义修正：created_at 是章节创建时间（unix 秒整数，首方 `je()` 本地格式化）。
      // 与 `Time` 一样用 formatTimestamp 转成 YYYY-MM-DD，无法解析时返回空串（不编造日期）。
      const createdAt: string = formatTimestamp(raw.created_at);
      chapters.push(new Chapter(chapterId, chapterTitle, 0, createdAt, false,
        groupId, groupName, toFiniteNumber(raw.sort) ?? 0,
        count === undefined ? 0 : Math.max(0, Math.floor(count))));
    }
    result.push(new ChapterGroup(groupId, groupName, chapters));
  }
  return result;
}

/** 按「分组顺序 + 组内已排好的顺序」拍平为兼容视图，并写入客户端展示序号 */
export function flattenChapters(groups: ChapterGroup[]): Chapter[] {
  const result: Chapter[] = [];
  for (let i = 0; i < groups.length; i++) {
    const chapters: Chapter[] = groups[i].chapters;
    for (let j = 0; j < chapters.length; j++) {
      chapters[j].order = result.length + 1;
      result.push(chapters[j]);
    }
  }
  return result;
}

/**
 * 解析书籍详情。
 *
 * 说明：本接口的成功响应**尚未取得真实抓包**（需登录），结构依据为首方前端
 * `manga-detail-CEvtaj1F.js` 的字段使用（附录 A.2/A.3）。
 * - 缺 `book.info` → `ProtocolError`，不返回空壳详情；
 * - `status=login` → `AuthRequiredError`，不降级成解析错误；
 * - 缺 `chapters` → 空分组 + 空章节（由 ViewModel 进入 EMPTY / 单本模式），不伪造章节；
 * - 所有可选元数据缺失时用明确的未知值（-1 / null / ''），不编造评分、状态或日期。
 */
export function parseBookDetail(envelope: RawBookDetailEnvelope | undefined,
  fallbackId: string): ComicDetail {
  if (envelope === undefined || envelope === null) {
    throw new ProtocolError('详情响应为空');
  }
  ensureAuthorized(envelope.status);
  const body: RawBookDetailResponseBody | undefined = envelope.book;
  const info: RawBookInfo | undefined = body === undefined ? undefined : body.info;
  if (info === undefined || info === null || typeof info !== 'object' || Array.isArray(info)) {
    throw new ProtocolError('详情响应缺少 book.info 字段');
  }

  const detail: ComicDetail = new ComicDetail();
  const id: string = toId(info.Bid);
  detail.id = id === '' ? fallbackId : id;
  detail.title = toText(info.Bookname);
  detail.author = toText(info.Author);
  detail.description = toText(info.Description);
  detail.alias = toText(info.alias);
  detail.cover = buildCoverUrl(detail.id);

  detail.tags = toStringArray(info.Ptag);
  detail.characters = toStringArray(info.Pname);
  detail.originals = toStringArray(info.Otag);
  detail.categories = buildCategories(info.Ptag, info.Otag);

  detail.rating = toFiniteNumber(info.RatingSUM) ?? DETAIL_VALUE_UNKNOWN;
  detail.ratingCount = toFiniteNumber(info.RatingCount) ?? DETAIL_VALUE_UNKNOWN;
  detail.favorites = toFiniteNumber(info.Favorites) ?? DETAIL_VALUE_UNKNOWN;
  // Phase 14-T：先解析 Mode，再按「Mode===1 且 Status 明确」写入状态（与列表/搜索同一入口）
  detail.mode = mapBookMode(info.Mode);
  detail.isCompleted = resolveCompletion(detail.mode, info.Status);
  detail.ptag = toStringArray(info.Ptag);
  detail.updatedAtRaw = toFiniteNumber(info.Time) ?? 0;
  detail.updatedAt = formatTimestamp(info.Time);
  const publishYear: number | undefined = toFiniteNumber(
    typeof info.publish_year === 'number' || typeof info.publish_year === 'string'
      ? info.publish_year : undefined);
  detail.publishYear = publishYear === undefined ? toText(info.publish_year) : String(publishYear);

  // Phase 14-I：服务端收藏状态（F = 当前用户是否已收藏），独立于本地收藏 isFavorite
  detail.favorited = mapFlag(info.F);

  // Phase 14-I：相关推荐（book.recommend，小写下划线字段）
  detail.recommend = mapRecommendList(body === undefined ? undefined : body.recommend);

  // Phase 14-I：首屏评论（comment.count / comment.data；count 不含官方置顶）
  detail.commentCount = envelope.comment === undefined ? 0 : toNumber(envelope.comment.count);
  detail.comments = envelope.comment === undefined
    ? [] : mapCommentList(envelope.comment.data);

  // Phase 14-I：阅读积分（points.book_price / user_balance，均为字符串；user_balance 为明文余额）
  detail.bookPrice = envelope.points === undefined
    ? '' : toText(envelope.points.book_price);
  detail.userBalance = envelope.points === undefined
    ? '' : toText(envelope.points.user_balance);

  detail.groups = parseChapterGroups(envelope.chapters);
  detail.chapters = flattenChapters(detail.groups);
  return detail;
}

// ==================== Phase 14-I：首页聚合 / 广告 / 推荐 / 评论 ====================

/**
 * 布尔/标志位归一化（用于 `F` 等「是否」字段）：boolean、0/1、'true'/'false'/'0'/'1'，
 * 其余返回 null（未知），绝不把未知值编造成已收藏/未收藏。
 */
function mapFlag(value: boolean | number | string | undefined): boolean | null {
  if (value === undefined || value === null) {
    return null;
  }
  if (typeof value === 'boolean') {
    return value;
  }
  if (typeof value === 'number') {
    return value === 0 ? false : (value === 1 ? true : null);
  }
  const normalized: string = value.toLowerCase();
  if (normalized === '' || normalized === '0' || normalized === 'false') {
    return false;
  }
  if (normalized === '1' || normalized === 'true') {
    return true;
  }
  return null;
}

/** 严格 http/https 校验（不依赖 utils，避免协议层引入系统 Kit 依赖，保持纯函数可测） */
function sanitizeHttpUrl(value: string | undefined): string {
  if (typeof value !== 'string') {
    return '';
  }
  const target: string = value.trim();
  const lower: string = target.toLowerCase();
  if (!(lower.startsWith('https://') || lower.startsWith('http://'))) {
    return '';
  }
  if (target.indexOf('@') >= 0) {
    return ''; // 拒绝含用户凭据的 URL
  }
  return target;
}

// ---------------- 首页聚合（POST /api/home） ----------------

/** 顶部公告（首方 `bulletin`） */
export interface RawBulletin {
  text?: string;
  show?: boolean | number | string;
}

/** 动画条目（首方 `stream[]`，小写字段，仅 `v=3` 时存在） */
export interface RawStreamItem {
  sid?: number | string;
  name?: string;
  des?: string;
  tags?: string;
  pages?: string;
  type?: number | string;
  count?: number | string;
  time?: number | string;
  up_time?: number | string;
  f?: boolean | number | string;
  views?: number | string;
  favorites?: number | string;
}

/** 首页聚合响应：{ status, bulletin, favDay, readDay, fs, proportion, stream, tags } */
export interface RawHomeEnvelope {
  status?: string;
  bulletin?: RawBulletin;
  favDay?: RawBookListItem[];
  readDay?: RawBookListItem[];
  fs?: RawBookListItem[];
  proportion?: RawBookListItem[];
  stream?: RawStreamItem[];
  tags?: string | string[];
}

/** 榜单数组 → Comic[]：缺 id 跳过，非数组/缺失按空处理（不假设长度、不 Mock） */
function mapBookArray(list: RawBookListItem[] | undefined): Comic[] {
  const result: Comic[] = [];
  if (list === undefined || !Array.isArray(list)) {
    return result;
  }
  for (let i = 0; i < list.length; i++) {
    const item: RawBookListItem = list[i];
    if (item === undefined || item === null) {
      continue;
    }
    const comic: Comic = mapBookListItem(item);
    if (comic.id !== '') {
      result.push(comic);
    }
  }
  return result;
}

/** 公告映射：非 string 文本、非明确布尔 show 一律安全降级 */
function mapBulletin(raw: RawBulletin | undefined): Bulletin {
  if (raw === undefined || raw === null) {
    return new Bulletin();
  }
  const show: boolean = raw.show === true || raw.show === 1
    || raw.show === '1' || raw.show === 'true';
  return new Bulletin(typeof raw.text === 'string' ? raw.text : '', show);
}

/**
 * 动画条目映射：封面走 stream CDN `{sid}/cover.webp`。
 * 注意：首页 `stream[]` 的 `sid` 直接作为路径（首方 home.md 约定），与
 * `buildCoverUrl` 里「搜索 `source=stream` 用 `-id`」是两套不同实体，不可混用。
 */
function mapStreamItem(raw: RawStreamItem | undefined | null): StreamItem | null {
  if (raw === undefined || raw === null) {
    return null;
  }
  const id: string = toId(raw.sid);
  if (id === '') {
    return null;
  }
  const item: StreamItem = new StreamItem();
  item.id = id;
  item.title = typeof raw.name === 'string' ? raw.name : '';
  item.description = typeof raw.des === 'string' ? raw.des : '';
  item.tags = typeof raw.tags === 'string' ? raw.tags : '';
  item.cover = `${NOY_STREAM_ORIGIN}/${id}/cover.webp`;
  item.views = toNumber(raw.views);
  item.favorites = toNumber(raw.favorites);
  item.count = toNumber(raw.count);
  item.favorited = raw.f === true || raw.f === 1 || raw.f === '1' || raw.f === 'true';
  item.updatedAt = formatTimestamp(raw.up_time);
  return item;
}

function mapStreamList(list: RawStreamItem[] | undefined): StreamItem[] {
  const result: StreamItem[] = [];
  if (list === undefined || !Array.isArray(list)) {
    return result;
  }
  for (let i = 0; i < list.length; i++) {
    const item: StreamItem | null = mapStreamItem(list[i]);
    if (item !== null) {
      result.push(item);
    }
  }
  return result;
}

/**
 * 解析首页聚合响应。
 * - `status=login` → AuthRequiredError；`status=error` → ProtocolError（业务失败）；
 * - 各榜单/stream/tags 全部允许缺失（→ 空），不假设长度、不生成 Mock。
 */
export function parseHomeFeed(envelope: RawHomeEnvelope | undefined): HomeFeed {
  if (envelope === undefined || envelope === null) {
    throw new ProtocolError('首页聚合响应为空');
  }
  ensureAuthorized(envelope.status);
  if (envelope.status === 'error') {
    throw new ProtocolError('首页聚合返回业务错误');
  }
  const feed: HomeFeed = new HomeFeed();
  feed.bulletin = mapBulletin(envelope.bulletin);
  feed.favDay = mapBookArray(envelope.favDay);
  feed.readDay = mapBookArray(envelope.readDay);
  feed.fs = mapBookArray(envelope.fs);
  feed.proportion = mapBookArray(envelope.proportion);
  feed.stream = mapStreamList(envelope.stream);
  feed.tags = toStringArray(envelope.tags);
  return feed;
}

/** 从原始 JSON 文本解析首页聚合（非 JSON 统一转 ProtocolError） */
export function parseHomeFeedJson(text: string): HomeFeed {
  let envelope: RawHomeEnvelope;
  try {
    envelope = JSON.parse(text) as RawHomeEnvelope;
  } catch (e) {
    throw new ProtocolError(`首页聚合响应不是合法 JSON: ${text.substring(0, 120)}`);
  }
  try {
    return parseHomeFeed(envelope);
  } catch (e) {
    Logger.debug(TAG, `首页聚合响应解析异常: ${(e as Error).message}`);
    throw e as Error;
  }
}

// ---------------- 首页广告（POST /api/v3/ads） ----------------

/** 广告条目：{ img, url } */
export interface RawAdItem {
  img?: string;
  url?: string;
}

/** 广告响应：{ data: [{img,url}], status } */
export interface RawAdsEnvelope {
  status?: string;
  data?: RawAdItem[];
}

/**
 * 解析广告列表。
 * - `status=login` → AuthRequiredError；`status=error` → ProtocolError；
 * - `data` 缺失/空数组 → 空列表（**支持空数据**，不生成 Mock）；
 * - img/url 只保留 http/https（非可信跳转指令，见 utils/ExternalLink.ets）。
 */
export function parseAds(envelope: RawAdsEnvelope | undefined): AdItem[] {
  if (envelope === undefined || envelope === null) {
    throw new ProtocolError('广告响应为空');
  }
  ensureAuthorized(envelope.status);
  if (envelope.status === 'error') {
    throw new ProtocolError('广告接口返回业务错误');
  }
  const list: RawAdItem[] | undefined = envelope.data;
  if (list === undefined) {
    return [];
  }
  if (!Array.isArray(list)) {
    throw new ProtocolError('广告响应 data 不是数组');
  }
  const result: AdItem[] = [];
  for (let i = 0; i < list.length; i++) {
    const item: RawAdItem = list[i];
    if (item === undefined || item === null) {
      continue;
    }
    const img: string = sanitizeHttpUrl(item.img);
    const url: string = sanitizeHttpUrl(item.url);
    if (img === '' && url === '') {
      continue; // 完全无效条目丢弃
    }
    result.push(new AdItem(img, url));
  }
  return result;
}

/** 从原始 JSON 文本解析广告 */
export function parseAdsJson(text: string): AdItem[] {
  let envelope: RawAdsEnvelope;
  try {
    envelope = JSON.parse(text) as RawAdsEnvelope;
  } catch (e) {
    throw new ProtocolError(`广告响应不是合法 JSON: ${text.substring(0, 120)}`);
  }
  try {
    return parseAds(envelope);
  } catch (e) {
    Logger.debug(TAG, `广告响应解析异常: ${(e as Error).message}`);
    throw e as Error;
  }
}

// ---------------- 相关推荐（book.recommend[]） ----------------

/** 推荐条目 → BookRecommend（缺 bid 丢弃） */
function mapRecommend(raw: RawBookRecommend | undefined | null): BookRecommend | null {
  if (raw === undefined || raw === null) {
    return null;
  }
  const id: string = toId(raw.bid);
  if (id === '') {
    return null;
  }
  const r: BookRecommend = new BookRecommend();
  r.bid = id;
  r.title = typeof raw.bookname === 'string' ? raw.bookname : '';
  r.author = typeof raw.author === 'string' ? raw.author : '';
  r.tags = typeof raw.tags === 'string' ? raw.tags : '';
  r.cover = buildCoverUrl(id);
  r.views = toNumber(raw.views);
  r.favorites = toNumber(raw.favorites);
  return r;
}

function mapRecommendList(list: RawBookRecommend[] | undefined): BookRecommend[] {
  const result: BookRecommend[] = [];
  if (list === undefined || !Array.isArray(list)) {
    return result;
  }
  for (let i = 0; i < list.length; i++) {
    const item: BookRecommend | null = mapRecommend(list[i]);
    if (item !== null) {
      result.push(item);
    }
  }
  return result;
}

// ---------------- 书籍评论（首屏 + 分页） ----------------

/** 评论 → BookComment（cid 为主键，缺失丢弃）；官方置顶 = uid 归一并等于 '0' */
function mapBookComment(raw: RawBookComment | undefined | null): BookComment | null {
  if (raw === undefined || raw === null) {
    return null;
  }
  const cid: string = toId(raw.cid);
  if (cid === '') {
    return null;
  }
  const c: BookComment = new BookComment();
  c.cid = cid;
  c.uid = toId(raw.uid);
  c.username = typeof raw.username === 'string' ? raw.username : '';
  c.content = typeof raw.content === 'string' ? raw.content : '';
  c.area = typeof raw.area === 'string' ? raw.area : '';
  c.time = formatTimestamp(raw.time);
  c.isOfficial = c.uid === '0';
  c.replyCount = toNumber(raw.reply_num);
  c.hasMoreReplies = raw.reply_more === true || raw.reply_more === 1
    || raw.reply_more === '1' || raw.reply_more === 'true';
  // 楼中楼只内联一层（每条回复不再展开自己的 replies），避免深层递归与数据膨胀
  c.replies = mapCommentList(raw.replies);
  return c;
}

function mapCommentList(list: RawBookComment[] | undefined): BookComment[] {
  const result: BookComment[] = [];
  if (list === undefined || !Array.isArray(list)) {
    return result;
  }
  for (let i = 0; i < list.length; i++) {
    const item: BookComment | null = mapBookComment(list[i]);
    if (item !== null) {
      result.push(item);
    }
  }
  return result;
}

/** `over` 归一化：true / 1 / 'true' / '1' 视为已到底 */
function parseOver(value: boolean | number | string | undefined): boolean {
  return value === true || value === 1 || value === '1' || value === 'true';
}

/**
 * 解析评论分页响应。
 * - `status=login` → AuthRequiredError；`status=error` → ProtocolError；
 * - 缺 `data`/`comments` → ProtocolError（分页接口必须返回评论数组，与「空数据可空」的广告不同）；
 * - `over` 是唯一「是否到底」判据，不自行按条数推断。
 */
export function parseCommentPage(envelope: RawCommentEnvelope | undefined, page: number): CommentPage {
  if (envelope === undefined || envelope === null) {
    throw new ProtocolError('评论响应为空');
  }
  ensureAuthorized(envelope.status);
  if (envelope.status === 'error') {
    throw new ProtocolError('评论接口返回业务错误');
  }
  const body: RawCommentPageBody | undefined = envelope.data;
  if (body === undefined || body === null) {
    throw new ProtocolError('评论响应缺少 data 字段');
  }
  const list: RawBookComment[] | undefined = body.comments;
  if (list === undefined) {
    throw new ProtocolError('评论响应缺少 comments 字段');
  }
  if (!Array.isArray(list)) {
    throw new ProtocolError('评论响应 comments 不是数组');
  }
  return new CommentPage(mapCommentList(list), page, parseOver(body.over));
}

/** 从原始 JSON 文本解析评论分页 */
export function parseCommentPageJson(text: string, page: number): CommentPage {
  let envelope: RawCommentEnvelope;
  try {
    envelope = JSON.parse(text) as RawCommentEnvelope;
  } catch (e) {
    throw new ProtocolError(`评论响应不是合法 JSON: ${text.substring(0, 120)}`);
  }
  try {
    return parseCommentPage(envelope, page);
  } catch (e) {
    Logger.debug(TAG, `评论响应解析异常: ${(e as Error).message}`);
    throw e as Error;
  }
}

// ==================== 用户资料 / 徽章 / 消息（Phase 14-J1） ====================

/** userinfo 原始结构：只读取有展示需求的字段；Integral/Email/Su/Badge 不参与展示 */
export interface RawUserProfile {
  Uid?: number | string;
  UID?: number | string;
  uid?: number | string;
  Username?: string;
  Name?: string;
  Avatar?: string;
  Bg?: string;
  Time?: number | string;
  CommentLen?: number | string;
}

export interface RawUserProfileEnvelope {
  status?: string;
  userinfo?: RawUserProfile;
}

/** /api/badge 原始条目 */
export interface RawBadgeItem {
  Id?: number | string;
  Name?: string;
  Img?: string;
  Minimg?: string;
  Des?: string;
}

export interface RawBadgeEnvelope {
  status?: string;
  data?: RawBadgeItem[];
  show?: (string | number)[];
}

/** 消息列表原始条目（字段按首方常见命名防御式读取；真实样本未取得 → NOT VERIFIED） */
export interface RawMessageItem {
  id?: number | string;
  cid?: number | string;
  rid?: number | string;
  mid?: number | string;
  title?: string;
  content?: string;
  message?: string;
  text?: string;
  time?: number | string;
  created_at?: number | string;
  cover?: string;
  img?: string;
  bid?: number | string;
  book_id?: number | string;
}

export interface RawReplyGroup {
  comment?: RawMessageItem[];
}

export interface RawCommunityReplyGroup {
  community_reply?: RawMessageItem[];
}

export interface RawSysMsgGroup {
  msg?: RawMessageItem[];
}

export interface RawMessageEnvelope {
  status?: string;
  reply?: RawReplyGroup;
  community_reply?: RawCommunityReplyGroup;
  sysmsg?: RawSysMsgGroup;
  page?: number | string;
  over?: boolean | number | string;
}

export interface RawMessageCountFields {
  all?: number | string;
  sys_msg?: number | string;
  community_reply?: number | string;
  comment_reply?: number | string;
}

export interface RawMessageCountEnvelope {
  status?: string;
  count?: RawMessageCountFields;
}

/** 图床 / 图片域名白名单（拒绝废弃域名 bucket.239847.xyz 及任意第三方） */
const ASSET_HOST_ALLOWLIST: string[] = [
  'bucket.noymanga.com',
  'img.noymanga.com',
  'noymanga.com',
  'stream.noyteam.online'
];

/** 提取 host（小写，无端口处理）；非 http(s) 返回 '' */
function hostOf(url: string): string {
  const lower: string = url.toLowerCase();
  let rest: string = '';
  if (lower.startsWith('https://')) {
    rest = lower.substring(8);
  } else if (lower.startsWith('http://')) {
    rest = lower.substring(7);
  } else {
    return '';
  }
  const slash: number = rest.indexOf('/');
  return slash >= 0 ? rest.substring(0, slash) : rest;
}

/** host 是否在白名单内 */
function isAllowedAssetHost(host: string): boolean {
  return ASSET_HOST_ALLOWLIST.indexOf(host) >= 0;
}

/**
 * 把用户资料相对路径解析为绝对 URL。
 * 1. 已是 http(s) → 直接校验 scheme/host；
 * 2. 相对路径 → 用 originHint（图床 origin）拼接，非法/缺失回退 https://bucket.noymanga.com；
 * 3. scheme 非 http(s) 或 host 不在白名单 → 返回 ''（不渲染，避免加载破图/第三方资源）。
 */
export function resolveUserAssetUrl(relative: string | undefined, originHint?: string): string {
  const raw: string = (relative ?? '').trim();
  if (raw === '') {
    return '';
  }
  const lower: string = raw.toLowerCase();
  const isHttp: boolean = lower.startsWith('https://') || lower.startsWith('http://');
  let absolute: string = raw;
  if (!isHttp) {
    // 含 scheme（':' 位于首个 '/' 之前）但不是 http(s) → 拒绝（javascript:/data:/file: 等）
    const colon: number = lower.indexOf(':');
    const slash: number = lower.indexOf('/');
    if (colon >= 0 && (slash < 0 || colon < slash)) {
      return '';
    }
    let origin: string = (originHint ?? '').trim();
    if (origin === '' || !isAllowedAssetHost(hostOf(origin))) {
      origin = 'https://bucket.noymanga.com';
    }
    absolute = origin.replace(/[\/]+$/, '') + '/' + raw.replace(/^[\/]+/, '');
  }
  const schemeOk: boolean = absolute.toLowerCase().startsWith('https://')
    || absolute.toLowerCase().startsWith('http://');
  if (!schemeOk || !isAllowedAssetHost(hostOf(absolute))) {
    return '';
  }
  return absolute;
}

/** 从徽章列表中取第一个合法绝对图片的 origin（供用户头像/背景拼接；无则返回 ''） */
export function badgeImageOrigin(badges: UserBadge[]): string {
  for (let i = 0; i < badges.length; i++) {
    const url: string = badges[i].img !== '' ? badges[i].img : badges[i].minImg;
    if (url === '') {
      continue;
    }
    const host: string = hostOf(url);
    if (host !== '' && isAllowedAssetHost(host)) {
      const scheme: string = url.toLowerCase().startsWith('https://') ? 'https://' : 'http://';
      return `${scheme}${host}`;
    }
  }
  return '';
}

/**
 * 解析用户资料。
 * - status=login → AuthRequiredError；其它非 ok → ProtocolError；
 * - `Integral` / `Email` / `Su` 一律不读取、不展示；
 * - Avatar/Bg 用 originHint（徽章图床 origin）解析，缺省回退 bucket.noymanga.com。
 */
export function parseUserInfo(envelope: RawUserProfileEnvelope | undefined,
  originHint?: string): UserInfo {
  if (envelope === undefined || envelope === null) {
    throw new ProtocolError('用户资料响应为空');
  }
  ensureAuthorized(envelope.status);
  if (envelope.status !== 'ok') {
    throw new ProtocolError(`用户资料返回未知状态: ${envelope.status ?? '(空)'}`);
  }
  const raw: RawUserProfile | undefined = envelope.userinfo;
  if (raw === undefined || raw === null) {
    throw new ProtocolError('用户资料响应缺少 userinfo');
  }
  const info: UserInfo = new UserInfo();
  info.uid = toId(raw.Uid ?? raw.UID ?? raw.uid);
  const username: string = toText(raw.Username);
  info.username = username !== '' ? username : toText(raw.Name);
  info.avatarPath = typeof raw.Avatar === 'string' ? raw.Avatar : '';
  info.bgPath = typeof raw.Bg === 'string' ? raw.Bg : '';
  info.avatarUrl = resolveUserAssetUrl(info.avatarPath, originHint);
  info.bgUrl = resolveUserAssetUrl(info.bgPath, originHint);
  info.createdAt = formatTimestamp(raw.Time);
  info.commentCount = toNumber(raw.CommentLen);
  return info;
}

/** 从 JSON 文本解析用户资料 */
export function parseUserInfoJson(text: string, originHint?: string): UserInfo {
  let envelope: RawUserProfileEnvelope;
  try {
    envelope = JSON.parse(text) as RawUserProfileEnvelope;
  } catch (e) {
    throw new ProtocolError(`用户资料响应不是合法 JSON: ${text.substring(0, 120)}`);
  }
  return parseUserInfo(envelope, originHint);
}

/** 用户资料资产在拿到徽章 origin 后重解析（不改其它字段） */
export function rebaseUserAssets(info: UserInfo, originHint: string): void {
  if (originHint === '') {
    return;
  }
  const avatar: string = resolveUserAssetUrl(info.avatarPath, originHint);
  const bg: string = resolveUserAssetUrl(info.bgPath, originHint);
  if (avatar !== '') {
    info.avatarUrl = avatar;
  }
  if (bg !== '') {
    info.bgUrl = bg;
  }
}

/** 徽章结果：全部可用徽章 + 按 show 顺序的已佩戴徽章 */
export class BadgeResult {
  readonly all: UserBadge[];
  readonly shown: UserBadge[];

  constructor(all: UserBadge[], shown: UserBadge[]) {
    this.all = all;
    this.shown = shown;
  }
}

/** 按 show 顺序匹配已佩戴徽章：只保留真实存在的 id，去重，保持服务端顺序 */
export function matchShownBadges(all: UserBadge[], show: string[]): UserBadge[] {
  const result: UserBadge[] = [];
  const used: string[] = [];
  for (let i = 0; i < show.length; i++) {
    const id: string = show[i];
    if (id === '' || used.indexOf(id) >= 0) {
      continue;
    }
    used.push(id);
    for (let j = 0; j < all.length; j++) {
      if (all[j].id === id) {
        result.push(all[j]);
        break;
      }
    }
  }
  return result;
}

/**
 * 解析徽章：
 * - `data` 全部徽章（Id 数字 → 字符串）；
 * - `show` 佩戴中的 id（字符串数组，数字也归一化）；
 * - 按 show 顺序输出已佩戴；`userinfo.Badge` 不参与。
 */
export function parseBadges(envelope: RawBadgeEnvelope | undefined): BadgeResult {
  if (envelope === undefined || envelope === null) {
    throw new ProtocolError('徽章响应为空');
  }
  ensureAuthorized(envelope.status);
  if (envelope.status !== 'ok') {
    throw new ProtocolError(`徽章接口返回未知状态: ${envelope.status ?? '(空)'}`);
  }
  const rawList: RawBadgeItem[] = Array.isArray(envelope.data) ? envelope.data : [];
  const all: UserBadge[] = [];
  for (let i = 0; i < rawList.length; i++) {
    const raw: RawBadgeItem = rawList[i];
    const id: string = toId(raw.Id);
    if (id === '') {
      continue;
    }
    const badge: UserBadge = new UserBadge();
    badge.id = id;
    badge.name = toText(raw.Name);
    badge.img = resolveUserAssetUrl(typeof raw.Img === 'string' ? raw.Img : '', '');
    badge.minImg = resolveUserAssetUrl(typeof raw.Minimg === 'string' ? raw.Minimg : '', '');
    badge.des = toText(raw.Des);
    all.push(badge);
  }
  const showRaw: (string | number)[] = Array.isArray(envelope.show) ? envelope.show : [];
  const show: string[] = [];
  for (let i = 0; i < showRaw.length; i++) {
    const v: string = toId(showRaw[i]);
    if (v !== '') {
      show.push(v);
    }
  }
  return new BadgeResult(all, matchShownBadges(all, show));
}

/** 从 JSON 文本解析徽章 */
export function parseBadgesJson(text: string): BadgeResult {
  let envelope: RawBadgeEnvelope;
  try {
    envelope = JSON.parse(text) as RawBadgeEnvelope;
  } catch (e) {
    throw new ProtocolError(`徽章响应不是合法 JSON: ${text.substring(0, 120)}`);
  }
  return parseBadges(envelope);
}

/** 解析未读消息计数（缺字段按 0；status=login → AuthRequiredError） */
export function parseMessageCount(envelope: RawMessageCountEnvelope | undefined): MessageCount {
  if (envelope === undefined || envelope === null) {
    throw new ProtocolError('消息计数响应为空');
  }
  ensureAuthorized(envelope.status);
  if (envelope.status !== 'ok') {
    throw new ProtocolError(`消息计数返回未知状态: ${envelope.status ?? '(空)'}`);
  }
  const raw = envelope.count;
  const result: MessageCount = new MessageCount();
  if (raw !== undefined && raw !== null) {
    result.all = toNumber(raw.all);
    result.sysMsg = toNumber(raw.sys_msg);
    result.communityReply = toNumber(raw.community_reply);
    result.commentReply = toNumber(raw.comment_reply);
  }
  return result;
}

/** 从 JSON 文本解析未读计数 */
export function parseMessageCountJson(text: string): MessageCount {
  let envelope: RawMessageCountEnvelope;
  try {
    envelope = JSON.parse(text) as RawMessageCountEnvelope;
  } catch (e) {
    throw new ProtocolError(`消息计数响应不是合法 JSON: ${text.substring(0, 120)}`);
  }
  return parseMessageCount(envelope);
}

/** 消息分页结果 */
export class MessagePageResult {
  readonly items: MessageItem[];
  readonly over: boolean;

  constructor(items: MessageItem[], over: boolean) {
    this.items = items;
    this.over = over;
  }
}

/** 单条消息防御式映射（字段名不统一，缺失留空；不编造内容） */
function mapMessageItem(raw: RawMessageItem | undefined | null, kind: string): MessageItem | null {
  if (raw === undefined || raw === null) {
    return null;
  }
  const item: MessageItem = new MessageItem();
  item.kind = kind;
  item.id = toId(raw.id ?? raw.cid ?? raw.rid ?? raw.mid);
  item.title = toText(raw.title);
  const content: string = toText(raw.content);
  item.content = content !== '' ? content : (toText(raw.message) !== '' ? toText(raw.message) : toText(raw.text));
  item.time = formatTimestamp(raw.time ?? raw.created_at);
  item.cover = resolveUserAssetUrl(typeof raw.cover === 'string' ? raw.cover : (typeof raw.img === 'string' ? raw.img : ''), '');
  item.bookId = toId(raw.bid ?? raw.book_id);
  return item;
}

/** 按 type 取三类消息数组（结构不同：reply.comment / community_reply.community_reply / sysmsg.msg） */
function messageArrayOf(envelope: RawMessageEnvelope, kind: string): RawMessageItem[] {
  let list: RawMessageItem[] | undefined;
  if (kind === MSG_TYPE_REPLY) {
    list = envelope.reply?.comment;
  } else if (kind === MSG_TYPE_COMMUNITY_REPLY) {
    list = envelope.community_reply?.community_reply;
  } else if (kind === MSG_TYPE_SYSMSG) {
    list = envelope.sysmsg?.msg;
  }
  return Array.isArray(list) ? list : [];
}

/**
 * 解析消息列表（三类结构独立取值）。
 * - status=login → AuthRequiredError；
 * - `over` 若服务端提供则采用；否则以「本页为空」保守判定到底（不做条数推断伪造分页）。
 */
export function parseMessageList(envelope: RawMessageEnvelope | undefined,
  kind: string): MessagePageResult {
  if (envelope === undefined || envelope === null) {
    throw new ProtocolError('消息列表响应为空');
  }
  ensureAuthorized(envelope.status);
  if (envelope.status !== 'ok') {
    throw new ProtocolError(`消息列表返回未知状态: ${envelope.status ?? '(空)'}`);
  }
  const list: RawMessageItem[] = messageArrayOf(envelope, kind);
  const items: MessageItem[] = [];
  for (let i = 0; i < list.length; i++) {
    const item: MessageItem | null = mapMessageItem(list[i], kind);
    if (item !== null) {
      items.push(item);
    }
  }
  const over: boolean = envelope.over !== undefined
    ? parseOver(envelope.over) : items.length === 0;
  return new MessagePageResult(items, over);
}

/** 从 JSON 文本解析消息列表 */
export function parseMessageListJson(text: string, kind: string): MessagePageResult {
  let envelope: RawMessageEnvelope;
  try {
    envelope = JSON.parse(text) as RawMessageEnvelope;
  } catch (e) {
    throw new ProtocolError(`消息列表响应不是合法 JSON: ${text.substring(0, 120)}`);
  }
  return parseMessageList(envelope, kind);
}

// ==================== 账号收藏（Phase 14-J2，静态契约证据） ====================

/**
 * 账号收藏读取接口的真实契约（证据：首方生产 bundle，2026-11-08 抓取）：
 *   assets/favorites-CzyYHNIA.js:
 *     e('/v4/favorites/get',      { page, class })  → 书籍收藏列表
 *     e('/v4/favorites/class/get',{})               → 收藏分类
 *     e('/v4/favorites/stream/get',{ page })        → 收藏的动画
 *   assets/form-BwbhdKB8.js: `t` = client.post(path, form-urlencoded) → 方法为 **POST 表单**
 *   assets/favorite-B6HMajD8.js:
 *     class='all' 时**省略** class 参数（`r!==E && (e.class=r)`）
 *     分页大小 Te=20，总页数 = ceil(total / 20)
 *     响应：{ status:'ok', data: Book[], count } / 分类 { status:'ok', data:[{id,name}] }
 *
 * 安全：本阶段只调用只读的 /favorites/get 与 /favorites/class/get；
 * **绝不调用** /favorites/toggle、class/add|edit|delete、migrate 等写操作。
 */
export const FAVORITE_PAGE_SIZE: number = 20;
/** 收藏分类特殊值：全部 */
export const FAVORITE_CLASS_ALL: string = 'all';
/** 收藏分类特殊值：收藏的动画（首页已移除番剧，但接口能力保留） */
export const FAVORITE_CLASS_STREAM: string = 'stream';

export interface RawFavoriteClass {
  id?: number | string;
  name?: string;
}

export interface RawFavoriteClassEnvelope {
  status?: string;
  data?: RawFavoriteClass[];
}

export interface RawAccountFavoriteEnvelope {
  status?: string;
  data?: RawBookListItem[];
  count?: number;
}

/** toggle 写接口响应：与收藏只读接口同构（status=ok/login/error），无额外业务字段证据 */
export interface RawFavoriteToggleEnvelope {
  status?: string;
}

/**
 * 构造账号收藏 toggle 请求表单。
 * 契约证据（首方生产 bundle，PHASE14J2_REPORT.md §3）：
 *   assets/favorites-CzyYHNIA.js: e('/v4/favorites/toggle', { bid })；
 *   assets/form-BwbhdKB8.js: client.post + application/x-www-form-urlencoded。
 * 即 POST /api/v4/favorites/toggle，表单参数名为 **bid**（书籍 id），与只读接口的 Bid 同源。
 */
export function buildFavoriteToggleForm(bid: string): Record<string, string> {
  return { 'bid': bid.trim() };
}

/**
 * 解析账号收藏 toggle 响应。
 * - status=login → AuthRequiredError；status!=ok → ProtocolError（不臆造业务字段）；
 * - 成功仅表示「已切换」，新状态由调用方以乐观取反 + /get 重取校准。
 */
export function parseFavoriteToggle(envelope: RawFavoriteToggleEnvelope | undefined): void {
  if (envelope === undefined || envelope === null) {
    throw new ProtocolError('收藏切换响应为空');
  }
  ensureAuthorized(envelope.status);
  if (envelope.status !== 'ok') {
    throw new ProtocolError(`收藏切换返回未知状态: ${envelope.status ?? '(空)'}`);
  }
}

/** 构造账号收藏请求表单：page 必带；class 非空且非 'all' 时追加 */
export function buildFavoriteForm(page: number, classId?: string): Record<string, string> {
  const p: number = page > 0 ? page : 1;
  const form: Record<string, string> = { 'page': String(p) };
  const cls: string = (classId ?? '').trim();
  if (cls !== '' && cls !== FAVORITE_CLASS_ALL) {
    form['class'] = cls;
  }
  return form;
}

/**
 * 解析账号收藏列表。
 * - status=login → AuthRequiredError；status=error → ProtocolError；
 * - data 必须是数组（缺字段视为协议错误，绝不伪造空列表冒充「没有收藏」）；
 * - 保留服务端顺序；按 Bid 去重在 ViewModel 层做（同页可能有重复需避免 key 冲突）。
 */
export function parseAccountFavorites(envelope: RawAccountFavoriteEnvelope | undefined,
  page: number): PageInfo<Comic> {
  if (envelope === undefined || envelope === null) {
    throw new ProtocolError('账号收藏响应为空');
  }
  ensureAuthorized(envelope.status);
  if (envelope.status === 'error') {
    throw new ProtocolError('账号收藏接口返回业务错误');
  }
  const list: RawBookListItem[] | undefined = envelope.data;
  if (list === undefined) {
    throw new ProtocolError('账号收藏响应缺少 data 字段');
  }
  if (!Array.isArray(list)) {
    throw new ProtocolError('账号收藏响应 data 不是数组');
  }
  const comics: Comic[] = mapBookArray(list);
  const total: number = toFiniteNumber(envelope.count) ?? -1;
  const totalPages: number = totalPagesOf(total);
  const hasMore: boolean = resolveHasMore(page, totalPages, comics.length);
  return new PageInfo<Comic>(page, totalPages, comics, hasMore, total);
}

/** 从 JSON 文本解析账号收藏列表 */
export function parseAccountFavoritesJson(text: string, page: number): PageInfo<Comic> {
  let envelope: RawAccountFavoriteEnvelope;
  try {
    envelope = JSON.parse(text) as RawAccountFavoriteEnvelope;
  } catch (e) {
    throw new ProtocolError(`账号收藏响应不是合法 JSON: ${text.substring(0, 120)}`);
  }
  return parseAccountFavorites(envelope, page);
}

/** 解析收藏分类列表（缺 id 的条目丢弃） */
export function parseFavoriteClasses(envelope: RawFavoriteClassEnvelope | undefined): FavoriteClass[] {
  if (envelope === undefined || envelope === null) {
    throw new ProtocolError('收藏分类响应为空');
  }
  ensureAuthorized(envelope.status);
  if (envelope.status !== 'ok') {
    throw new ProtocolError(`收藏分类返回未知状态: ${envelope.status ?? '(空)'}`);
  }
  const raw: RawFavoriteClass[] = Array.isArray(envelope.data) ? envelope.data : [];
  const result: FavoriteClass[] = [];
  for (let i = 0; i < raw.length; i++) {
    const id: string = toId(raw[i].id);
    if (id === '') {
      continue;
    }
    const item: FavoriteClass = new FavoriteClass();
    item.id = id;
    item.name = toText(raw[i].name);
    result.push(item);
  }
  return result;
}

/** 从 JSON 文本解析收藏分类 */
export function parseFavoriteClassesJson(text: string): FavoriteClass[] {
  let envelope: RawFavoriteClassEnvelope;
  try {
    envelope = JSON.parse(text) as RawFavoriteClassEnvelope;
  } catch (e) {
    throw new ProtocolError(`收藏分类响应不是合法 JSON: ${text.substring(0, 120)}`);
  }
  return parseFavoriteClasses(envelope);
}

// ---------------- 每日签到（POST /api/v4/signin/record & /api/v4/signin/sign） ----------------

/** 签到记录条目（仅提取连续天数，绝不读取/留存 ip 字段） */
export interface RawSignInRecordItem {
  continuous?: number;
}

/** 查询今日签到状态响应信封（注意：成功时 status 为数字 200，未登录时为字符串 'login'） */
export interface RawSignInRecordEnvelope {
  status?: number | string;
  today?: boolean;
  continuous?: number;
  data?: RawSignInRecordItem[];
}

/** 执行签到响应信封（成功 status=200，今日已签 status=500，未登录 status='login'） */
export interface RawSignInEnvelope {
  status?: number | string;
  msg?: string;
  continuous?: number;
}

/** 签到记录解析结果 */
export interface SignInRecordResult {
  today: boolean;
  continuous: number;
}

/** 签到状态 */
export type SignInStatus = 'SIGNED' | 'ALREADY_SIGNED';

/** 执行签到解析结果 */
export interface SignInResult {
  status: SignInStatus;
  continuous: number;
  message: string;
}

/** 安全解析整数（仅接受有限数字，其余返回 fallback） */
function safeInt(val: number | undefined, fallback: number): number {
  return typeof val === 'number' && Number.isFinite(val) ? Math.trunc(val) : fallback;
}

/** 解析签到记录响应（POST /api/v4/signin/record） */
export function parseSignInRecord(envelope: RawSignInRecordEnvelope | undefined): SignInRecordResult {
  if (envelope === undefined || envelope === null) {
    throw new ProtocolError('签到记录响应为空');
  }
  if (envelope.status === 'login') {
    throw new AuthRequiredError();
  }
  if (envelope.status !== 200) {
    throw new ProtocolError(`签到记录状态异常: ${String(envelope.status ?? '')}`);
  }
  const signedToday: boolean = envelope.today === true;
  let continuous: number = safeInt(envelope.continuous, -1);
  // 未签到时服务端 continuous 返回 -1，若有历史记录则取 data[0].continuous 作为历史连续天数
  if (continuous < 0 && Array.isArray(envelope.data) && envelope.data.length > 0) {
    continuous = safeInt(envelope.data[0].continuous, 0);
  }
  return {
    today: signedToday,
    continuous: continuous > 0 ? continuous : 0
  };
}

/** 解析执行签到响应（POST /api/v4/signin/sign） */
export function parseSignInResult(envelope: RawSignInEnvelope | undefined): SignInResult {
  if (envelope === undefined || envelope === null) {
    throw new ProtocolError('签到响应为空');
  }
  if (envelope.status === 'login') {
    throw new AuthRequiredError();
  }
  if (envelope.status === 200) {
    const continuous: number = safeInt(envelope.continuous, 0);
    return {
      status: 'SIGNED',
      continuous: continuous > 0 ? continuous : 0,
      message: continuous > 0
        ? LocalizationManager.getInstance().getString(
            $r('app.string.checkin_success_streak_fmt'),
            `签到成功，连续 ${continuous} 天`,
            continuous
          )
        : LocalizationManager.getInstance().getString(
            $r('app.string.checkin_success_today'),
            '今日签到完成'
          )
    };
  }
  if (envelope.status === 500) {
    const continuous: number = safeInt(envelope.continuous, 0);
    return {
      status: 'ALREADY_SIGNED',
      continuous: continuous > 0 ? continuous : 0,
      message: '今天已经签过到了'
    };
  }
  throw new ProtocolError(toText(envelope.msg) !== '' ? toText(envelope.msg) : '签到失败');
}
