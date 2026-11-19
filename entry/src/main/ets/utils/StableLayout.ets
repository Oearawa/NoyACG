/**
 * StableLayout.ets —— 图片/文本/列表稳定性纯逻辑（Phase 14-O）
 *
 * 不依赖 ArkUI 组件实例；UI 与单元测试共用同一份规则。
 * 目标：固定几何、稳定 key、只对真正变化的列表项发通知，避免图片节点被整表重建。
 */
import { Comic } from '../model/Comic';
import { ThemeDims } from './Theme';

/** 网格封面首帧兜底高度：用已有最小卡宽和统一封面比例算，不再从 0 跳变。 */
export const STABLE_COVER_FALLBACK_HEIGHT: number = ThemeDims.COVER_FALLBACK_HEIGHT;

/** 列表项封面默认宽度与稳定信息区高度。 */
export const LIST_COVER_WIDTH: number = ThemeDims.LIST_COVER_WIDTH;
export const STABLE_LIST_INFO_HEIGHT: number = ThemeDims.LIST_INFO_STABLE_HEIGHT;

/** 卡片文本统一行高、行数与最小高度，避免字段异步出现时插入/删除整行。 */
export interface CardTextLayoutSpec {
  titleMaxLines: number;
  titleLineHeight: number;
  metaMaxLines: number;
  metaLineHeight: number;
  descMaxLines: number;
  descLineHeight: number;
  tagRowMinHeight: number;
  posterInfoMinHeight: number;
  overflow: TextOverflow;
}

export const CARD_TEXT_LAYOUT: CardTextLayoutSpec = {
  titleMaxLines: 2,
  titleLineHeight: ThemeDims.TITLE_CARD_LINE_HEIGHT,
  metaMaxLines: 1,
  metaLineHeight: ThemeDims.META_LINE_HEIGHT,
  descMaxLines: 2,
  descLineHeight: ThemeDims.DESC_LINE_HEIGHT,
  tagRowMinHeight: ThemeDims.TAG_ROW_MIN_HEIGHT,
  posterInfoMinHeight: ThemeDims.POSTER_INFO_MIN_HEIGHT,
  overflow: TextOverflow.Ellipsis
};

export interface ImageGeometrySpec {
  mode: string;
  width: string;
  height: string;
  aspectRatio: number;
  minHeight: number;
}

/**
 * 同一场景 Loading / Success / Error 必须返回同一份几何规格。
 * streamAspectRatio=0 表示没有可信尺寸元数据：保留 minHeight 兜底，但不伪装成已知比例。
 */
export function stableImageGeometry(
  coverRatio: number,
  fillPage: boolean,
  streamAspectRatio: number
): ImageGeometrySpec {
  if (coverRatio > 0) {
    return { mode: 'cover', width: '100%', height: '', aspectRatio: coverRatio, minHeight: 0 };
  }
  if (fillPage) {
    return { mode: 'page', width: '100%', height: '100%', aspectRatio: 0, minHeight: 0 };
  }
  return {
    mode: 'stream',
    width: '100%',
    height: '',
    aspectRatio: streamAspectRatio > 0 ? streamAspectRatio : 0,
    minHeight: 180
  };
}

/** 同一 URL 且已成功显示时，父组件无关状态更新不应重新进入 Loading。 */
export function shouldReloadImage(
  currentUrl: string,
  nextUrl: string,
  loadedUrl: string,
  hasError: boolean
): boolean {
  if (nextUrl === '' || nextUrl !== currentUrl) {
    return true;
  }
  if (loadedUrl !== nextUrl || hasError) {
    return true;
  }
  return false;
}

/** 稳定 key 基本判定：非空、不含占位/下标噪声。 */
export function isStableKey(key: string): boolean {
  if (key === '' || key.indexOf('undefined') >= 0 || key.indexOf('null') >= 0) {
    return false;
  }
  return true;
}

/**
 * Comic 显示指纹：覆盖列表卡片会读取的全部字段。
 * 文本字段变化会触发单条 notifyDataChange；cover/id 不变时图片节点不需要重下载。
 */
export function comicDisplayFingerprint(comic: Comic): string {
  return [
    comic.id,
    comic.title,
    comic.cover,
    comic.author,
    comic.categories,
    comic.latestChapter,
    comic.updatedAt,
    String(comic.ratingSum),
    String(comic.views),
    String(comic.favorites),
    comic.publishYear,
    String(comic.pageCount),
    comic.description,
    String(comic.mode),
    comic.ptag.join(' '),
    comic.isCompleted === null ? 'null' : (comic.isCompleted ? 'done' : 'ongoing')
  ].join('\u001f');
}

export interface ListUpdatePlan {
  fullReload: boolean;
  changed: number[];
  added: number[];
  removed: number[];
}

function hasDuplicateKeys(keys: string[]): boolean {
  const seen: Set<string> = new Set<string>();
  for (let i = 0; i < keys.length; i++) {
    if (!isStableKey(keys[i]) || seen.has(keys[i])) {
      return true;
    }
    seen.add(keys[i]);
  }
  return false;
}

/**
 * 只支持「共同前缀内字段变化 + 尾部追加/删除」的增量更新。
 * 中间插入、重排、重复 key 都回退到整表 reload，避免错误复用旧图片节点。
 */
export function planStableListUpdate<T>(
  oldItems: T[],
  newItems: T[],
  keyOf: (item: T) => string,
  fingerprintOf: (item: T) => string
): ListUpdatePlan {
  const oldKeys: string[] = [];
  const newKeys: string[] = [];
  for (let i = 0; i < oldItems.length; i++) {
    oldKeys.push(keyOf(oldItems[i]));
  }
  for (let i = 0; i < newItems.length; i++) {
    newKeys.push(keyOf(newItems[i]));
  }
  if (hasDuplicateKeys(oldKeys) || hasDuplicateKeys(newKeys)) {
    return { fullReload: true, changed: [], added: [], removed: [] };
  }
  const min: number = Math.min(oldKeys.length, newKeys.length);
  let prefix: number = 0;
  while (prefix < min && oldKeys[prefix] === newKeys[prefix]) {
    prefix++;
  }
  if (prefix < min) {
    return { fullReload: true, changed: [], added: [], removed: [] };
  }
  const changed: number[] = [];
  for (let i = 0; i < prefix; i++) {
    if (fingerprintOf(oldItems[i]) !== fingerprintOf(newItems[i])) {
      changed.push(i);
    }
  }
  const added: number[] = [];
  for (let i = prefix; i < newItems.length; i++) {
    added.push(i);
  }
  const removed: number[] = [];
  for (let i = oldItems.length - 1; i >= prefix; i--) {
    removed.push(i);
  }
  return { fullReload: false, changed: changed, added: added, removed: removed };
}
