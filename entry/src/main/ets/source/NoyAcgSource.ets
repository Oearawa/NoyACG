/**
 * NoyAcgSource.ets —— NoyAcg 漫画源适配器（IComicSource 的实际实现）
 *
 * ★ 协议来源（Phase 9 审计结论，详见 API_PROTOCOL_AUDIT.md）：
 * 全部路径/方法/参数均取自 NoyAcg **首方 Web 客户端**（noymanga.com）线上 JS 的实际调用，
 * 并已用匿名 HTTP 请求验证「未登录时的真实响应」。不再保留前几阶段凭命名习惯推测的路径。
 *
 *   首页/最新   POST /api/b1/booklist        表单 page/sort/finished   → { info: [], len }
 *   搜索        POST /api/v4/search/fetch    表单 value/mode/sort/type/page/finished
 *                                                                      → { data: [], count }
 *   详情        GET  /api/v4/book/{id}                                 → { book:{info}, chapters }
 *   章节图片    GET  /api/v4/book/detail/{bid}/{cid}                   → { chapter:{...}, data:{count} }
 *
 * 鉴权：NoyAcg 全量数据接口需要登录会话（cookie）。未登录时服务端返回
 * **HTTP 200 + {"status":"login"}**，本层统一转成 AuthRequiredError，
 * 由 UI 显示「需要登录」，绝不把它伪装成解析失败或空列表。
 *
 * Phase 10：所有业务请求复用 HttpManager 单例的 rcp 会话（绑定 CookieRepository），
 * 因此登录后自动携带同一 Cookie；一旦任一业务请求返回 status=login，
 * 统一通知 AuthManager 降级认证状态，个人中心/登录入口随之刷新。
 *
 * 说明：登录成功响应因无账号/邀请码尚未抓取，相关解析以「首方前端字段用法」
 * 为依据并用 Fixture 覆盖，报告中标注为未运行验证。
 */
import { Comic } from '../model/Comic';
import { ComicDetail } from '../model/ComicDetail';
import { PageInfo } from '../model/PageInfo';
import { HomeFeed } from '../model/HomeFeed';
import { AdItem } from '../model/AdItem';
import { CommentPage } from '../model/BookComment';
import { IComicSource } from './IComicSource';
import { AccountFavoritePort } from './AccountFavoritePort';
import { BigTagPort, LeaderboardPort, RecommendPort } from './DiscoverySourcePort';
import { FavoriteClass } from '../model/FavoriteClass';
import { normalizeSearchMode } from '../model/NavParams';
import {
  NOY_PAGE_SIZE,
  buildBookListForm,
  buildFavoriteForm,
  RawAdsEnvelope,
  RawAccountFavoriteEnvelope,
  RawBigTagEnvelope,
  RawBookDetailEnvelope,
  RawBookListEnvelope,
  RawChapterEnvelope,
  RawCommentEnvelope,
  RawFavoriteClassEnvelope,
  RawFavoriteToggleEnvelope,
  RawHomeEnvelope,
  RawLeaderboardEnvelope,
  RawSearchEnvelope,
  parseAccountFavorites,
  parseAds,
  buildFavoriteToggleForm,
  parseFavoriteToggle,
  parseBigTagList,
  parseBookDetail,
  parseBookListPage,
  parseChapterImages,
  parseCommentPage,
  parseFavoriteClasses,
  parseHomeFeed,
  parseLeaderboardPage,
  parseSearchPage
} from './NoyAcgProtocol';
import { BigTagItem, buildLeaderboardForm, buildRecommendForm, rankKindPath } from '../model/LeaderboardModels';
import { HttpManager, NOY_WEB_ORIGIN } from '../api/HttpManager';
import { ProtocolError, notifyIfSessionExpired } from '../api/ApiErrors';
import { AuthManager } from '../utils/AuthManager';
import { Logger } from '../utils/Logger';

const TAG: string = 'NoyAcgSource';

/**
 * 搜索筛选合法值（I-000003；契约来源 API_PROTOCOL_AUDIT.md §2.1 :52，已实测）。
 * sort ∈ {''/views/favorites/rating}；type ∈ {''/book/stream}；
 * finished ∈ {''/true/false}；只登记录音内已确认的取值，绝不虚构扩展。
 */
export const SEARCH_SORT_DEFAULT: string = '';
export const SEARCH_SORT_VIEWS: string = 'views';
export const SEARCH_SORT_FAVORITES: string = 'favorites';
export const SEARCH_SORT_RATING: string = 'rating';
export const SEARCH_TYPE_DEFAULT: string = '';
export const SEARCH_TYPE_BOOK: string = 'book';
export const SEARCH_TYPE_STREAM: string = 'stream';
export const SEARCH_FINISHED_ALL: string = '';
export const SEARCH_FINISHED_COMPLETED: string = 'true';
export const SEARCH_FINISHED_ONGOING: string = 'false';

/**
 * 归一化单个搜索筛选值（I-000003）。
 * FALSY（undefined / ''）→ ''；白名单内合法值原样返回；其余非法值 → null（调用方拒发 + 日志）。
 */
export function normalizeSearchFilter(value: string | undefined,
  legalValues: string[]): string | null {
  if (value === undefined || value === '') {
    return '';
  }
  if (legalValues.indexOf(value) >= 0) {
    return value;
  }
  return null;
}

/**
 * 构造搜索请求表单（I-000003 参数化）。
 * mode 沿用既有 normalizeSearchMode（default/tag/author，首方 bundle 证据）；
 * sort/type/finished 按审计合法表映射，任一非法 → 返回 null（调用方拒发 + 日志，不发请求）。
 * 独立纯函数（与 buildBookListForm 同模式），便于无网络单测组合断言。
 */
export function buildSearchForm(keyword: string, page: number, mode: string,
  sort: string | undefined, type: string | undefined,
  finished: string | undefined): Record<string, string> | null {
  const s: string | null = normalizeSearchFilter(sort,
    [SEARCH_SORT_VIEWS, SEARCH_SORT_FAVORITES, SEARCH_SORT_RATING]);
  const t: string | null = normalizeSearchFilter(type,
    [SEARCH_TYPE_BOOK, SEARCH_TYPE_STREAM]);
  const f: string | null = normalizeSearchFilter(finished,
    [SEARCH_FINISHED_COMPLETED, SEARCH_FINISHED_ONGOING]);
  if (s === null || t === null || f === null) {
    return null;
  }
  return {
    'value': keyword,
    'mode': normalizeSearchMode(mode),
    'sort': s,
    'type': t,
    'page': String(page),
    'finished': f
  };
}

export class NoyAcgSource implements IComicSource, AccountFavoritePort, LeaderboardPort,
  RecommendPort, BigTagPort {
  readonly sourceId: string = 'noyacg_web';
  readonly sourceName: string = 'NoyAcg';
  readonly baseUrl: string = NOY_WEB_ORIGIN;

  /** 分页大小（与 Web 端一致，供 UI 估算使用，不参与请求参数） */
  readonly pageSize: number = NOY_PAGE_SIZE;

  /** 复用统一网络核心（rcp 会话 + 三级 Header 合并 + HttpError 归一化） */
  private http: HttpManager = HttpManager.getInstance();

  /**
   * 获取首页 / 最新列表（分页，支持排序与完结筛选）。
   * 使用 /b1/booklist（支持 page/sort/finished），而不是聚合首页 /home，
   * 因为首页 VM 需要稳定的分页语义。
   */
  async getHomeList(page: number, sort?: string, finished?: string): Promise<PageInfo<Comic>> {
    const form: Record<string, string> = buildBookListForm(page, sort, finished);
    const resp: RawBookListEnvelope =
      await this.http.postForm<RawBookListEnvelope>('/api/b1/booklist', form);
    let result: PageInfo<Comic>;
    try {
      result = parseBookListPage(resp, page);
    } catch (e) {
      this.reportAuthFailure(e);
      Logger.warn(TAG, `书单响应解析失败: ${(e as Error).message}`);
      throw e as Error; // 保留 AuthRequiredError / ProtocolError 的具体类型
    }
    Logger.info(TAG,
      `书单第${page}页(sort=${form['sort']}, finished=${form['finished']}): ` +
      `${result.list.length}条, hasMore=${result.hasMore}`);
    return result;
  }

  /**
   * 搜索漫画（I-000003：sort/type/finished 按审计合法值参数化）
   * @param keyword 关键词（标签搜索传完整标签原文，不按空格拆分）
   * @param page 页码，从 1 开始（Web 端同样从 1 开始，页大小固定 20）
   * @param mode 搜索范围（default/tag/author，缺省/非法值归一为 default）
   * @param sort 排序（''/views/favorites/rating；FALSY 归一为 ''；非法值拒发 + 日志）
   * @param type 类型（''/book/stream；同上）
   * @param finished 完结筛选（''/true/false；同上）
   */
  async search(keyword: string, page: number, mode?: string, sort?: string,
    type?: string, finished?: string): Promise<PageInfo<Comic>> {
    const form: Record<string, string> | null = buildSearchForm(keyword, page,
      normalizeSearchMode(mode === undefined ? '' : mode), sort, type, finished);
    if (form === null) {
      // 非法筛选值：在发网之前拒发并记日志，绝不把未在协议中确认的值发给服务端
      Logger.warn(TAG, '搜索筛选含非法值，已拒绝发送: sort=' + (sort ?? '')
        + ' type=' + (type ?? '') + ' finished=' + (finished ?? ''));
      throw new ProtocolError('搜索筛选参数非法，已拒绝发送请求');
    }
    // allow-adult 内容分级由 HttpManager 统一按全局策略注入（ContentRatingPolicy），此处不再重复传参
    const resp: RawSearchEnvelope = await this.http.postForm<RawSearchEnvelope>(
      '/api/v4/search/fetch', form);
    let result: PageInfo<Comic>;
    try {
      result = parseSearchPage(resp, page);
    } catch (e) {
      this.reportAuthFailure(e);
      // 保留协议层抛出的具体类型（AuthRequiredError / ProtocolError），补日志后原样上抛
      Logger.warn(TAG, `搜索响应解析失败: ${(e as Error).message}`);
      throw e as Error;
    }
    Logger.info(TAG,
      `搜索 "${keyword}" 第${page}页: ${result.list.length}条/${result.totalPages}页`);
    return result;
  }

  /** 获取漫画详情（书籍信息 + 章节列表 + 推荐 + 首屏评论 + 积分） */
  async getComicDetail(id: string): Promise<ComicDetail> {
    const path: string = `/api/v4/book/${encodeURIComponent(id)}`;
    const resp: RawBookDetailEnvelope = await this.http.get<RawBookDetailEnvelope>(path);
    let detail: ComicDetail;
    try {
      detail = parseBookDetail(resp, id);
    } catch (e) {
      this.reportAuthFailure(e);
      Logger.warn(TAG, `详情响应解析失败: ${(e as Error).message}`);
      throw e as Error; // 保留 AuthRequiredError / ProtocolError 的具体类型
    }
    Logger.info(TAG, `详情 id=${id}, 分组数=${detail.groups.length}, ` +
      `章节数=${detail.chapters.length}, mode=${detail.mode}`);
    return detail;
  }

  /**
   * 获取章节图片地址列表（GET /api/v4/book/detail/{bid}/{cid}）
   *
   * 协议事实：读图接口需要「书籍 id + 章节 id」两个参数（Phase 10 已升级接口签名）；
   * 页数只取响应 `chapter.this.count ?? data.count`，图片按 1..N 连续编号拼装。
   * Phase 11：按首方 `ct(bid,cid)`，`cid === '0'`（Mode=0 单本）时路径少一级目录
   * （`img/{bid}/{n}.webp`），其余为 `img/{bid}/{cid}/{n}.webp`。见审计附录 A.4。
   * 该请求与会话共享同一 Cookie，未登录会得到 status=login → AuthRequiredError。
   */
  async getChapterImages(bookId: string, chapterId: string): Promise<string[]> {
    const bid: string = bookId.trim();
    const cid: string = chapterId.trim();
    if (bid === '' || cid === '') {
      throw new ProtocolError('读取章节图片需要「书籍 id + 章节 id」两个参数');
    }
    const path: string =
      `/api/v4/book/detail/${encodeURIComponent(bid)}/${encodeURIComponent(cid)}`;
    const resp: RawChapterEnvelope = await this.http.get<RawChapterEnvelope>(path);
    let images: string[];
    try {
      images = parseChapterImages(resp, bid, cid);
    } catch (e) {
      this.reportAuthFailure(e);
      Logger.warn(TAG, `章节响应解析失败: ${(e as Error).message}`);
      throw e as Error; // 保留 AuthRequiredError / ProtocolError 类型
    }
    Logger.info(TAG, `章节 bid=${bid} cid=${cid}: ${images.length} 张`);
    return images;
  }

  /**
   * 获取首页聚合数据（POST /api/home）。
   * 与 getHomeList（/b1/booklist）分工：本方法一次性返回公告/榜单/动画/标签，无分页；
   * getHomeList 仍服务于「最新」Tab 的稳定分页语义。请求体固定 v=3&stream_all=1
   * （stream 仅 v=3 才有）；allow-adult 显式传递，绝不省略。
   */
  async getHomeFeed(adultLevel?: string): Promise<HomeFeed> {
    const form: Record<string, string> = { 'v': '3', 'stream_all': '1' };
    // adultLevel 参数仅为签名兼容保留；实际分级由 HttpManager 按全局策略注入 allow-adult
    const resp: RawHomeEnvelope = await this.http.postForm<RawHomeEnvelope>('/api/home', form);
    try {
      const feed: HomeFeed = parseHomeFeed(resp);
      Logger.info(TAG, `首页聚合: 收藏榜${feed.favDay.length} 阅读榜${feed.readDay.length} ` +
        `fs=${feed.fs.length} proportion=${feed.proportion.length} stream=${feed.stream.length} ` +
        `tags=${feed.tags.length}`);
      return feed;
    } catch (e) {
      this.reportAuthFailure(e);
      Logger.warn(TAG, `首页聚合解析失败: ${(e as Error).message}`);
      throw e as Error;
    }
  }

  /** 获取首页广告位（POST /api/v3/ads）。支持空数据；url 已在协议层限定 http/https。 */
  async getAds(adultLevel?: string): Promise<AdItem[]> {
    // adultLevel 参数仅为签名兼容保留；实际分级由 HttpManager 按全局策略注入 allow-adult
    const resp: RawAdsEnvelope = await this.http.postForm<RawAdsEnvelope>('/api/v3/ads', {});
    try {
      const ads: AdItem[] = parseAds(resp);
      Logger.info(TAG, `广告位: ${ads.length} 条`);
      return ads;
    } catch (e) {
      this.reportAuthFailure(e);
      Logger.warn(TAG, `广告解析失败: ${(e as Error).message}`);
      throw e as Error;
    }
  }

  /** 获取书籍评论分页（GET /api/v4/comment/book/{bid}/comments?page=）。 */
  async getBookComments(bookId: string, page: number): Promise<CommentPage> {
    const bid: string = bookId.trim();
    const path: string = `/api/v4/comment/book/${encodeURIComponent(bid)}/comments`;
    const resp: RawCommentEnvelope = await this.http.get<RawCommentEnvelope>(path,
      { 'page': String(page) });
    try {
      const result: CommentPage = parseCommentPage(resp, page);
      Logger.info(TAG, `评论 bid=${bid} 第${page}页: ${result.comments.length}条, over=${result.over}`);
      return result;
    } catch (e) {
      this.reportAuthFailure(e);
      Logger.warn(TAG, `评论解析失败: ${(e as Error).message}`);
      throw e as Error;
    }
  }

  /**
   * 账号收藏书籍分页（Phase 14-J2）。
   * 接口证据（首方生产 bundle）：POST /api/v4/favorites/get，表单 page[, class]；
   * 响应 { status, data: Book[], count }；class='all' 时省略 class。
   * 只读接口，绝不触发 toggle / class 增删改。
   */
  async fetchAccountFavorites(page: number, classId: string): Promise<PageInfo<Comic>> {
    const form: Record<string, string> = buildFavoriteForm(page, classId);
    const resp: RawAccountFavoriteEnvelope =
      await this.http.postForm<RawAccountFavoriteEnvelope>('/api/v4/favorites/get', form);
    try {
      const result: PageInfo<Comic> = parseAccountFavorites(resp, page);
      Logger.info(TAG, `账号收藏第${page}页: ${result.list.length}条, hasMore=${result.hasMore}`);
      return result;
    } catch (e) {
      this.reportAuthFailure(e);
      Logger.warn(TAG, `账号收藏解析失败: ${(e as Error).message}`);
      throw e as Error;
    }
  }

  /**
   * 账号收藏 toggle（I-000002 写路径）。
   * 契约证据（PHASE14J2_REPORT.md §3 静态）：POST /api/v4/favorites/toggle，表单 { bid }；
   * 响应 { status }，status=login → AuthRequiredError，status!=ok → ProtocolError。
   * 成功即「已切换」，新状态由调用方乐观取反 + /get 重取校准。
   */
  async toggleFavorite(bid: string): Promise<void> {
    const trimmed: string = bid.trim();
    if (trimmed === '') {
      throw new ProtocolError('收藏切换需要书籍 id');
    }
    const form: Record<string, string> = buildFavoriteToggleForm(trimmed);
    const resp: RawFavoriteToggleEnvelope = await this.http.postForm<RawFavoriteToggleEnvelope>(
      '/api/v4/favorites/toggle', form);
    try {
      parseFavoriteToggle(resp);
    } catch (e) {
      this.reportAuthFailure(e);
      Logger.warn(TAG, `收藏切换失败 bid=${trimmed}: ${(e as Error).message}`);
      throw e as Error; // 保留 AuthRequiredError / ProtocolError 类型
    }
    Logger.info(TAG, `账号收藏已切换 bid=${trimmed}`);
  }

  /** 收藏分类（POST /api/v4/favorites/class/get，只读） */
  async fetchFavoriteClasses(): Promise<FavoriteClass[]> {
    const resp: RawFavoriteClassEnvelope =
      await this.http.postForm<RawFavoriteClassEnvelope>('/api/v4/favorites/class/get', {});
    try {
      const classes: FavoriteClass[] = parseFavoriteClasses(resp);
      Logger.info(TAG, `收藏分类: ${classes.length} 个`);
      return classes;
    } catch (e) {
      this.reportAuthFailure(e);
      Logger.warn(TAG, `收藏分类解析失败: ${(e as Error).message}`);
      throw e as Error;
    }
  }

  /**
   * 阅读 / 收藏 / 高质量排行榜（Phase 14-Q）。
   * 证据（首方 rankings-CYXAJkYb.js）：POST /api/readLeaderboard、/api/favLeaderboard 传 {page,type}，
   * /api/proportion 只传 {page}；响应 { status, info: Book[], len }，每页 20。
   * @param kind reading | favorite | quality
   * @param page 页码，从 1 开始
   * @param period day | week | moon（quality 忽略，且绝不发送）
   */
  async fetchLeaderboard(kind: string, page: number, period: string): Promise<PageInfo<Comic>> {
    const path: string = rankKindPath(kind);
    const form: Record<string, string> = buildLeaderboardForm(kind, page, period);
    const resp: RawLeaderboardEnvelope =
      await this.http.postForm<RawLeaderboardEnvelope>(path, form);
    try {
      const result: PageInfo<Comic> = parseLeaderboardPage(resp, page);
      Logger.info(TAG,
        `榜单 ${kind}/${form['type'] ?? '-'} 第${page}页: ${result.list.length}条, ` +
        `len=${result.totalCount}, totalPages=${result.totalPages}`);
      return result;
    } catch (e) {
      this.reportAuthFailure(e);
      Logger.warn(TAG, `榜单(${kind})解析失败: ${(e as Error).message}`);
      throw e as Error;
    }
  }

  /**
   * 个人化精选（Phase 14-Q）：POST /api/favoritesrecommend，表单 {page}。
   * 响应 { status, info: Book[], len }；未登录返回 status=login → AuthRequiredError。
   */
  async fetchRecommend(page: number): Promise<PageInfo<Comic>> {
    const form: Record<string, string> = buildRecommendForm(page);
    const resp: RawLeaderboardEnvelope =
      await this.http.postForm<RawLeaderboardEnvelope>('/api/favoritesrecommend', form);
    try {
      const result: PageInfo<Comic> = parseLeaderboardPage(resp, page);
      Logger.info(TAG,
        `个人化精选第${page}页: ${result.list.length}条, len=${result.totalCount}`);
      return result;
    } catch (e) {
      this.reportAuthFailure(e);
      Logger.warn(TAG, `个人化精选解析失败: ${(e as Error).message}`);
      throw e as Error;
    }
  }

  /**
   * 分类目录（Phase 14-Q）：POST /api/bigtaglist，空表单。
   * 响应 { status, data: [{tag, search, cover}] }；cover 是漫画 Bid，不是分类 ID。
   */
  async fetchBigTags(): Promise<BigTagItem[]> {
    const resp: RawBigTagEnvelope =
      await this.http.postForm<RawBigTagEnvelope>('/api/bigtaglist', {});
    try {
      const items: BigTagItem[] = parseBigTagList(resp);
      Logger.info(TAG, `分类目录: ${items.length} 项`);
      return items;
    } catch (e) {
      this.reportAuthFailure(e);
      Logger.warn(TAG, `分类目录解析失败: ${(e as Error).message}`);
      throw e as Error;
    }
  }

  /**
   * 业务请求发现会话失效时统一上报全局认证状态（四处调用点共用，避免判定逻辑漂移）。
   * Phase 11 审计：判定收口到 `notifyIfSessionExpired()` 纯函数，只认
   * `AuthRequiredError`（即服务端 200 + status=login）。协议错误、5xx、
   * JSON 解析失败、超时都**不会**触发降级、更不会删除 Cookie。
   * 只有当前确实是「已登录」才会降级（AuthManager 内部守卫），
   * 因此匿名用户的正常 status=login 不会污染状态机。
   */
  private reportAuthFailure(e: Object): void {
    notifyIfSessionExpired(e, () => {
      AuthManager.getInstance().notifySessionExpired();
    });
  }
}

/** 全局唯一实例：ViewModel 层统一引用该实例，为后续「多源切换」预留注册点 */
export const noyAcgSource: NoyAcgSource = new NoyAcgSource();
