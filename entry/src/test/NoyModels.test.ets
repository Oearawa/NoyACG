/**
 * NoyModels.test.ets —— 阶段 0 社区与消息真实响应模型解析单测（Hypium）
 *
 * 覆盖：
 *   1. 帖子列表项 + 分页标志 over/len/top（community-list-sample.json）；
 *   2. 帖子详情 + 顶层评论（post-detail-sample.json）；
 *   3. 评论分页与楼中楼回复（comment-replies-sample.json）；
 *   4. 三类消息结构：reply / community_reply / sysmsg；
 *   5. 未读计数（msg-count.json）；
 *   6. 社区图片基地址拼接与 spoiler 模糊下标解析；
 *   7. 缺字段 / 空对象 / 畸形 JSON 防御式解析不崩溃。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  NOY_BUCKET_ORIGIN,
  CommunityListResp,
  PostDetailResp,
  PostCommentsResp,
  CommentRepliesResp,
  MsgReplyResp,
  MsgCommunityReplyResp,
  MsgSysResp,
  MsgCountResp,
  parseCommunityListResp,
  parsePostDetailResp,
  parsePostCommentsResp,
  parseCommentRepliesResp,
  parseMsgReplyResp,
  parseMsgCommunityReplyResp,
  parseMsgSysResp,
  parseMsgCountResp,
  parseSpoilerIndices,
  resolveCommunityImageUrl
} from '../main/ets/models/NoyModels';
import {
  FIXTURE_COMMUNITY_LIST,
  FIXTURE_POST_DETAIL,
  FIXTURE_COMMENT_REPLIES,
  FIXTURE_MSG_COMMENT_REPLY,
  FIXTURE_MSG_COMMUNITY_REPLY,
  FIXTURE_MSG_SYSMSG,
  FIXTURE_MSG_COUNT
} from './CommunityFixtures';

export default function noyModelsTest(): void {
  describe('NoyModels_ContractFixtures', () => {

    it('parsesCommunityListFixtureAccurately', 0, () => {
      const resp: CommunityListResp = parseCommunityListResp(FIXTURE_COMMUNITY_LIST);
      expect(resp.status).assertEqual('ok');
      expect(resp.len).assertEqual(70086);
      expect(resp.over).assertFalse();
      expect(resp.top).assertTrue();
      expect(resp.info.length).assertEqual(1);

      const post = resp.info[0];
      expect(post.id).assertEqual(78930);
      expect(post.uid).assertEqual(12345);
      expect(post.username).assertEqual('your-name');
      expect(post.title).assertEqual('图');
      expect(post.content).assertEqual('[noygirl:yeah]');
      expect(post.image.length).assertEqual(2);
      expect(post.image[0]).assertEqual('image/91266-<sha-1>.webp');
      expect(post.avatar).assertEqual('avatar/91266-<sha>.webp');
      expect(post.spoiler).assertEqual('0,1');
      expect(post.is_like).assertFalse();
      expect(post.edit).assertEqual(0);
    });

    it('parsesPostDetailAndTopLevelCommentFixture', 0, () => {
      const resp: PostDetailResp = parsePostDetailResp(FIXTURE_POST_DETAIL);
      expect(resp.status).assertEqual('ok');
      expect(resp.data.comment_count).assertEqual(1);
      expect(resp.data.top_count).assertEqual(1);
      expect(resp.data.uid).assertEqual(12345);
      expect(resp.data.post.id).assertEqual(78930);
      expect(resp.data.comments.length).assertEqual(1);

      const c = resp.data.comments[0];
      expect(c.rid).assertEqual(460483);
      expect(c.cid).assertEqual(78930);
      expect(c.reply_id).assertEqual(-1);
      expect(c.root_id).assertEqual(0);
      expect(c.show_badge).assertEqual('https://bucket.noymanga.com/image/<badge>.webp');
      expect(c.reply_more).assertFalse();
      expect(c.reply_num).assertEqual(0);
    });

    it('parsesCommentRepliesAndNestedIds', 0, () => {
      const resp: CommentRepliesResp = parseCommentRepliesResp(FIXTURE_COMMENT_REPLIES);
      expect(resp.status).assertEqual('ok');
      expect(resp.data.count).assertEqual(2);
      expect(resp.data.over).assertTrue();
      expect(resp.data.page).assertEqual(1);
      expect(resp.data.replies.length).assertEqual(2);

      const r0 = resp.data.replies[0];
      expect(r0.rid).assertEqual(456401);
      expect(r0.cid).assertEqual(41029);
      expect(r0.reply_id).assertEqual(450225);
      expect(r0.root_id).assertEqual(445567);
      expect(r0.reply_username).assertEqual('user-b');
      expect(r0.reply).assertEqual('被回复的那条内容节选');
    });

    it('parsesThreeMessageTypesAndUnreadCount', 0, () => {
      const replyResp: MsgReplyResp = parseMsgReplyResp(FIXTURE_MSG_COMMENT_REPLY);
      expect(replyResp.status).assertEqual('ok');
      expect(replyResp.reply.count).assertEqual(2);
      expect(replyResp.reply.comment.length).assertEqual(2);
      expect(replyResp.reply.comment[0].cid).assertEqual(91290);
      expect(replyResp.reply.comment[0].bid).assertEqual(15970);
      expect(replyResp.reply.comment[0].avatarUrl).assertEqual('avatar/0-<sha>.webp');
      expect(replyResp.reply.book['15970'] !== undefined).assertTrue();
      expect(replyResp.reply.book['15970'].Bid).assertEqual(15970);

      const commResp: MsgCommunityReplyResp = parseMsgCommunityReplyResp(FIXTURE_MSG_COMMUNITY_REPLY);
      expect(commResp.status).assertEqual('ok');
      expect(commResp.community_reply.count).assertEqual(1399);
      expect(commResp.community_reply.community_reply.length).assertEqual(2);
      expect(commResp.community_reply.community_reply[0].rid).assertEqual(460483);
      expect(commResp.community_reply.community_reply[0].cid).assertEqual(78930);
      expect(commResp.community_reply.community_reply[0].reply).assertEqual(-1);
      expect(commResp.community_reply.community['78930'].title).assertEqual('图');

      const sysResp: MsgSysResp = parseMsgSysResp(FIXTURE_MSG_SYSMSG);
      expect(sysResp.status).assertEqual('ok');
      expect(sysResp.sysmsg.count).assertEqual(0);
      expect(sysResp.sysmsg.len).assertEqual(0);
      expect(sysResp.sysmsg.msg.length).assertEqual(0);

      const countResp: MsgCountResp = parseMsgCountResp(FIXTURE_MSG_COUNT);
      expect(countResp.status).assertEqual('ok');
      expect(countResp.count.all).assertEqual(0);
      expect(countResp.count.sys_msg).assertEqual(0);
      expect(countResp.count.community_reply).assertEqual(0);
      expect(countResp.count.comment_reply).assertEqual(0);
    });

    it('resolvesImageUrlsAndSpoilerIndicesCorrectly', 0, () => {
      expect(resolveCommunityImageUrl('image/91266-abc.webp'))
        .assertEqual(`${NOY_BUCKET_ORIGIN}/image/91266-abc.webp`);
      expect(resolveCommunityImageUrl('avatar/91266-abc.webp'))
        .assertEqual(`${NOY_BUCKET_ORIGIN}/avatar/91266-abc.webp`);
      expect(resolveCommunityImageUrl('bg/91266-abc.webp'))
        .assertEqual(`${NOY_BUCKET_ORIGIN}/bg/91266-abc.webp`);
      expect(resolveCommunityImageUrl('https://bucket.noymanga.com/image/nry.webp'))
        .assertEqual('https://bucket.noymanga.com/image/nry.webp');
      expect(resolveCommunityImageUrl('')).assertEqual('');

      const indices: number[] = parseSpoilerIndices('0, 1, 2, 1, -1, abc');
      expect(indices.length).assertEqual(3);
      expect(indices[0]).assertEqual(0);
      expect(indices[1]).assertEqual(1);
      expect(indices[2]).assertEqual(2);
      expect(parseSpoilerIndices('').length).assertEqual(0);
    });

    it('handlesMissingFieldsAndMalformedJsonWithoutCrashing', 0, () => {
      const brokenInputs: string[] = ['', 'not-json', '{}', '{"status":"login"}', '{"info":[{}],"data":{"comments":[null]}}'];
      for (let i = 0; i < brokenInputs.length; i++) {
        const s: string = brokenInputs[i];
        const r1: CommunityListResp = parseCommunityListResp(s);
        const r2: PostDetailResp = parsePostDetailResp(s);
        const r3: PostCommentsResp = parsePostCommentsResp(s);
        const r4: CommentRepliesResp = parseCommentRepliesResp(s);
        const r5: MsgReplyResp = parseMsgReplyResp(s);
        const r6: MsgCommunityReplyResp = parseMsgCommunityReplyResp(s);
        const r7: MsgSysResp = parseMsgSysResp(s);
        const r8: MsgCountResp = parseMsgCountResp(s);
        expect(Array.isArray(r1.info)).assertTrue();
        expect(Array.isArray(r2.data.comments)).assertTrue();
        expect(Array.isArray(r3.data.comments)).assertTrue();
        expect(Array.isArray(r4.data.replies)).assertTrue();
        expect(Array.isArray(r5.reply.comment)).assertTrue();
        expect(Array.isArray(r6.community_reply.community_reply)).assertTrue();
        expect(Array.isArray(r7.sysmsg.msg)).assertTrue();
        expect(r8.count.all >= 0).assertTrue();
      }
    });

  });
}
