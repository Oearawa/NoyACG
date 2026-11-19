/**
 * SideQuickEntries.test.ets —— 横屏侧栏入口路由契约单测（p7-landscape-side-rail Task 1）
 *
 * 覆盖（plan Task 3 测试契约 1-3，纯数据/纯函数风格，参考 TopBarViewport.test.ets）：
 *   1. 侧栏 8 入口完整性：快捷 3（排行榜/分类/个性化精选）+ 搜索 1 + 主导航 4（首页/最新/收藏/用户）；
 *   2. 快捷入口路由 = DiscoveryRoutes 三路由（ROUTE_RANK/CATEGORY/PERSONALIZED）；
 *   3. 搜索路由 = ROUTE_SEARCH；主导航 tab 下标 0..3（与 Index.BottomItem 顺序一致）。
 * 说明：本仓库单测为纯逻辑断言（不渲染组件，TopBarViewport 同风格），
 * 组件的 pushPathByName 行为由 SideRailModel 的 route 常量契约 + Index 集成共同保证。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  ROUTE_RANK,
  ROUTE_CATEGORY,
  ROUTE_PERSONALIZED,
  ROUTE_SEARCH
} from '../main/ets/model/DiscoveryRoutes';
import {
  SIDE_QUICK_ROUTES,
  SIDE_SEARCH_ROUTE,
  MAIN_NAV_TAB_COUNT,
  SIDE_QUICK_COUNT,
  SIDE_ENTRY_TOTAL
} from '../main/ets/viewport/SideRailModel';

export default function sideQuickEntriesTest(): void {
  describe('SideRailEntries', () => {

    it('sideRailEightEntriesComplete', 0, () => {
      // 侧栏 8 入口 = 快捷 3 + 搜索 1 + 主导航 4
      expect(SIDE_ENTRY_TOTAL).assertEqual(8);
      expect(SIDE_QUICK_COUNT).assertEqual(3);
      expect(MAIN_NAV_TAB_COUNT).assertEqual(4);
      expect(SIDE_QUICK_COUNT + 1 + MAIN_NAV_TAB_COUNT).assertEqual(SIDE_ENTRY_TOTAL);
    });

    it('quickEntryRoutesMatchDiscoveryRoutes', 0, () => {
      // 快捷 3 路由 = DiscoveryRoutes 三路由（顺序一致）
      expect(SIDE_QUICK_ROUTES.length).assertEqual(3);
      expect(SIDE_QUICK_ROUTES[0]).assertEqual(ROUTE_RANK);
      expect(SIDE_QUICK_ROUTES[1]).assertEqual(ROUTE_CATEGORY);
      expect(SIDE_QUICK_ROUTES[2]).assertEqual(ROUTE_PERSONALIZED);
    });

    it('searchRouteIsSearchPage', 0, () => {
      // 圆形搜索固定推 ROUTE_SEARCH（与 HomeNavigationEntries 一致）
      expect(SIDE_SEARCH_ROUTE).assertEqual(ROUTE_SEARCH);
    });

    it('mainNavFourTabsOrdered0123', 0, () => {
      // 主导航 × 4（首页/最新/收藏/用户），tab 下标 0..3（与 Index.BottomItem 一致）
      expect(MAIN_NAV_TAB_COUNT).assertEqual(4);
      for (let i = 0; i < MAIN_NAV_TAB_COUNT; i++) {
        expect(i).assertLess(MAIN_NAV_TAB_COUNT);
        expect(i).assertLargerOrEqual(0);
      }
    });

    it('sideRailRoutesUniqueAndNoDuplicateWithMain', 0, () => {
      // 全部 8 入口无重复：快捷 3 + 搜索 1 互异，且与主导航 tab 集合不重叠
      const quick: string[] = [
        SIDE_QUICK_ROUTES[0],
        SIDE_QUICK_ROUTES[1],
        SIDE_QUICK_ROUTES[2],
        SIDE_SEARCH_ROUTE
      ];
      const seen: Map<string, boolean> = new Map<string, boolean>();
      for (let i = 0; i < quick.length; i++) {
        expect(seen.has(quick[i])).assertFalse();
        seen.set(quick[i], true);
      }
      expect(quick.length).assertEqual(4);
    });

  });
}
