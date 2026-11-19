/**
 * AccountFavoriteRepository.ets —— 账号收藏数据访问层（Phase 14-J2 + I-000002）
 *
 * 职责：封装账号收藏端口（只读 + toggle 写），不拼 HTTP、不碰 Cookie。
 * 端口默认实现为 NoyAcgSource（/api/v4/favorites/get、/class/get、/toggle）。
 *
 * I-000002：toggleFavorite(bid) 为唯一写能力（契约：POST /api/v4/favorites/toggle 表单 { bid }）；
 * class 增删改 / migrate 仍未暴露，杜绝其余误改账号收藏。
 */
import { Comic } from '../model/Comic';
import { PageInfo } from '../model/PageInfo';
import { FavoriteClass } from '../model/FavoriteClass';
import { AccountFavoritePort } from '../source/AccountFavoritePort';
import { noyAcgSource } from '../source/NoyAcgSource';
import { FAVORITE_CLASS_ALL } from '../source/NoyAcgProtocol';

export class AccountFavoriteRepository {
  private port: AccountFavoritePort;

  constructor(port?: AccountFavoritePort) {
    this.port = port ?? noyAcgSource;
  }

  /** 拉取账号收藏分页（classId 默认 all） */
  async fetchPage(page: number, classId: string = FAVORITE_CLASS_ALL): Promise<PageInfo<Comic>> {
    return this.port.fetchAccountFavorites(page, classId);
  }

  /** 拉取收藏分类 */
  async fetchClasses(): Promise<FavoriteClass[]> {
    return this.port.fetchFavoriteClasses();
  }

  /**
   * 账号收藏 toggle（I-000002 写路径）。透传端口实现：
   * POST /api/v4/favorites/toggle，表单 { bid }（契约见 AccountFavoritePort）。
   */
  async toggleFavorite(bid: string): Promise<void> {
    return this.port.toggleFavorite(bid);
  }
}
