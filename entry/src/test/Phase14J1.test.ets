/**
 * Phase14J1.test.ets —— Phase 14-J1 内容分级 / 用户资料 / 徽章 / 消息 / 抽屉 / 登出 测试
 *
 * 全部为协议解析与纯状态机测试（不联网、不依赖设备）。
 * userinfo/badge/message 样本是 `*.derived.json` 派生样例，**不是真实抓包**；
 * 消息条目字段结构未取得完整样本，本套件只验证「按 type 取对应数组 + 防御式映射」的行为。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { ContentRatingPolicy } from '../main/ets/utils/ContentRatingPolicy';
import { ContentRating, PreferenceManager } from '../main/ets/utils/PreferenceManager';
import {
  RATING_LABELS,
  ratingToIndex,
  indexToRating,
  ratingLabel
} from '../main/ets/viewmodel/SettingsViewModel';
import { HttpManager } from '../main/ets/api/HttpManager';
import {
  badgeImageOrigin,
  matchShownBadges,
  parseBadgesJson,
  parseMessageCountJson,
  parseMessageListJson,
  parseUserInfoJson,
  resolveUserAssetUrl
} from '../main/ets/source/NoyAcgProtocol';
import { BadgeResult } from '../main/ets/source/NoyAcgProtocol';
import { MessagePageResult } from '../main/ets/source/NoyAcgProtocol';
import { UserInfo, UserBadge } from '../main/ets/model/UserInfo';
import { MessageCount, MSG_TYPE_COMMUNITY_REPLY, MSG_TYPE_REPLY, MSG_TYPE_SYSMSG } from '../main/ets/model/Message';
import { AuthRequiredError, ProtocolError } from '../main/ets/api/ApiErrors';
import { AuthRepository } from '../main/ets/api/AuthRepository';
import { AuthStatus } from '../main/ets/api/AuthTypes';
import { AuthManager } from '../main/ets/utils/AuthManager';
import { StubAuthCookies, StubAuthHttp } from './AuthStubs';
import {
  BADGE_SUCCESS_DERIVED,
  LOGOUT_SUCCESS_DERIVED,
  MSG_COUNT_SUCCESS_DERIVED,
  MSG_LIST_REPLY_DERIVED,
  USERINFO_ANON,
  USERINFO_SUCCESS_DERIVED
} from './fixtures/FixtureData';

function catchError(fn: () => void): Error | null {
  try {
    fn();
    return null;
  } catch (e) {
    return e as Error;
  }
}

export default function phase14j1Test() {
  describe('Phase14J1', () => {
    // ==================== 内容分级策略 ====================

    it('contentRatingDefaultsToAllAges', 0, () => {
      ContentRatingPolicy.getInstance().resetForTest();
      expect(ContentRatingPolicy.getInstance().resolve()).assertEqual(ContentRating.ALL_AGES);
      expect(ContentRating.ALL_AGES).assertEqual('false');
    });

    it('contentRatingSanitizeFallsBackToAllAges', 0, () => {
      expect(ContentRatingPolicy.sanitize('true')).assertEqual('true');
      expect(ContentRatingPolicy.sanitize('both')).assertEqual('both');
      expect(ContentRatingPolicy.sanitize('false')).assertEqual('false');
      expect(ContentRatingPolicy.sanitize('')).assertEqual('false');
      expect(ContentRatingPolicy.sanitize('nsfw')).assertEqual('false');
    });

    it('contentRatingSetUpdatesAndNotifies', 0, async () => {
      const policy = ContentRatingPolicy.getInstance();
      policy.resetForTest();
      PreferenceManager.getInstance().reset();
      let notified: number = 0;
      const listener: () => void = (): void => {
        notified++;
      };
      policy.onChange(listener);
      const ok: boolean = await policy.set('true');
      expect(ok).assertTrue();
      expect(policy.current).assertEqual('true');
      expect(notified).assertEqual(1);
      // 相同值不重复通知
      await policy.set('true');
      expect(notified).assertEqual(1);
      // 非法值回退全年龄
      await policy.set('junk');
      expect(policy.current).assertEqual('false');
      policy.offChange(listener);
    });

    it('contentRatingMappingThreeOptions', 0, () => {
      expect(RATING_LABELS.length).assertEqual(3);
      expect(ratingToIndex('false')).assertEqual(0);
      expect(ratingToIndex('true')).assertEqual(1);
      expect(ratingToIndex('both')).assertEqual(2);
      expect(ratingToIndex('junk')).assertEqual(0);
      expect(indexToRating(0)).assertEqual('false');
      expect(indexToRating(1)).assertEqual('true');
      expect(indexToRating(2)).assertEqual('both');
      expect(indexToRating(9)).assertEqual('false');
      expect(ratingLabel('both')).assertEqual(RATING_LABELS[2]);
    });

    it('onlyApiUrlGetsContentRatingHeader', 0, () => {
      // 站内 /api 请求注入；图片 CDN / 图床 / 外部域名不注入
      expect(HttpManager.isNoyApiUrl('https://noymanga.com/api/home')).assertTrue();
      expect(HttpManager.isNoyApiUrl('https://noymanga.com/api/v3/userinfo')).assertTrue();
      expect(HttpManager.isNoyApiUrl('https://img.noymanga.com/1/m1.webp')).assertFalse();
      expect(HttpManager.isNoyApiUrl('https://bucket.noymanga.com/image/a.webp')).assertFalse();
      expect(HttpManager.isNoyApiUrl('https://stream.noyteam.online/1/cover.webp')).assertFalse();
      expect(HttpManager.isNoyApiUrl('https://example.com/api/x')).assertFalse();
    });

    // ==================== 用户资料 ====================

    it('userInfoParsesRealFieldsAndDropsIntegral', 0, () => {
      const info: UserInfo = parseUserInfoJson(USERINFO_SUCCESS_DERIVED);
      expect(info.uid).assertEqual('900001');
      expect(info.username).assertEqual('sample_user');
      expect(info.avatarUrl).assertEqual('https://bucket.noymanga.com/avatar/900001.webp');
      expect(info.bgUrl).assertEqual('https://bucket.noymanga.com/bg/900001.webp');
      expect(info.createdAt).assertEqual('2025-01-01');
      expect(info.commentCount).assertEqual(12);
      // 模型没有 Integral 字段 → 积分不会被展示
      expect(info.avatarPath).assertEqual('avatar/900001.webp');
    });

    it('userInfoLoginStatusRaisesAuthRequired', 0, () => {
      const err: Error | null = catchError(() => {
        parseUserInfoJson(USERINFO_ANON);
      });
      expect(err instanceof AuthRequiredError).assertTrue();
    });

    it('userInfoMissingUserinfoRejected', 0, () => {
      const err: Error | null = catchError(() => {
        parseUserInfoJson('{"status":"ok"}');
      });
      expect(err instanceof ProtocolError).assertTrue();
    });

    it('assetUrlValidatesSchemeAndHost', 0, () => {
      expect(resolveUserAssetUrl('a/b.webp', 'https://bucket.noymanga.com'))
        .assertEqual('https://bucket.noymanga.com/a/b.webp');
      expect(resolveUserAssetUrl('/a/b.webp', '')).assertEqual('https://bucket.noymanga.com/a/b.webp');
      expect(resolveUserAssetUrl('https://bucket.noymanga.com/x.webp', '')).assertEqual('https://bucket.noymanga.com/x.webp');
      expect(resolveUserAssetUrl('https://bucket.239847.xyz/x.webp', '')).assertEqual('');
      expect(resolveUserAssetUrl('javascript:alert(1)', '')).assertEqual('');
      expect(resolveUserAssetUrl('', '')).assertEqual('');
    });

    // ==================== 徽章 ====================

    it('badgesMatchShowOrderAndNumericId', 0, () => {
      const result: BadgeResult = parseBadgesJson(BADGE_SUCCESS_DERIVED);
      expect(result.all.length).assertEqual(4);
      expect(result.shown.length).assertEqual(4);
      // show = ["10","11","9","8"] → 按此顺序
      expect(result.shown[0].id).assertEqual('10');
      expect(result.shown[0].name).assertEqual('徽章十');
      expect(result.shown[1].id).assertEqual('11');
      expect(result.shown[2].id).assertEqual('9');
      expect(result.shown[3].id).assertEqual('8');
      expect(result.shown[0].img).assertEqual('https://bucket.noymanga.com/image/b10.webp');
    });

    it('badgesIgnoreUnknownShowIds', 0, () => {
      const result: BadgeResult = parseBadgesJson(BADGE_SUCCESS_DERIVED);
      const matched: UserBadge[] = matchShownBadges(result.all, ['999', '8', '8']);
      expect(matched.length).assertEqual(1);
      expect(matched[0].id).assertEqual('8');
    });

    it('badgeOriginFromAbsoluteImg', 0, () => {
      const result: BadgeResult = parseBadgesJson(BADGE_SUCCESS_DERIVED);
      expect(badgeImageOrigin(result.all)).assertEqual('https://bucket.noymanga.com');
      expect(badgeImageOrigin([])).assertEqual('');
    });

    it('badgesLoginStatusRaisesAuthRequired', 0, () => {
      const err: Error | null = catchError(() => {
        parseBadgesJson(USERINFO_ANON);
      });
      expect(err instanceof AuthRequiredError).assertTrue();
    });

    // ==================== 消息计数 / 列表 ====================

    it('messageCountParsesAllFields', 0, () => {
      const count: MessageCount = parseMessageCountJson(MSG_COUNT_SUCCESS_DERIVED);
      expect(count.all).assertEqual(5);
      expect(count.sysMsg).assertEqual(1);
      expect(count.communityReply).assertEqual(2);
      expect(count.commentReply).assertEqual(2);
    });

    it('messageListParsesReplyStructure', 0, () => {
      const result: MessagePageResult = parseMessageListJson(MSG_LIST_REPLY_DERIVED, MSG_TYPE_REPLY);
      expect(result.items.length).assertEqual(2);
      expect(result.over).assertTrue();
      expect(result.items[0].kind).assertEqual(MSG_TYPE_REPLY);
      expect(result.items[0].bookId).assertEqual('900201');
      expect(result.items[0].cover).assertEqual('https://bucket.noymanga.com/m/900201.webp');
      expect(result.items[1].id).assertEqual('7002');
    });

    it('messageListParsesCommunityAndSysmsg', 0, () => {
      const community: MessagePageResult = parseMessageListJson(
        '{"status":"ok","community_reply":{"community_reply":[{"id":1,"content":"社群回覆"}]}}',
        MSG_TYPE_COMMUNITY_REPLY);
      expect(community.items.length).assertEqual(1);
      expect(community.items[0].kind).assertEqual(MSG_TYPE_COMMUNITY_REPLY);
      expect(community.items[0].content).assertEqual('社群回覆');
      // 无 over 字段且非空 → 保守视为未到底
      expect(community.over).assertFalse();

      const sys: MessagePageResult = parseMessageListJson(
        '{"status":"ok","sysmsg":{"msg":[{"id":2,"title":"系統","message":"通知"}]}}',
        MSG_TYPE_SYSMSG);
      expect(sys.items.length).assertEqual(1);
      expect(sys.items[0].content).assertEqual('通知');
    });

    it('messageListLoginStatusRaisesAuthRequired', 0, () => {
      const err: Error | null = catchError(() => {
        parseMessageListJson(USERINFO_ANON, MSG_TYPE_REPLY);
      });
      expect(err instanceof AuthRequiredError).assertTrue();
    });

    // ==================== 严格登出 ====================

    it('logoutWithServerAckSucceedsAndClears', 0, async () => {
      const http: StubAuthHttp = new StubAuthHttp();
      const cookies: StubAuthCookies = new StubAuthCookies();
      cookies.count = 1;
      http.userInfoResponse = USERINFO_SUCCESS_DERIVED;
      http.logoutResponse = LOGOUT_SUCCESS_DERIVED;
      const manager: AuthManager = new AuthManager(new AuthRepository(http, cookies));
      await manager.restoreSession();
      expect(manager.status).assertEqual(AuthStatus.AUTHENTICATED);
      const ok: boolean = await manager.logoutWithServerAck();
      expect(ok).assertTrue();
      expect(manager.status).assertEqual(AuthStatus.UNAUTHENTICATED);
      expect(manager.user === null).assertTrue();
      expect(cookies.clearCalls).assertEqual(1);
    });

    it('logoutWithServerFailureKeepsSessionAndReports', 0, async () => {
      const http: StubAuthHttp = new StubAuthHttp();
      const cookies: StubAuthCookies = new StubAuthCookies();
      cookies.count = 1;
      http.userInfoResponse = USERINFO_SUCCESS_DERIVED;
      http.throwOnLogout = true;
      const manager: AuthManager = new AuthManager(new AuthRepository(http, cookies));
      await manager.restoreSession();
      expect(manager.status).assertEqual(AuthStatus.AUTHENTICATED);
      const ok: boolean = await manager.logoutWithServerAck();
      expect(ok).assertFalse();
      // 服务端未确认 → 保持登录态，不假装成功
      expect(manager.status).assertEqual(AuthStatus.AUTHENTICATED);
      expect(cookies.clearCalls).assertEqual(0);
      expect(manager.errorMessage !== '').assertTrue();
    });
  });
}
