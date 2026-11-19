/**
 * MessageCenterHelper.ets —— 消息中心三类消息映射与官方公告（coconut）接入纯函数
 *
 * 严格遵循 ArkTS 严格模式：无 any / unknown，显式类型与防御式判空。
 */
import {
  MessageItem,
  MSG_TYPE_COMMUNITY_REPLY,
  MSG_TYPE_REPLY,
  MSG_TYPE_SYSMSG
} from '../model/Message';
import {
  CommentReplyMsgItem,
  CommunityPost,
  CommunityReplyMsgItem,
  MsgBookBrief,
  MsgCommunityBrief,
  MsgCommunityReplyResp,
  MsgReplyResp,
  MsgSysResp,
  resolveCommunityImageUrl,
  SysMsgItem
} from '../models/NoyModels';
import { formatCommunityTime } from './CommunityFeedHelper';

export const OFFICIAL_ANNOUNCER_USERNAME: string = 'coconut';
export const OFFICIAL_ANNOUNCEMENT_TAG: string = '官方公告';

/** 将官方账号 coconut 发布的社区帖子过滤、去重并映射为系统消息条目 */
export function mapOfficialPostsToSysMessages(posts: CommunityPost[]): MessageItem[] {
  const seenIds: Set<number> = new Set<number>();
  const out: MessageItem[] = [];
  for (let i = 0; i < posts.length; i++) {
    const post: CommunityPost = posts[i];
    if (post.id <= 0 || seenIds.has(post.id)) {
      continue;
    }
    if (post.username.trim().toLowerCase() !== OFFICIAL_ANNOUNCER_USERNAME) {
      continue;
    }
    seenIds.add(post.id);
    const item: MessageItem = new MessageItem();
    item.kind = MSG_TYPE_SYSMSG;
    item.id = `official_${post.id}`;
    item.title = post.title !== '' ? post.title : OFFICIAL_ANNOUNCEMENT_TAG;
    item.content = post.content;
    item.time = formatCommunityTime(post.time);
    item.avatarUrl = resolveCommunityImageUrl(post.avatar);
    item.postId = String(post.id);
    item.isOfficial = true;
    item.tagLabel = OFFICIAL_ANNOUNCEMENT_TAG;
    out.push(item);
  }
  return out;
}

/** 合并官方公告与原生系统消息（按 id 去重，官方公告置前） */
export function mergeSysMessages(officialItems: MessageItem[], sysItems: MessageItem[]): MessageItem[] {
  const seen: Set<string> = new Set<string>();
  const merged: MessageItem[] = [];
  for (let i = 0; i < officialItems.length; i++) {
    const it: MessageItem = officialItems[i];
    if (!seen.has(it.id)) {
      seen.add(it.id);
      merged.push(it);
    }
  }
  for (let i = 0; i < sysItems.length; i++) {
    const it: MessageItem = sysItems[i];
    if (!seen.has(it.id)) {
      seen.add(it.id);
      merged.push(it);
    }
  }
  return merged;
}

function pickAvatarUrl(avatarUrl: string, avatar: string): string {
  const raw: string = avatarUrl.trim() !== '' ? avatarUrl.trim() : avatar.trim();
  if (raw === '') {
    return '';
  }
  return resolveCommunityImageUrl(raw);
}

/** 映射评论回复消息（reply）：优先读取 avatarUrl，绑定 bookId */
export function mapReplyMessages(resp: MsgReplyResp): MessageItem[] {
  const list: CommentReplyMsgItem[] = resp.reply.comment;
  const bookMap: Record<string, MsgBookBrief> = resp.reply.book;
  const out: MessageItem[] = [];
  for (let i = 0; i < list.length; i++) {
    const raw: CommentReplyMsgItem = list[i];
    const item: MessageItem = new MessageItem();
    item.kind = MSG_TYPE_REPLY;
    item.id = `reply_${raw.cid}_${raw.bid}_${i}`;
    const bookBrief: MsgBookBrief | undefined = bookMap[String(raw.bid)];
    const bookName: string = bookBrief !== undefined && bookBrief.Bookname !== ''
      ? `《${bookBrief.Bookname}》`
      : '你的评论';
    const sender: string = raw.username !== '' ? raw.username : `UID ${raw.uid}`;
    item.title = `${sender} 回复了 ${bookName}`;
    item.content = raw.content !== '' ? raw.content : raw.reply_text;
    item.time = formatCommunityTime(raw.time);
    item.avatarUrl = pickAvatarUrl(raw.avatarUrl, raw.avatar);
    item.bookId = raw.bid > 0 ? String(raw.bid) : '';
    out.push(item);
  }
  return out;
}

/** 映射社区回复消息（community_reply）：优先读取 avatarUrl，绑定 postId（cid） */
export function mapCommunityReplyMessages(resp: MsgCommunityReplyResp): MessageItem[] {
  const list: CommunityReplyMsgItem[] = resp.community_reply.community_reply;
  const postMap: Record<string, MsgCommunityBrief> = resp.community_reply.community;
  const out: MessageItem[] = [];
  for (let i = 0; i < list.length; i++) {
    const raw: CommunityReplyMsgItem = list[i];
    const item: MessageItem = new MessageItem();
    item.kind = MSG_TYPE_COMMUNITY_REPLY;
    item.id = `creply_${raw.rid}_${raw.cid}_${i}`;
    const postBrief: MsgCommunityBrief | undefined = postMap[String(raw.cid)];
    const postTitle: string = postBrief !== undefined && postBrief.title !== ''
      ? `《${postBrief.title}》`
      : '你的帖子';
    const sender: string = raw.username !== '' ? raw.username : `UID ${raw.uid}`;
    item.title = `${sender} 回复了 ${postTitle}`;
    item.content = raw.content !== '' ? raw.content : raw.reply_text;
    item.time = formatCommunityTime(raw.time);
    item.avatarUrl = pickAvatarUrl(raw.avatarUrl, raw.avatar);
    item.postId = raw.cid > 0 ? String(raw.cid) : '';
    out.push(item);
  }
  return out;
}

/** 映射原生系统消息（sysmsg） */
export function mapNativeSysMessages(resp: MsgSysResp): MessageItem[] {
  const list: SysMsgItem[] = resp.sysmsg.msg;
  const out: MessageItem[] = [];
  for (let i = 0; i < list.length; i++) {
    const raw: SysMsgItem = list[i];
    const item: MessageItem = new MessageItem();
    item.kind = MSG_TYPE_SYSMSG;
    item.id = `sys_${raw.id}_${i}`;
    item.title = raw.title !== '' ? raw.title : '系统通知';
    item.content = raw.content;
    item.time = formatCommunityTime(raw.time);
    out.push(item);
  }
  return out;
}
