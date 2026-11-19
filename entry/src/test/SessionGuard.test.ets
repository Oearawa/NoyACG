/**
 * SessionGuard.test.ets —— Phase 11 Step 3 认证失效联动回归测试
 *
 * 审计对象：`api/ApiErrors.ets::notifyIfSessionExpired`、`NoyAcgSource` 四处 `reportAuthFailure`
 * 调用点、`AuthManager.notifySessionExpired()`、`HomeViewModel.needsLogin`。
 *
 * 核心不变量（任务书 §三）：
 * 1. 只有真实的认证失效响应（status=login → AuthRequiredError）才触发全局状态降级；
 * 2. 普通 JSON 解析错误 / ProtocolError 不得误判；
 * 3. 5xx 服务端错误不得导致退出登录；
 * 4. 网络超时不得删除 Cookie（本测试验证不触发通知，且 AuthManager 状态保持）；
 * 5. 认证状态改变后 UI 可观测（needsLogin / status）。
 *
 * 说明：本地单测不触网、不碰真实 CookieRepository；所有「已登录」都是桩驱动状态机。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { HttpError } from '../main/ets/api/HttpManager';
import {
  AuthRequiredError,
  ProtocolError,
  notifyIfSessionExpired
} from '../main/ets/api/ApiErrors';
import { AuthRepository } from '../main/ets/api/AuthRepository';
import { AuthStatus } from '../main/ets/api/AuthTypes';
import { AuthManager } from '../main/ets/utils/AuthManager';
import { HomeViewModel } from '../main/ets/viewmodel/HomeViewModel';
import { IComicSource } from '../main/ets/source/IComicSource';
import { Comic } from '../main/ets/model/Comic';
import { ComicDetail } from '../main/ets/model/ComicDetail';
import { PageInfo } from '../main/ets/model/PageInfo';
import { HomeFeed } from '../main/ets/model/HomeFeed';
import { AdItem } from '../main/ets/model/AdItem';
import { CommentPage } from '../main/ets/model/BookComment';
import { StubAuthCookies, StubAuthHttp } from './AuthStubs';

/** 可编程首页源桩：按预设异常或空结果响应 */
class StubHomeSource implements IComicSource {
  readonly sourceId: string = 'stub-home';
  readonly sourceName: string = 'StubHome';
  readonly baseUrl: string = 'https://stub.local';
  /** ArkTS 不支持把子类结构赋给 Error 抽象基类，这里用具体的 HttpError 基类 */
  error: HttpError | null = null;
  calls: number = 0;

  async getHomeList(page: number, sort?: string, finished?: string): Promise<PageInfo<Comic>> {
    this.calls++;
    if (this.error !== null) {
      throw this.error;
    }
    return new PageInfo<Comic>(page, 1, [], false);
  }

  async search(keyword: string, page: number): Promise<PageInfo<Comic>> {
    return new PageInfo<Comic>(page, 1, [], false);
  }

  async getComicDetail(id: string): Promise<ComicDetail> {
    return new ComicDetail();
  }

  async getChapterImages(bookId: string, chapterId: string): Promise<string[]> {
    return [];
  }

  async getHomeFeed(adultLevel?: string): Promise<HomeFeed> {
    return new HomeFeed();
  }

  async getAds(adultLevel?: string): Promise<AdItem[]> {
    return [];
  }

  async getBookComments(bookId: string, page: number): Promise<CommentPage> {
    return new CommentPage([], page, true);
  }
}

export default function sessionGuardTest() {
  describe('SessionGuard', () => {
    let notifyCalls: number = 0;

    beforeEach(() => {
      notifyCalls = 0;
    });

    const notify = (): void => {
      notifyCalls++;
    };

    it('onlyAuthRequiredErrorTriggersNotification', 0, () => {
      const fired: boolean = notifyIfSessionExpired(new AuthRequiredError(), notify);
      expect(fired).assertTrue();
      expect(notifyCalls).assertEqual(1);
    });

    it('protocolErrorDoesNotNotify', 0, () => {
      const fired: boolean = notifyIfSessionExpired(new ProtocolError('详情响应缺少 book.info'), notify);
      expect(fired).assertFalse();
      expect(notifyCalls).assertEqual(0);
    });

    it('jsonParseErrorDoesNotNotify', 0, () => {
      // HttpError(-1) 是 HttpManager.parseJson 的约定：响应不是合法 JSON
      const fired: boolean = notifyIfSessionExpired(new HttpError(-1, 'JSON 解析失败: <html>'), notify);
      expect(fired).assertFalse();
      expect(notifyCalls).assertEqual(0);
    });

    it('serverErrorDoesNotNotify', 0, () => {
      expect(notifyIfSessionExpired(new HttpError(500, 'Internal Server Error'), notify)).assertFalse();
      expect(notifyIfSessionExpired(new HttpError(502, 'Bad Gateway'), notify)).assertFalse();
      expect(notifyCalls).assertEqual(0);
    });

    it('networkTimeoutDoesNotNotify', 0, () => {
      expect(notifyIfSessionExpired(new HttpError(408, '网络异常: timeout'), notify)).assertFalse();
      expect(notifyIfSessionExpired(new Error('connect ETIMEDOUT'), notify)).assertFalse();
      expect(notifyCalls).assertEqual(0);
    });

    it('sameStatusCodeButDifferentClassDoesNotNotify', 0, () => {
      // 关键：AuthRequiredError.statusCode = -2，但「同码的普通 HttpError/BusinessError」不能误判
      const impostor: HttpError = new HttpError(-2, '某个系统错误码恰好是 -2');
      expect(notifyIfSessionExpired(impostor, notify)).assertFalse();
      expect(notifyCalls).assertEqual(0);
    });

    it('authRequiredDowngradesOnlyAuthenticatedManager', 0, async () => {
      const http: StubAuthHttp = new StubAuthHttp();
      const auth: AuthManager = new AuthManager(new AuthRepository(http, new StubAuthCookies()));
      await auth.login('demo', 'demo_pass');
      expect(auth.status).assertEqual(AuthStatus.AUTHENTICATED);

      const fired: boolean = notifyIfSessionExpired(new AuthRequiredError(),
        () => {
          auth.notifySessionExpired();
        });
      expect(fired).assertTrue();
      expect(auth.status).assertEqual(AuthStatus.UNAUTHENTICATED);
      expect(auth.user === null).assertTrue();
    });

    it('protocolErrorKeepsAuthenticatedManager', 0, async () => {
      const http: StubAuthHttp = new StubAuthHttp();
      const auth: AuthManager = new AuthManager(new AuthRepository(http, new StubAuthCookies()));
      await auth.login('demo', 'demo_pass');

      const fired: boolean = notifyIfSessionExpired(new ProtocolError('章节响应缺少字段'),
        () => {
          auth.notifySessionExpired();
        });
      expect(fired).assertFalse();
      expect(auth.status).assertEqual(AuthStatus.AUTHENTICATED); // 不得误退出
      expect(auth.isAuthenticated).assertTrue();
    });

    it('serverErrorHttpErrorKeepsAuthenticatedManager', 0, async () => {
      const http: StubAuthHttp = new StubAuthHttp();
      const auth: AuthManager = new AuthManager(new AuthRepository(http, new StubAuthCookies()));
      await auth.login('demo', 'demo_pass');
      notifyIfSessionExpired(new HttpError(503, '服务不可用'),
        () => {
          auth.notifySessionExpired();
        });
      expect(auth.status).assertEqual(AuthStatus.AUTHENTICATED);
    });

    // ==================== 首页 UI 状态联动 ====================

    it('homeViewModelSurfacesNeedsLoginOnlyOnAuthRequired', 0, async () => {
      const source: StubHomeSource = new StubHomeSource();
      source.error = new AuthRequiredError();
      const vm: HomeViewModel = new HomeViewModel(source);
      await vm.loadData(true);
      expect(vm.needsLogin).assertTrue();
      expect(source.calls).assertEqual(1);
    });

    it('homeViewModelDoesNotSurfaceLoginOnNetworkError', 0, async () => {
      const source: StubHomeSource = new StubHomeSource();
      source.error = new HttpError(504, '超时');
      const vm: HomeViewModel = new HomeViewModel(source);
      await vm.loadData(true);
      expect(vm.needsLogin).assertFalse();
      expect(vm.errorMessage).assertEqual('超时');
    });

    it('homeViewModelClearsNeedsLoginOnNextSuccess', 0, async () => {
      const source: StubHomeSource = new StubHomeSource();
      source.error = new AuthRequiredError();
      const vm: HomeViewModel = new HomeViewModel(source);
      await vm.loadData(true);
      expect(vm.needsLogin).assertTrue();

      source.error = null;
      await vm.loadData(true);
      expect(vm.needsLogin).assertFalse();
      expect(vm.errorMessage).assertEqual('');
    });
  });
}
