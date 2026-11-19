import { describe, expect, it } from '@ohos/hypium';
import { MSG_TYPE_COMMUNITY_REPLY, MSG_TYPE_REPLY, MSG_TYPE_SYSMSG } from '../main/ets/model/Message';
import { ROUTE_SHELF, SHELF_ENTRY } from '../main/ets/model/ProfileMenu';
import {
  CommunityPost,
  NOY_BUCKET_ORIGIN,
  parseMsgCommunityReplyResp,
  parseMsgReplyResp,
  parseMsgSysResp
} from '../main/ets/models/NoyModels';
import {
  mapCommunityReplyMessages,
  mapNativeSysMessages,
  mapOfficialPostsToSysMessages,
  mapReplyMessages,
  mergeSysMessages,
  OFFICIAL_ANNOUNCEMENT_TAG
} from '../main/ets/utils/MessageCenterHelper';
import {
  NavTabId,
  resolveSafeSelectedTab,
  resolveTabIndexById,
  resolveVisibleNavTabs
} from '../main/ets/utils/NavTabsPolicy';

function makePost(id: number, username: string, title: string, avatar: string): CommunityPost {
  const p = new CommunityPost();
  p.id = id;
  p.username = username;
  p.title = title;
  p.content = `${title} 正文`;
  p.avatar = avatar;
  p.time = 1700000000;
  return p;
}

export default function messageAndNavTabsTest(): void {
  describe('MessageAndNavTabsTest', () => {
    it('officialCoconutPostsFilterDedupAndMergeIntoSysMessages', 0, () => {
      const posts: CommunityPost[] = [
        makePost(10, 'coconut', '緊急停機維護警告', 'avatar/coconut.webp'),
        makePost(11, 'other_user', '普通用户帖子', 'avatar/u.webp'),
        makePost(10, 'Coconut', '重复置顶公告', 'avatar/coconut.webp'),
        makePost(12, 'COCONUT', '社區規則', 'avatar/coconut.webp')
      ];

      const official = mapOfficialPostsToSysMessages(posts);
      expect(official.length).assertEqual(2);
      expect(official[0].kind).assertEqual(MSG_TYPE_SYSMSG);
      expect(official[0].postId).assertEqual('10');
      expect(official[0].isOfficial).assertTrue();
      expect(official[0].tagLabel).assertEqual(OFFICIAL_ANNOUNCEMENT_TAG);
      expect(official[0].avatarUrl).assertEqual(`${NOY_BUCKET_ORIGIN}/avatar/coconut.webp`);
      expect(official[1].postId).assertEqual('12');

      const sysResp = parseMsgSysResp('{"status":"ok","sysmsg":{"count":1,"len":1,"msg":[{"id":99,"title":"系统通知","content":"欢迎使用","time":1700000100}]}}');
      const nativeSys = mapNativeSysMessages(sysResp);
      expect(nativeSys.length).assertEqual(1);

      const merged = mergeSysMessages(official, nativeSys);
      expect(merged.length).assertEqual(3);
      expect(merged[0].postId).assertEqual('10');
      expect(merged[1].postId).assertEqual('12');
      expect(merged[2].id).assertEqual('sys_99_0');
    });

    it('messageMappersReadAvatarUrlAndTargetIdsDefensively', 0, () => {
      const replyResp = parseMsgReplyResp(
        '{"status":"ok","reply":{"book":{"200":{"Bid":200,"Bookname":"测试漫画"}},"comment":[{"cid":1,"uid":2,"bid":200,"username":"bob","avatar":"","avatarUrl":"avatar/bob.webp","content":"不错","time":1700000000}]}}'
      );
      const replies = mapReplyMessages(replyResp);
      expect(replies.length).assertEqual(1);
      expect(replies[0].kind).assertEqual(MSG_TYPE_REPLY);
      expect(replies[0].bookId).assertEqual('200');
      expect(replies[0].avatarUrl).assertEqual(`${NOY_BUCKET_ORIGIN}/avatar/bob.webp`);

      const creplyResp = parseMsgCommunityReplyResp(
        '{"status":"ok","community_reply":{"community":{"55":{"id":55,"title":"讨论帖"}},"community_reply":[{"rid":7,"uid":3,"cid":55,"username":"carol","avatar":"","avatarUrl":"avatar/carol.webp","content":"顶一下","time":1700000000}]}}'
      );
      const creplies = mapCommunityReplyMessages(creplyResp);
      expect(creplies.length).assertEqual(1);
      expect(creplies[0].kind).assertEqual(MSG_TYPE_COMMUNITY_REPLY);
      expect(creplies[0].postId).assertEqual('55');
      expect(creplies[0].avatarUrl).assertEqual(`${NOY_BUCKET_ORIGIN}/avatar/carol.webp`);
    });

    it('navTabsPolicyAlwaysPinsHomeAndProfileAndFallsBackSafely', 0, () => {
      const allOn: NavTabId[] = resolveVisibleNavTabs({ showLatest: true, showCommunity: true, showShelf: true });
      expect(allOn.length).assertEqual(5);
      expect(allOn[0]).assertEqual('home');
      expect(allOn[1]).assertEqual('latest');
      expect(allOn[2]).assertEqual('community');
      expect(allOn[3]).assertEqual('shelf');
      expect(allOn[4]).assertEqual('profile');

      const minimal: NavTabId[] = resolveVisibleNavTabs({ showLatest: false, showCommunity: false, showShelf: false });
      expect(minimal.length).assertEqual(2);
      expect(minimal[0]).assertEqual('home');
      expect(minimal[1]).assertEqual('profile');

      const noShelf: NavTabId[] = resolveVisibleNavTabs({ showLatest: true, showCommunity: true, showShelf: false });
      expect(noShelf.length).assertEqual(4);
      expect(noShelf[3]).assertEqual('profile');

      // 关闭当前激活的 'shelf' 后安全回落到 'home'
      expect(resolveSafeSelectedTab('shelf', noShelf)).assertEqual('home');
      expect(resolveSafeSelectedTab('community', noShelf)).assertEqual('community');
      expect(resolveTabIndexById('profile', noShelf)).assertEqual(3);
      expect(resolveTabIndexById('shelf', noShelf)).assertEqual(0);
    });

    it('profileShelfEntryTargetsStandaloneShelfPage', 0, () => {
      expect(ROUTE_SHELF).assertEqual('ShelfPage');
      expect(SHELF_ENTRY.route).assertEqual('ShelfPage');
      expect(SHELF_ENTRY.title).assertEqual('我的收藏');
    });
  });
}
