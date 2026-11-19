/**
 * CachePolicy.ets —— 图片缓存容量策略（纯逻辑，Phase 14-R）
 *
 * 只做决策，不做 IO：
 * - 给定「上限 + 当前占用 + 每个文件的最近访问时间」，算出应该删哪些文件；
 * - 排序规则：最近访问时间升序（最久未访问先删），时间相同则按体积大者先删
 *   （同样收益下更快回到上限内）；
 * - 预留 10% headroom：一次清理回到 limit 的 90%，避免「删一个文件又立刻超限」抖动；
 * - 正在写入的文件（protected）永不入选。
 *
 * 真正的文件遍历与删除在 ImageCacheManager 中完成，本文件可被单元测试完整覆盖。
 */
import { CACHE_LIMIT_UNLIMITED } from './PreferenceManager';

/** 单个缓存文件的元数据（由 ImageCacheManager 从文件系统 + 访问索引组装） */
export class CacheFileMeta {
  /** 缓存文件名（不是完整路径） */
  readonly name: string;
  /** 字节数 */
  readonly size: number;
  /** 最近访问时间（毫秒时间戳；0 = 未知，按「最旧」处理） */
  readonly lastAccess: number;

  constructor(name: string, size: number, lastAccess: number) {
    this.name = name;
    this.size = size;
    this.lastAccess = lastAccess;
  }
}

/** 一次清理的执行结果（UI 只依赖该结构） */
export class CacheEvictionResult {
  /** 是否真的执行了删除 */
  readonly ran: boolean;
  /** 删除的文件数 */
  readonly deletedCount: number;
  /** 释放字节数 */
  readonly freedBytes: number;
  /** 清理后剩余字节数（-1 = 未重新统计） */
  readonly remainingBytes: number;
  /** 本次使用的上限（-1 = 无限制） */
  readonly limitBytes: number;

  constructor(ran: boolean, deletedCount: number, freedBytes: number,
    remainingBytes: number, limitBytes: number) {
    this.ran = ran;
    this.deletedCount = deletedCount;
    this.freedBytes = freedBytes;
    this.remainingBytes = remainingBytes;
    this.limitBytes = limitBytes;
  }

  static skipped(limitBytes: number): CacheEvictionResult {
    return new CacheEvictionResult(false, 0, 0, -1, limitBytes);
  }
}

/** 一次清理最多删除的文件数（有界，避免单次扫描/删除长时间占用） */
export const MAX_EVICTIONS_PER_RUN: number = 200;
/** 清理目标：回到上限的 90%（留 10% 抖动空间） */
export const EVICTION_TARGET_RATIO: number = 0.9;

/** 是否为「无限制」 */
export function isUnlimited(limitBytes: number): boolean {
  return limitBytes <= 0 || limitBytes === CACHE_LIMIT_UNLIMITED;
}

/** 是否需要清理：只有设置了正上限且已超出才需要 */
export function shouldEvict(currentBytes: number, limitBytes: number): boolean {
  if (isUnlimited(limitBytes)) {
    return false;
  }
  return currentBytes > limitBytes;
}

/** 清理目标字节数（limit 的 90%，至少为 0） */
export function evictionTargetBytes(limitBytes: number): number {
  if (isUnlimited(limitBytes)) {
    return 0;
  }
  return Math.max(0, Math.floor(limitBytes * EVICTION_TARGET_RATIO));
}

/**
 * 选出应删除的文件（按「最久未访问优先」）。
 * @param files        全部缓存文件元数据
 * @param currentBytes 当前总占用
 * @param limitBytes   上限（<=0 或 -1 表示无限制 → 不删任何文件）
 * @param isProtected  额外保护判定（如正在写入 / 正在显示），命中则永不入选
 * @returns 待删除文件（已排序，数量受 MAX_EVICTIONS_PER_RUN 限制）
 */
export function selectEvictions(files: CacheFileMeta[], currentBytes: number,
  limitBytes: number, isProtected?: (name: string) => boolean): CacheFileMeta[] {
  if (!shouldEvict(currentBytes, limitBytes) || files.length === 0) {
    return [];
  }
  const candidates: CacheFileMeta[] = [];
  for (let i = 0; i < files.length; i++) {
    const file: CacheFileMeta = files[i];
    if (file.size <= 0) {
      continue;
    }
    if (isProtected !== undefined && isProtected(file.name)) {
      continue;
    }
    candidates.push(file);
  }
  // 最久未访问优先；同一时间点优先删大文件
  candidates.sort((a: CacheFileMeta, b: CacheFileMeta): number => {
    const aTime: number = a.lastAccess > 0 ? a.lastAccess : 0;
    const bTime: number = b.lastAccess > 0 ? b.lastAccess : 0;
    if (aTime !== bTime) {
      return aTime - bTime;
    }
    return b.size - a.size;
  });

  const target: number = evictionTargetBytes(limitBytes);
  const selected: CacheFileMeta[] = [];
  let remaining: number = currentBytes;
  for (let i = 0; i < candidates.length; i++) {
    if (remaining <= target || selected.length >= MAX_EVICTIONS_PER_RUN) {
      break;
    }
    const file: CacheFileMeta = candidates[i];
    selected.push(file);
    remaining -= file.size;
  }
  return selected;
}

/**
 * 访问索引清洗：只保留仍然存在的文件（缓存目录被系统清理后索引会残留）。
 * @returns 过滤后的索引项（保持入参顺序）
 */
export function pruneAccessIndex(files: CacheFileMeta[],
  index: Map<string, number>): CacheFileMeta[] {
  const result: CacheFileMeta[] = [];
  for (let i = 0; i < files.length; i++) {
    const file: CacheFileMeta = files[i];
    const hit: number | undefined = index.get(file.name);
    const lastAccess: number = hit !== undefined ? hit : 0;
    result.push(new CacheFileMeta(file.name, file.size, lastAccess));
  }
  return result;
}

/** 容量上限的中文档位标识（i18n key 后缀；UI 据此取资源，不在逻辑层写文案） */
export function cacheLimitOptionKey(limitBytes: number): string {
  if (limitBytes === 524288000) {
    return 'mb500';
  }
  if (limitBytes === 1073741824) {
    return 'gb1';
  }
  return 'unlimited';
}
