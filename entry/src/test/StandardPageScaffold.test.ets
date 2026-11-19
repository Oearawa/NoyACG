/**
 * StandardPageScaffold.test.ets —— 公共页面骨架、吸顶顶栏不变量、R1 收藏分页校准与 R2 FilterBar 回归测试
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  FILTER_BAR_SCROLL_BREAKPOINT_VP,
  INLINE_HEADER_MIN_WIDTH_VP,
  INLINE_TOP_BAR_HEIGHT_VP,
  SCAFFOLD_BACK_TARGET_VP,
  SCAFFOLD_TOP_BAR_HEIGHT_VP,
  resolveScaffoldState,
  scaffoldBottomInsetVp,
  scaffoldConstrainedWidthVp,
  scaffoldTopBarTotalHeightVp,
  secondaryHeaderTotalHeightVp,
  shouldScrollFilterBar,
  shouldUseInlineSecondaryHeader
} from '../main/ets/utils/StandardScaffoldLayout';
import { mainTabBottomClearanceVp } from '../main/ets/utils/BottomInset';
import { COMPACT_TOP_BAR_HEIGHT_VP, homeTopInsetVp } from '../main/ets/utils/TopBarViewport';
import { parseAccountFavorites } from '../main/ets/source/NoyAcgProtocol';
import { ShelfViewModel } from '../main/ets/viewmodel/ShelfViewModel';
import { AccountFavoriteRepository } from '../main/ets/api/AccountFavoriteRepository';
import { AccountFavoritePort } from '../main/ets/source/AccountFavoritePort';
import { Comic } from '../main/ets/model/Comic';
import { PageInfo } from '../main/ets/model/PageInfo';
import { FavoriteClass } from '../main/ets/model/FavoriteClass';

class StubAccountFavoritePort implements AccountFavoritePort {
  pages: Map<number, PageInfo<Comic>> = new Map<number, PageInfo<Comic>>();

  async fetchAccountFavorites(page: number, _classId?: string): Promise<PageInfo<Comic>> {
    return this.pages.get(page) ?? new PageInfo<Comic>(page, 1, [], false, 0);
  }

  async fetchFavoriteClasses(): Promise<FavoriteClass[]> {
    return [];
  }

  async toggleFavorite(_bid: string): Promise<void> {
  }
}

function makeComics(startId: number, count: number): Comic[] {
  const list: Comic[] = [];
  for (let i = 0; i < count; i++) {
    const id: string = String(startId + i);
    list.push(new Comic(id, `Comic ${id}`, `https://img.noymanga.com/${id}/m1.webp`, 'author', 'tag'));
  }
  return list;
}

export default function standardPageScaffoldTest(): void {
  describe('StickyPortraitTopBar_Invariant', () => {
    it('keepsPortraitTopInsetFixedRegardlessOfScrollState', 0, () => {
      const topAtZero: number = homeTopInsetVp(true, false, 30);
      const topWhileScrolled: number = homeTopInsetVp(true, true, 30);
      expect(topAtZero).assertEqual(30 + COMPACT_TOP_BAR_HEIGHT_VP);
      expect(topWhileScrolled).assertEqual(topAtZero);
      // 横屏模式始终仅保留系统状态栏安全区
      expect(homeTopInsetVp(false, false, 24)).assertEqual(24);
      expect(homeTopInsetVp(false, true, 24)).assertEqual(24);
    });
  });

  describe('StandardScaffoldLayout_StateAndSafeArea', () => {
    it('resolvesFourStatesWithoutLoadingFlashWhenContentExists', 0, () => {
      expect(resolveScaffoldState(true, false, '', true)).assertEqual('loading');
      expect(resolveScaffoldState(true, true, '', false)).assertEqual('content');
      expect(resolveScaffoldState(false, false, 'network error', true)).assertEqual('error');
      expect(resolveScaffoldState(false, true, 'network error', false)).assertEqual('content');
      expect(resolveScaffoldState(false, false, '', true)).assertEqual('empty');
      expect(resolveScaffoldState(false, true, '', false)).assertEqual('content');
    });

    it('enforcesTopBarHeightBackTouchTargetAndBottomInset', 0, () => {
      expect(SCAFFOLD_BACK_TARGET_VP >= 40).assertTrue();
      expect(scaffoldTopBarTotalHeightVp(30)).assertEqual(30 + SCAFFOLD_TOP_BAR_HEIGHT_VP);
      expect(scaffoldTopBarTotalHeightVp(-5)).assertEqual(SCAFFOLD_TOP_BAR_HEIGHT_VP);
      expect(scaffoldBottomInsetVp(24, 56)).assertEqual(80);
      expect(scaffoldConstrainedWidthVp(360, 840)).assertUndefined();
      expect(scaffoldConstrainedWidthVp(1080, 840)).assertEqual(840);
    });
  });

  describe('R1_AccountFavoritesOver20PaginationAndCalibration', () => {
    it('preservesServerTotalCountAndPaginatesOver20ItemsWithoutLossOrDuplicates', 0, async () => {
      const parsed = parseAccountFavorites({
        status: 'ok',
        count: 35,
        data: [
          { Bid: 1, Bookname: 'Book 1' },
          { Bid: 2, Bookname: 'Book 2' }
        ]
      }, 1);
      expect(parsed.totalCount).assertEqual(35);
      expect(parsed.totalPages).assertEqual(2);
      expect(parsed.hasMore).assertTrue();

      const port: StubAccountFavoritePort = new StubAccountFavoritePort();
      port.pages.set(1, new PageInfo<Comic>(1, 2, makeComics(1, 20), true, 35));
      // 第 2 页包含 1 条重复 Bid=20 与 15 条新记录（总计 35 条）
      const page2Comics: Comic[] = makeComics(20, 16);
      port.pages.set(2, new PageInfo<Comic>(2, 2, page2Comics, false, 35));

      const vm: ShelfViewModel = new ShelfViewModel(new AccountFavoriteRepository(port));
      await vm.loadAccount(true);
      expect(vm.accountList.length).assertEqual(20);
      expect(vm.accountDisplayCount()).assertEqual(35);
      expect(vm.accountHasMore).assertTrue();

      await vm.loadMoreAccount();
      expect(vm.accountList.length).assertEqual(35);
      expect(vm.accountDisplayCount()).assertEqual(35);
      expect(vm.accountHasMore).assertFalse();

      // 取消收藏与新增收藏实时校准总数
      vm.reconcileFavoriteChange(vm.accountList[0], false);
      expect(vm.accountList.length).assertEqual(34);
      expect(vm.accountDisplayCount()).assertEqual(34);

      const added: Comic = new Comic('999', 'New Fav', 'https://img.noymanga.com/999/m1.webp', '', '');
      vm.reconcileFavoriteChange(added, true);
      expect(vm.accountList.length).assertEqual(35);
      expect(vm.accountDisplayCount()).assertEqual(35);
    });
  });

  describe('R2_FilterBarResponsiveLayout', () => {
    it('enablesHorizontalScrollOnNarrowPortraitAndInlineOnLandscape', 0, () => {
      expect(shouldScrollFilterBar(360)).assertTrue();
      expect(shouldScrollFilterBar(FILTER_BAR_SCROLL_BREAKPOINT_VP - 1)).assertTrue();
      expect(shouldScrollFilterBar(FILTER_BAR_SCROLL_BREAKPOINT_VP)).assertFalse();
      expect(shouldScrollFilterBar(840)).assertFalse();
      expect(shouldScrollFilterBar(0)).assertTrue();
    });

    it('mergesSecondaryHeaderToSingleRow52vpOnWideAndLandscapeScreens', 0, () => {
      expect(INLINE_HEADER_MIN_WIDTH_VP).assertEqual(600);
      expect(INLINE_TOP_BAR_HEIGHT_VP).assertEqual(52);
      // 手机竖屏 390x844 → 统一 52vp 顶栏
      expect(shouldUseInlineSecondaryHeader(390, 844)).assertFalse();
      expect(secondaryHeaderTotalHeightVp(30, false)).assertEqual(30 + 52);
      // 手机横屏 844x390 / 折叠屏近方屏 700x800 / 平板横屏 1080x720 → 合并单行紧凑顶栏（52vp）
      expect(shouldUseInlineSecondaryHeader(844, 390)).assertTrue();
      expect(shouldUseInlineSecondaryHeader(700, 800)).assertTrue();
      expect(shouldUseInlineSecondaryHeader(1080, 720)).assertTrue();
      expect(secondaryHeaderTotalHeightVp(0, true)).assertEqual(52);
      // 主 Tab 底部防遮挡留白：bottomInset + 64 + 20
      expect(mainTabBottomClearanceVp(56, true, 24)).assertEqual(24 + 64 + 20);
      expect(mainTabBottomClearanceVp(56, false, 24)).assertEqual(24);
    });
  });
}
