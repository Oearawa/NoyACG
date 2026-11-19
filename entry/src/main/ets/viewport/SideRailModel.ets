/**
 * SideRailModel.ets —— 横屏侧栏路由/结构契约纯数据（p7-landscape-side-rail Task 1）
 *
 * 纯数据 + 零 ArkUI 装饰器：供 SideQuickEntries / Index.SideRail 引用，
 * 并作为侧栏 8 入口路由契约的唯一可测数据源（测试不渲染组件，见本任务测试风格）。
 */
import {
  ROUTE_RANK,
  ROUTE_CATEGORY,
  ROUTE_PERSONALIZED,
  ROUTE_SEARCH
} from '../model/DiscoveryRoutes';

/** 快捷入口路由（默认 DiscoveryRoutes 三项：排行榜 / 分类 / 个性化精选） */
export const SIDE_QUICK_ROUTES: string[] = [ROUTE_RANK, ROUTE_CATEGORY, ROUTE_PERSONALIZED];

/** 圆形搜索路由（SideQuickEntries 内置 pushPathByName 目标） */
export const SIDE_SEARCH_ROUTE: string = ROUTE_SEARCH;

/** 主导航项数（首页 / 最新 / 收藏 / 用户，tab 下标 0..3） */
export const MAIN_NAV_TAB_COUNT: number = 4;

/** 侧栏入口完整性契约：快捷路由数 */
export const SIDE_QUICK_COUNT: number = SIDE_QUICK_ROUTES.length;

/** 侧栏 8 入口 = 快捷 3 + 搜索 1 + 主导航 4 */
export const SIDE_ENTRY_TOTAL: number = SIDE_QUICK_COUNT + 1 + MAIN_NAV_TAB_COUNT;
