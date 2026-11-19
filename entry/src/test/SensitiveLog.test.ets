/**
 * SensitiveLog.test.ets —— I-000005 认证诊断生产路径收敛：敏感信息不出现在生产日志/落盘
 *
 * 覆盖（全部宿主侧纯逻辑，不联网、不依赖 rcp）：
 * 1. 诊断门控：HttpManager.diagnosticEnabled() 与 BuildInfo.IS_DEBUG_BUILD 一致
 *    （唯一事实来源）；release 构建下 probe 直接返回 disabled，不执行、不输出；
 * 2. LogSanitizer 兜底：Cookie 名/值、指纹格式（fp=）、Authorization/Bearer、token、
 *    密码在任何拼接格式下都被脱敏；URL/路径脱敏后不残留查询值；
 * 3. 落盘侧 mock 捕获：DiagnosticLogManager 写入即脱敏（snapshotForTest 断言
 *    不含敏感值）；NetworkLogManager 路径在持久化前已去查询值；
 * 4. 生产认证路径（会话被拒）：桩驱动 AuthManager.restoreSession()，捕获的诊断
 *    日志不含敏感字段，且 release 构建不产生“显式携带 Cookie”探针日志。
 */
import { describe, it, expect } from '@ohos/hypium';
import { AuthManager } from '../main/ets/utils/AuthManager';
import { AuthRepository } from '../main/ets/api/AuthRepository';
import { AuthStatus } from '../main/ets/api/AuthTypes';
import BuildProfile from 'BuildProfile';
import { HttpManager } from '../main/ets/api/HttpManager';
import { IS_DEBUG_BUILD, resolveIsDebugBuild } from '../main/ets/utils/BuildInfo';
import { MASK, sanitizePath, sanitizeText, sanitizeUrl } from '../main/ets/utils/LogSanitizer';
import { DiagnosticLogManager, LOG_LEVEL_WARN } from '../main/ets/utils/DiagnosticLogManager';
import { NetworkLogManager } from '../main/ets/utils/NetworkLogManager';
import { USERINFO_ANON } from './fixtures/FixtureData';
import { StubAuthCookies, StubAuthHttp } from './AuthStubs';

export default function sensitiveLogTest() {
  describe('SensitiveLog_BuildGate', () => {
    it('diagnostic_gate_matches_build_info', 0, () => {
      // 门控唯一事实来源：HttpManager 与 BuildInfo 必须一致，不允许两处漂移
      expect(HttpManager.diagnosticEnabled()).assertEqual(IS_DEBUG_BUILD);
    });

    it('release_build_probe_is_disabled', 0, async () => {
      // release 构建下诊断探针不得执行（入口即返回 disabled，不触碰 CookieRepository）
      const releaseStatus: string = await HttpManager.getInstance().probeUserinfoWithExplicitCookie(false);
      expect(releaseStatus).assertEqual('disabled');
      if (!IS_DEBUG_BUILD) {
        const status: string = await HttpManager.getInstance().probeUserinfoWithExplicitCookie();
        expect(status).assertEqual('disabled');
      }
    });

    it('release_build_diagnostic_flag_is_false', 0, () => {
      // I-000012：IS_DEBUG_BUILD 由 BuildProfile 动态派生，release 模式下严格为 false
      expect(resolveIsDebugBuild('release', false)).assertFalse();
      expect(resolveIsDebugBuild('release', true)).assertFalse();
      expect(resolveIsDebugBuild('debug', false)).assertFalse();
      expect(resolveIsDebugBuild('debug', true)).assertTrue();
      expect(IS_DEBUG_BUILD).assertEqual(
        resolveIsDebugBuild(BuildProfile.BUILD_MODE_NAME, BuildProfile.DEBUG)
      );
    });
  });

  describe('SensitiveLog_Sanitizer', () => {
    it('masks_cookie_name_value_and_fingerprint', 0, () => {
      const masked: string = sanitizeText('Cookie: SESSION=abc123; NOY_SESSION=xyz456 fp=deadbeef');
      expect(masked.indexOf('abc123')).assertEqual(-1);
      expect(masked.indexOf('xyz456')).assertEqual(-1);
      expect(masked.indexOf('deadbeef')).assertEqual(-1);
      // 键名保留便于排查，值一律打码
      expect(masked.indexOf('fp=') >= 0).assertTrue();
      expect(masked.indexOf(MASK) >= 0).assertTrue();
    });

    it('masks_authorization_token_password', 0, () => {
      const masked: string = sanitizeText('Authorization: Bearer abcdefgh token=xyz password=hunter2');
      expect(masked.indexOf('abcdefgh')).assertEqual(-1);
      expect(masked.indexOf('xyz')).assertEqual(-1);
      expect(masked.indexOf('hunter2')).assertEqual(-1);
    });

    it('url_and_path_never_keep_query_values', 0, () => {
      const url: string = 'https://noymanga.com/api/v3/userinfo?token=secret123';
      expect(sanitizePath(url).indexOf('secret123')).assertEqual(-1);
      expect(sanitizePath(url).indexOf('token=')).assertEqual(-1);
      expect(sanitizeUrl(url).indexOf('secret123')).assertEqual(-1);
      expect(sanitizeUrl(url).indexOf('token=') >= 0).assertTrue(); // 键名保留，值打码
    });
  });

  describe('SensitiveLog_PersistGate', () => {
    it('diagnostic_persist_contains_no_secrets', 0, () => {
      const manager: DiagnosticLogManager = DiagnosticLogManager.getInstance();
      manager.injectForTest([]);
      manager.record(LOG_LEVEL_WARN, 'Auth',
        '登录失败 Cookie: SESSION=abc123 token=xyz password=hunter2 fp=deadbeef');
      const entries = manager.snapshotForTest();
      expect(entries.length).assertEqual(1);
      const message: string = entries[0].message;
      expect(message.indexOf('abc123')).assertEqual(-1);
      expect(message.indexOf('xyz')).assertEqual(-1);
      expect(message.indexOf('hunter2')).assertEqual(-1);
      expect(message.indexOf('deadbeef')).assertEqual(-1);
    });

    it('network_persist_never_contains_query_values', 0, () => {
      const manager: NetworkLogManager = NetworkLogManager.getInstance();
      manager.injectForTest([]);
      const trace = manager.begin('POST',
        'https://noymanga.com/api/v3/userinfo?token=secret123');
      trace.statusCode = 200;
      manager.end(trace);
      const entries = manager.snapshotForTest();
      expect(entries.length).assertEqual(1);
      expect(entries[0].path.indexOf('secret123')).assertEqual(-1);
      expect(entries[0].path.indexOf('token=')).assertEqual(-1);
    });
  });

  describe('SensitiveLog_ProductionAuthPath', () => {
    it('rejected_session_leaks_no_secrets_and_no_probe_log', 0, async () => {
      const manager: DiagnosticLogManager = DiagnosticLogManager.getInstance();
      manager.injectForTest([]);
      const http: StubAuthHttp = new StubAuthHttp();
      const cookies: StubAuthCookies = new StubAuthCookies();
      const auth: AuthManager = new AuthManager(new AuthRepository(http, cookies));
      http.userInfoResponse = USERINFO_ANON;
      await auth.restoreSession();
      expect(auth.status).assertEqual(AuthStatus.UNAUTHENTICATED);
      const entries = manager.snapshotForTest();
      for (let i = 0; i < entries.length; i++) {
        const message: string = entries[i].message;
        expect(message.indexOf('abc123')).assertEqual(-1);
        expect(message.indexOf('token=')).assertEqual(-1);
        expect(message.indexOf('password')).assertEqual(-1);
        expect(message.indexOf('fp=')).assertEqual(-1);
      }
      // 任何构建下都不得产生“显式携带 Cookie”探针诊断日志：
      // release 被 diagnosticEnabled() 整个门控；debug 测试环境探针抛错只记“探针失败”。
      let probeLogCount: number = 0;
      for (let i = 0; i < entries.length; i++) {
        if (entries[i].message.indexOf('显式携带 Cookie') >= 0) {
          probeLogCount++;
        }
      }
      expect(probeLogCount).assertEqual(0);
    });
  });
}
