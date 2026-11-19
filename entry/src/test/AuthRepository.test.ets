/**
 * AuthRepository.test.ets —— 登录协议层单元测试（桩注入，不联网）
 *
 * 覆盖：表单字段、status=error/danger/login 分支、Cookie 落地门槛、
 * 「必须服务端认可」的二次校验、用户信息字段兼容、网络/协议异常映射、
 * 退出时「服务端失败仍清理本地」与「清理失败如实返回 false」。
 *
 * ⚠ 本套件的「登录成功」是**桩响应驱动的状态机验证**，不是真实账号登录验证。
 * 真实登录成功响应因无账号/邀请码而始终未取得（见 LOGIN_PROTOCOL_AUDIT.md）。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { AuthRepository } from '../main/ets/api/AuthRepository';
import { AuthErrorKind, AuthFailure, AuthUser } from '../main/ets/api/AuthTypes';
import {
  LOGIN_EMPTY_FORM,
  LOGIN_INVALID_CREDENTIALS,
  LOGOUT_ANON,
  USERINFO_ANON
} from './fixtures/FixtureData';
import { StubAuthCookies, StubAuthHttp, assertFailureKind, captureFailure } from './AuthStubs';

export default function authRepositoryTest() {
  describe('AuthRepository', () => {
    let http: StubAuthHttp = new StubAuthHttp();
    let cookies: StubAuthCookies = new StubAuthCookies();
    let repo: AuthRepository = new AuthRepository(http, cookies);

    beforeEach(() => {
      http = new StubAuthHttp();
      cookies = new StubAuthCookies();
      repo = new AuthRepository(http, cookies);
    });

    // ==================== 输入校验 ====================

    it('loginRejectsEmptyCredentialsWithoutRequest', 0, async () => {
      const err: AuthFailure | null = await captureFailure(async (): Promise<void> => {
        await repo.login('   ', 'secret');
      });
      expect(err !== null).assertTrue();
      assertFailureKind(err, AuthErrorKind.INVALID_CREDENTIALS);
      expect(http.calls.length).assertEqual(0); // 不得发出任何请求
    });

    it('loginRejectsEmptyPasswordWithoutRequest', 0, async () => {
      const err: AuthFailure | null = await captureFailure(async (): Promise<void> => {
        await repo.login('user', '');
      });
      expect(err !== null).assertTrue();
      assertFailureKind(err, AuthErrorKind.INVALID_CREDENTIALS);
      expect(http.calls.length).assertEqual(0);
    });

    // ==================== 登录响应业务状态 ====================

    it('loginErrorStatusMapsToInvalidCredentials', 0, async () => {
      http.loginResponse = LOGIN_INVALID_CREDENTIALS;
      const err: AuthFailure | null = await captureFailure(async (): Promise<void> => {
        await repo.login('probe_user', 'probe_pass');
      });
      expect(err !== null).assertTrue();
      assertFailureKind(err, AuthErrorKind.INVALID_CREDENTIALS);
      // 真实抓包：POST /api/login form user/pass
      expect(http.calls[0]).assertEqual('/api/login');
      expect(http.loginForm['user']).assertEqual('probe_user');
      expect(http.loginForm['pass']).assertEqual('probe_pass');
      expect(cookies.persistCalls).assertEqual(0); // 失败不得落盘
    });

    it('loginEmptyFormFixtureIsAlsoRejected', 0, async () => {
      http.loginResponse = LOGIN_EMPTY_FORM;
      const err: AuthFailure | null = await captureFailure(async (): Promise<void> => {
        await repo.login('probe_user', 'probe_pass');
      });
      expect(err !== null).assertTrue();
      assertFailureKind(err, AuthErrorKind.INVALID_CREDENTIALS);
    });

    it('loginDangerStatusMapsToForbiddenInput', 0, async () => {
      http.loginResponse = '{"status":"danger"}';
      const err: AuthFailure | null = await captureFailure(async (): Promise<void> => {
        await repo.login('user', 'pass');
      });
      expect(err !== null).assertTrue();
      assertFailureKind(err, AuthErrorKind.FORBIDDEN_INPUT);
    });

    it('loginLoginStatusIsNotTreatedAsSuccess', 0, async () => {
      http.loginResponse = USERINFO_ANON; // {"status":"login"}
      const err: AuthFailure | null = await captureFailure(async (): Promise<void> => {
        await repo.login('user', 'pass');
      });
      expect(err !== null).assertTrue();
      assertFailureKind(err, AuthErrorKind.SERVER);
      expect(http.calls.length).assertEqual(1); // 不得继续请求 userinfo
    });

    // ==================== 会话门槛 ====================

    it('loginWithoutCookieIsRejected', 0, async () => {
      cookies.count = 0;
      const err: AuthFailure | null = await captureFailure(async (): Promise<void> => {
        await repo.login('user', 'pass');
      });
      expect(err !== null).assertTrue();
      assertFailureKind(err, AuthErrorKind.COOKIE_MISSING);
      expect(http.calls.length).assertEqual(1); // 无 Cookie 不得再校验 userinfo
    });

    it('loginWithCookieButAnonymousUserInfoIsRejected', 0, async () => {
      http.userInfoResponse = USERINFO_ANON;
      const err: AuthFailure | null = await captureFailure(async (): Promise<void> => {
        await repo.login('user', 'pass');
      });
      expect(err !== null).assertTrue();
      assertFailureKind(err, AuthErrorKind.SESSION_REJECTED);
      expect(http.calls.length).assertEqual(2);
    });

    it('loginSucceedsOnlyAfterServerValidation', 0, async () => {
      // 桩响应：非真实登录抓包，只验证状态机顺序与字段映射
      const account: AuthUser = await repo.login('  demo_user  ', 'demo_pass');
      expect(account.uid).assertEqual('900001');
      expect(account.name).assertEqual('範例使用者');
      expect(http.calls.length).assertEqual(2);
      expect(http.calls[0]).assertEqual('/api/login');
      expect(http.calls[1]).assertEqual('/api/v3/userinfo');
      expect(http.loginForm['user']).assertEqual('demo_user'); // 账号去空格，密码不动
      expect(http.loginForm['pass']).assertEqual('demo_pass');
      expect(cookies.persistCalls).assertEqual(1); // 登录后主动落盘
    });

    it('loginNetworkFailureMapsToNetwork', 0, async () => {
      http.throwOnLogin = true;
      const err: AuthFailure | null = await captureFailure(async (): Promise<void> => {
        await repo.login('user', 'pass');
      });
      expect(err !== null).assertTrue();
      assertFailureKind(err, AuthErrorKind.NETWORK);
    });

    // ==================== 会话校验 ====================

    it('fetchUserReturnsNullWhenAnonymous', 0, async () => {
      http.userInfoResponse = USERINFO_ANON;
      const account: AuthUser | null = await repo.fetchUser();
      expect(account === null).assertTrue();
      expect(http.calls[0]).assertEqual('/api/v3/userinfo');
    });

    it('fetchUserRejectsUnknownStatus', 0, async () => {
      http.userInfoResponse = '{"status":"something_else"}';
      const err: AuthFailure | null = await captureFailure(async (): Promise<void> => {
        await repo.fetchUser();
      });
      expect(err !== null).assertTrue();
      assertFailureKind(err, AuthErrorKind.PROTOCOL);
    });

    it('fetchUserRejectsMissingUserInfo', 0, async () => {
      http.userInfoResponse = '{"status":"ok"}';
      const err: AuthFailure | null = await captureFailure(async (): Promise<void> => {
        await repo.fetchUser();
      });
      expect(err !== null).assertTrue();
      assertFailureKind(err, AuthErrorKind.PROTOCOL);
    });

    it('fetchUserMapsNetworkErrorToNetwork', 0, async () => {
      http.throwOnUserInfo = true;
      const err: AuthFailure | null = await captureFailure(async (): Promise<void> => {
        await repo.fetchUser();
      });
      expect(err !== null).assertTrue();
      assertFailureKind(err, AuthErrorKind.NETWORK);
      expect(cookies.clearCalls).assertEqual(0); // 网络异常不得清会话
    });

    it('fetchUserMapsParseErrorToProtocol', 0, async () => {
      http.throwParseErrorOnUserInfo = true;
      const err: AuthFailure | null = await captureFailure(async (): Promise<void> => {
        await repo.fetchUser();
      });
      expect(err !== null).assertTrue();
      assertFailureKind(err, AuthErrorKind.PROTOCOL);
    });

    it('fetchUserSupportsAlternateFieldNames', 0, async () => {
      http.userInfoResponse = '{"status":"ok","userinfo":{"uid":42,"nickname":"暱稱"}}';
      const account: AuthUser | null = await repo.fetchUser();
      expect(account !== null).assertTrue();
      if (account !== null) {
        expect(account.uid).assertEqual('42');
        expect(account.name).assertEqual('暱稱');
      }
    });

    // ==================== 退出 ====================

    it('logoutClearsCookiesEvenIfServerRequestFails', 0, async () => {
      http.throwOnLogout = true;
      const ok: boolean = await repo.logout();
      expect(ok).assertTrue();
      expect(http.calls[0]).assertEqual('/api/logout');
      expect(cookies.clearCalls).assertEqual(1);
      expect(cookies.persistCalls).assertEqual(1);
      expect(cookies.count).assertEqual(0);
    });

    it('logoutReturnsFalseWhenLocalCleanupFails', 0, async () => {
      cookies.throwOnClear = true;
      const ok: boolean = await repo.logout();
      expect(ok).assertFalse();
      expect(cookies.persistCalls).assertEqual(0); // 清理失败不再落盘
    });

    it('hasCookiesReflectsRepositoryCount', 0, async () => {
      cookies.count = 2;
      expect(await repo.hasCookies()).assertTrue();
      cookies.count = 0;
      expect(await repo.hasCookies()).assertFalse();
    });

    it('logoutWithAnonymousServerResponseStillClearsLocally', 0, async () => {
      // 真实抓包：匿名 POST /api/logout → 200 {"status":"login"}，无 Set-Cookie
      http.logoutResponse = LOGOUT_ANON;
      const ok: boolean = await repo.logout();
      expect(ok).assertTrue();
      expect(cookies.clearCalls).assertEqual(1);
      expect(cookies.count).assertEqual(0);
    });
  });
}
