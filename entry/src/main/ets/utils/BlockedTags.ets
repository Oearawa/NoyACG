/**
 * BlockedTags.ets —— 标签屏蔽的纯逻辑（Phase 14-R）
 *
 * 只做「字符串规范化 / 集合判定 / 列表过滤」，不碰 Preferences、不碰 UI，
 * 因此可以被单元测试直接覆盖，也保证过滤规则全应用唯一。
 *
 * 关键约定（与任务书一致）：
 * 1. 精确匹配：屏蔽「校園」不会顺带屏蔽「校園生活」——归一化后必须完全相等；
 * 2. 归一化只做：去首尾空白、压缩内部连续空白 → 单个空格、拉丁字母小写；
 *    不做繁简转换、不做模糊包含、不做去标点（服务端 tag 原样保留）；
 * 3. 空标签一律拒绝：空串不是有效屏蔽项，也不会参与匹配；
 * 4. 漫画无标签数据时不因「缺失」被屏蔽（无标签 = 不匹配任何规则）。
 */

/** 单条屏蔽标签的最大长度（防御异常输入写入 Preferences） */
export const MAX_TAG_LENGTH: number = 40;
/** 屏蔽标签数量上限（有界，防止无限增长） */
export const MAX_BLOCKED_TAGS: number = 200;

/**
 * 标签归一化：唯一实现处。
 * - null / undefined / 非字符串 → 空串（调用方据此判定「无效」）
 * - 全角空格也视为空白（\u3000），避免从正文复制标签后匹配失败
 */
export function normalizeTag(raw: string | null | undefined): string {
  if (raw === null || raw === undefined || typeof raw !== 'string') {
    return '';
  }
  const collapsed: string = raw.replace(/[\s\u3000]+/g, ' ').trim();
  if (collapsed === '') {
    return '';
  }
  // 拉丁字符大小写归一；CJK 不受影响
  return collapsed.toLowerCase();
}

/**
 * 标签是否可以被加入黑名单。
 * 拒绝：空串 / 仅空白 / 超长（超长多半是被污染的脏数据，不是真实标签）。
 */
export function isValidBlockedTag(raw: string | null | undefined): boolean {
  const normalized: string = normalizeTag(raw);
  return normalized !== '' && normalized.length <= MAX_TAG_LENGTH;
}

/**
 * 把漫画的标签串（源站 Ptag，空格分隔）拆成展示标签数组。
 * 同时兼容 `、` 与 `,` 分隔（部分来源混用），并去重保持原始顺序。
 */
export function parseTagList(raw: string | null | undefined): string[] {
  if (raw === null || raw === undefined || typeof raw !== 'string') {
    return [];
  }
  const parts: string[] = raw.split(/[\s\u3000、,]+/);
  const result: string[] = [];
  const seen: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    const tag: string = parts[i].trim();
    if (tag === '') {
      continue;
    }
    const key: string = normalizeTag(tag);
    if (key === '' || seen.indexOf(key) >= 0) {
      continue;
    }
    seen.push(key);
    result.push(tag);
  }
  return result;
}

/**
 * 标签黑名单（不可变值对象）。
 * 内部只保存归一化后的值，判定时对入参再次归一化 —— 保证「大小写/多余空格」不影响命中。
 */
export class BlockedTagSet {
  /** 归一化后的屏蔽值（唯一、有序，顺序 = 加入顺序） */
  readonly values: string[];

  constructor(values: string[]) {
    const unique: string[] = [];
    for (let i = 0; i < values.length; i++) {
      const key: string = normalizeTag(values[i]);
      if (key === '' || key.length > MAX_TAG_LENGTH) {
        continue;
      }
      if (unique.indexOf(key) < 0) {
        unique.push(key);
      }
      if (unique.length >= MAX_BLOCKED_TAGS) {
        break;
      }
    }
    this.values = unique;
  }

  static empty(): BlockedTagSet {
    return new BlockedTagSet([]);
  }

  /** 从持久化数组安全重建（脏数据自动丢弃，不抛异常） */
  static fromPersisted(raw: string[] | null | undefined): BlockedTagSet {
    if (raw === null || raw === undefined || !Array.isArray(raw)) {
      return BlockedTagSet.empty();
    }
    return new BlockedTagSet(raw);
  }

  get size(): number {
    return this.values.length;
  }

  isEmpty(): boolean {
    return this.values.length === 0;
  }

  /** 精确匹配（入参归一化后完全相等才算命中） */
  contains(tag: string | null | undefined): boolean {
    const key: string = normalizeTag(tag);
    if (key === '') {
      return false;
    }
    return this.values.indexOf(key) >= 0;
  }

  /** 加入一条（已存在 / 非法 / 超上限时返回自身，不产生变更） */
  add(tag: string | null | undefined): BlockedTagSet {
    if (!isValidBlockedTag(tag) || this.values.length >= MAX_BLOCKED_TAGS) {
      return this;
    }
    const key: string = normalizeTag(tag);
    if (this.values.indexOf(key) >= 0) {
      return this;
    }
    const next: string[] = this.values.slice();
    next.push(key);
    return new BlockedTagSet(next);
  }

  /** 移除一条（不存在时返回自身） */
  remove(tag: string | null | undefined): BlockedTagSet {
    const key: string = normalizeTag(tag);
    const index: number = this.values.indexOf(key);
    if (index < 0) {
      return this;
    }
    const next: string[] = this.values.slice();
    next.splice(index, 1);
    return new BlockedTagSet(next);
  }

  /** 导出为可持久化数组（归一化值） */
  toPersisted(): string[] {
    return this.values.slice();
  }
}

/**
 * 漫画是否命中任一屏蔽标签。
 * 无标签数据（空串 / 全空白）→ 返回 false（不因缺失而误杀）。
 */
export function comicMatchesBlockedTags(categories: string | null | undefined,
  blocked: BlockedTagSet): boolean {
  if (blocked.isEmpty()) {
    return false;
  }
  const tags: string[] = parseTagList(categories);
  for (let i = 0; i < tags.length; i++) {
    if (blocked.contains(tags[i])) {
      return true;
    }
  }
  return false;
}

/** 过滤依赖的最小结构（Comic 满足该形状；这里不 import Comic，保持纯逻辑零依赖） */
export interface TaggedItem {
  categories: string;
}

/**
 * 列表过滤：保持原始顺序，只剔除命中屏蔽标签的条目。
 * 返回新数组（不修改入参），便于 LazyForEach 的稳定 key 比对。
 */
export function filterBlockedItems<T extends TaggedItem>(items: T[],
  blocked: BlockedTagSet): T[] {
  if (blocked.isEmpty() || items.length === 0) {
    return items;
  }
  const result: T[] = [];
  for (let i = 0; i < items.length; i++) {
    if (!comicMatchesBlockedTags(items[i].categories, blocked)) {
      result.push(items[i]);
    }
  }
  return result;
}

/** 被过滤掉的条目数（用于 UI「已按屏蔽标签过滤」提示与统计） */
export function blockedRemovedCount<T extends TaggedItem>(items: T[],
  blocked: BlockedTagSet): number {
  if (blocked.isEmpty() || items.length === 0) {
    return 0;
  }
  let removed: number = 0;
  for (let i = 0; i < items.length; i++) {
    if (comicMatchesBlockedTags(items[i].categories, blocked)) {
      removed++;
    }
  }
  return removed;
}

// ==================== 账号作用域 ====================

/** 未登录（匿名）作用域标识 */
export const BLOCKED_SCOPE_ANON: string = 'anon';
/** Preferences 键前缀：本地匿名配置 */
const KEY_PREFIX_ANON: string = 'blocked_tags_anon';
/** Preferences 键前缀：按账号隔离 */
const KEY_PREFIX_USER: string = 'blocked_tags_uid_';

/**
 * 作用域标识：空 uid → anon。
 * uid 只用于生成**本机 Preferences 键**，不参与任何网络请求。
 */
export function blockedScopeOf(uid: string | null | undefined): string {
  const value: string = uid === null || uid === undefined ? '' : uid.trim();
  return value === '' ? BLOCKED_SCOPE_ANON : value;
}

/**
 * 作用域 → Preferences 键。
 * uid 中的非法字符统一替换为下划线，避免把任意字符写进键名。
 */
export function blockedTagsStorageKey(uid: string | null | undefined): string {
  const scope: string = blockedScopeOf(uid);
  if (scope === BLOCKED_SCOPE_ANON) {
    return KEY_PREFIX_ANON;
  }
  return `${KEY_PREFIX_USER}${scope.replace(/[^0-9A-Za-z_-]/g, '_')}`;
}

/** 是否账号作用域（非匿名）。用于 UI 区分「仅本机 / 跟随账号」 */
export function isAccountScope(uid: string | null | undefined): boolean {
  return blockedScopeOf(uid) !== BLOCKED_SCOPE_ANON;
}
