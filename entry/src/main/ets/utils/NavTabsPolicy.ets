/**
 * NavTabsPolicy.ets —— 导航栏可配置页签纯策略函数（零 ArkUI 依赖，可离线单测）
 *
 * 规则：
 * - 'home'（主页）永远固定在第 1 位；
 * - 'profile'（用户）永远固定在最后 1 位；
 * - 'latest'（最新）、'community'（社区）、'shelf'（收藏）可由用户在设置中自由开关；
 * - 最少 2 项（home + profile），最多 5 项（home + latest + community + shelf + profile）。
 */

export type NavTabId = 'home' | 'latest' | 'community' | 'shelf' | 'profile';

export interface NavBarPrefs {
  showLatest: boolean;
  showCommunity: boolean;
  showShelf: boolean;
}

export function resolveVisibleNavTabs(prefs: NavBarPrefs): NavTabId[] {
  const tabs: NavTabId[] = ['home'];
  if (prefs.showLatest) {
    tabs.push('latest');
  }
  if (prefs.showCommunity) {
    tabs.push('community');
  }
  if (prefs.showShelf) {
    tabs.push('shelf');
  }
  tabs.push('profile');
  return tabs;
}

/** 若当前激活的 Tab 被关闭，安全回落到 'home' */
export function resolveSafeSelectedTab(currentTab: NavTabId, visibleTabs: NavTabId[]): NavTabId {
  if (visibleTabs.indexOf(currentTab) >= 0) {
    return currentTab;
  }
  return 'home';
}

export function resolveTabIndexById(tabId: NavTabId, visibleTabs: NavTabId[]): number {
  const idx: number = visibleTabs.indexOf(tabId);
  return idx >= 0 ? idx : 0;
}
