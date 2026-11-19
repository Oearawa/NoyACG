/**
 * Phase14K2.test.ets —— 用户中心入口唯一性回归测试（14-K2 建立，14-K 双层重构后调整口径）
 *
 * 不变量（历次重构都不许放宽）：
 *   1. 一级导航之外，用户侧功能入口总数固定且 key 唯一；
 *   2. 每个功能有且仅有一个主要入口（按 route 计数）；
 *   3. 所有 route 必须已注册（route_map.json）；
 *   4. 不得出现邀请码 / 积分 / 登出 / Drawer 等不属于日常入口的项。
 *
 * 说明：14-K 把下载管理归回第一层日常功能、设置入口独立渲染，
 * 因此断言对象统一为 `DAILY_ACTIONS`（三项日常功能）+ `SETTINGS_ENTRY`（唯一设置入口）。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  DAILY_ACTIONS,
  SETTINGS_ENTRY,
  ProfileMenuEntry,
  ROUTE_ABOUT,
  ROUTE_DOWNLOAD,
  ROUTE_HISTORY,
  ROUTE_LOGIN,
  ROUTE_MESSAGE,
  ROUTE_SETTINGS,
  allProfileEntries,
  findDailyAction,
  routeOfDailyAction
} from '../main/ets/model/ProfileMenu';

/** route_map.json 中已注册的系统路由名（镜像，改动路由表需同步此处） */
const REGISTERED_ROUTES: string[] = [
  'ComicDetail', 'ComicReader', 'SearchPage', 'LoginPage', 'DownloadPage',
  'ProfilePage', 'SettingsPage', 'MessagePage', 'HistoryPage', 'AboutPage', 'SectionListPage'
];

function isRegistered(route: string): boolean {
  return REGISTERED_ROUTES.indexOf(route) >= 0;
}

/** 统计某 route 在日常入口中出现次数 */
function countByRoute(route: string): number {
  let n: number = 0;
  for (let i = 0; i < DAILY_ACTIONS.length; i++) {
    if (DAILY_ACTIONS[i].route === route) {
      n++;
    }
  }
  return n;
}

export default function phase14k2Test() {
  describe('Phase14K2_ProfileMenu', () => {
    it('layerOneHasThreeDailyEntries', 0, () => {
      expect(DAILY_ACTIONS.length).assertEqual(3);
      expect(allProfileEntries().length).assertEqual(3);
    });

    it('entryKeysAreUniqueAndNonEmpty', 0, () => {
      const seen: string[] = [];
      const all: ProfileMenuEntry[] = allProfileEntries();
      for (let i = 0; i < all.length; i++) {
        expect(all[i].key !== '').assertTrue();
        expect(seen.indexOf(all[i].key) < 0).assertTrue();
        seen.push(all[i].key);
      }
      expect(seen.indexOf(SETTINGS_ENTRY.key) < 0).assertTrue();
    });

    it('everyEntryHasTitleSubtitleAndRoute', 0, () => {
      const all: ProfileMenuEntry[] = allProfileEntries();
      for (let i = 0; i < all.length; i++) {
        expect(all[i].icon !== '').assertTrue();
        expect(all[i].title !== '').assertTrue();
        expect(all[i].subtitle !== '').assertTrue();
        expect(all[i].route !== '').assertTrue();
      }
      // 设置入口只有标题与目标，不堆叠说明文字
      expect(SETTINGS_ENTRY.title !== '').assertTrue();
      expect(SETTINGS_ENTRY.route !== '').assertTrue();
    });

    it('allRoutesAreRegisteredInRouteMap', 0, () => {
      const all: ProfileMenuEntry[] = allProfileEntries();
      for (let i = 0; i < all.length; i++) {
        expect(isRegistered(all[i].route)).assertTrue();
      }
      expect(isRegistered(SETTINGS_ENTRY.route)).assertTrue();
      expect(isRegistered(ROUTE_ABOUT)).assertTrue();
      expect(isRegistered(ROUTE_LOGIN)).assertTrue();
    });

    it('eachFeatureHasExactlyOneEntry', 0, () => {
      expect(countByRoute(ROUTE_MESSAGE)).assertEqual(1);
      expect(countByRoute(ROUTE_HISTORY)).assertEqual(1);
      expect(countByRoute(ROUTE_DOWNLOAD)).assertEqual(1);
    });

    it('noDuplicateRouteAcrossEntries', 0, () => {
      const routes: string[] = [SETTINGS_ENTRY.route];
      const all: ProfileMenuEntry[] = allProfileEntries();
      for (let i = 0; i < all.length; i++) {
        expect(routes.indexOf(all[i].route) < 0).assertTrue();
        routes.push(all[i].route);
      }
    });

    it('settingsIsSingleDoorToLayerTwo', 0, () => {
      // 第二层只有 SettingsPage 一个入口，且不能同时出现在日常功能表里
      expect(SETTINGS_ENTRY.route).assertEqual(ROUTE_SETTINGS);
      expect(countByRoute(ROUTE_SETTINGS)).assertEqual(0);
    });

    it('noUnsupportedFeatureEntries', 0, () => {
      const forbidden: string[] = [
        'logout', 'signout', 'invite', 'invite_code', 'points', 'points_store', 'points_log', 'drawer'
      ];
      const all: ProfileMenuEntry[] = allProfileEntries();
      for (let i = 0; i < all.length; i++) {
        expect(forbidden.indexOf(all[i].key) < 0).assertTrue();
        expect(all[i].title.indexOf('邀请') < 0).assertTrue();
        expect(all[i].title.indexOf('积分') < 0).assertTrue();
      }
    });

    it('aboutAndLoginAreNotDailyEntries', 0, () => {
      expect(countByRoute(ROUTE_ABOUT)).assertEqual(0);
      expect(countByRoute(ROUTE_LOGIN)).assertEqual(0);
    });

    it('findDailyActionHandlesUnknownKey', 0, () => {
      const found: ProfileMenuEntry | null = findDailyAction('message');
      expect(found !== null).assertTrue();
      expect(findDailyAction('not_exists') === null).assertTrue();
      expect(routeOfDailyAction('not_exists')).assertEqual('');
    });
  });
}
