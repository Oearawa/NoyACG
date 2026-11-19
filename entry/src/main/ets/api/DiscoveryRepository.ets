/**
 * DiscoveryRepository.ets —— 内容发现页的聚合数据源封装（Phase 14-N / 14-Q）
 *
 * UI → ViewModel → Repository → Source 分层。
 * - 保留 Phase 14-N 的 HomeFeedPort（首页聚合，Phase 14-N 的 Rank/Category 旧实现仍在用）；
 * - Phase 14-Q 新增三个端口实现：排行榜 / 个人化精选 / 分类目录，全部走官方真实端点；
 * - 个人化精选与分类目录带**内存页缓存**，按「用户身份 + 内容分级」隔离，绝不跨账号/跨分级复用。
 */
import { HomeFeed } from '../model/HomeFeed';
import { Comic } from '../model/Comic';
import { PageInfo } from '../model/PageInfo';
import { BigTagItem } from '../model/LeaderboardModels';
import { IComicSource } from '../source/IComicSource';
import { noyAcgSource } from '../source/NoyAcgSource';
import { BigTagPort, LeaderboardPort, RecommendPort } from '../source/DiscoverySourcePort';
import { AuthManager } from '../utils/AuthManager';
import { ContentRatingPolicy } from '../utils/ContentRatingPolicy';
import { filterComics, filterPageInfo } from './ContentFilter';

export interface HomeFeedPort {
  getHomeFeed(): Promise<HomeFeed>;
}

export class DiscoveryRepository implements HomeFeedPort {
  private source: IComicSource;

  constructor(source?: IComicSource) {
    this.source = source ?? noyAcgSource;
  }

  async getHomeFeed(): Promise<HomeFeed> {
    const feed: HomeFeed = await this.source.getHomeFeed();
    // 分类代表封面只用真实漫画；先按屏蔽标签过滤，避免把用户不想看的题材作为分类门面
    feed.readDay = filterComics(feed.readDay);
    feed.favDay = filterComics(feed.favDay);
    feed.fs = filterComics(feed.fs);
    feed.proportion = filterComics(feed.proportion);
    return feed;
  }
}

/** 榜单仓库：只做转发，不做客户端重排/切片（排序由服务端决定）。 */
export class LeaderboardRepository implements LeaderboardPort {
  private source: LeaderboardPort;

  constructor(source?: LeaderboardPort) {
    this.source = source ?? noyAcgSource;
  }

  async fetchLeaderboard(kind: string, page: number, period: string): Promise<PageInfo<Comic>> {
    // Phase 14-R：只过滤 list；服务端 len / totalPages 原样保留（过滤不改写分页语义）
    return filterPageInfo(await this.source.fetchLeaderboard(kind, page, period));
  }
}

/**
 * 缓存隔离键：用户 uid（未登录为 anonymous）+ 内容分级 + 页号。
 * 换账号 / 切换 allow-adult 后会得到不同的 key，天然不会串数据。
 */
export function discoveryCacheKey(kind: string, page: number): string {
  const user = AuthManager.getInstance().user;
  const uid: string = user !== null && user.uid !== '' ? user.uid : 'anonymous';
  const rating: string = ContentRatingPolicy.getInstance().resolve();
  return `${kind}|${uid}|${rating}|${page}`;
}

interface CacheEntry<T> {
  value: T;
  stamp: number;
}

/** 有界内存缓存（避免为推荐/分类建立复杂持久化系统）。LRU + TTL。 */
class BoundedCache<T> {
  private map: Map<string, CacheEntry<T>> = new Map<string, CacheEntry<T>>();
  private order: string[] = [];
  private readonly limit: number;
  private readonly ttlMs: number;

  constructor(limit: number, ttlMs: number) {
    this.limit = limit > 0 ? Math.floor(limit) : 1;
    this.ttlMs = ttlMs > 0 ? ttlMs : 0;
  }

  get(key: string): T | null {
    const entry: CacheEntry<T> | undefined = this.map.get(key);
    if (entry === undefined) {
      return null;
    }
    if (this.ttlMs > 0 && Date.now() - entry.stamp > this.ttlMs) {
      this.map.delete(key);
      const index: number = this.order.indexOf(key);
      if (index >= 0) {
        this.order.splice(index, 1);
      }
      return null;
    }
    this.touch(key);
    return entry.value;
  }

  put(key: string, value: T): void {
    if (this.map.has(key)) {
      this.touch(key);
    } else {
      this.order.push(key);
    }
    this.map.set(key, { value, stamp: Date.now() });
    while (this.order.length > this.limit) {
      const oldest: string | undefined = this.order.shift();
      if (oldest !== undefined) {
        this.map.delete(oldest);
      }
    }
  }

  clear(): void {
    this.map.clear();
    this.order = [];
  }

  size(): number {
    return this.map.size;
  }

  private touch(key: string): void {
    const index: number = this.order.indexOf(key);
    if (index >= 0) {
      this.order.splice(index, 1);
      this.order.push(key);
    }
  }
}

/**
 * 个人化精选仓库：page 级内存缓存（10 分钟 / 最多 8 页）。
 * 只缓存成功且非空的页；失败不缓存，避免把错误固化成「暂无推荐」。
 */
export class RecommendRepository implements RecommendPort {
  private source: RecommendPort;
  private cache: BoundedCache<PageInfo<Comic>> = new BoundedCache<PageInfo<Comic>>(8, 10 * 60 * 1000);
  /**
   * 缓存所属的内容分级（Phase 14-S）。
   * 缓存 key 本身已含分级，这里额外做「分级变化即清空」是为了：
   * 切换分级后不再让旧分级的页继续占内存，且避免任何误用旧 key 的可能。
   */
  private cacheRating: string = '';

  constructor(source?: RecommendPort) {
    this.source = source ?? noyAcgSource;
  }

  async fetchRecommend(page: number): Promise<PageInfo<Comic>> {
    this.ensureRatingScope();
    const key: string = discoveryCacheKey('recommend', page);
    const hit: PageInfo<Comic> | null = this.cache.get(key);
    if (hit !== null) {
      return filterPageInfo(hit);
    }
    const fresh: PageInfo<Comic> = await this.source.fetchRecommend(page);
    if (fresh.list.length > 0) {
      // 缓存保留服务端原始页，过滤在返回时进行 —— 修改黑名单后无需等缓存过期即刻生效
      this.cache.put(key, fresh);
    }
    return filterPageInfo(fresh);
  }

  /** 分级变化则丢弃旧分级缓存（Phase 14-S） */
  private ensureRatingScope(): void {
    const rating: string = ContentRatingPolicy.getInstance().resolve();
    if (rating !== this.cacheRating) {
      this.cacheRating = rating;
      this.cache.clear();
    }
  }

  /** 登出 / 账号切换时清空，避免推荐结果跨用户复用。 */
  invalidate(): void {
    this.cache.clear();
  }

  cacheSize(): number {
    return this.cache.size();
  }
}

/**
 * 分类目录仓库：整表缓存（30 分钟），因为 bigtaglist 无分页、一次返回全部。
 * 分类目录随内容分级可能变化，故 key 含分级。
 */
export class BigTagRepository implements BigTagPort {
  private source: BigTagPort;
  private cache: BoundedCache<BigTagItem[]> = new BoundedCache<BigTagItem[]>(4, 30 * 60 * 1000);
  /** 缓存所属的内容分级（Phase 14-S）：分类目录随分级变化，变化即清空 */
  private cacheRating: string = '';

  constructor(source?: BigTagPort) {
    this.source = source ?? noyAcgSource;
  }

  async fetchBigTags(): Promise<BigTagItem[]> {
    this.ensureRatingScope();
    const key: string = discoveryCacheKey('bigtags', 1);
    const hit: BigTagItem[] | null = this.cache.get(key);
    if (hit !== null) {
      return hit;
    }
    const fresh: BigTagItem[] = await this.source.fetchBigTags();
    if (fresh.length > 0) {
      this.cache.put(key, fresh);
    }
    return fresh;
  }

  /** 分级变化则丢弃旧分级缓存（Phase 14-S） */
  private ensureRatingScope(): void {
    const rating: string = ContentRatingPolicy.getInstance().resolve();
    if (rating !== this.cacheRating) {
      this.cacheRating = rating;
      this.cache.clear();
    }
  }

  invalidate(): void {
    this.cache.clear();
  }

  cacheSize(): number {
    return this.cache.size();
  }
}
