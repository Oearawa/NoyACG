/**
 * NoyModels.ets —— NoyAcg 社区与消息真实响应模型及防御式解析（阶段 0：固化契约）
 *
 * 契约来源：https://github.com/kwkare/NoyAcg-API-Collect
 * - docs/community/community_list.md
 * - docs/community/post_detail.md
 * - docs/user/messages.md
 * - fixtures/*-sample.json
 *
 * 约束（ArkTS 严格模式）：
 * - 不用 any / unknown；对象字面量有明确声明类型；不用索引签名（使用 Record）；
 * - 构造函数不使用参数属性；
 * - 所有解析函数对缺失字段、null、非数组/非对象、畸形 JSON 均做防御式判空，绝不崩溃。
 */

/** 社区图床基地址（与 docs/user/userinfo.md 徽章域名同源） */
export const NOY_BUCKET_ORIGIN: string = 'https://bucket.noymanga.com';
/** 表情包静态资源基地址（docs/community/stickers.md） */
export const NOY_STICKER_ORIGIN: string = 'https://noymanga.com/stickers';

// ==================== 原始响应接口（字段名严格对齐 fixtures） ====================

export interface RawCommunityPost {
  id?: number;
  uid?: number;
  username?: string;
  title?: string;
  content?: string;
  image?: string[];
  time?: number;
  expired?: number;
  area?: string;
  avatar?: string;
  platform?: string;
  like?: number;
  reply?: number;
  is_like?: boolean;
  su?: number;
  spoiler?: string;
  edit?: number;
}

export interface RawCommunityListResp {
  status?: string;
  info?: RawCommunityPost[];
  len?: number;
  over?: boolean;
  top?: boolean;
}

export interface RawCommunityComment {
  uid?: number;
  rid?: number;
  cid?: number;
  username?: string;
  avatar?: string;
  su?: number;
  content?: string;
  reply_id?: number;
  root_id?: number;
  reply_uid?: number;
  reply_username?: string;
  reply?: string;
  area?: string;
  time?: number;
  updated_at?: number;
  platform?: string;
  show_badge?: string;
  replies?: RawCommunityComment[];
  reply_more?: boolean;
  reply_num?: number;
}

export interface RawPostDetailData {
  comment_count?: number;
  comments?: RawCommunityComment[];
  post?: RawCommunityPost;
  top_count?: number;
  uid?: number;
}

export interface RawPostDetailResp {
  status?: string;
  data?: RawPostDetailData;
}

export interface RawPostCommentsData {
  comments?: RawCommunityComment[];
  page?: number;
  over?: boolean;
  top_count?: number;
}

export interface RawPostCommentsResp {
  status?: string;
  data?: RawPostCommentsData;
}

export interface RawCommentRepliesData {
  count?: number;
  over?: boolean;
  page?: number;
  replies?: RawCommunityComment[];
}

export interface RawCommentRepliesResp {
  status?: string;
  data?: RawCommentRepliesData;
}

export interface RawMsgBookBrief {
  Bid?: number;
  Bookname?: string;
  Time?: number;
  Views?: number;
  Favorites?: number;
  Mode?: number;
}

export interface RawCommentReplyMsgItem {
  cid?: number;
  uid?: number;
  bid?: number;
  username?: string;
  avatar?: string;
  avatarUrl?: string;
  area?: string;
  reply?: number;
  reply_text?: string;
  platform?: string;
  time?: number;
  content?: string;
}

export interface RawMsgReplyBlock {
  book?: Record<string, RawMsgBookBrief>;
  comment?: RawCommentReplyMsgItem[];
  commentLen?: number;
  count?: number;
}

export interface RawMsgReplyResp {
  status?: string;
  reply?: RawMsgReplyBlock;
}

export interface RawMsgCommunityBrief {
  id?: number;
  title?: string;
  content?: string;
  image?: string[];
  time?: number;
}

export interface RawCommunityReplyMsgItem {
  rid?: number;
  uid?: number;
  cid?: number;
  username?: string;
  avatar?: string;
  avatarUrl?: string;
  area?: string;
  reply?: number;
  reply_text?: string;
  platform?: string;
  time?: number;
  content?: string;
}

export interface RawMsgCommunityReplyBlock {
  community?: Record<string, RawMsgCommunityBrief>;
  community_reply?: RawCommunityReplyMsgItem[];
  community_reply_len?: number;
  count?: number;
}

export interface RawMsgCommunityReplyResp {
  status?: string;
  community_reply?: RawMsgCommunityReplyBlock;
}

export interface RawSysMsgItem {
  id?: number;
  title?: string;
  content?: string;
  time?: number;
}

export interface RawMsgSysBlock {
  count?: number;
  len?: number;
  msg?: RawSysMsgItem[];
}

export interface RawMsgSysResp {
  status?: string;
  sysmsg?: RawMsgSysBlock;
}

export interface RawMsgCountBlock {
  all?: number;
  sys_msg?: number;
  community_reply?: number;
  comment_reply?: number;
}

export interface RawMsgCountResp {
  status?: string;
  count?: RawMsgCountBlock;
}

// ==================== 归一化模型（供业务层与单测消费） ====================

export class CommunityPost {
  id: number = 0;
  uid: number = 0;
  username: string = '';
  title: string = '';
  content: string = '';
  image: string[] = [];
  time: number = 0;
  expired: number = 0;
  area: string = '';
  avatar: string = '';
  platform: string = '';
  like: number = 0;
  reply: number = 0;
  is_like: boolean = false;
  su: number = 0;
  spoiler: string = '';
  edit: number = 0;

  constructor() {
  }
}

export class CommunityListResp {
  status: string = '';
  info: CommunityPost[] = [];
  len: number = 0;
  over: boolean = false;
  top: boolean = false;

  constructor() {
  }
}

export class CommunityComment {
  uid: number = 0;
  rid: number = 0;
  cid: number = 0;
  username: string = '';
  avatar: string = '';
  su: number = 0;
  content: string = '';
  reply_id: number = -1;
  root_id: number = 0;
  reply_uid: number = 0;
  reply_username: string = '';
  reply: string = '';
  area: string = '';
  time: number = 0;
  updated_at: number = 0;
  platform: string = '';
  show_badge: string = '';
  replies: CommunityComment[] = [];
  reply_more: boolean = false;
  reply_num: number = 0;

  constructor() {
  }
}

export class PostDetailData {
  comment_count: number = 0;
  comments: CommunityComment[] = [];
  post: CommunityPost = new CommunityPost();
  top_count: number = 0;
  uid: number = 0;

  constructor() {
  }
}

export class PostDetailResp {
  status: string = '';
  data: PostDetailData = new PostDetailData();

  constructor() {
  }
}

export class PostCommentsData {
  comments: CommunityComment[] = [];
  page: number = 0;
  over: boolean = true;
  top_count: number = 0;

  constructor() {
  }
}

export class PostCommentsResp {
  status: string = '';
  data: PostCommentsData = new PostCommentsData();

  constructor() {
  }
}

export class CommentRepliesData {
  count: number = 0;
  over: boolean = true;
  page: number = 0;
  replies: CommunityComment[] = [];

  constructor() {
  }
}

export class CommentRepliesResp {
  status: string = '';
  data: CommentRepliesData = new CommentRepliesData();

  constructor() {
  }
}

export class MsgBookBrief {
  Bid: number = 0;
  Bookname: string = '';
  Time: number = 0;
  Views: number = 0;
  Favorites: number = 0;
  Mode: number = 0;

  constructor() {
  }
}

export class CommentReplyMsgItem {
  cid: number = 0;
  uid: number = 0;
  bid: number = 0;
  username: string = '';
  avatar: string = '';
  avatarUrl: string = '';
  area: string = '';
  reply: number = 0;
  reply_text: string = '';
  platform: string = '';
  time: number = 0;
  content: string = '';

  constructor() {
  }
}

export class MsgReplyData {
  book: Record<string, MsgBookBrief> = {};
  comment: CommentReplyMsgItem[] = [];
  commentLen: number = 0;
  count: number = 0;

  constructor() {
  }
}

export class MsgReplyResp {
  status: string = '';
  reply: MsgReplyData = new MsgReplyData();

  constructor() {
  }
}

export class MsgCommunityBrief {
  id: number = 0;
  title: string = '';
  content: string = '';
  image: string[] = [];
  time: number = 0;

  constructor() {
  }
}

export class CommunityReplyMsgItem {
  rid: number = 0;
  uid: number = 0;
  cid: number = 0;
  username: string = '';
  avatar: string = '';
  avatarUrl: string = '';
  area: string = '';
  reply: number = -1;
  reply_text: string = '';
  platform: string = '';
  time: number = 0;
  content: string = '';

  constructor() {
  }
}

export class MsgCommunityReplyData {
  community: Record<string, MsgCommunityBrief> = {};
  community_reply: CommunityReplyMsgItem[] = [];
  community_reply_len: number = 0;
  count: number = 0;

  constructor() {
  }
}

export class MsgCommunityReplyResp {
  status: string = '';
  community_reply: MsgCommunityReplyData = new MsgCommunityReplyData();

  constructor() {
  }
}

export class SysMsgItem {
  id: number = 0;
  title: string = '';
  content: string = '';
  time: number = 0;

  constructor() {
  }
}

export class MsgSysData {
  count: number = 0;
  len: number = 0;
  msg: SysMsgItem[] = [];

  constructor() {
  }
}

export class MsgSysResp {
  status: string = '';
  sysmsg: MsgSysData = new MsgSysData();

  constructor() {
  }
}

export class MsgCount {
  all: number = 0;
  sys_msg: number = 0;
  community_reply: number = 0;
  comment_reply: number = 0;

  constructor() {
  }
}

export class MsgCountResp {
  status: string = '';
  count: MsgCount = new MsgCount();

  constructor() {
  }
}

// ==================== 防御式工具与解析纯函数 ====================

function strOf(v: string | undefined | null, fallback: string = ''): string {
  return typeof v === 'string' ? v : fallback;
}

function numOf(v: number | undefined | null, fallback: number = 0): number {
  return typeof v === 'number' && Number.isFinite(v) ? v : fallback;
}

function boolOf(v: boolean | undefined | null, fallback: boolean = false): boolean {
  return typeof v === 'boolean' ? v : fallback;
}

function strArrayOf(v: string[] | undefined | null): string[] {
  if (!Array.isArray(v)) {
    return [];
  }
  const out: string[] = [];
  for (let i = 0; i < v.length; i++) {
    if (typeof v[i] === 'string' && v[i].length > 0) {
      out.push(v[i]);
    }
  }
  return out;
}

function safeParseJson<T>(rawJson: string): T | null {
  if (rawJson.trim() === '') {
    return null;
  }
  try {
    const parsed: Object = JSON.parse(rawJson) as Object;
    if (parsed === null || parsed === undefined || typeof parsed !== 'object') {
      return null;
    }
    return parsed as T;
  } catch (_e) {
    return null;
  }
}

/**
 * 拼接社区相对图片路径（帖子图 `image/...`、头像 `avatar/...`、背景 `bg/...`）。
 * 严禁统一添加 `/image/` 前缀；绝对 URL 原样返回。
 */
export function resolveCommunityImageUrl(relativePath: string, origin: string = NOY_BUCKET_ORIGIN): string {
  const clean: string = relativePath.trim();
  if (clean === '') {
    return '';
  }
  if (clean.startsWith('http://') || clean.startsWith('https://')) {
    return clean;
  }
  const base: string = origin.endsWith('/') ? origin.substring(0, origin.length - 1) : origin;
  const path: string = clean.startsWith('/') ? clean.substring(1) : clean;
  return `${base}/${path}`;
}

/** 解析 `Post.spoiler` 逗号分隔的图片下标数组（如 `"0,1,2"` → `[0, 1, 2]`） */
export function parseSpoilerIndices(spoiler: string): number[] {
  const clean: string = spoiler.trim();
  if (clean === '') {
    return [];
  }
  const parts: string[] = clean.split(',');
  const indices: number[] = [];
  for (let i = 0; i < parts.length; i++) {
    const item: string = parts[i].trim();
    if (item === '') {
      continue;
    }
    const n: number = Number(item);
    if (Number.isInteger(n) && n >= 0 && indices.indexOf(n) < 0) {
      indices.push(n);
    }
  }
  return indices;
}

export function normalizeCommunityPost(raw?: RawCommunityPost | null): CommunityPost {
  const post: CommunityPost = new CommunityPost();
  if (raw === undefined || raw === null) {
    return post;
  }
  post.id = numOf(raw.id);
  post.uid = numOf(raw.uid);
  post.username = strOf(raw.username);
  post.title = strOf(raw.title);
  post.content = strOf(raw.content);
  post.image = strArrayOf(raw.image);
  post.time = numOf(raw.time);
  post.expired = numOf(raw.expired);
  post.area = strOf(raw.area);
  post.avatar = strOf(raw.avatar);
  post.platform = strOf(raw.platform);
  post.like = numOf(raw.like);
  post.reply = numOf(raw.reply);
  post.is_like = boolOf(raw.is_like);
  post.su = numOf(raw.su);
  post.spoiler = strOf(raw.spoiler);
  post.edit = numOf(raw.edit);
  return post;
}

export function normalizeCommunityComment(raw?: RawCommunityComment | null, depth: number = 0): CommunityComment {
  const c: CommunityComment = new CommunityComment();
  if (raw === undefined || raw === null) {
    return c;
  }
  c.uid = numOf(raw.uid);
  c.rid = numOf(raw.rid);
  c.cid = numOf(raw.cid);
  c.username = strOf(raw.username);
  c.avatar = strOf(raw.avatar);
  c.su = numOf(raw.su);
  c.content = strOf(raw.content);
  c.reply_id = numOf(raw.reply_id, -1);
  c.root_id = numOf(raw.root_id);
  c.reply_uid = numOf(raw.reply_uid);
  c.reply_username = strOf(raw.reply_username);
  c.reply = strOf(raw.reply);
  c.area = strOf(raw.area);
  c.time = numOf(raw.time);
  c.updated_at = numOf(raw.updated_at);
  c.platform = strOf(raw.platform);
  c.show_badge = strOf(raw.show_badge);
  if (depth < 2 && Array.isArray(raw.replies)) {
    const nested: CommunityComment[] = [];
    for (let i = 0; i < raw.replies.length; i++) {
      nested.push(normalizeCommunityComment(raw.replies[i], depth + 1));
    }
    c.replies = nested;
  }
  c.reply_more = boolOf(raw.reply_more);
  c.reply_num = numOf(raw.reply_num);
  return c;
}

export function parseCommunityListResp(rawJson: string): CommunityListResp {
  const out: CommunityListResp = new CommunityListResp();
  const raw: RawCommunityListResp | null = safeParseJson<RawCommunityListResp>(rawJson);
  if (raw === null) {
    return out;
  }
  out.status = strOf(raw.status);
  out.len = numOf(raw.len);
  out.over = boolOf(raw.over);
  out.top = boolOf(raw.top);
  if (Array.isArray(raw.info)) {
    for (let i = 0; i < raw.info.length; i++) {
      out.info.push(normalizeCommunityPost(raw.info[i]));
    }
  }
  return out;
}

export function parsePostDetailResp(rawJson: string): PostDetailResp {
  const out: PostDetailResp = new PostDetailResp();
  const raw: RawPostDetailResp | null = safeParseJson<RawPostDetailResp>(rawJson);
  if (raw === null) {
    return out;
  }
  out.status = strOf(raw.status);
  if (raw.data !== undefined && raw.data !== null) {
    out.data.comment_count = numOf(raw.data.comment_count);
    out.data.top_count = numOf(raw.data.top_count);
    out.data.uid = numOf(raw.data.uid);
    out.data.post = normalizeCommunityPost(raw.data.post);
    if (Array.isArray(raw.data.comments)) {
      for (let i = 0; i < raw.data.comments.length; i++) {
        out.data.comments.push(normalizeCommunityComment(raw.data.comments[i]));
      }
    }
  }
  return out;
}

export function parsePostCommentsResp(rawJson: string): PostCommentsResp {
  const out: PostCommentsResp = new PostCommentsResp();
  const raw: RawPostCommentsResp | null = safeParseJson<RawPostCommentsResp>(rawJson);
  if (raw === null) {
    return out;
  }
  out.status = strOf(raw.status);
  if (raw.data !== undefined && raw.data !== null) {
    out.data.page = numOf(raw.data.page);
    out.data.over = boolOf(raw.data.over, true);
    out.data.top_count = numOf(raw.data.top_count);
    if (Array.isArray(raw.data.comments)) {
      for (let i = 0; i < raw.data.comments.length; i++) {
        out.data.comments.push(normalizeCommunityComment(raw.data.comments[i]));
      }
    }
  }
  return out;
}

export function parseCommentRepliesResp(rawJson: string): CommentRepliesResp {
  const out: CommentRepliesResp = new CommentRepliesResp();
  const raw: RawCommentRepliesResp | null = safeParseJson<RawCommentRepliesResp>(rawJson);
  if (raw === null) {
    return out;
  }
  out.status = strOf(raw.status);
  if (raw.data !== undefined && raw.data !== null) {
    out.data.count = numOf(raw.data.count);
    out.data.over = boolOf(raw.data.over, true);
    out.data.page = numOf(raw.data.page);
    if (Array.isArray(raw.data.replies)) {
      for (let i = 0; i < raw.data.replies.length; i++) {
        out.data.replies.push(normalizeCommunityComment(raw.data.replies[i]));
      }
    }
  }
  return out;
}

export function parseMsgReplyResp(rawJson: string): MsgReplyResp {
  const out: MsgReplyResp = new MsgReplyResp();
  const raw: RawMsgReplyResp | null = safeParseJson<RawMsgReplyResp>(rawJson);
  if (raw === null) {
    return out;
  }
  out.status = strOf(raw.status);
  const block: RawMsgReplyBlock | undefined = raw.reply;
  if (block === undefined || block === null) {
    return out;
  }
  out.reply.commentLen = numOf(block.commentLen);
  out.reply.count = numOf(block.count);
  if (block.book !== undefined && block.book !== null && typeof block.book === 'object') {
    const keys: string[] = Object.keys(block.book);
    for (let i = 0; i < keys.length; i++) {
      const k: string = keys[i];
      const rawBook: RawMsgBookBrief | undefined = block.book[k];
      if (rawBook !== undefined && rawBook !== null) {
        const b: MsgBookBrief = new MsgBookBrief();
        b.Bid = numOf(rawBook.Bid);
        b.Bookname = strOf(rawBook.Bookname);
        b.Time = numOf(rawBook.Time);
        b.Views = numOf(rawBook.Views);
        b.Favorites = numOf(rawBook.Favorites);
        b.Mode = numOf(rawBook.Mode);
        out.reply.book[k] = b;
      }
    }
  }
  if (Array.isArray(block.comment)) {
    for (let i = 0; i < block.comment.length; i++) {
      const r: RawCommentReplyMsgItem | undefined = block.comment[i];
      if (r !== undefined && r !== null) {
        const item: CommentReplyMsgItem = new CommentReplyMsgItem();
        item.cid = numOf(r.cid);
        item.uid = numOf(r.uid);
        item.bid = numOf(r.bid);
        item.username = strOf(r.username);
        item.avatar = strOf(r.avatar);
        item.avatarUrl = strOf(r.avatarUrl);
        item.area = strOf(r.area);
        item.reply = numOf(r.reply);
        item.reply_text = strOf(r.reply_text);
        item.platform = strOf(r.platform);
        item.time = numOf(r.time);
        item.content = strOf(r.content);
        out.reply.comment.push(item);
      }
    }
  }
  return out;
}

export function parseMsgCommunityReplyResp(rawJson: string): MsgCommunityReplyResp {
  const out: MsgCommunityReplyResp = new MsgCommunityReplyResp();
  const raw: RawMsgCommunityReplyResp | null = safeParseJson<RawMsgCommunityReplyResp>(rawJson);
  if (raw === null) {
    return out;
  }
  out.status = strOf(raw.status);
  const block: RawMsgCommunityReplyBlock | undefined = raw.community_reply;
  if (block === undefined || block === null) {
    return out;
  }
  out.community_reply.community_reply_len = numOf(block.community_reply_len);
  out.community_reply.count = numOf(block.count);
  if (block.community !== undefined && block.community !== null && typeof block.community === 'object') {
    const keys: string[] = Object.keys(block.community);
    for (let i = 0; i < keys.length; i++) {
      const k: string = keys[i];
      const rawPost: RawMsgCommunityBrief | undefined = block.community[k];
      if (rawPost !== undefined && rawPost !== null) {
        const p: MsgCommunityBrief = new MsgCommunityBrief();
        p.id = numOf(rawPost.id);
        p.title = strOf(rawPost.title);
        p.content = strOf(rawPost.content);
        p.image = strArrayOf(rawPost.image);
        p.time = numOf(rawPost.time);
        out.community_reply.community[k] = p;
      }
    }
  }
  if (Array.isArray(block.community_reply)) {
    for (let i = 0; i < block.community_reply.length; i++) {
      const r: RawCommunityReplyMsgItem | undefined = block.community_reply[i];
      if (r !== undefined && r !== null) {
        const item: CommunityReplyMsgItem = new CommunityReplyMsgItem();
        item.rid = numOf(r.rid);
        item.uid = numOf(r.uid);
        item.cid = numOf(r.cid);
        item.username = strOf(r.username);
        item.avatar = strOf(r.avatar);
        item.avatarUrl = strOf(r.avatarUrl);
        item.area = strOf(r.area);
        item.reply = numOf(r.reply, -1);
        item.reply_text = strOf(r.reply_text);
        item.platform = strOf(r.platform);
        item.time = numOf(r.time);
        item.content = strOf(r.content);
        out.community_reply.community_reply.push(item);
      }
    }
  }
  return out;
}

export function parseMsgSysResp(rawJson: string): MsgSysResp {
  const out: MsgSysResp = new MsgSysResp();
  const raw: RawMsgSysResp | null = safeParseJson<RawMsgSysResp>(rawJson);
  if (raw === null) {
    return out;
  }
  out.status = strOf(raw.status);
  const block: RawMsgSysBlock | undefined = raw.sysmsg;
  if (block === undefined || block === null) {
    return out;
  }
  out.sysmsg.count = numOf(block.count);
  out.sysmsg.len = numOf(block.len);
  if (Array.isArray(block.msg)) {
    for (let i = 0; i < block.msg.length; i++) {
      const r: RawSysMsgItem | undefined = block.msg[i];
      if (r !== undefined && r !== null) {
        const item: SysMsgItem = new SysMsgItem();
        item.id = numOf(r.id);
        item.title = strOf(r.title);
        item.content = strOf(r.content);
        item.time = numOf(r.time);
        out.sysmsg.msg.push(item);
      }
    }
  }
  return out;
}

export function parseMsgCountResp(rawJson: string): MsgCountResp {
  const out: MsgCountResp = new MsgCountResp();
  const raw: RawMsgCountResp | null = safeParseJson<RawMsgCountResp>(rawJson);
  if (raw === null) {
    return out;
  }
  out.status = strOf(raw.status);
  if (raw.count !== undefined && raw.count !== null) {
    out.count.all = numOf(raw.count.all);
    out.count.sys_msg = numOf(raw.count.sys_msg);
    out.count.community_reply = numOf(raw.count.community_reply);
    out.count.comment_reply = numOf(raw.count.comment_reply);
  }
  return out;
}
