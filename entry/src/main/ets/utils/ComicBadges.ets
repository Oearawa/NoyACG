/**
 * ComicBadges.ets —— 漫画封面角标规则（唯一真相源，Phase 14-S）
 *
 * 背景（旧实现的真实缺陷）：
 * 1. `mapCompletionStatus('')` 曾把**空字符串**映射成 `false`（= 连载中），
 *    于是「状态缺失」被当成「连载中」显示；
 * 2. 各封面组件各自写 `if (isCompleted !== null) Text(isCompleted ? '已完结' : '连载中')`，
 *    一旦映射层给了 false，就再也分不清「确认连载中」和「未知状态」。
 *
 * 本文件只做纯决策，返回**角标标识**而不是文案（文案由组件用 `$r()` 解析），因此：
 * - 可被单元测试逐条覆盖；
 * - 组件与页面之间不会出现第二套判断逻辑；
 * - 新增状态/关键词只需改这一处。
 *
 * 允许的角标只有两类：
 *   A. 状态角标：仅当 `isCompleted === true / false`（已由协议层确认）时出现；
 *   B. 关键词角标：仅从**漫画真实标签串**（服务端 Ptag/Otag 映射出的 categories）中匹配。
 * 其余一切（null / undefined / 未知状态 / 无标签）都不产生角标。
 */
import { normalizeTag, parseTagList } from './BlockedTags';

/** 角标类别 */
export const BADGE_KIND_STATUS: string = 'status';
export const BADGE_KIND_KEYWORD: string = 'keyword';

/** 状态角标标识 */
export const BADGE_STATUS_COMPLETED: string = 'status_completed';
export const BADGE_STATUS_ONGOING: string = 'status_ongoing';
/** 关键词角标标识（顺序即展示顺序） */
export const BADGE_KEYWORD_KINKY: string = 'kw_kinky';
export const BADGE_KEYWORD_NTR: string = 'kw_ntr';
export const BADGE_KEYWORD_UNCLE: string = 'kw_uncle';

/** 单个角标（只含标识与类别，不含文案） */
export class ComicBadgeSpec {
  /** 稳定标识（同时用作 i18n key 后缀与 ForEach key） */
  readonly id: string;
  /** 类别：status / keyword */
  readonly kind: string;

  constructor(id: string, kind: string) {
    this.id = id;
    this.kind = kind;
  }
}

/**
 * 状态角标：只接受协议层已确认的布尔语义。
 * `null`（未提供 / 无法解析）→ 不显示，绝不默认「连载中」。
 */
export function resolveStatusBadge(isCompleted: boolean | null | undefined): ComicBadgeSpec | null {
  if (isCompleted === true) {
    return new ComicBadgeSpec(BADGE_STATUS_COMPLETED, BADGE_KIND_STATUS);
  }
  if (isCompleted === false) {
    return new ComicBadgeSpec(BADGE_STATUS_ONGOING, BADGE_KIND_STATUS);
  }
  return null;
}

/**
 * 单个标签文本 → 关键词角标（未命中返回 null）。
 *
 * 匹配规则（任务书 §2.2-B）：
 * - 「重口」与「重口味」统一为「重口」；
 * - 「NTR」大小写不敏感；
 * - 「大叔」精确匹配；
 * - 只匹配**完整标签项**，不做「包含」匹配（`大叔控` 不会命中「大叔」）。
 */
export function keywordBadgeOfTag(tag: string | null | undefined): ComicBadgeSpec | null {
  const key: string = normalizeTag(tag);
  if (key === '') {
    return null;
  }
  if (key === '重口味' || key === '重口') {
    return new ComicBadgeSpec(BADGE_KEYWORD_KINKY, BADGE_KIND_KEYWORD);
  }
  if (key === 'ntr') {
    return new ComicBadgeSpec(BADGE_KEYWORD_NTR, BADGE_KIND_KEYWORD);
  }
  if (key === '大叔') {
    return new ComicBadgeSpec(BADGE_KEYWORD_UNCLE, BADGE_KIND_KEYWORD);
  }
  return null;
}

/** 关键词角标的固定展示顺序（重口 → NTR → 大叔） */
const KEYWORD_ORDER: string[] = [BADGE_KEYWORD_KINKY, BADGE_KEYWORD_NTR, BADGE_KEYWORD_UNCLE];

/**
 * 从漫画标签串解析关键词角标。
 * - 输入必须是**当前漫画自己的**标签串（服务端 Ptag/Otag）；
 * - 空串 / null → 空数组（不显示任何关键词角标）；
 * - 去重且按固定顺序输出。
 */
export function resolveKeywordBadges(categories: string | null | undefined): ComicBadgeSpec[] {
  const tags: string[] = parseTagList(categories);
  if (tags.length === 0) {
    return [];
  }
  const found: string[] = [];
  for (let i = 0; i < tags.length; i++) {
    const badge: ComicBadgeSpec | null = keywordBadgeOfTag(tags[i]);
    if (badge !== null && found.indexOf(badge.id) < 0) {
      found.push(badge.id);
    }
  }
  if (found.length === 0) {
    return [];
  }
  const result: ComicBadgeSpec[] = [];
  for (let i = 0; i < KEYWORD_ORDER.length; i++) {
    const id: string = KEYWORD_ORDER[i];
    if (found.indexOf(id) >= 0) {
      result.push(new ComicBadgeSpec(id, BADGE_KIND_KEYWORD));
    }
  }
  return result;
}

/**
 * 从**完整标签数组**解析关键词角标（Phase 14-T，UI 实际使用入口）。
 *
 * 与 `resolveKeywordBadges(categories)` 的区别：
 * - 输入是漫画 `Comic.ptag`（服务端 Ptag 全量、未截断、未混入 Otag）；
 * - 避免「第 7 个标签被截断」与「Otag 原作名误命中」两类误判。
 *
 * 匹配规则不变：完整标签项精确匹配、固定顺序（重口 → NTR → 大叔）、去重。
 */
export function resolveKeywordBadgesFromTags(tags: string[] | null | undefined): ComicBadgeSpec[] {
  if (tags === null || tags === undefined || tags.length === 0) {
    return [];
  }
  const found: string[] = [];
  for (let i = 0; i < tags.length; i++) {
    const badge: ComicBadgeSpec | null = keywordBadgeOfTag(tags[i]);
    if (badge !== null && found.indexOf(badge.id) < 0) {
      found.push(badge.id);
    }
  }
  if (found.length === 0) {
    return [];
  }
  const result: ComicBadgeSpec[] = [];
  for (let i = 0; i < KEYWORD_ORDER.length; i++) {
    const id: string = KEYWORD_ORDER[i];
    if (found.indexOf(id) >= 0) {
      result.push(new ComicBadgeSpec(id, BADGE_KIND_KEYWORD));
    }
  }
  return result;
}

/**
 * 组合解析：关键词角标（左）+ 状态角标（右）。
 * 拆成两个返回值而不是一个数组，因为两者在封面上的**位置与配色都不同**
 * （状态右上有语义色，关键词左上为半透明中性底），混在一个数组里会互相遮挡。
 */
export class ComicBadgeSet {
  readonly status: ComicBadgeSpec | null;
  readonly keywords: ComicBadgeSpec[];

  constructor(status: ComicBadgeSpec | null, keywords: ComicBadgeSpec[]) {
    this.status = status;
    this.keywords = keywords;
  }

  isEmpty(): boolean {
    return this.status === null && this.keywords.length === 0;
  }
}

/** 唯一入口：调用方只需提供「已确认的完结状态」与「自身标签串」 */
export function resolveComicBadges(isCompleted: boolean | null | undefined,
  categories: string | null | undefined): ComicBadgeSet {
  return new ComicBadgeSet(resolveStatusBadge(isCompleted), resolveKeywordBadges(categories));
}

/**
 * 唯一入口（UI 使用）：`isCompleted` 必须来自协议层 `resolveCompletion()`，
 * `tags` 必须是漫画自身的完整 Ptag 列表。
 */
export function resolveComicBadgesFromTags(isCompleted: boolean | null | undefined,
  tags: string[] | null | undefined): ComicBadgeSet {
  return new ComicBadgeSet(resolveStatusBadge(isCompleted), resolveKeywordBadgesFromTags(tags));
}
