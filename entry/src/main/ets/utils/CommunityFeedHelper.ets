/**
 * CommunityFeedHelper.ets —— 社区列表与详情的纯函数（无 ArkUI 依赖，可离线单测）
 */
import { CommunityPost, parseSpoilerIndices, resolveCommunityImageUrl } from '../models/NoyModels';

export interface CommunitySortOption {
  label: string;
  value: string;
}

export const COMMUNITY_SORT_OPTIONS: CommunitySortOption[] = [
  { label: '最新发布', value: 'new' },
  { label: '最新回复', value: 'latest' },
  { label: '最多点赞', value: 'like' }
];

export function communitySortOptions(locale: string = 'zh-CN'): CommunitySortOption[] {
  if (locale === 'en-US') {
    return [
      { label: 'Newest', value: 'new' },
      { label: 'Latest Reply', value: 'latest' },
      { label: 'Most Liked', value: 'like' }
    ];
  }
  if (locale === 'zh-TW') {
    return [
      { label: '最新發佈', value: 'new' },
      { label: '最新回覆', value: 'latest' },
      { label: '最多按讚', value: 'like' }
    ];
  }
  return COMMUNITY_SORT_OPTIONS;
}

export const COMMUNITY_UNREAD_POLL_INTERVAL_MS: number = 60000;
export const COMMUNITY_SPOILER_BLUR_RADIUS: number = 28;

/** 计算剧透/敏感图高斯内容模糊半径：未解锁返回 28，已解锁或非剧透图返回 0 */
export function resolveSpoilerBlurRadius(isSpoiler: boolean, isRevealed: boolean): number {
  if (isSpoiler && !isRevealed) {
    return COMMUNITY_SPOILER_BLUR_RADIUS;
  }
  return 0;
}

/** 点击图片时是否直接打开全屏大图：未解锁剧透图首次点击仅解锁，二次点击才打开大图 */
export function shouldOpenImageOnTap(isSpoiler: boolean, isRevealed: boolean): boolean {
  return !isSpoiler || isRevealed;
}

/** 置顶帖标识：接口 top=true 时，列表首条为置顶帖 */
export function isPostPinned(indexInList: number, respHasTop: boolean): boolean {
  return respHasTop && indexInList === 0;
}

/** 仅当 currentUid > 0 且等于 postUid 时才展示编辑按钮（区分 data.uid 与 data.post.uid） */
export function canEditPost(currentUid: number, postUid: number): boolean {
  return currentUid > 0 && postUid > 0 && currentUid === postUid;
}

/** 未读消息轮询门禁：仅前台且距离上次轮询 >= 60s 时才允许请求 */
export function isUnreadPollDue(
  lastPollMs: number,
  nowMs: number,
  minIntervalMs: number = COMMUNITY_UNREAD_POLL_INTERVAL_MS
): boolean {
  if (lastPollMs <= 0) {
    return true;
  }
  return nowMs - lastPollMs >= minIntervalMs;
}

export interface LikeToggleState {
  is_like: boolean;
  like: number;
}

/** 计算乐观点赞切换后的状态（不修改入参对象，便于 ArkUI V2 替换数组项触发刷新） */
export function toggleOptimisticLikeState(currentLiked: boolean, currentCount: number): LikeToggleState {
  const nextLiked: boolean = !currentLiked;
  const delta: number = nextLiked ? 1 : -1;
  const nextCount: number = Math.max(0, currentCount + delta);
  return {
    is_like: nextLiked,
    like: nextCount
  };
}

/** 克隆并应用点赞状态到 CommunityPost */
export function clonePostWithLike(post: CommunityPost, liked: boolean, likeCount: number): CommunityPost {
  const next: CommunityPost = new CommunityPost();
  next.id = post.id;
  next.uid = post.uid;
  next.username = post.username;
  next.title = post.title;
  next.content = post.content;
  next.image = post.image.slice();
  next.time = post.time;
  next.expired = post.expired;
  next.area = post.area;
  next.avatar = post.avatar;
  next.platform = post.platform;
  next.like = Math.max(0, likeCount);
  next.reply = post.reply;
  next.is_like = liked;
  next.su = post.su;
  next.spoiler = post.spoiler;
  next.edit = post.edit;
  return next;
}

/** 解析帖子图片为完整图床 URL 列表 */
export function resolvePostImageUrls(post: CommunityPost): string[] {
  const urls: string[] = [];
  for (let i = 0; i < post.image.length; i++) {
    const resolved: string = resolveCommunityImageUrl(post.image[i]);
    if (resolved !== '') {
      urls.push(resolved);
    }
  }
  return urls;
}

/** 返回剧透遮罩下标集合 */
export function buildSpoilerSet(spoiler: string): Set<number> {
  const indices: number[] = parseSpoilerIndices(spoiler);
  const set: Set<number> = new Set<number>();
  for (let i = 0; i < indices.length; i++) {
    set.add(indices[i]);
  }
  return set;
}

/** 格式化社区 Unix 时间戳（自动兼容秒/毫秒） */
export function formatCommunityTime(ts: number, nowMs: number = Date.now(), locale: string = 'zh-CN'): string {
  if (!Number.isFinite(ts) || ts <= 0) {
    return '';
  }
  const tsMs: number = ts < 100000000000 ? ts * 1000 : ts;
  const diffSec: number = Math.floor((nowMs - tsMs) / 1000);
  if (diffSec < 60) {
    if (locale === 'en-US') {
      return 'Just now';
    }
    if (locale === 'zh-TW') {
      return '剛剛';
    }
    return '刚刚';
  }
  if (diffSec < 3600) {
    const m: number = Math.floor(diffSec / 60);
    if (locale === 'en-US') {
      return `${m}m ago`;
    }
    if (locale === 'zh-TW') {
      return `${m} 分鐘前`;
    }
    return `${m} 分钟前`;
  }
  if (diffSec < 86400) {
    const h: number = Math.floor(diffSec / 3600);
    if (locale === 'en-US') {
      return `${h}h ago`;
    }
    if (locale === 'zh-TW') {
      return `${h} 小時前`;
    }
    return `${h} 小时前`;
  }
  if (diffSec < 86400 * 7) {
    const d: number = Math.floor(diffSec / 86400);
    if (locale === 'en-US') {
      return `${d}d ago`;
    }
    return `${d} 天前`;
  }
  const d: Date = new Date(tsMs);
  const m: number = d.getMonth() + 1;
  const day: number = d.getDate();
  const mm: string = m < 10 ? `0${m}` : `${m}`;
  const dd: string = day < 10 ? `0${day}` : `${day}`;
  return `${d.getFullYear()}-${mm}-${dd}`;
}
