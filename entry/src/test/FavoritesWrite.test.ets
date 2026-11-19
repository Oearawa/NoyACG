/**
 * FavoritesWrite.test.ets —— I-000002 收藏写入与状态同步 测试
 *
 * 覆盖（任务书要求：toggle 参数构造 / 失败回滚 / 防抖 / 状态同步）：
 * - 协议层：buildFavoriteToggleForm 参数名为 bid、值正确；parseFavoriteToggle 对
 *   ok/login/error 的处理（login 抛 AuthRequiredError，非 ok 抛 ProtocolError）；
 * - Repository：toggleFavorite 透传端口；
 * - ViewModel：toggle 参数构造（bid）、成功 /get 校准、网络失败回滚、
 *   登录失效提示、回滚重取失败保持操作前状态、重复点击防抖、重新进入校准。
 *
 * 全部使用可编程桩（StubAccountFavPort / StubDetailSource / InMemoryReadingStore），
 * 不联网、不触达真实服务端；契约依据：PHASE14J2_REPORT.md §3（POST /api/v4/favorites/toggle 表单 { bid }）。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  buildFavoriteToggleForm,
  parseFavoriteToggle,
  RawFavoriteToggleEnvelope,
  buildFavoriteForm,
  parseAccountFavoritesJson
} from '../main/ets/source/NoyAcgProtocol';
import { AccountFavoriteRepository } from '../main/ets/api/AccountFavoriteRepository';
import { ComicDetailViewModel, DetailState } from '../main/ets/viewmodel/ComicDetailViewModel';
import { ComicDetail } from '../main/ets/model/ComicDetail';
import { HttpError } from '../main/ets/api/HttpManager';
import { AuthRequiredError, ProtocolError } from '../main/ets/api/ApiErrors';
import { PageInfo } from '../main/ets/model/PageInfo';
import { Comic } from '../main/ets/model/Comic';
import { FavoriteClass } from '../main/ets/model/FavoriteClass';
import { AccountFavoritePort } from '../main/ets/source/AccountFavoritePort';
import { InMemoryReadingStore, StubAccountFavPort, StubDetailSource } from './DetailStubs';
import { parseBookDetailJson } from '../main/ets/source/NoyAcgProtocol';
import { BOOK_DETAIL_FULL_DERIVED } from './fixtures/FixtureData';

function catchSync(fn: () => void): Error | null {
  try {
    fn();
    return null;
  } catch (e) {
    return e as Error;
  }
}

/** 极简端口桩：验证 Repository 透传 + 参数 */ 
class RecordingPort implements AccountFavoritePort {
  toggleArgs: string[] = [];
  getCalls: number = 0;
  async fetchAccountFavorites(page: number, classId: string): Promise<PageInfo<Comic>> {
    this.getCalls++;
    return new PageInfo<Comic>(page, 0, [], false);
  }
  async fetchFavoriteClasses(): Promise<FavoriteClass[]> {
    return [];
  }
  async toggleFavorite(bid: string): Promise<void> {
    this.toggleArgs.push(bid);
  }
}

export default function favoritesWriteTest() {
  describe('FavoritesWrite', () => {
    // ==================== 协议层：toggle 参数构造与解析 ====================
    it('toggleFormUsesBidParam', 0, () => {
      const form: Record<string, string> = buildFavoriteToggleForm(' 900201 ');
      expect(form['bid']).assertEqual('900201'); // 参数名必须是 bid（契约证据）
      expect(Object.keys(form).length).assertEqual(1); // 只传 bid，不夹带其它字段
    });

    it('toggleParseAcceptsOk', 0, () => {
      const envelope: RawFavoriteToggleEnvelope = { status: 'ok' };
      parseFavoriteToggle(envelope); // 不抛
    });

    it('toggleParseLoginThrowsAuthRequired', 0, () => {
      const err: Error | null = catchSync(() => {
        parseFavoriteToggle({ status: 'login' });
      });
      expect(err instanceof AuthRequiredError).assertTrue();
    });

    it('toggleParseErrorThrowsProtocol', 0, () => {
      const err: Error | null = catchSync(() => {
        parseFavoriteToggle({ status: 'error' });
      });
      expect(err instanceof ProtocolError).assertTrue();
    });

    it('toggleParseEmptyThrowsProtocol', 0, () => {
      const err: Error | null = catchSync(() => {
        parseFavoriteToggle(undefined);
      });
      expect(err instanceof ProtocolError).assertTrue();
    });

    // ==================== Repository：透传 ====================
    it('repositoryDelegatesToggleToPort', 0, async () => {
      const port: RecordingPort = new RecordingPort();
      const repo: AccountFavoriteRepository = new AccountFavoriteRepository(port);
      await repo.toggleFavorite('900201');
      expect(port.toggleArgs.length).assertEqual(1);
      expect(port.toggleArgs[0]).assertEqual('900201');
    });

    // ==================== ViewModel：写路径 ====================
    it('vmToggleSendsBid', 0, async () => {
      const src: StubDetailSource = new StubDetailSource();
      src.detail = parseBookDetailJson(BOOK_DETAIL_FULL_DERIVED, '900201');
      const store: InMemoryReadingStore = new InMemoryReadingStore();
      const fav: StubAccountFavPort = new StubAccountFavPort();
      const vm: ComicDetailViewModel = new ComicDetailViewModel(src, store, undefined, fav);
      await vm.loadDetail('900201');
      await vm.toggleFavorite();
      expect(fav.toggleCalls.length).assertEqual(1);
      expect(fav.toggleCalls[0]).assertEqual('900201');
    });

    it('vmToggleSuccessSyncsFromGet', 0, async () => {
      const src: StubDetailSource = new StubDetailSource();
      src.detail = parseBookDetailJson(BOOK_DETAIL_FULL_DERIVED, '900201');
      const store: InMemoryReadingStore = new InMemoryReadingStore();
      const fav: StubAccountFavPort = new StubAccountFavPort();
      // 详情 F=false → 初始 false；toggle 成功后 /get 返回已收藏 → true
      fav.favoriteIds = ['900201'];
      const vm: ComicDetailViewModel = new ComicDetailViewModel(src, store, undefined, fav);
      await vm.loadDetail('900201');
      expect(vm.isFavorite).assertFalse();
      await vm.toggleFavorite();
      expect(vm.isFavorite).assertTrue();
      // 详情 F=false 已知 → loadDetail 不走 /get；仅 toggle 成功后校准 1 次
      expect(fav.getCalls).assertEqual(1);
    });

    it('vmToggleNetworkFailureRollsBack', 0, async () => {
      const src: StubDetailSource = new StubDetailSource();
      src.detail = parseBookDetailJson(BOOK_DETAIL_FULL_DERIVED, '900201');
      const store: InMemoryReadingStore = new InMemoryReadingStore();
      const fav: StubAccountFavPort = new StubAccountFavPort();
      fav.toggleError = new HttpError(-1, '网络失败');
      const vm: ComicDetailViewModel = new ComicDetailViewModel(src, store, undefined, fav);
      await vm.loadDetail('900201');
      await vm.toggleFavorite();
      expect(vm.isFavorite).assertFalse(); // 回滚到操作前
      expect(vm.favoriteNotice.indexOf('失败') >= 0).assertTrue();
    });

    it('vmToggleAuthFailureNoticesLogin', 0, async () => {
      const src: StubDetailSource = new StubDetailSource();
      src.detail = parseBookDetailJson(BOOK_DETAIL_FULL_DERIVED, '900201');
      const store: InMemoryReadingStore = new InMemoryReadingStore();
      const fav: StubAccountFavPort = new StubAccountFavPort();
      fav.toggleError = new AuthRequiredError('登录已失效');
      const vm: ComicDetailViewModel = new ComicDetailViewModel(src, store, undefined, fav);
      await vm.loadDetail('900201');
      await vm.toggleFavorite();
      expect(vm.isFavorite).assertFalse();
      expect(vm.favoriteNotice.indexOf('登录') >= 0).assertTrue();
    });

    it('vmToggleDebouncesDuplicateClicks', 0, async () => {
      const src: StubDetailSource = new StubDetailSource();
      src.detail = parseBookDetailJson(BOOK_DETAIL_FULL_DERIVED, '900201');
      const store: InMemoryReadingStore = new InMemoryReadingStore();
      const fav: StubAccountFavPort = new StubAccountFavPort();
      fav.toggleDelayMs = 60;
      const vm: ComicDetailViewModel = new ComicDetailViewModel(src, store, undefined, fav);
      await vm.loadDetail('900201');
      const p1: Promise<void> = vm.toggleFavorite();
      const p2: Promise<void> = vm.toggleFavorite();
      const p3: Promise<void> = vm.toggleFavorite();
      await Promise.all([p1, p2, p3]);
      expect(fav.toggleCalls.length).assertEqual(1); // 在途期间忽略后续点击
    });

    it('vmReentrySyncsFromServer', 0, async () => {
      const src: StubDetailSource = new StubDetailSource();
      src.detail = parseBookDetailJson(BOOK_DETAIL_FULL_DERIVED, '900201');
      const store: InMemoryReadingStore = new InMemoryReadingStore();
      const fav: StubAccountFavPort = new StubAccountFavPort();
      const vm: ComicDetailViewModel = new ComicDetailViewModel(src, store, undefined, fav);
      await vm.loadDetail('900201');
      expect(vm.isFavorite).assertFalse();
      // 服务端此后已收藏
      fav.favoriteIds = ['900201'];
      await vm.resyncFavoriteOnReentry();
      expect(vm.isFavorite).assertTrue();
    });

    it('vmRollbackRefetchFailureKeepsPrevious', 0, async () => {
      const src: StubDetailSource = new StubDetailSource();
      src.detail = parseBookDetailJson(BOOK_DETAIL_FULL_DERIVED, '900201');
      const store: InMemoryReadingStore = new InMemoryReadingStore();
      const fav: StubAccountFavPort = new StubAccountFavPort();
      fav.favoriteIds = ['900201']; // 服务端已收藏
      const vm: ComicDetailViewModel = new ComicDetailViewModel(src, store, undefined, fav);
      await vm.loadDetail('900201');
      await vm.resyncFavoriteOnReentry();
      expect(vm.isFavorite).assertTrue();
      fav.toggleError = new HttpError(-1, '写失败');
      fav.getError = new HttpError(-1, '校准失败');
      await vm.toggleFavorite();
      expect(vm.isFavorite).assertTrue(); // /get 失败 → 回滚到操作前 true
    });
  });
}
