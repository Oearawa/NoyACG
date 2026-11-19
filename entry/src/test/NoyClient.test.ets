/**
 * NoyClient.test.ets —— 阶段 1 社区基础层离线单测（Hypium）
 *
 * 覆盖：
 *   1. 单一会话与成人内容确认契约（未显式确认前社区请求一律传 allow-adult: false，不改非社区行为）；
 *   2. ApiHeaders 保留调用方显式 allow-adult，非社区无显式传参时保持原策略；
 *   3. status: 'login'（含登出后请求）触发 notifySessionExpired + clearSiteCookies + onSessionExpired + NoyAuthError；
 *   4. status: 'error' 抛 NoyApiError 且不误触发登出；
 *   5. 串行节流（最小请求间隔）；
 *   6. 社区读接口（listPosts / postDetail / unreadCount）通过 NoyModels 解析返回。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  NoyApiError,
  NoyAuthError,
  NoyClient,
  NoyClientDeps,
  NoyHttpTransport,
  resolveCommunityAllowAdult
} from '../main/ets/api/NoyClient';
import { NOY_API_PREFIX, resolveContentRatingHeader } from '../main/ets/api/ApiHeaders';
import { ContentRating } from '../main/ets/utils/PreferenceManager';
import { ContentRatingPolicy } from '../main/ets/utils/ContentRatingPolicy';
import {
  FIXTURE_COMMUNITY_LIST,
  FIXTURE_MSG_COUNT,
  FIXTURE_POST_DETAIL
} from './CommunityFixtures';

class StubTransport implements NoyHttpTransport {
  calls: number = 0;
  lastPath: string = '';
  lastHeaders: Record<string, string> = {};
  callTimestamps: number[] = [];
  clearCookiesCalls: number = 0;
  responseByPath: Record<string, string> = {};

  async postFormText(path: string, _form: Record<string, string>,
    headers?: Record<string, string>): Promise<string> {
    this.calls++;
    this.callTimestamps.push(Date.now());
    this.lastPath = path;
    this.lastHeaders = headers ?? {};
    return this.responseByPath[path] ?? '{"status":"ok"}';
  }

  async clearSiteCookies(): Promise<void> {
    this.clearCookiesCalls++;
  }
}

class StubDeps implements NoyClientDeps {
  authenticated: boolean = true;
  policyRating: string = ContentRating.ALL_AGES;
  adultConfirmed: boolean = false;
  expiredNotifications: number = 0;

  isAuthenticated(): boolean {
    return this.authenticated;
  }

  notifySessionExpired(): void {
    this.expiredNotifications++;
    this.authenticated = false;
  }

  resolveContentRating(): string {
    return this.policyRating;
  }

  isCommunityAdultConfirmed(): boolean {
    return this.adultConfirmed;
  }
}

export default function noyClientTest(): void {
  describe('NoyClient_Stage1', () => {

    it('enforcesAdultFalseUntilExplicitlyConfirmedWithoutChangingNonCommunity', 0, async () => {
      expect(resolveCommunityAllowAdult(ContentRating.ALL_AGES, false)).assertEqual('false');
      expect(resolveCommunityAllowAdult(ContentRating.ADULT, false)).assertEqual('false');
      expect(resolveCommunityAllowAdult(ContentRating.BOTH, false)).assertEqual('false');
      expect(resolveCommunityAllowAdult(ContentRating.ADULT, true)).assertEqual('true');
      expect(resolveCommunityAllowAdult(ContentRating.BOTH, true)).assertEqual('both');
      expect(resolveCommunityAllowAdult(ContentRating.ALL_AGES, true)).assertEqual('false');

      const transport: StubTransport = new StubTransport();
      transport.responseByPath['/api/v3/community_list'] = FIXTURE_COMMUNITY_LIST;
      const deps: StubDeps = new StubDeps();
      deps.policyRating = ContentRating.ADULT;
      deps.adultConfirmed = false;

      const client: NoyClient = new NoyClient(transport, deps, 0);
      await client.listPosts(1, 'new', '');
      expect(transport.lastHeaders['allow-adult']).assertEqual('false');

      deps.adultConfirmed = true;
      await client.listPosts(1, 'new', '');
      expect(transport.lastHeaders['allow-adult']).assertEqual('true');

      // 验证 ApiHeaders 对非社区请求不改变原有行为，同时尊重社区显式传入的 allow-adult
      const policy: ContentRatingPolicy = ContentRatingPolicy.getInstance();
      const prev: string = policy.resolve();
      try {
        await policy.set(ContentRating.ADULT);
        const nonCommunityHeaders = resolveContentRatingHeader(`${NOY_API_PREFIX}home`);
        expect(nonCommunityHeaders !== undefined).assertTrue();
        expect(nonCommunityHeaders!['allow-adult']).assertEqual(ContentRating.ADULT);

        const communityHeaders = resolveContentRatingHeader(`${NOY_API_PREFIX}v3/community_list`, {
          'allow-adult': 'false'
        });
        expect(communityHeaders!['allow-adult']).assertEqual('false');
      } finally {
        await policy.set(prev);
      }
    });

    it('triggersLoginFlowOnSessionExpiredEvenAfterLogout', 0, async () => {
      const transport: StubTransport = new StubTransport();
      transport.responseByPath['/api/v3/community_list'] = '{"status":"login"}';
      const deps: StubDeps = new StubDeps();
      deps.authenticated = false; // 模拟已登出后再次发社区请求

      let expiredCallbackCount: number = 0;
      const client: NoyClient = new NoyClient(transport, deps, 0);
      client.setOnSessionExpired((): void => {
        expiredCallbackCount++;
      });

      let caughtAuthError: boolean = false;
      try {
        await client.listPosts(1, 'new', '');
      } catch (e) {
        caughtAuthError = e instanceof NoyAuthError;
      }
      expect(caughtAuthError).assertTrue();
      expect(deps.expiredNotifications).assertEqual(1);
      expect(transport.clearCookiesCalls).assertEqual(1);
      expect(expiredCallbackCount).assertEqual(1);
    });

    it('throwsNoyApiErrorWithoutLogoutOnBusinessError', 0, async () => {
      const transport: StubTransport = new StubTransport();
      transport.responseByPath['/api/v4/community/post/1'] = '{"status":"error"}';
      const deps: StubDeps = new StubDeps();
      let expiredCallbackCount: number = 0;
      const client: NoyClient = new NoyClient(transport, deps, 0);
      client.setOnSessionExpired((): void => {
        expiredCallbackCount++;
      });

      let caughtApiError: boolean = false;
      try {
        await client.postDetail(1);
      } catch (e) {
        caughtApiError = e instanceof NoyApiError;
      }
      expect(caughtApiError).assertTrue();
      expect(deps.expiredNotifications).assertEqual(0);
      expect(expiredCallbackCount).assertEqual(0);
    });

    it('serializesAndThrottlesConcurrentRequests', 0, async () => {
      const transport: StubTransport = new StubTransport();
      transport.responseByPath['/api/v4/msg/count'] = FIXTURE_MSG_COUNT;
      const deps: StubDeps = new StubDeps();
      const client: NoyClient = new NoyClient(transport, deps, 40);

      await Promise.all([
        client.unreadCount(),
        client.unreadCount(),
        client.unreadCount()
      ]);
      expect(transport.calls).assertEqual(3);
      expect(transport.callTimestamps.length).assertEqual(3);
      const delta1: number = transport.callTimestamps[1] - transport.callTimestamps[0];
      const delta2: number = transport.callTimestamps[2] - transport.callTimestamps[1];
      expect(delta1 >= 30).assertTrue();
      expect(delta2 >= 30).assertTrue();
    });

    it('parsesCommunityReadResponsesIntoStage0Models', 0, async () => {
      const transport: StubTransport = new StubTransport();
      transport.responseByPath['/api/v3/community_list'] = FIXTURE_COMMUNITY_LIST;
      transport.responseByPath['/api/v4/community/post/78930'] = FIXTURE_POST_DETAIL;
      transport.responseByPath['/api/v4/msg/count'] = FIXTURE_MSG_COUNT;

      const client: NoyClient = new NoyClient(transport, new StubDeps(), 0);
      const list = await client.listPosts(1, 'new', '');
      expect(list.info.length).assertEqual(1);
      expect(list.info[0].id).assertEqual(78930);

      const detail = await client.postDetail(78930);
      expect(detail.data.post.id).assertEqual(78930);
      expect(detail.data.comments.length).assertEqual(1);

      const count = await client.unreadCount();
      expect(count.status).assertEqual('ok');
      expect(count.count.all).assertEqual(0);
    });

  });
}
