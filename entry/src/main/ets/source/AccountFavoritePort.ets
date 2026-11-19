/**
 * AccountFavoritePort.ets —— 账号收藏端口（Phase 14-J2 + I-000002 写路径）
 *
 * 读取能力（Phase 14-J2）：
 *   - fetchAccountFavorites(page, classId) → 账号收藏书籍分页
 *   - fetchFavoriteClasses()               → 收藏分类
 * 写能力（I-000002，契约证据 PHASE14J2_REPORT.md §3）：
 *   - toggleFavorite(bid)                  → POST /api/v4/favorites/toggle 表单 { bid }
 *
 * 生产实现：NoyAcgSource（POST /api/v4/favorites/get、/class/get、/toggle）。
 * 仍不包含 class 增删改 / migrate 等其它写操作。
 */
import { Comic } from '../model/Comic';
import { PageInfo } from '../model/PageInfo';
import { FavoriteClass } from '../model/FavoriteClass';

export interface AccountFavoritePort {
  /** 拉取账号收藏（classId='all' 表示全部） */
  fetchAccountFavorites(page: number, classId: string): Promise<PageInfo<Comic>>;
  /** 拉取收藏分类（未登录抛 AuthRequiredError） */
  fetchFavoriteClasses(): Promise<FavoriteClass[]>;
  /**
   * 账号收藏 toggle（写）。POST /api/v4/favorites/toggle，表单 { bid }。
   * 成功（status=ok）返回；未登录抛 AuthRequiredError，业务拒绝抛 ProtocolError。
   * 不返回新状态（契约无该字段证据），新状态由调用方乐观取反 + /get 校准。
   */
  toggleFavorite(bid: string): Promise<void>;
}
