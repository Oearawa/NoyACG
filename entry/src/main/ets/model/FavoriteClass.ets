/**
 * FavoriteClass.ets —— 账号收藏分类（Phase 14-J2）
 *
 * 来源：POST /api/v4/favorites/class/get（首方生产 bundle 证据：
 * assets/favorites-CzyYHNIA.js 中 `e('/v4/favorites/class/get', {})`）。
 * 响应形如 `{ status:'ok', data:[{ id, name }] }`。
 *
 * 说明：本阶段 UI 只展示「全部」收藏（class 省略），分类能力仅在数据层解析保留，
 * 未在 UI 暴露分类切换，避免引入未验证的交互。
 */
@ObservedV2
export class FavoriteClass {
  /** 分类 ID（数字/字符串统一为字符串） */
  @Trace id: string = '';
  /** 分类名称 */
  @Trace name: string = '';

  constructor() {
  }
}
