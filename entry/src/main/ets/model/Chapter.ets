/**
 * Chapter.ets —— 章节信息实体
 *
 * 隶属于某部漫画 / 某个章节分组（ComicDetail.groups）。
 * 阅读器通过 (bookId, chapter.id) 调用 IComicSource.getChapterImages() 获取图片列表。
 *
 * Phase 11：补齐首方详情分包的真实字段（见 API_PROTOCOL_AUDIT.md 附录 A.3）：
 * `groupId / sort / pageCount / createdAt`，并保留既有 `id/title/order/updatedAt/isRead`
 * 以免破坏 Phase 7–10 的 UI 与测试。
 *
 * 字段语义（避免混淆）：
 * - `sort`      = 服务端给的组内排序键，**目录排序只用它**，不按标题字符串排；
 * - `order`     = 客户端拍平后的展示序号（1 起），仅用于 UI 显示；
 * - `pageCount` = 目录里显示的 `(N P)`，**不是**读图接口的图片数（未验证相等）；
 * - `updatedAt` = `created_at` 的兼容别名（Phase 14-I 起按 unix 秒格式化为 YYYY-MM-DD）。
 */
@ObservedV2
export class Chapter {
  /** 章节唯一标识 */
  @Trace id: string = '';
  /** 章节标题（如「第 12 话」） */
  @Trace title: string = '';
  /** 客户端拍平后的展示序号（1 起；仅用于 UI 显示） */
  @Trace order: number = 0;
  /** 章节更新时间 / created_at（源站原始字符串，不猜测格式） */
  @Trace updatedAt: string = '';
  /** 本地已读标记（配合阅读进度功能） */
  @Trace isRead: boolean = false;

  /** 所属分组 id（无分组时为 ''） */
  @Trace groupId: string = '';
  /** 所属分组名称（无分组时为 ''） */
  @Trace groupName: string = '';
  /** 服务端排序键（缺失/非数值时为 0，此时保留服务端原始顺序） */
  @Trace sort: number = 0;
  /** 章节摘要页数（首方显示 `(N P)`；0 = 响应未提供，不用于推导图片列表） */
  @Trace pageCount: number = 0;

  constructor(id: string = '', title: string = '', order: number = 0,
    updatedAt: string = '', isRead: boolean = false, groupId: string = '',
    groupName: string = '', sort: number = 0, pageCount: number = 0) {
    this.id = id;
    this.title = title;
    this.order = order;
    this.updatedAt = updatedAt;
    this.isRead = isRead;
    this.groupId = groupId;
    this.groupName = groupName;
    this.sort = sort;
    this.pageCount = pageCount;
  }
}
