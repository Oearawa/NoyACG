/**
 * BookRecommend.ets —— 漫画相关推荐条目（详情响应 `book.recommend[]`）
 *
 * Phase 14-I 新增。字段为**小写下划线**风格（与 Book 的帕斯卡命名不同）：
 * `bid / bookname / author / tags / views / favorites / mode / status`。
 *
 * 注意：`mode` / `status` 是**布尔值**，与 `Book.Mode` / `Book.Status` 的整数不同；
 * 本模型不把布尔 `status` 强行映射成连载/完结徽标（语义未与整数 Status 做等价验证），
 * 只保留展示所需的确定性字段：标题、作者、标签、封面、浏览/收藏数。
 */
@ObservedV2
export class BookRecommend {
  /** 推荐书籍 id（bid） */
  @Trace bid: string = '';
  /** 书名 */
  @Trace title: string = '';
  /** 作者 */
  @Trace author: string = '';
  /** 标签（空格分隔原始串，客户端不拆解语义） */
  @Trace tags: string = '';
  /** 封面地址（客户端按图片 CDN 规则拼装） */
  @Trace cover: string = '';
  /** 浏览量 */
  @Trace views: number = 0;
  /** 收藏数 */
  @Trace favorites: number = 0;

  constructor() {
  }
}
