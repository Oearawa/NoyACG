/**
 * DiscoverySourcePort.ets —— 内容发现相关的最小端口（Phase 14-Q）
 *
 * 与 IComicSource 分开，避免改动既有接口（其实现/测试桩遍布详情、阅读器、下载等模块）。
 * NoyAcgSource 显式实现本端口；Repository 只依赖端口，单测可注入 Fake。
 */
import { Comic } from '../model/Comic';
import { PageInfo } from '../model/PageInfo';
import { BigTagItem } from '../model/LeaderboardModels';

/** 排行榜：阅读 / 收藏 / 高质量（kind 决定端点，period 仅前两者使用）。 */
export interface LeaderboardPort {
  fetchLeaderboard(kind: string, page: number, period: string): Promise<PageInfo<Comic>>;
}

/** 个人化精选：官方收藏推荐。 */
export interface RecommendPort {
  fetchRecommend(page: number): Promise<PageInfo<Comic>>;
}

/** 分类目录：官方 bigtaglist。 */
export interface BigTagPort {
  fetchBigTags(): Promise<BigTagItem[]>;
}
