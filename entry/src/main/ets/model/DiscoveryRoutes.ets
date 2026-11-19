/**
 * DiscoveryRoutes.ets —— 内容发现页面路由名（Phase 14-N）
 *
 * 与 route_map.json 的 name 一一对应；不建立第二套路由系统，
 * 所有页面仍走 Index.ets 的 @Provider('pageStack') / NavPathStack。
 */
export const ROUTE_RANK: string = 'RankPage';
export const ROUTE_CATEGORY: string = 'CategoryPage';
export const ROUTE_PERSONALIZED: string = 'PersonalizedPage';
export const ROUTE_SEARCH: string = 'SearchPage';

export const DISCOVERY_ROUTES: string[] = [ROUTE_RANK, ROUTE_CATEGORY, ROUTE_PERSONALIZED];
