import { describe, expect, it } from '@ohos/hypium';
import { NoyClient, NoyClientDeps, NoyHttpTransport } from '../main/ets/api/NoyClient';
import { CommunityPost } from '../main/ets/models/NoyModels';
import { canEditPost } from '../main/ets/utils/CommunityFeedHelper';
import {
  buildCreatePostImageList,
  CommunityDraftImage,
  inferImageContentType,
  inferImageExtension,
  normalizeImageFileForCreatePost,
  UploadStatus
} from '../main/ets/utils/CommunityMediaHelper';
import {
  appendStickerTag,
  canSubmitPost,
  hasPendingOrFailedUploads,
  validatePostDraft
} from '../main/ets/utils/CommunityWriteHelper';
import { PageResult, PagedLoader } from '../main/ets/utils/PagedLoader';

class RecordedCall {
  path: string;
  form: Record<string, string>;

  constructor(path: string, form: Record<string, string>) {
    this.path = path;
    this.form = form;
  }
}

class MockWriteTransport implements NoyHttpTransport {
  readonly calls: RecordedCall[] = [];
  private handler: (path: string, form: Record<string, string>) => string;

  constructor(handler: (path: string, form: Record<string, string>) => string) {
    this.handler = handler;
  }

  async postFormText(path: string, form: Record<string, string>,
    _headers?: Record<string, string>): Promise<string> {
    this.calls.push(new RecordedCall(path, form));
    return this.handler(path, form);
  }

  async clearSiteCookies(): Promise<void> {}
}

class MockWriteDeps implements NoyClientDeps {
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

export default function communityWriteTest(): void {
  describe('CommunityWriteTest', () => {
    it('validatesTitleContentAndUploadStatesBeforeSubmit', 0, () => {
      expect(validatePostDraft('', '正文')).assertEqual('请输入帖子标题');
      expect(validatePostDraft('   ', '正文')).assertEqual('请输入帖子标题');
      expect(validatePostDraft('标题', '')).assertEqual('请输入帖子正文');
      expect(validatePostDraft('标题', '正文')).assertEqual('');

      const uploadingImg = new CommunityDraftImage('1', 'file://a.webp', '/cache/a.webp', 'internal://cache/a.webp');
      uploadingImg.status = UploadStatus.UPLOADING;
      expect(hasPendingOrFailedUploads([uploadingImg])).assertTrue();
      expect(canSubmitPost('标题', '正文', [uploadingImg], false)).assertFalse();

      const failedImg = new CommunityDraftImage('2', 'file://b.webp', '/cache/b.webp', 'internal://cache/b.webp');
      failedImg.status = UploadStatus.FAILED;
      expect(canSubmitPost('标题', '正文', [failedImg], false)).assertFalse();

      const okImg = new CommunityDraftImage('3', 'file://c.webp', '/cache/c.webp', 'internal://cache/c.webp');
      okImg.status = UploadStatus.SUCCESS;
      okImg.serverFile = 'abc.webp';
      expect(canSubmitPost('标题', '正文', [okImg], false)).assertTrue();
      expect(canSubmitPost('标题', '正文', [okImg], true)).assertFalse();

      expect(appendStickerTag('你好', '[noygirl:yeah]')).assertEqual('你好[noygirl:yeah]');
    });

    it('infersMediaTypesAndSerializesImagePrefixForCreatePost', 0, async () => {
      expect(inferImageExtension('photo.PNG?x=1')).assertEqual('png');
      expect(inferImageExtension('photo.jpeg')).assertEqual('jpg');
      expect(inferImageContentType('png')).assertEqual('image/png');
      expect(inferImageContentType('webp')).assertEqual('image/webp');
      expect(normalizeImageFileForCreatePost('a.webp')).assertEqual('image/a.webp');
      expect(normalizeImageFileForCreatePost('image/b.webp')).assertEqual('image/b.webp');

      const img1 = new CommunityDraftImage('1', '', '', '');
      img1.status = UploadStatus.SUCCESS;
      img1.serverFile = 'one.webp';
      const img2 = new CommunityDraftImage('2', '', '', '');
      img2.status = UploadStatus.SUCCESS;
      img2.serverFile = 'image/two.png';
      const files: string[] = buildCreatePostImageList([img1, img2]);
      expect(files.length).assertEqual(2);
      expect(files[0]).assertEqual('image/one.webp');
      expect(files[1]).assertEqual('image/two.png');

      const transport = new MockWriteTransport((_path: string, _form: Record<string, string>): string => {
        return '{"status":"ok"}';
      });
      const client = new NoyClient(transport, new MockWriteDeps(), 0);
      await client.createPost('新帖标题', '新帖正文 [noygirl:hi]', files);

      expect(transport.calls.length).assertEqual(1);
      expect(transport.calls[0].path).assertEqual('/api/v3/send_community');
      expect(transport.calls[0].form['title']).assertEqual('新帖标题');
      expect(transport.calls[0].form['content']).assertEqual('新帖正文 [noygirl:hi]');
      expect(transport.calls[0].form['image']).assertEqual('["image/one.webp","image/two.png"]');
    });

    it('createPostSuccessTriggersFeedRefreshToShowNewPost', 0, async () => {
      let created: boolean = false;
      const transport = new MockWriteTransport((path: string, _form: Record<string, string>): string => {
        if (path === '/api/v3/send_community') {
          created = true;
          return '{"status":"ok"}';
        }
        if (path === '/api/v3/community_list') {
          if (!created) {
            return '{"status":"ok","top":false,"over":true,"info":[{"id":1,"uid":10,"title":"旧帖"}]}';
          }
          return '{"status":"ok","top":false,"over":true,"info":[{"id":2,"uid":10,"title":"刚发布的新帖"},{"id":1,"uid":10,"title":"旧帖"}]}';
        }
        return '{"status":"ok"}';
      });

      const client = new NoyClient(transport, new MockWriteDeps(), 0);
      const loader = new PagedLoader<CommunityPost>(
        async (page: number): Promise<PageResult<CommunityPost>> => {
          const resp = await client.listPosts(page, 'new', '');
          return { items: resp.info, over: resp.over };
        },
        (p: CommunityPost): string => String(p.id)
      );

      await loader.refresh();
      expect(loader.items.length).assertEqual(1);
      expect(loader.items[0].id).assertEqual(1);

      await client.createPost('刚发布的新帖', '内容', []);
      await loader.refresh();
      expect(loader.items.length).assertEqual(2);
      expect(loader.items[0].id).assertEqual(2);
      expect(loader.items[0].title).assertEqual('刚发布的新帖');
    });

    it('editPostChecksAuthorPermissionAndSubmitsUpdatedFields', 0, async () => {
      expect(canEditPost(10, 10)).assertTrue();
      expect(canEditPost(10, 20)).assertFalse();

      const transport = new MockWriteTransport((_path: string, _form: Record<string, string>): string => {
        return '{"status":"ok"}';
      });
      const client = new NoyClient(transport, new MockWriteDeps(), 0);
      await client.editPost(88, '修改后标题', '修改后正文');

      expect(transport.calls.length).assertEqual(1);
      expect(transport.calls[0].path).assertEqual('/api/v3/edit_community_post');
      expect(transport.calls[0].form['id']).assertEqual('88');
      expect(transport.calls[0].form['title']).assertEqual('修改后标题');
      expect(transport.calls[0].form['content']).assertEqual('修改后正文');
    });

    it('communityMessagesIncludePostIdForDetailNavigation', 0, async () => {
      const transport = new MockWriteTransport((path: string, form: Record<string, string>): string => {
        if (path === '/api/v3/get_msg' && form['type'] === 'community_reply') {
          return '{"status":"ok","community_reply":{"count":1,"community_reply_len":1,"community":{"55":{"id":55,"title":"讨论帖"}},"community_reply":[{"rid":700,"uid":12,"cid":55,"username":"alice","content":"回复了你","time":1700000000}]}}';
        }
        return '{"status":"ok"}';
      });
      const client = new NoyClient(transport, new MockWriteDeps(), 0);
      const resp = await client.messagesCommunityReply(1);
      expect(resp.community_reply.community_reply.length).assertEqual(1);
      expect(resp.community_reply.community_reply[0].cid).assertEqual(55);
      expect(resp.community_reply.community['55'].title).assertEqual('讨论帖');
    });
  });
}
