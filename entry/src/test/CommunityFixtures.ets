/**
 * CommunityFixtures.ets —— 脱敏契约测试夹具（与 entry/src/test/fixtures/*.json 一一对应）
 */

export const FIXTURE_COMMUNITY_LIST: string = `{
  "info": [
    {"id": 78930, "uid": 12345, "username": "your-name", "title": "图", "content": "[noygirl:yeah]", "image": ["image/91266-<sha-1>.webp", "image/91266-<sha-2>.webp"], "time": 1793030753, "expired": 1800806753, "area": "Japan", "avatar": "avatar/91266-<sha>.webp", "platform": "web", "like": 0, "reply": 1, "is_like": false, "su": 0, "spoiler": "0,1", "edit": 0}
  ],
  "len": 70086,
  "over": false,
  "top": true,
  "status": "ok"
}`;

export const FIXTURE_POST_DETAIL: string = `{
  "data": {
    "comment_count": 1,
    "comments": [
      {"uid": 12345, "rid": 460483, "cid": 78930, "username": "your-name", "avatar": "avatar/91266-<sha>.webp", "su": 0, "content": "pixiv: 133916454, 135484571", "reply_id": -1, "root_id": 0, "reply_uid": 0, "reply_username": "", "reply": "", "area": "Japan", "time": 1793030863, "updated_at": 1793030863, "platform": "web", "show_badge": "https://bucket.noymanga.com/image/<badge>.webp", "replies": [], "reply_more": false, "reply_num": 0}
    ],
    "post": {"id": 78930, "uid": 12345, "username": "your-name", "title": "图", "content": "[noygirl:yeah]", "image": ["image/91266-<sha-1>.webp", "image/91266-<sha-2>.webp"], "time": 1793030753, "expired": 1800806753, "area": "Japan", "avatar": "avatar/91266-<sha>.webp", "platform": "web", "like": 0, "reply": 1, "is_like": false, "su": 0, "spoiler": "0,1", "edit": 0},
    "top_count": 1,
    "uid": 12345
  },
  "status": "ok"
}`;

export const FIXTURE_COMMENT_REPLIES: string = `{
  "data": {
    "count": 2,
    "over": true,
    "page": 1,
    "replies": [
      {"uid": 0, "rid": 456401, "cid": 41029, "username": "user-a", "avatar": "", "su": 0, "content": "楼中楼回复正文", "reply_id": 450225, "root_id": 445567, "reply_uid": 0, "reply_username": "user-b", "reply": "被回复的那条内容节选", "area": "China mainland", "time": 1792415675, "updated_at": 1792415675, "platform": "web", "show_badge": "", "replies": [], "reply_more": false, "reply_num": 0},
      {"uid": 0, "rid": 456400, "cid": 41029, "username": "user-a", "avatar": "", "su": 0, "content": "紧接着的一条回复", "reply_id": 450225, "root_id": 445567, "reply_uid": 0, "reply_username": "user-b", "reply": "被回复的那条内容节选", "area": "China mainland", "time": 1792415664, "updated_at": 1792415664, "platform": "web", "show_badge": "", "replies": [], "reply_more": false, "reply_num": 0}
    ]
  },
  "status": "ok"
}`;

export const FIXTURE_MSG_COMMENT_REPLY: string = `{
  "reply": {
    "book": {
      "15970": {"Bid": 15970, "Bookname": "<deleted-or-sample>", "Time": 0, "Views": 0, "Favorites": 0, "Mode": 1},
      "9238": {"Bid": 9238, "Bookname": "<deleted-or-sample>", "Time": 0, "Views": 0, "Favorites": 0, "Mode": 1}
    },
    "comment": [
      {"cid": 91290, "uid": 0, "bid": 15970, "username": "user-a", "avatar": "", "avatarUrl": "avatar/0-<sha>.webp", "area": "China mainland", "reply": 91263, "reply_text": "这条评论的内容节选", "platform": "android", "time": 1757223929, "content": "回复正文"},
      {"cid": 26587, "uid": 0, "bid": 9238, "username": "user-b", "avatar": "", "avatarUrl": "avatar/0-<sha>.webp", "area": "China mainland", "reply": 26454, "reply_text": "另一条被回复内容的节选", "platform": "android", "time": 1689325264, "content": "另一条回复正文"}
    ],
    "commentLen": 0,
    "count": 2
  },
  "status": "ok"
}`;

export const FIXTURE_MSG_COMMUNITY_REPLY: string = `{
  "community_reply": {
    "community": {
      "78930": {"id": 78930, "title": "图", "content": "[noygirl:yeah]", "image": ["image/91266-<sha-1>.webp"], "time": 1793030753},
      "78855": {"id": 78855, "title": "<deleted-or-sample>", "content": "", "image": [], "time": 1793028714}
    },
    "community_reply": [
      {"rid": 460483, "uid": 0, "cid": 78930, "username": "user-a", "avatar": "", "avatarUrl": "avatar/0-<sha>.webp", "area": "Japan", "reply": -1, "reply_text": "", "platform": "", "time": 1793030863, "content": "顶层回复正文"},
      {"rid": 460338, "uid": 0, "cid": 78855, "username": "user-b", "avatar": "", "avatarUrl": "avatar/0-<sha>.webp", "area": "China mainland", "reply": -1, "reply_text": "", "platform": "", "time": 1793028714, "content": "另一个帖子的顶层回复"}
    ],
    "community_reply_len": 0,
    "count": 1399
  },
  "status": "ok"
}`;

export const FIXTURE_MSG_SYSMSG: string = `{"sysmsg": {"count": 0, "len": 0, "msg": []}, "status": "ok"}`;

export const FIXTURE_MSG_COUNT: string = `{"count": {"all": 0, "sys_msg": 0, "community_reply": 0, "comment_reply": 0}, "status": "ok"}`;
