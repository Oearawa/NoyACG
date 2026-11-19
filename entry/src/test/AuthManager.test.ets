/**
 * AuthManager.test.ets —— 全局认证状态机单元测试（桩注入，不联网）
 *
 * 覆盖：启动恢复的「无 Cookie 不发请求」「有 Cookie 必须服务端认可」、
 * 网络异常保留会话、并发恢复去重、登录/退出状态迁移、会话过期降级、
 * 以及退出清理失败时不伪造「完全成功」。
 *
 * ⚠ 所有「已登录」状态都由桩响应驱动，不代表真实账号登录成功。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { AuthRepository } from '../main/ets/api/AuthRepository';
import { AuthErrorKind, AuthStatus } from '../main/ets/api/AuthTypes';
import { AuthManager } from '../main/ets/utils/AuthManager';
import { LOGIN_INVALID_CREDENTIALS, USERINFO_ANON } from './fixtures/FixtureData';
import { StubAuthCookies, StubAuthHttp } from './AuthStubs';

export default function authManagerTest() {
  describe('AuthManager', () => {
    let http: StubAuthHttp = new StubAuthHttp();
    let cookies: StubAuthCookies = new StubAuthCookies();
    let manager: AuthManager = new AuthManager(new AuthRepository(http, cookies));

    beforeEach(() => {
      http = new StubAuthHttp();
      cookies = new StubAuthCookies();
      manager = new AuthManager(new AuthRepository(http, cookies));
    });

    // ==================== 启动恢复 ====================

    it('initialStatusIsUnknown', 0, () => {
      expect(manager.status).assertEqual(AuthStatus.UNKNOWN);
      expect(manager.isAuthenticated).assertFalse();
      expect(manager.user === null).assertTrue();
    });

    it('restoreWithoutCookiesSkipsServerCheck', 0, async () => {
      cookies.count = 0;
      await manager.restoreSession();
      expect(manager.status).assertEqual(AuthStatus.UNAUTHENTICATED);
      expect(http.calls.length).assertEqual(0);
    });

    it('restoreWithValidSessionAuthenticates', 0, async () => {
      await manager.restoreSession();
      expect(manager.isAuthenticated).assertTrue();
      expect(manager.status).assertEqual(AuthStatus.AUTHENTICATED);
      expect(manager.user !== null).assertTrue();
      if (manager.user !== null) {
        expect(manager.user.uid).assertEqual('900001');
      }
      expect(http.calls[0]).assertEqual('/api/v3/userinfo');
    });

    it('restoreWithRejectedSessionDoesNotClearCookies', 0, async () => {
      http.userInfoResponse = USERINFO_ANON;
      await manager.restoreSession();
      expect(manager.status).assertEqual(AuthStatus.UNAUTHENTICATED);
      expect(manager.user === null).assertTrue();
      // 服务端不认可可能是临时故障，不能擅自删除会话
      expect(cookies.clearCalls).assertEqual(0);
    });

    it('restoreNetworkErrorKeepsCookiesAndAllowsRetry', 0, async () => {
      http.throwOnUserInfo = true;
      await manager.restoreSession();
      expect(manager.status).assertEqual(AuthStatus.ERROR);
      expect(manager.errorKind === AuthErrorKind.NETWORK).assertTrue();
      expect(cookies.clearCalls).assertEqual(0);

      http.throwOnUserInfo = false;
      await manager.restoreSession(true);
      expect(manager.isAuthenticated).assertTrue();
      expect(manager.errorMessage).assertEqual('');
    });

    it('concurrentRestoreSharesOneRequest', 0, async () => {
      const first: Promise<void> = manager.restoreSession(true);
      const second: Promise<void> = manager.restoreSession(true);
      await first;
      await second;
      expect(http.calls.length).assertEqual(1);
      expect(manager.isAuthenticated).assertTrue();
    });

    it('restoreIsSkippedWhenAlreadyAuthenticated', 0, async () => {
      await manager.restoreSession();
      expect(http.calls.length).assertEqual(1);
      await manager.restoreSession();
      expect(http.calls.length).assertEqual(1);
    });

    // ==================== 登录 ====================

    it('loginSuccessTransitionsToAuthenticated', 0, async () => {
      const ok: boolean = await manager.login('demo', 'demo_pass');
      expect(ok).assertTrue();
      expect(manager.isAuthenticated).assertTrue();
      expect(manager.errorMessage).assertEqual('');
      expect(manager.errorKind === null).assertTrue();
    });

    it('loginFailureTransitionsToLoginFailed', 0, async () => {
      http.loginResponse = LOGIN_INVALID_CREDENTIALS;
      const ok: boolean = await manager.login('demo', 'wrong');
      expect(ok).assertFalse();
      expect(manager.status).assertEqual(AuthStatus.LOGIN_FAILED);
      expect(manager.errorKind === AuthErrorKind.INVALID_CREDENTIALS).assertTrue();
      expect(manager.errorMessage).assertEqual('账号或密码错误');
      expect(manager.user === null).assertTrue();
    });

    // ==================== 退出 ====================

    it('logoutResetsStateAndClearsCookies', 0, async () => {
      await manager.login('demo', 'demo_pass');
      const ok: boolean = await manager.logout();
      expect(ok).assertTrue();
      expect(manager.status).assertEqual(AuthStatus.UNAUTHENTICATED);
      expect(manager.user === null).assertTrue();
      expect(manager.isAuthenticated).assertFalse();
      expect(cookies.clearCalls).assertEqual(1);
      expect(manager.errorMessage).assertEqual('');
    });

    it('logoutCleanupFailureIsReportedNotFaked', 0, async () => {
      await manager.login('demo', 'demo_pass');
      cookies.throwOnClear = true;
      const ok: boolean = await manager.logout();
      expect(ok).assertFalse();
      expect(manager.status).assertEqual(AuthStatus.UNAUTHENTICATED);
      expect(manager.errorMessage).assertEqual('本地会话清理失败，请重试退出');
    });

    // ==================== 会话过期降级 ====================

    it('notifySessionExpiredDowngradesOnlyWhenAuthenticated', 0, async () => {
      manager.notifySessionExpired(); // 未登录时调用：不应产生任何提示
      expect(manager.errorMessage).assertEqual('');

      await manager.login('demo', 'demo_pass');
      manager.notifySessionExpired();
      expect(manager.status).assertEqual(AuthStatus.UNAUTHENTICATED);
      expect(manager.errorKind === AuthErrorKind.SESSION_REJECTED).assertTrue();
      expect(manager.errorMessage).assertEqual('登录状态已过期，请重新登录');
    });

    it('resetForTestClearsAllState', 0, async () => {
      await manager.login('demo', 'demo_pass');
      manager.resetForTest();
      expect(manager.status).assertEqual(AuthStatus.UNKNOWN);
      expect(manager.user === null).assertTrue();
      expect(manager.errorMessage).assertEqual('');
      expect(manager.errorKind === null).assertTrue();
    });
  });
}
