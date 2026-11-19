/**
 * ExternalLink.ets —— 安全外链跳转工具（广告点击等场景）
 *
 * Phase 14-I 新增。职责：把「打开外部 URL」收敛到一个经过严格校验的入口，
 * 绝不把服务端下发的 URL 当作可信任的任意外部跳转指令。
 *
 * 校验策略：
 * - 只允许 `http://` / `https://`；
 * - 明确拒绝 `javascript:`、`file:`、自定义 scheme、含用户凭据的 URL；
 * - 任何非法输入返回 false，由调用方决定是否提示「无法打开该链接」。
 *
 * 跳转能力：UIAbilityContext.openLink(link)（API 26 已核实签名：
 * `openLink(link: string, options?: OpenLinkOptions, callback?): Promise<void>`，
 * @since 9）。只调用系统标准 App/Deep Linking 打开 https 地址，不在应用内嵌 WebView。
 */
import { common, OpenLinkOptions, Want } from '@kit.AbilityKit';
import { NOY_WEB_ORIGIN } from '../api/HttpManager';
import { Logger } from './Logger';

const TAG: string = 'ExternalLink';

export const NOY_REGISTER_URL: string = `${NOY_WEB_ORIGIN}/register`;

export function buildRegisterUrl(origin: string = NOY_WEB_ORIGIN): string {
  const clean: string = origin.trim();
  if (clean.endsWith('/')) {
    return `${clean}register`;
  }
  return `${clean}/register`;
}

export interface ExternalLinkContext {
  openLink(link: string, options?: OpenLinkOptions): Promise<void>;
  startAbility(want: Want): Promise<void>;
}

/**
 * 判断 URL 是否为「可安全外跳」的 http/https 地址。
 * @returns true = 仅 http/https 且不含凭据、非 javascript/file 等危险 scheme
 */
export function isSafeHttpUrl(url: string): boolean {
  if (typeof url !== 'string' || url.trim() === '') {
    return false;
  }
  const target: string = url.trim();
  // 仅允许 http/https（大小写不敏感）
  const lower: string = target.toLowerCase();
  if (!(lower.startsWith('https://') || lower.startsWith('http://'))) {
    return false;
  }
  // 拒绝含用户凭据的 URL（user:pass@host）
  if (target.indexOf('@') >= 0) {
    return false;
  }
  return true;
}

/**
 * 安全打开外链（仅 https/http）。
 * @param url     待打开地址（非法时直接返回 false，不触发任何系统能力）
 * @param context UIAbility 上下文（组件内经 `getUIContext().getHostContext()` 取得）
 * @returns 是否已提交打开（true 不代表最终成功，失败会记录日志并返回 false）
 */
export async function openExternalLink(url: string, context: common.UIAbilityContext | undefined): Promise<boolean> {
  if (!isSafeHttpUrl(url)) {
    Logger.warn(TAG, `拒绝打开非 http/https 链接: ${url.substring(0, 120)}`);
    return false;
  }
  if (context === undefined) {
    Logger.warn(TAG, '缺少 UIAbility 上下文，无法打开外链');
    return false;
  }
  try {
    await context.openLink(url.trim());
    Logger.info(TAG, `已提交打开外链: ${url.substring(0, 120)}`);
    return true;
  } catch (e) {
    Logger.error(TAG, `打开外链失败: ${(e as Error).message}`);
    return false;
  }
}

/**
 * 拉起系统默认浏览器打开官方注册网址：
 * 优先调用 UIAbilityContext.openLink(url, { appLinkingOnly: false })，
 * 失败时兜底调用 startAbility(viewData + browsable)，绝不在应用内加载 WebView。
 */
export async function openExternalRegisterUrl(
  context: ExternalLinkContext | undefined,
  registerUrl: string = NOY_REGISTER_URL
): Promise<boolean> {
  if (!isSafeHttpUrl(registerUrl)) {
    Logger.warn(TAG, `拒绝打开非法注册地址: ${registerUrl.substring(0, 120)}`);
    return false;
  }
  if (context === undefined) {
    Logger.warn(TAG, '缺少 UIAbility 上下文，无法打开官方注册页');
    return false;
  }
  const target: string = registerUrl.trim();
  try {
    const opts: OpenLinkOptions = { appLinkingOnly: false };
    await context.openLink(target, opts);
    Logger.info(TAG, `已通过 openLink 拉起官方注册页: ${target}`);
    return true;
  } catch (e) {
    Logger.warn(TAG, `openLink 失败，尝试 startAbility 兜底: ${(e as Error).message}`);
  }
  try {
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: target
    };
    await context.startAbility(want);
    Logger.info(TAG, `已通过 startAbility 兜底拉起官方注册页: ${target}`);
    return true;
  } catch (e2) {
    Logger.error(TAG, `拉起系统浏览器打开注册页失败: ${(e2 as Error).message}`);
    return false;
  }
}

class AbilityContextLinkAdapter implements ExternalLinkContext {
  private readonly abilityCtx: common.UIAbilityContext;

  constructor(abilityCtx: common.UIAbilityContext) {
    this.abilityCtx = abilityCtx;
  }

  openLink(link: string, options?: OpenLinkOptions): Promise<void> {
    return this.abilityCtx.openLink(link, options);
  }

  startAbility(want: Want): Promise<void> {
    return this.abilityCtx.startAbility(want);
  }
}

export async function openExternalUrlWithAbilityContext(
  url: string,
  context: common.UIAbilityContext | undefined
): Promise<boolean> {
  if (context === undefined) {
    return openExternalRegisterUrl(undefined, url);
  }
  return openExternalRegisterUrl(new AbilityContextLinkAdapter(context), url);
}

export async function openExternalRegisterUrlWithAbilityContext(
  context: common.UIAbilityContext | undefined,
  registerUrl: string = NOY_REGISTER_URL
): Promise<boolean> {
  return openExternalUrlWithAbilityContext(registerUrl, context);
}
