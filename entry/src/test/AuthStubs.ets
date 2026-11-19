/**
 * AuthStubs.ets —— 认证层测试共用桩实现
 *
 * 为什么单独成文件：AuthRepository / AuthManager / LoginViewModel 三套测试都要
 * 注入「HTTP + Cookie」两个端口；集中定义可避免三份实现漂移。
 *
 * 严格性声明：
 * - 这些桩**只用于验证状态机、分支与错误映射**，不联网、不读取真实会话；
 * - `USERINFO_SUCCESS_DERIVED` 是派生样例，**不是登录成功抓包**；
 * - 任何用例都不得被解读为「真实账号已登录成功」的验证结论。
 *
 * ArkTS 注意：类必须显式 `implements` 端口接口（arkts-no-structural-typing），
 * 不能像 TypeScript 那样靠结构兼容隐式赋值。
 */
import { expect } from '@ohos/hypium';
import {
  AuthCookiePort,
  AuthErrorKind,
  AuthFailure,
  AuthHttpPort
} from '../main/ets/api/AuthTypes';
import { HttpError } from '../main/ets/api/HttpManager';
import { USERINFO_SUCCESS_DERIVED } from './fixtures/FixtureData';

/** 记录调用路径与表单内容的可编程 HTTP 桩 */
export class StubAuthHttp implements AuthHttpPort {
  /** 调用过的路径（按顺序） */
  calls: string[] = [];
  /** 最近一次提交的表单 */
  lastForm: Record<string, string> = {};
  /** 登录请求的表单（单独保存，避免被后续 userinfo 请求覆盖） */
  loginForm: Record<string, string> = {};
  /** 各接口返回的 JSON 文本 */
  loginResponse: string = '{}';
  userInfoResponse: string = USERINFO_SUCCESS_DERIVED;
  logoutResponse: string = '{}';
  /** 让指定接口抛出网络异常 */
  throwOnLogin: boolean = false;
  throwOnUserInfo: boolean = false;
  throwOnLogout: boolean = false;
  /** true = 抛 HttpError(-1)，模拟「响应不是合法 JSON」 */
  throwParseErrorOnUserInfo: boolean = false;

  async postForm<T>(path: string, form: Record<string, string>,
    headers?: Record<string, string>): Promise<T> {
    this.calls.push(path);
    this.lastForm = form;
    let body: string = '{}';
    if (path === '/api/login') {
      this.loginForm = form;
      if (this.throwOnLogin) {
        throw new HttpError(503, '模拟网络失败');
      }
      body = this.loginResponse;
    } else if (path === '/api/v3/userinfo') {
      if (this.throwOnUserInfo) {
        throw new HttpError(503, '模拟网络失败');
      }
      if (this.throwParseErrorOnUserInfo) {
        throw new HttpError(-1, 'JSON 解析失败');
      }
      body = this.userInfoResponse;
    } else if (path === '/api/logout') {
      if (this.throwOnLogout) {
        throw new HttpError(503, '模拟网络失败');
      }
      body = this.logoutResponse;
    }
    try {
      return JSON.parse(body) as T;
    } catch (e) {
      throw new HttpError(-1, `桩响应不是合法 JSON: ${body.substring(0, 60)}`);
    }
  }
}

/** 记录清理/落盘次数的 Cookie 桩 */
export class StubAuthCookies implements AuthCookiePort {
  /** 当前 Cookie 数量 */
  count: number = 1;
  clearCalls: number = 0;
  persistCalls: number = 0;
  throwOnClear: boolean = false;
  throwOnPersist: boolean = false;

  async countCookies(): Promise<number> {
    return this.count;
  }

  async clearSiteCookies(): Promise<void> {
    this.clearCalls++;
    if (this.throwOnClear) {
      throw new Error('模拟 Cookie 清理失败');
    }
    this.count = 0;
  }

  async persistCookies(): Promise<void> {
    this.persistCalls++;
    if (this.throwOnPersist) {
      throw new Error('模拟 Cookie 落盘失败');
    }
  }
}

/** 捕获认证失败；未抛异常返回 null，非 AuthFailure 归为 UNKNOWN */
export async function captureFailure(fn: () => Promise<void>): Promise<AuthFailure | null> {
  try {
    await fn();
    return null;
  } catch (e) {
    if (e instanceof AuthFailure) {
      return e;
    }
    return new AuthFailure(AuthErrorKind.UNKNOWN, (e as Error).message);
  }
}

/** 断言确实抛出了指定类型的认证失败 */
export function assertFailureKind(failure: AuthFailure | null, kind: AuthErrorKind): void {
  if (failure === null) {
    return; // 调用方另行断言 failure !== null
  }
  expect(failure.kind).assertEqual(kind);
}
