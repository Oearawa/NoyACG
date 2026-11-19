import { describe, expect, it } from '@ohos/hypium';
import { NoyClient, NoyClientDeps, NoyHttpTransport } from '../main/ets/api/NoyClient';
import { CommunityComment, CommunityPost, NOY_BUCKET_ORIGIN } from '../main/ets/models/NoyModels';
import {
  buildSpoilerSet,
  canEditPost,
  clonePostWithLike,
  formatCommunityTime,
  isPostPinned,
  isUnreadPollDue,
  resolvePostImageUrls,
  toggleOptimisticLikeState
} from '../main/ets/utils/CommunityFeedHelper';
import { PageResult, PagedLoader } from '../main/ets/utils/PagedLoader';
import { parseRichText, resolveStickerUrl, RichKind } from '../main/ets/utils/RichText';

class MockFeedTransport implements NoyHttpTransport {
  readonly calls: string[] = [];
  private handler: (path: string, form: Record<string, string>) => string;

  constructor(handler: (path: string, form: Record<string, string>) => string) {
    this.handler = handler;
  }

  async postFormText(path: string, form: Record<string, string>,
    _headers?: Record<string, string>): Promise<string> {
    this.calls.push(path);
    return this.handler(path, form);
  }

  async clearSiteCookies(): Promise<void> {}
}

class MockFeedDeps implements NoyClientDeps {
  isAuthenticated(): boolean {
    return true;
  }

  notifySessionExpired(): void {}

  resolveContentRating(): string {
    return 'false';
  }

  isCommunityAdultConfirmed(): boolean {
    return false;
  }
}

export default function communityFeedTest(): void {
  describe('CommunityFeedTest', () => {
    it('pagedLoaderStopsStrictlyOnOverAndDedupsPinnedPost', 0, async () => {
      const transport = new MockFeedTransport((path: string, form: Record<string, string>): string => {
        if (path === '/api/v3/community_list' && form['page'] === '1') {
          return '{"status":"ok","top":true,"len":999,"over":false,"info":[{"id":100,"uid":1,"title":"置顶帖"},{"id":101,"uid":2,"title":"新帖 101"}]}';
        }
        return '{"status":"ok","top":false,"len":999,"over":true,"info":[{"id":100,"uid":1,"title":"置顶帖"},{"id":102,"uid":3,"title":"新帖 102"}]}';
      });

      const client = new NoyClient(transport, new MockFeedDeps(), 0);
      let topFlag: boolean = false;
      const loader = new PagedLoader<CommunityPost>(
        async (page: number): Promise<PageResult<CommunityPost>> => {
          const resp = await client.listPosts(page, 'new', '');
          if (page === 1) {
            topFlag = resp.top;
          }
          return { items: resp.info, over: resp.over };
        },
        (p: CommunityPost): string => String(p.id)
      );

      await loader.refresh();
      expect(loader.page).assertEqual(1);
      expect(loader.over).assertFalse();
      expect(loader.items.length).assertEqual(2);
      expect(isPostPinned(0, topFlag)).assertTrue();
      expect(isPostPinned(1, topFlag)).assertFalse();

      await loader.loadMore();
      expect(loader.page).assertEqual(2);
      expect(loader.over).assertTrue();
      // 去重：id=100 不重复追加
      expect(loader.items.length).assertEqual(3);
      expect(loader.items[0].id).assertEqual(100);
      expect(loader.items[1].id).assertEqual(101);
      expect(loader.items[2].id).assertEqual(102);

      // 已到底后再调 loadMore 不再发请求
      await loader.loadMore();
      expect(transport.calls.length).assertEqual(2);
    });

    it('optimisticLikeToggleAndRollbackPreserveNonNegativeCount', 0, async () => {
      const post = new CommunityPost();
      post.id = 77;
      post.like = 0;
      post.is_like = false;

      const likedState = toggleOptimisticLikeState(post.is_like, post.like);
      expect(likedState.is_like).assertTrue();
      expect(likedState.like).assertEqual(1);

      const updated = clonePostWithLike(post, likedState.is_like, likedState.like);
      expect(updated.is_like).assertTrue();
      expect(updated.like).assertEqual(1);

      const unlikedState = toggleOptimisticLikeState(false, 0);
      expect(unlikedState.is_like).assertTrue();
      const decFromZero = toggleOptimisticLikeState(true, 0);
      expect(decFromZero.is_like).assertFalse();
      expect(decFromZero.like).assertEqual(0);
    });

    it('authorEditPermissionDistinguishesDataUidAndPostUid', 0, () => {
      expect(canEditPost(42, 42)).assertTrue();
      expect(canEditPost(42, 99)).assertFalse();
      expect(canEditPost(0, 0)).assertFalse();
      expect(canEditPost(0, 42)).assertFalse();
    });

    it('unreadPollEnforcesSixtySecondForegroundInterval', 0, () => {
      expect(isUnreadPollDue(0, 1000)).assertTrue();
      expect(isUnreadPollDue(1000, 30000)).assertFalse();
      expect(isUnreadPollDue(1000, 61000)).assertTrue();
    });

    it('richTextParsesStickersAndNidBookLinksSafely', 0, () => {
      const segs = parseRichText('看看 [noygirl:yeah] 和 NID12345 还有 KNID999');
      expect(segs.length).assertEqual(5);
      expect(segs[0].kind).assertEqual(RichKind.Text);
      expect(segs[1].kind).assertEqual(RichKind.Sticker);
      expect(segs[1].pack).assertEqual('noygirl');
      expect(segs[1].name).assertEqual('yeah');
      expect(resolveStickerUrl('noygirl', 'yeah'))
        .assertEqual('https://noymanga.com/stickers/noygirl/yeah.webp');
      expect(segs[3].kind).assertEqual(RichKind.Book);
      expect(segs[3].bid).assertEqual(12345);
      // KNID999 不误判为书籍引用
      expect(segs[4].kind).assertEqual(RichKind.Text);
    });

    it('postDetailCommentsAndRepliesBindCorrectly', 0, async () => {
      const transport = new MockFeedTransport((path: string, form: Record<string, string>): string => {
        if (path === '/api/v4/community/post/55') {
          return '{"status":"ok","data":{"uid":88,"comment_count":2,"post":{"id":55,"uid":88,"username":"alice","title":"详情测试","content":"正文 [noygirl:hi] NID666","image":["image/a.webp","image/b.webp"],"spoiler":"1","like":5,"reply":2,"is_like":false}}}';
        }
        if (path === '/api/v4/community/post/55/comments') {
          return '{"status":"ok","data":{"page":1,"over":true,"comments":[{"rid":301,"uid":9,"username":"bob","content":"顶层评论","reply_more":true,"reply_num":1,"replies":[{"rid":302,"uid":10,"username":"carol","content":"子回复预览"}]}]}}';
        }
        if (path === '/api/v4/community/post/55/comment/301/replies') {
          expect(form['page']).assertEqual('1');
          return '{"status":"ok","data":{"page":1,"over":true,"count":1,"replies":[{"rid":302,"uid":10,"username":"carol","reply_username":"bob","content":"完整楼中楼"}]}}';
        }
        return '{"status":"ok"}';
      });

      const client = new NoyClient(transport, new MockFeedDeps(), 0);
      const detail = await client.postDetail(55);
      expect(canEditPost(detail.data.uid, detail.data.post.uid)).assertTrue();
      const imgUrls: string[] = resolvePostImageUrls(detail.data.post);
      expect(imgUrls.length).assertEqual(2);
      expect(imgUrls[0]).assertEqual(`${NOY_BUCKET_ORIGIN}/image/a.webp`);
      const spoilers: Set<number> = buildSpoilerSet(detail.data.post.spoiler);
      expect(spoilers.has(0)).assertFalse();
      expect(spoilers.has(1)).assertTrue();

      const commentsResp = await client.comments(55, 1);
      expect(commentsResp.data.over).assertTrue();
      expect(commentsResp.data.comments.length).assertEqual(1);
      const firstComment: CommunityComment = commentsResp.data.comments[0];
      expect(firstComment.reply_more).assertTrue();

      const repliesResp = await client.replies(55, firstComment.rid, 1);
      expect(repliesResp.data.over).assertTrue();
      expect(repliesResp.data.replies.length).assertEqual(1);
      expect(repliesResp.data.replies[0].reply_username).assertEqual('bob');

      expect(formatCommunityTime(1700000000, 1700000030 * 1000)).assertEqual('刚刚');
    });
  });
}
