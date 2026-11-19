/**
 * IComicSource.ets —— 漫画源适配器接口（Adapter 模式）
 *
 * 上层 UI / ViewModel 只依赖本接口编程，不感知任何具体源站实现；
 * 后续新增漫画源时只需再实现一个适配器并注册，无需改动 UI 层代码。
 * 阶段二将提供本接口的第一个实现：NoyAcgSource（解析 release.noymanga.com webapp 接口）。
 */
import { Comic } from '../model/Comic';
import { ComicDetail } from '../model/ComicDetail';
import { PageInfo } from '../model/PageInfo';
import { HomeFeed } from '../model/HomeFeed';
import { AdItem } from '../model/AdItem';
import { CommentPage } from '../model/BookComment';

export interface IComicSource {
  /** 源的唯一标识（用作本地偏好 / 持久化时的 key） */
  readonly sourceId: string;
  /** 源名称（用于 UI 展示与源切换） */
  readonly sourceName: string;
  /** 源站基地址 */
  readonly baseUrl: string;

  /**
   * 获取首页 / 最新列表
   * @param page 页码，从 1 开始
   * @param sort 排序（可选，默认 'new'）：new/views/favorites/rating（见 NoyAcgProtocol）
   * @param finished 完结筛选（可选，默认 ''）：''/true/false
   */
  getHomeList(page: number, sort?: string, finished?: string): Promise<PageInfo<Comic>>;

  /**
   * 搜索漫画
   * @param keyword  搜索关键词（标签搜索时传完整标签文本，不拆分空格）
   * @param page     页码，从 1 开始
   * @param mode     搜索范围（可选，协议值 default/tag/author，缺省 default）。
   *                 取值来源：首方前端搜索页范围内的下拉选项（已证据确认）。
   * @param sort     排序（可选，''/views/favorites/rating，缺省 ''；I-000003）
   * @param type     类型（可选，''/book/stream，缺省 ''；I-000003）
   * @param finished 完结筛选（可选，''/true/false，缺省 ''；I-000003）
   */
  search(keyword: string, page: number, mode?: string, sort?: string,
    type?: string, finished?: string): Promise<PageInfo<Comic>>;

  /**
   * 获取漫画详情（含章节列表）
   * @param id Comic.id
   */
  getComicDetail(id: string): Promise<ComicDetail>;

  /**
   * 获取章节的全部图片地址（按阅读顺序排列）
   *
   * Phase 10 调整：真实接口 GET /api/v4/book/detail/{bid}/{cid} 需要「书籍 id + 章节 id」
   * 两个独立参数，单参数签名无法表达，故升级为双参数（旧假实现已移除）。
   * @param bookId    Comic.id（书籍 id）
   * @param chapterId Chapter.id
   */
  getChapterImages(bookId: string, chapterId: string): Promise<string[]>;

  /**
   * 获取首页聚合数据（Phase 14-I 新增，POST /api/home）。
   * 与 getHomeList（/b1/booklist 分页）分工：本方法是一次性聚合（公告/榜单/动画/标签），
   * 无分页；getHomeList 仍服务于「最新」Tab 的稳定分页语义。
   * @param adultLevel 内容分级 allow-adult：false/true/both；缺省时由源实现按用户设置解析（默认 false）
   */
  getHomeFeed(adultLevel?: string): Promise<HomeFeed>;

  /**
   * 获取首页广告位（Phase 14-I 新增，POST /api/v3/ads）。
   * 广告独立于漫画推荐；支持空数据；返回的 url 已被协议层限定为 http/https。
   * @param adultLevel 内容分级 allow-adult；缺省时由源实现按用户设置解析（默认 false）
   */
  getAds(adultLevel?: string): Promise<AdItem[]>;

  /**
   * 获取书籍评论分页（Phase 14-I 新增，GET /api/v4/comment/book/{bid}/comments?page=）。
   * @param bookId Comic.id（书籍 id）
   * @param page   页码，从 1 开始
   */
  getBookComments(bookId: string, page: number): Promise<CommentPage>;
}
