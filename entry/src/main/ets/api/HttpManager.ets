/**
 * HttpManager.ets —— 基于 rcp（Remote Communication Platform）的统一网络请求核心
 *
 * 能力清单：
 * 1. 单例管理 rcp.Session，全 App 共享一个会话，底层自动维护连接池复用；
 * 2. 全局默认 Header（PC 浏览器 UA / Referer / Accept-Language），突破基础防盗链；
 * 3. 三级 Header 合并：全局默认 Header → 动态注入 Header(Provider) → 调用级 Header，
 *    动态 Provider 即后续注入 Token / Cookie 的统一入口；
 *
 * ★ 诊断安全（I-000005）：probeUserinfoWithExplicitCookie / countCookies 的诊断输出
 *   仅限 debug 构建（BuildInfo.IS_DEBUG_BUILD）；日志中的 Cookie 指纹在记录前经
 *   LogSanitizer 脱敏，生产构建不调用、不输出任何 Cookie 元数据。
 * 4. 统一 JSON 解析与 HttpError 错误模型，业务层只处理一种异常类型。
 *
 * ★ API 26 适配说明（以当前 SDK 类型声明为准，非旧版教程）：
 * - rcp 在 API 26 中移除了 RequestInterceptor / SessionConfiguration.sessionName，
 *   因此「拦截器合并 Header」改为「请求构建期合并 Header」（HeaderMerger），对外行为不变；
 * - rcp.Request 由 interface 变为 class，url 类型为 URL，必须用构造函数创建；
 * - rcp.Response 移除 toByteArray()，二进制改由 readonly body?: ArrayBuffer 读取；
 * - toString() 返回 string | null，统一收敛为 ''。
 *
 * 注意：rcp 约定 Header 字段名必须全小写（如 'user-agent'、'content-type'、'referer'），
 *       本封装已统一做小写归一化处理，调用方无需关心。
 */
import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { url } from '@kit.ArkTS';
import { Logger } from '../utils/Logger';
import { CancelToken, RequestCanceledError } from './CancelToken';
import { GateRejectedError, RequestGate, RequestSlot, Transport } from './RequestGate';
import { parseRetryAfterMs } from './RetryPolicy';
import { NetworkLogManager, NetworkTrace } from '../utils/NetworkLogManager';
import { IS_DEBUG_BUILD } from '../utils/BuildInfo';
import { sanitizeText } from '../utils/LogSanitizer';
import { isNoyApiUrl, resolveContentRatingHeader } from './ApiHeaders';
import { AuthCookiePort, AuthHttpPort } from './AuthTypes';

const TAG: string = 'HttpManager';

/**
 * Transport 适配器（ArkTS 限制内联对象字面量，故用具名类包装闭包）。
 * 把「一次请求的实际执行」包装成 RequestGate 的 Transport 接口。
 */
class HttpTextTransport implements Transport<string> {
  private exec: (slot: RequestSlot<string>) => Promise<void>;

  constructor(exec: (slot: RequestSlot<string>) => Promise<void>) {
    this.exec = exec;
  }

  async execute(slot: RequestSlot<string>): Promise<void> {
    await this.exec(slot);
  }
}

export class HttpBytesResult {
  readonly bytes: Uint8Array;
  readonly statusCode: number;
  readonly contentType: string;

  constructor(bytes: Uint8Array, statusCode: number, contentType: string) {
    this.bytes = bytes;
    this.statusCode = statusCode;
    this.contentType = contentType;
  }
}

class HttpBytesTransport implements Transport<HttpBytesResult> {
  private exec: (slot: RequestSlot<HttpBytesResult>) => Promise<void>;

  constructor(exec: (slot: RequestSlot<HttpBytesResult>) => Promise<void>) {
    this.exec = exec;
  }

  async execute(slot: RequestSlot<HttpBytesResult>): Promise<void> {
    await this.exec(slot);
  }
}

/** NoyAcg Web 站点源（2026-11 实测：/api 与本页面同源，release.noymanga.com 仅为下载页） */
export const NOY_WEB_ORIGIN: string = 'https://noymanga.com';

/** CookieRepository 标识：只允许字母/数字/下划线；同 ID 实例共享 Cookie */
export const NOY_COOKIE_REPOSITORY_ID: string = 'NOYACG_AUTH';

/** 伪造的 PC 端 Chrome UA（配合 Referer 突破源站防盗链） */
const DEFAULT_PC_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/**
 * 统一网络异常模型。
 * statusCode >= 0：HTTP 响应状态码；< 0：本地阶段错误（连接失败 / 超时 / JSON 解析失败等）
 */
export class HttpError extends Error {
  readonly statusCode: number;
  /** 本地阶段标注（http/network/cancel/parse），供 RetryPolicy 分类（I-000004） */
  readonly retryHint: string;
  /** 服务端 Retry-After 解析后的退避毫秒数（可选） */
  readonly retryAfterMs: number | undefined;

  constructor(statusCode: number, message: string, retryHint: string = '',
    retryAfterMs?: number) {
    super(message);
    this.name = 'HttpError';
    this.statusCode = statusCode;
    this.retryHint = retryHint;
    this.retryAfterMs = retryAfterMs;
  }
}

/** 动态 Header 提供器：每次请求前回调，返回需要注入的 Header（如最新 Token、Cookie） */
export type HeaderProvider = () => Record<string, string>;

/**
 * 三级 Header 合并器（替代 API 26 已移除的 rcp.RequestInterceptor）。
 * 优先级：全局默认 < 动态注入 < 调用级
 */
class HeaderMerger {
  private globalHeaders: Record<string, string> = {
    'user-agent': DEFAULT_PC_UA,
    'accept': 'application/json, text/plain, */*',
    'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'referer': NOY_WEB_ORIGIN + '/'
  };
  private providers: HeaderProvider[] = [];

  /** 设置/覆盖一条全局默认 Header（字段名自动转小写） */
  setGlobalHeader(name: string, value: string): void {
    this.globalHeaders[name.toLowerCase()] = value;
  }

  /** 移除一条全局默认 Header（ArkTS 禁用 delete 运算符，故重建对象） */
  removeGlobalHeader(name: string): void {
    const target: string = name.toLowerCase();
    const next: Record<string, string> = {};
    const keys: string[] = Object.keys(this.globalHeaders);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] !== target) {
        next[keys[i]] = this.globalHeaders[keys[i]];
      }
    }
    this.globalHeaders = next;
  }

  /** 注册动态 Header 提供器（同一提供器不会重复注册） */
  addProvider(provider: HeaderProvider): void {
    if (this.providers.indexOf(provider) < 0) {
      this.providers.push(provider);
    }
  }

  /** 注销动态 Header 提供器 */
  removeProvider(provider: HeaderProvider): void {
    const index = this.providers.indexOf(provider);
    if (index >= 0) {
      this.providers.splice(index, 1);
    }
  }

  /**
   * 合并三级 Header 并返回新对象（不修改任何入参）。
   * @param callLevel 调用级 Header（优先级最高，如针对图片域名单独伪造 Referer）
   */
  merge(callLevel?: Record<string, string>): Record<string, string> {
    const merged: Record<string, string> = {};
    this.mergeInto(merged, this.globalHeaders);
    for (let i = 0; i < this.providers.length; i++) {
      this.mergeInto(merged, this.providers[i]());
    }
    if (callLevel !== undefined) {
      this.mergeInto(merged, callLevel);
    }
    return merged;
  }

  /** 将 source 中的键值对合并进 target，键名统一转小写 */
  private mergeInto(target: Record<string, string>, source: Record<string, string>): void {
    const keys: string[] = Object.keys(source);
    for (let i = 0; i < keys.length; i++) {
      target[keys[i].toLowerCase()] = source[keys[i]];
    }
  }
}

/**
 * 网络请求管理器（单例）。
 * 使用方式：HttpManager.getInstance().get<RespType>('/api/xxx', { page: '1' })
 */
export class HttpManager implements AuthHttpPort, AuthCookiePort {
  private static instance?: HttpManager;
  private static readonly CONNECT_TIMEOUT_MS: number = 15000;
  private static readonly TRANSFER_TIMEOUT_MS: number = 30000;

  private session?: rcp.Session;
  /**
   * 应用级 CookieRepository（懒创建）。
   * 与会话绑定后：响应 Set-Cookie 自动入库、后续请求自动携带，并每 30s 自动落盘。
   * 懒创建 + try/catch 是为了在无系统能力的测试运行时也能安全降级（不带 Cookie 的会话）。
   */
  private cookieRepository?: rcp.CookieRepository;
  private cookieRepositoryResolved: boolean = false;
  private headers: HeaderMerger = new HeaderMerger();
  /** 源站基地址：阶段一固定为 NoyAcg webapp 源，多源扩展时可通过 setBaseAddress 切换 */
  private baseAddress: string = NOY_WEB_ORIGIN;

  private constructor() {
    // 会话与会话级 CookieRepository 改为首次请求时懒创建：
    // 避免在无网络能力的测试运行时构造会话导致整个模块导入失败
  }

  /** 获取单例 */
  static getInstance(): HttpManager {
    if (HttpManager.instance === undefined) {
      HttpManager.instance = new HttpManager();
    }
    return HttpManager.instance;
  }

  /**
   * 诊断能力总开关（I-000005）：与 BuildInfo.IS_DEBUG_BUILD 单一事实来源保持一致。
   * release 构建恒为 false —— 探针/明细日志在入口即短路，不触碰 CookieRepository。
   */
  static diagnosticEnabled(): boolean {
    return IS_DEBUG_BUILD;
  }

  /** （重新）创建 rcp 会话；连接池复用由 rcp 底层自动管理 */
  private createSession(): void {
    if (this.session !== undefined) {
      this.session.close();
      this.session = undefined;
    }
    const config: rcp.SessionConfiguration = {
      baseAddress: this.baseAddress,
      requestConfiguration: {
        transfer: {
          timeout: {
            connectMs: HttpManager.CONNECT_TIMEOUT_MS,
            transferMs: HttpManager.TRANSFER_TIMEOUT_MS
          }
        }
      }
    };
    // 关键：会话必须绑定 CookieRepository，登录 Set-Cookie 才会自动接收并在后续请求携带
    const repository: rcp.CookieRepository | undefined = this.getCookieRepository();
    if (repository !== undefined) {
      config.cookieRepository = repository;
    }
    this.session = rcp.createSession(config);
    Logger.info(TAG, repository === undefined
      ? '会话已创建（无 CookieRepository，仅匿名可用）'
      : `会话已创建（CookieRepository=${repository.identifier}）`);
  }

  // ==================== 对外请求 API ====================

  /**
   * GET 请求，返回统一 JSON 解析后的对象
   * @param path    相对路径（以 / 开头）或完整 URL
   * @param params  查询参数（自动做 URL 编码拼接）
   * @param headers 调用级 Header（优先级最高，如单独伪造 Referer）
   */
  async get<T>(path: string, params?: Record<string, string>,
    headers?: Record<string, string>, token?: CancelToken): Promise<T> {
    const text: string = await this.getString(path, params, headers, token);
    return HttpManager.parseJson<T>(text);
  }

  /** GET 请求，返回原始字符串（用于后续 HTML 源码解析场景） */
  async getString(path: string, params?: Record<string, string>,
    headers?: Record<string, string>, token?: CancelToken): Promise<string> {
    const url: string = HttpManager.buildUrl(this.baseAddress, path, params);
    const request: rcp.Request =
      new rcp.Request(url, 'GET', this.headers.merge(this.withApiHeaders(url, headers)));
    const trace: NetworkTrace = NetworkLogManager.getInstance().begin('GET', url);
    try {
      // 经 RequestGate：断网挂起（幂等 GET）→ 恢复重放（有上限）→ 有界退避重试（I-000004）
      return await RequestGate.getInstance().run<string>('GET', url,
        new HttpTextTransport(async (slot: RequestSlot<string>): Promise<void> => {
          try {
            const response: rcp.Response = await this.doRequest(url, request, trace, token);
            const text: string = response.toString() ?? '';
            trace.bytes = text.length;
            slot.done = true;
            slot.value = text;
          } catch (e) {
            slot.done = false;
            slot.errorObj = e as Object;
          }
        }), token);
    } catch (e) {
      throw HttpManager.normalizeGate(e);
    } finally {
      NetworkLogManager.getInstance().end(trace);
    }
  }

  /**
   * POST 请求（JSON body），返回统一 JSON 解析后的对象
   * @param body 请求体，将被序列化为 JSON 并自动设置 content-type
   */
  async post<T>(path: string, body?: Record<string, Object>,
    headers?: Record<string, string>): Promise<T> {
    const url: string = HttpManager.buildUrl(this.baseAddress, path);
    const merged: Record<string, string> = this.headers.merge(this.withApiHeaders(url, headers));
    merged['content-type'] = 'application/json;charset=UTF-8';
    const request: rcp.Request = new rcp.Request(url, 'POST', merged);
    if (body !== undefined) {
      request.content = JSON.stringify(body);
    }
    const trace: NetworkTrace = NetworkLogManager.getInstance().begin('POST', url);
    try {
      // POST 写操作：经 RequestGate 单发路径 —— 断网立即拒绝、绝不自动重试（防重复提交，I-000004）
      const text: string = await RequestGate.getInstance().run<string>('POST', url,
        new HttpTextTransport(async (slot: RequestSlot<string>): Promise<void> => {
          try {
            const response: rcp.Response = await this.doRequest(url, request, trace);
            const text: string = response.toString() ?? '';
            trace.bytes = text.length;
            slot.done = true;
            slot.value = text;
          } catch (e) {
            slot.done = false;
            slot.errorObj = e as Object;
          }
        }), undefined);
      return HttpManager.parseJson<T>(text);
    } catch (e) {
      throw HttpManager.normalizeGate(e);
    } finally {
      NetworkLogManager.getInstance().end(trace);
    }
  }

  /**
   * POST 表单请求（application/x-www-form-urlencoded）。
   *
   * NoyAcg 的列表/搜索类接口（/v4/search/fetch、/b1/booklist）只接受表单编码，
   * 用 JSON body 会拿不到参数；因此单独提供本方法，避免在业务层手拼 Content-Type。
   */
  async postForm<T>(path: string, form: Record<string, string>,
    headers?: Record<string, string>): Promise<T> {
    const text: string = await this.postFormText(path, form, headers);
    return HttpManager.parseJson<T>(text);
  }

  /**
   * POST 表单请求并返回原始响应文本（供社区封装 NoyClient 等自行做防御式解析，复用统一 Session/Cookie/Header/Gate）。
   */
  async postFormText(path: string, form: Record<string, string>,
    headers?: Record<string, string>): Promise<string> {
    const url: string = HttpManager.buildUrl(this.baseAddress, path);
    const merged: Record<string, string> = this.headers.merge(this.withApiHeaders(url, headers));
    merged['content-type'] = 'application/x-www-form-urlencoded';
    const request: rcp.Request = new rcp.Request(url, 'POST', merged);
    request.content = HttpManager.encodeForm(form);
    const trace: NetworkTrace = NetworkLogManager.getInstance().begin('POST', url);
    try {
      // POST 写操作：经 RequestGate 单发路径 —— 断网立即拒绝、绝不自动重试（防重复提交，I-000004）
      return await RequestGate.getInstance().run<string>('POST', url,
        new HttpTextTransport(async (slot: RequestSlot<string>): Promise<void> => {
          try {
            const response: rcp.Response = await this.doRequest(url, request, trace);
            const text: string = response.toString() ?? '';
            trace.bytes = text.length;
            slot.done = true;
            slot.value = text;
          } catch (e) {
            slot.done = false;
            slot.errorObj = e as Object;
          }
        }), undefined);
    } catch (e) {
      throw HttpManager.normalizeGate(e);
    } finally {
      NetworkLogManager.getInstance().end(trace);
    }
  }

  /** 表单编码：key/value 逐项 encodeURIComponent，空值保留（服务端以空串表示“默认/全部”） */
  private static encodeForm(form: Record<string, string>): string {
    const parts: string[] = [];
    const keys: string[] = Object.keys(form);
    for (let i = 0; i < keys.length; i++) {
      parts.push(`${encodeURIComponent(keys[i])}=${encodeURIComponent(form[keys[i]])}`);
    }
    return parts.join('&');
  }

  /**
   * 获取/创建应用级 CookieRepository。
   * 失败时返回 undefined（会话降级为无 Cookie），不抛出、不阻断业务。
   */
  private getCookieRepository(): rcp.CookieRepository | undefined {
    if (this.cookieRepositoryResolved) {
      return this.cookieRepository;
    }
    this.cookieRepositoryResolved = true;
    try {
      this.cookieRepository = rcp.CookieRepository.create(NOY_COOKIE_REPOSITORY_ID);
      Logger.info(TAG, `CookieRepository 已就绪: ${this.cookieRepository.identifier}`);
    } catch (e) {
      this.cookieRepository = undefined;
      Logger.error(TAG, `CookieRepository 创建失败: ${(e as BusinessError).message}`);
    }
    return this.cookieRepository;
  }

  // ==================== Cookie 会话能力（AuthCookiePort 的生产实现） ====================

  /** 诊断：把仓库中匹配的 Cookie 值做不可逆指纹（FNV-1a），用于比对取值是否一致 */
  private static cookieFingerprint(value: string): string {
    let h: number = 2166136261;
    for (let i = 0; i < value.length; i++) {
      h = h ^ value.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return (h >>> 0).toString(16);
  }

  /**
   * 诊断：显式携带仓库中的 Cookie 请求 /api/v3/userinfo。
   * 仅用于定位「自动携带失效」还是「Cookie 值失效」，返回服务端 status 字段。
   */
  async probeUserinfoWithExplicitCookie(debugOverride?: boolean): Promise<string> {
    const enabled: boolean = debugOverride !== undefined
      ? debugOverride : HttpManager.diagnosticEnabled();
    if (!enabled) {
      return 'disabled'; // release 构建：诊断探针不执行、不输出
    }
    const repository: rcp.CookieRepository | undefined = this.getCookieRepository();
    if (repository === undefined) {
      return 'no-repository';
    }
    const matched: rcp.ResponseCookie[] = await repository.getCookiesByUrl(new url.URL(`${NOY_WEB_ORIGIN}/api/v3/userinfo`));
    if (matched === undefined || matched === null || matched.length === 0) {
      return 'no-match';
    }
    const pairs: string[] = matched.map((c: rcp.ResponseCookie): string => `${c.name}=${c.value}`);
    const fingerprintText: string = matched.map((c: rcp.ResponseCookie): string =>
      `${c.name}:${HttpManager.cookieFingerprint(c.value ?? '')}`).join(',');
    Logger.debug(TAG, `诊断 Cookie 指纹: ${sanitizeText(fingerprintText)}`);
    const headers: Record<string, string> = this.headers.merge(this.withApiHeaders(`${NOY_WEB_ORIGIN}/api/v3/userinfo`));
    headers['cookie'] = pairs.join('; ');
    headers['content-type'] = 'application/x-www-form-urlencoded';
    const request: rcp.Request = new rcp.Request(`${NOY_WEB_ORIGIN}/api/v3/userinfo`, 'POST', headers);
    request.content = '';
    try {
      const response: rcp.Response = await this.doRequest(`${NOY_WEB_ORIGIN}/api/v3/userinfo`, request);
      const text: string = response.toString() ?? '';
      const parsed: Record<string, Object> = HttpManager.parseJson<Record<string, Object>>(text);
      return `${parsed['status'] ?? 'unknown'}`;
    } catch (e) {
      return `error:${(e as BusinessError).message}`;
    }
  }

  /** 当前 CookieRepository 中的 Cookie 数量（只记数量，不打印值） */
  async countCookies(): Promise<number> {
    const repository: rcp.CookieRepository | undefined = this.getCookieRepository();
    if (repository === undefined) {
      return 0;
    }
    try {
      const cookies: rcp.ResponseCookie[] = await repository.getAllCookies();
      const total: number = cookies === undefined || cookies === null ? 0 : cookies.length;
      // 诊断：只记录脱敏后的结构信息（名称/域名/路径/过期均打码，值长度与指纹不落日志）。
      // 仅 debug 构建输出（HttpManager.diagnosticEnabled()），release 不产生任何 Cookie 元数据日志。
      if (total > 0 && HttpManager.diagnosticEnabled()) {
        const meta: string[] = cookies.map((c: rcp.ResponseCookie): string =>
          sanitizeText(`${c.name}@${c.domain ?? '-'}${c.path ?? '-'}exp=${c.expires ?? '-'}len=${(c.value ?? '').length}fp=${HttpManager.cookieFingerprint(c.value ?? '')}s=${c.isSecure ?? '-'}h=${c.httpOnly ?? '-'}`));
        Logger.debug(TAG, `Cookie 明细(${total}): ${meta.join(' | ')}`);
        const matched: rcp.ResponseCookie[] = await repository.getCookiesByUrl(new url.URL(`${NOY_WEB_ORIGIN}/api/v3/userinfo`));
        Logger.debug(TAG, `按 URL 匹配 Cookie 数: ${matched === undefined || matched === null ? 0 : matched.length}`);
      }
      return total;
    } catch (e) {
      // 读取失败按「无 Cookie」降级：绝不能因为读不到就把匿名态误判成已登录
      Logger.warn(TAG, `读取 Cookie 失败: ${(e as BusinessError).message}`);
      return 0;
    }
  }

  /**
   * 删除 NoyAcg 站点 Cookie 并落盘。
   * 该 CookieRepository 专用于 NoyAcg（identifier=NOYACG_AUTH），
   * 因此其中不含第三方 Cookie；仍按域名做一次白名单过滤，避免误删。
   */
  async clearSiteCookies(): Promise<void> {
    const repository: rcp.CookieRepository | undefined = this.getCookieRepository();
    if (repository === undefined) {
      return;
    }
    let cookies: rcp.ResponseCookie[] | undefined;
    try {
      cookies = await repository.getAllCookies();
    } catch (e) {
      throw HttpManager.cookieFailure(e, '读取待清理 Cookie 失败');
    }
    if (cookies !== undefined && cookies !== null && cookies.length > 0) {
      const targets: rcp.ResponseCookie[] = cookies.filter((cookie: rcp.ResponseCookie): boolean => {
        const domain: string | undefined = cookie.domain;
        if (domain === undefined || domain === '') {
          return true; // host-only Cookie：属于当前站点
        }
        return domain.indexOf('noymanga.com') >= 0 || domain.indexOf('noyteam.online') >= 0;
      });
      if (targets.length > 0) {
        try {
          await repository.deleteCookies(targets);
        } catch (e) {
          // 上抛让 AuthRepository.logout() 能如实返回「清理失败」，不伪造退出成功
          throw HttpManager.cookieFailure(e, '删除站点 Cookie 失败');
        }
      }
    }
    // 兜底：按 URL 再清一次（覆盖 path 维度不同的 Cookie）
    try {
      // API 26：rcp.URL 是 @ohos.url 的 url.URL 类型别名，ArkTS 无全局 URL 构造器
      await repository.deleteCookiesByUrl(new url.URL(`${NOY_WEB_ORIGIN}/`));
    } catch (e) {
      Logger.warn(TAG, `按 URL 清理 Cookie 失败: ${(e as BusinessError).message}`);
    }
    Logger.info(TAG, '站点 Cookie 已清理');
  }

  /** 触发 CookieRepository 立即落盘（空数组 = 仅保存现有 Cookie） */
  async persistCookies(): Promise<void> {
    const repository: rcp.CookieRepository | undefined = this.getCookieRepository();
    if (repository === undefined) {
      return;
    }
    try {
      await repository.setCookies([]);
    } catch (e) {
      throw HttpManager.cookieFailure(e, 'Cookie 落盘失败');
    }
  }

  /** Cookie 操作的异常归一化：日志只带错误码/消息，绝不打印 Cookie 值 */
  private static cookieFailure(e: Object, prefix: string): HttpError {
    const err: BusinessError = e as BusinessError;
    Logger.error(TAG, `${prefix}: ${err.code} - ${err.message}`);
    return new HttpError(-1, `${prefix}: ${err.message}`);
  }

  /**
   * 取消指定在途请求（API 26 `rcp.Session.cancel(requestToCancel?: Request | Request[])`）。
   *
   * Phase 12 依据：任务书要求「暂停/取消时必须考虑正在进行的网络请求」，
   * 修改任务状态**不能**取消已发出的 HTTP 请求。SDK 明确支持按 Request 取消
   * （`@hms.collaboration.rcp.d.ts` Session.cancel，@since 4.1.0(11)），
   * 取消后 `fetch()` 会抛 BusinessError 1007900992，由本类归一化为 HttpError，
   * 下载层通过 DownloadToken 识别为「中断」而非「失败」。
   */
  cancelRequest(request: rcp.Request): void {
    if (this.session === undefined) {
      return;
    }
    try {
      this.session.cancel(request);
      Logger.info(TAG, '已请求取消在途 RCP 请求');
    } catch (e) {
      // 请求已完成/已取消时 SDK 会抛参数错误，此处不视为下载失败
      Logger.warn(TAG, `取消请求未生效（可能已结束）: ${(e as BusinessError).message}`);
    }
  }

  /**
   * 流式 GET：把响应体分块交给 sink，而不是一次性把整张图放进 ArrayBuffer。
   *
   * API 26 依据：`Request.destination?: ResponseBodyDestination` 支持
   * `IncomingDataCallback = (incomingData: ArrayBuffer) => void | Promise<void>`
   * （@since 5.0.0(12)）。大图片因此不会整张驻留内存；DownloadManager 仍以
   * 并发上限（默认 3）限制同时驻留的 chunk 数。
   *
   * @param onRequestCreated 回调传出 rcp.Request，供下载层注册真正的取消动作
   */
  async streamToSink(url: string, headers: Record<string, string>,
    sink: (chunk: ArrayBuffer) => void | Promise<void>,
    onRequestCreated: (request: rcp.Request) => void): Promise<void> {
    const request: rcp.Request = new rcp.Request(url, 'GET', this.headers.merge(headers));
    request.destination = sink;
    onRequestCreated(request);
    await this.doRequest(url, request);
  }

  /**
   * GET 请求二进制数据（ImageCacheManager 图片下载专用）。
   * 经 RequestGate：断网挂起 → 恢复重放 → 有界退避重试（含 429 Retry-After），支持 CancelToken 取消在途 rcp.Request。
   * 防盗链 Header（referer / user-agent）由调用方按图片域名传入，优先级最高。
   */
  async getBytes(url: string, headers?: Record<string, string>,
    token?: CancelToken): Promise<Uint8Array> {
    const res: HttpBytesResult = await this.getBytesWithMeta(url, headers, token);
    return res.bytes;
  }

  async getBytesWithMeta(url: string, headers?: Record<string, string>,
    token?: CancelToken): Promise<HttpBytesResult> {
    const mergedHeaders: Record<string, string> = this.headers.merge(headers);
    const trace: NetworkTrace = NetworkLogManager.getInstance().begin('GET', url);
    try {
      return await RequestGate.getInstance().run<HttpBytesResult>('GET', url,
        new HttpBytesTransport(async (slot: RequestSlot<HttpBytesResult>): Promise<void> => {
          try {
            const request: rcp.Request = new rcp.Request(url, 'GET', mergedHeaders);
            const response: rcp.Response = await this.doRequest(url, request, trace, token);
            const body: ArrayBuffer | undefined = response.body;
            const bytes: Uint8Array = body === undefined ? new Uint8Array(0) : new Uint8Array(body);
            const ct: string = HttpManager.extractHeader(response.headers, 'content-type');
            trace.bytes = bytes.byteLength;
            slot.done = true;
            slot.value = new HttpBytesResult(bytes, response.statusCode, ct);
          } catch (e) {
            slot.done = false;
            slot.errorObj = e as Object;
          }
        }), token);
    } catch (e) {
      throw HttpManager.normalizeGate(e);
    } finally {
      NetworkLogManager.getInstance().end(trace);
    }
  }

  // ==================== 配置与管理 API ====================

  /** 设置/覆盖一条全局默认 Header（如 UA、Referer），对所有后续请求生效 */
  setGlobalHeader(name: string, value: string): void {
    this.headers.setGlobalHeader(name, value);
  }

  /** 移除一条全局默认 Header */
  removeGlobalHeader(name: string): void {
    this.headers.removeGlobalHeader(name);
  }

  /** 注册动态 Header 提供器 —— 后续注入 Token / Cookie 的统一入口 */
  addHeaderProvider(provider: HeaderProvider): void {
    this.headers.addProvider(provider);
  }

  /** 注销动态 Header 提供器 */
  removeHeaderProvider(provider: HeaderProvider): void {
    this.headers.removeProvider(provider);
  }

  /** 切换源站基地址（多源扩展用；将销毁并重建会话） */
  setBaseAddress(base: string): void {
    if (this.baseAddress !== base) {
      this.baseAddress = base;
      this.createSession();
      Logger.info(TAG, `基地址已切换: ${base}`);
    }
  }

  /** 销毁会话，释放底层连接资源（一般在应用退出时调用） */
  destroy(): void {
    if (this.session !== undefined) {
      this.session.close();
      this.session = undefined;
      Logger.info(TAG, '会话已销毁');
    }
  }

  // ==================== 内部工具方法 ====================

  /** 统一 JSON 解析：失败时抛出 HttpError(-1)，方便业务层统一捕获 */
  private static parseJson<T>(text: string): T {
    try {
      return JSON.parse(text) as T;
    } catch (e) {
      throw new HttpError(-1, `JSON 解析失败: ${sanitizeText(text.substring(0, 128))}`, 'parse');
    }
  }

  /**
   * 闸门拒绝归一化为 HttpError（-4），保持业务层统一异常模型：
   * 断网拒绝 / 重放上限 / 等待超时对调用方显示为普通网络失败，不泄露内部状态机。
   */
  private static normalizeGate(e: Object): Error {
    if (e instanceof GateRejectedError) {
      return new HttpError(-4, e.message);
    }
    if (e instanceof Error) {
      return e;
    }
    return new Error(String(e));
  }

  /**
   * 是否为 NoyAcg 站内 API 请求（同源 `https://noymanga.com/api/`）。
   * 只有此类请求才注入 `allow-adult`；图片 CDN / 图床 / 外部域名一律不注入。
   */
  static isNoyApiUrl(url: string): boolean {
    return isNoyApiUrl(url);
  }

  /**
   * 站内 API 请求统一注入内容分级头 `allow-adult`（全局策略唯一来源）。
   * 委托给纯函数 `resolveContentRatingHeader`（Phase 14-T），使该规则可被单测直接证明。
   */
  private withApiHeaders(url: string, headers?: Record<string, string>): Record<string, string> | undefined {
    return resolveContentRatingHeader(url, headers);
  }

  /**
   * 暴露给集成测试的请求头解析入口（Phase 14-T1）。
   *
   * 它就是 `get / getString / post / postForm` 四条真实请求路径在构建 `rcp.Request` 时
   * **唯一**调用的 header 注入函数（见本类各方法内的 `this.withApiHeaders(url, ...)`）。
   * 单测直接通过它验证「分级 A → B 后再次解析得到 B」，等价于证明真实请求会携带新分级，
   * 而不必起一个真实的 rcp 网络会话（测试运行时无系统网络能力）。
   */
  static buildRequestHeaders(url: string,
    headers?: Record<string, string>): Record<string, string> | undefined {
    return resolveContentRatingHeader(url, headers);
  }

  /**
   * 拼接完整请求 URL
   * 1. path 为绝对地址（http/https 开头）时直接使用 —— 跨域图片等场景；
   * 2. 相对路径拼接到基地址；
   * 3. 查询参数逐项 encodeURIComponent 后拼接。
   */
  private static buildUrl(base: string, path: string, params?: Record<string, string>): string {
    let url: string;
    if (path.startsWith('http://') || path.startsWith('https://')) {
      url = path;
    } else {
      url = base + (path.startsWith('/') ? path : '/' + path);
    }
    if (params !== undefined) {
      const keys: string[] = Object.keys(params);
      if (keys.length > 0) {
        const parts: string[] = [];
        for (let i = 0; i < keys.length; i++) {
          const key: string = keys[i];
          parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(params[key])}`);
        }
        url += (url.indexOf('?') >= 0 ? '&' : '?') + parts.join('&');
      }
    }
    return url;
  }

  private static extractHeader(headers: rcp.ResponseHeaders | undefined, name: string): string {
    if (headers === undefined || headers === null) {
      return '';
    }
    const val: string | string[] | undefined = headers[name.toLowerCase()];
    if (typeof val === 'string') {
      return val;
    }
    if (Array.isArray(val) && val.length > 0 && typeof val[0] === 'string') {
      return val[0];
    }
    return '';
  }

  /**
   * 统一执行请求：日志 + 状态码校验 + 异常归一化为 HttpError
   * 非常警惕：此方法是全 App 唯一真正触碰 rcp.Session 的出口。
   */
  private async doRequest(url: string, request: rcp.Request,
    trace?: NetworkTrace, token?: CancelToken): Promise<rcp.Response> {
    if (token !== undefined && token.isCanceled()) {
      throw new RequestCanceledError();
    }
    if (this.session === undefined) {
      this.createSession();
    }
    const safeUrl: string = sanitizeText(url);
    Logger.debug(TAG, `--> ${request.method} ${safeUrl}`);
    let unregisterCancel: (() => void) | undefined = undefined;
    if (token !== undefined) {
      unregisterCancel = token.onCancel((): void => {
        this.cancelRequest(request);
      });
    }
    try {
      const response: rcp.Response = await this.session!.fetch(request);
      Logger.debug(TAG, `<-- ${response.statusCode} ${safeUrl}`);
      if (trace !== undefined) {
        trace.statusCode = response.statusCode;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        const retryAfterRaw: string = HttpManager.extractHeader(response.headers, 'retry-after');
        const retryAfterMs: number | undefined = parseRetryAfterMs(retryAfterRaw);
        throw new HttpError(response.statusCode, `请求失败 (HTTP ${response.statusCode}): ${safeUrl}`,
          'http', retryAfterMs);
      }
      return response;
    } catch (e) {
      if (e instanceof RequestCanceledError) {
        throw e;
      }
      // 已是统一异常模型则直接透传
      if (e instanceof HttpError) {
        if (trace !== undefined) {
          trace.statusCode = e.statusCode > 0 ? e.statusCode : trace.statusCode;
          trace.error = e.statusCode > 0 ? `HTTP ${e.statusCode}` : 'request failed';
        }
        throw e;
      }
      const err = e as BusinessError;
      if (trace !== undefined) {
        trace.error = `network ${err.code}`;
      }
      Logger.error(TAG, `网络异常 ${err.code}: ${err.message} (${safeUrl})`);
      // 取消码（rcp Session.cancel 后 fetch 抛 1007900992）标注 hint='cancel'：取消绝不重试
      throw new HttpError(err.code, `网络异常: ${err.message}`,
        err.code === 1007900992 ? 'cancel' : 'network');
    } finally {
      if (unregisterCancel !== undefined) {
        unregisterCancel();
      }
    }
  }
}
