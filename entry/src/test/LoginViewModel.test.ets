/**
 * LoginViewModel.test.ets —— 登录页视图模型单元测试（桩注入，不联网）
 *
 * 覆盖：本地校验、密码可见性切换、防重复提交、成功/失败后的密码出栈、
 * 错误原因透传、页面销毁后的 disposed 守卫。
 *
 * 安全断言：无论成功或失败，`submit()` 结束后 `password` 必须为空，
 * 且密码不得出现在任何持久化结构或日志中（本层不写日志/不写 Preferences）。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { OpenLinkOptions, Want } from '@kit.AbilityKit';
import { AuthRepository } from '../main/ets/api/AuthRepository';
import { AuthErrorKind } from '../main/ets/api/AuthTypes';
import { AuthManager } from '../main/ets/utils/AuthManager';
import {
  ExternalLinkContext,
  NOY_REGISTER_URL,
  buildRegisterUrl,
  isSafeHttpUrl,
  openExternalRegisterUrl
} from '../main/ets/utils/ExternalLink';
import { LoginViewModel } from '../main/ets/viewmodel/LoginViewModel';
import { LOGIN_INVALID_CREDENTIALS } from './fixtures/FixtureData';
import { StubAuthCookies, StubAuthHttp } from './AuthStubs';

class StubExternalLinkContext implements ExternalLinkContext {
  failOpenLink: boolean = false;
  failStartAbility: boolean = false;
  openLinkCalls: string[] = [];
  openLinkAppLinkingFlags: boolean[] = [];
  startAbilityUris: string[] = [];

  async openLink(link: string, options?: OpenLinkOptions): Promise<void> {
    this.openLinkCalls.push(link);
    this.openLinkAppLinkingFlags.push(options?.appLinkingOnly === true);
    if (this.failOpenLink) {
      throw new Error('openLink unavailable');
    }
  }

  async startAbility(want: Want): Promise<void> {
    this.startAbilityUris.push(want.uri ?? '');
    if (this.failStartAbility) {
      throw new Error('startAbility failed');
    }
  }
}

export default function loginViewModelTest() {
  describe('LoginViewModel', () => {
    let http: StubAuthHttp = new StubAuthHttp();
    let vm: LoginViewModel = new LoginViewModel(new AuthManager(new AuthRepository(http, new StubAuthCookies())));

    beforeEach(() => {
      http = new StubAuthHttp();
      const auth: AuthManager = new AuthManager(new AuthRepository(http, new StubAuthCookies()));
      vm = new LoginViewModel(auth);
    });

    it('validateRequiresUsername', 0, () => {
      vm.password = 'secret';
      expect(vm.validate()).assertFalse();
      expect(vm.validationError).assertEqual('请输入账号');
    });

    it('validateRequiresPassword', 0, () => {
      vm.username = 'demo';
      expect(vm.validate()).assertFalse();
      expect(vm.validationError).assertEqual('请输入密码');
    });

    it('validateClearsErrorWhenValid', 0, () => {
      vm.username = 'demo';
      vm.password = 'secret';
      expect(vm.validate()).assertTrue();
      expect(vm.validationError).assertEqual('');
    });

    it('togglePasswordVisible', 0, () => {
      expect(vm.isPasswordVisible).assertFalse();
      vm.togglePasswordVisible();
      expect(vm.isPasswordVisible).assertTrue();
      vm.togglePasswordVisible();
      expect(vm.isPasswordVisible).assertFalse();
    });

    it('submitRejectsInvalidFormWithoutRequest', 0, async () => {
      vm.password = 'secret';
      const ok: boolean = await vm.submit();
      expect(ok).assertFalse();
      expect(vm.validationError).assertEqual('请输入账号');
      expect(http.calls.length).assertEqual(0);
      expect(vm.isSubmitting).assertFalse();
    });

    it('submitSuccessClearsPasswordAndUsername', 0, async () => {
      vm.username = 'demo';
      vm.password = 'secret';
      const ok: boolean = await vm.submit();
      expect(ok).assertTrue();
      expect(vm.password).assertEqual('');
      expect(vm.username).assertEqual('');
      expect(vm.isSubmitting).assertFalse();
      expect(vm.errorMessage).assertEqual('');
      expect(http.calls.length).assertEqual(2); // login + userinfo
    });

    it('submitFailureMapsErrorAndStillClearsPassword', 0, async () => {
      http.loginResponse = LOGIN_INVALID_CREDENTIALS;
      vm.username = 'demo';
      vm.password = 'secret';
      const ok: boolean = await vm.submit();
      expect(ok).assertFalse();
      expect(vm.password).assertEqual('');
      expect(vm.username).assertEqual('demo'); // 失败保留账号，便于用户改密码
      expect(vm.isSubmitting).assertFalse();
      expect(vm.errorKind === AuthErrorKind.INVALID_CREDENTIALS).assertTrue();
      expect(vm.errorMessage).assertEqual('账号或密码错误');
    });

    it('concurrentSubmitIsGuarded', 0, async () => {
      vm.username = 'demo';
      vm.password = 'secret';
      const first: Promise<boolean> = vm.submit();
      const second: boolean = await vm.submit();
      expect(second).assertFalse();
      const firstResult: boolean = await first;
      expect(firstResult).assertTrue();
      expect(http.calls.length).assertEqual(2); // 只发了一组请求
    });

    it('disposeClearsPasswordAndBlocksSubmit', 0, async () => {
      vm.username = 'demo';
      vm.password = 'secret';
      vm.dispose();
      expect(vm.password).assertEqual('');
      expect(vm.isSubmitting).assertFalse();
      const ok: boolean = await vm.submit();
      expect(ok).assertFalse();
      expect(http.calls.length).assertEqual(0);
    });
  });

  describe('ExternalLink_Register', () => {
    it('officialRegisterUrlIsValidHttps', 0, () => {
      expect(NOY_REGISTER_URL.startsWith('https://')).assertTrue();
      expect(NOY_REGISTER_URL.endsWith('/register')).assertTrue();
      expect(isSafeHttpUrl(NOY_REGISTER_URL)).assertTrue();
      expect(buildRegisterUrl('https://noymanga.com/')).assertEqual('https://noymanga.com/register');
    });

    it('openExternalRegisterUrlUsesOpenLinkFirst', 0, async () => {
      const ctx: StubExternalLinkContext = new StubExternalLinkContext();
      const ok: boolean = await openExternalRegisterUrl(ctx);
      expect(ok).assertTrue();
      expect(ctx.openLinkCalls.length).assertEqual(1);
      expect(ctx.openLinkCalls[0]).assertEqual(NOY_REGISTER_URL);
      expect(ctx.openLinkAppLinkingFlags[0]).assertFalse();
      expect(ctx.startAbilityUris.length).assertEqual(0);
    });

    it('openExternalRegisterUrlFallsBackToStartAbility', 0, async () => {
      const ctx: StubExternalLinkContext = new StubExternalLinkContext();
      ctx.failOpenLink = true;
      const ok: boolean = await openExternalRegisterUrl(ctx);
      expect(ok).assertTrue();
      expect(ctx.openLinkCalls.length).assertEqual(1);
      expect(ctx.startAbilityUris.length).assertEqual(1);
      expect(ctx.startAbilityUris[0]).assertEqual(NOY_REGISTER_URL);
    });

    it('openExternalRegisterUrlHandlesFailureAndInvalidUrl', 0, async () => {
      const ctx: StubExternalLinkContext = new StubExternalLinkContext();
      ctx.failOpenLink = true;
      ctx.failStartAbility = true;
      expect(await openExternalRegisterUrl(ctx)).assertFalse();
      expect(await openExternalRegisterUrl(undefined)).assertFalse();
      expect(await openExternalRegisterUrl(ctx, 'javascript:alert(1)')).assertFalse();
    });
  });
}
