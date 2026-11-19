/**
 * AdItem.ets —— 首页广告位条目（POST /api/v3/ads）
 *
 * Phase 14-I 新增。广告**独立于普通漫画推荐**，不混入任何榜单。
 *
 * 安全约定（任务书 §五）：
 * - 广告 `img` 与 `url` 均由协议层严格校验为 http/https 后才入库；
 *   非 http(s)（javascript:、自定义 scheme 等）一律丢弃 / 置空；
 * - 广告 URL 不被当作可信任的任意外部跳转指令，点击时只允许通过
 *   `openLink` 打开 https 地址（见 utils/ExternalLink.ets）。
 */
@ObservedV2
export class AdItem {
  /** 广告图地址（已校验 http/https，空串 = 无效不渲染） */
  @Trace image: string = '';
  /** 跳转地址（已校验 http/https，空串 = 不可跳转） */
  @Trace url: string = '';

  constructor(image: string = '', url: string = '') {
    this.image = image;
    this.url = url;
  }
}
