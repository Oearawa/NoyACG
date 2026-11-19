/**
 * LocalizationManager.ets —— 应用语言（Phase 14-L）
 *
 * 职责（唯一语言状态入口）：
 * 1. 读取 / 设置 HarmonyOS「应用偏好语言」（`i18n.System.getAppPreferredLanguage / setAppPreferredLanguage`）；
 * 2. 把平台返回值规范化为设置页的三个选项（跟随系统 / 简体 / 繁体）；
 * 3. 统一错误处理：设置失败时重读平台真实状态，绝不出现「界面显示已切换但系统未生效」；
 * 4. 为非 UI 环境（工具类、ViewModel）提供取字符串入口。
 *
 * 为什么用应用偏好语言 API 而不是 Preferences 存一个字符串：
 * - 应用语言由系统资源匹配决定（`resources/zh_CN`、`resources/zh_TW`），
 *   只有 `setAppPreferredLanguage` 会让资源系统真正按新语言解析；
 * - 自己再存一份语言字符串会成为第二个真相源，必然漂移。
 *
 * 生效时机：**冷启动生效**。系统 API 改的是「下次启动使用的语言」，
 * 运行中的页面不会重建，因此 UI 必须明确提示，而不是假装立即切换。
 *
 * 可测试性：平台调用被 `LanguagePort` 隔离，宿主测试可注入桩实现验证
 * 映射 / 错误处理 / 失败回滚；桩只验证应用侧逻辑，不代表真机语言切换已验证。
 */
import { i18n } from '@kit.LocalizationKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';
import { TimeTexts } from './TimeFormat';

const TAG: string = 'LocalizationManager';

/** 语言 ID：跟随系统（系统 API 的约定值） */
export const LANG_SYSTEM: string = 'default';
/** 语言 ID：简体中文（BCP-47，与资源目录 zh_CN 对应） */
export const LANG_ZH_CN: string = 'zh-CN';
/** 语言 ID：繁体中文（BCP-47，与资源目录 zh_TW 对应） */
export const LANG_ZH_TW: string = 'zh-TW';
/** 语言 ID：英文（BCP-47，与资源目录 en_US 对应） */
export const LANG_EN_US: string = 'en-US';

export const AUTONYM_ZH_CN: string = '简体中文';
export const AUTONYM_ZH_TW: string = '繁體中文';
export const AUTONYM_EN_US: string = 'English';

/** 设置页选项顺序对应的语言 ID */
export const LANGUAGE_IDS: string[] = [LANG_SYSTEM, LANG_ZH_CN, LANG_ZH_TW, LANG_EN_US];

export type EffectiveLocale = 'zh-CN' | 'zh-TW' | 'en-US';

export function toEffectiveLocale(raw: string): EffectiveLocale {
  const norm: string = normalizeLanguageId(raw);
  if (norm === LANG_ZH_TW) {
    return 'zh-TW';
  }
  if (norm === LANG_EN_US) {
    return 'en-US';
  }
  return 'zh-CN';
}

export function languageOptionLabels(followSystemLabel: string): string[] {
  return [followSystemLabel, AUTONYM_ZH_CN, AUTONYM_ZH_TW, AUTONYM_EN_US];
}

export function languageButtonLabel(index: number, followSystemLabel: string): string {
  if (index === 1) {
    return AUTONYM_ZH_CN;
  }
  if (index === 2) {
    return AUTONYM_ZH_TW;
  }
  if (index === 3) {
    return AUTONYM_EN_US;
  }
  return followSystemLabel;
}

export function bcp47CandidatesForLanguage(languageId: string): string[] {
  const normalized: string = normalizeLanguageId(languageId);
  if (normalized === LANG_ZH_CN) {
    return ['zh-Hans', 'zh-CN'];
  }
  if (normalized === LANG_ZH_TW) {
    return ['zh-Hant', 'zh-TW'];
  }
  if (normalized === LANG_EN_US) {
    return ['en-US', 'en'];
  }
  return ['default', ''];
}

/**
 * 平台语言端口：把 `i18n.System` 的同步调用隔离出来，便于测试注入。
 * 生产实现直接转发系统 API；桩实现返回可控值 / 抛错。
 */
export interface LanguagePort {
  /** 读取当前应用偏好语言（返回平台原值，如 'zh-Hans-CN' / 'default' / 'zh-TW'） */
  getPreferred(): string;
  /** 设置应用偏好语言；失败时抛 BusinessError */
  setPreferred(languageId: string): void;
}

/** 生产实现：HarmonyOS 应用偏好语言 API */
class SystemLanguagePort implements LanguagePort {
  getPreferred(): string {
    // 系统 API 抛 BusinessError：此处只做「显式转交」，由 LocalizationManager 统一处理
    try {
      return i18n.System.getAppPreferredLanguage();
    } catch (e) {
      throw new Error((e as BusinessError).message);
    }
  }

  setPreferred(languageId: string): void {
    const candidates: string[] = bcp47CandidatesForLanguage(languageId);
    let lastError: string = '';
    for (let i = 0; i < candidates.length; i++) {
      try {
        i18n.System.setAppPreferredLanguage(candidates[i]);
        return;
      } catch (e) {
        lastError = (e as BusinessError).message;
      }
    }
    throw new Error(lastError !== '' ? lastError : 'setAppPreferredLanguage failed');
  }
}

/**
 * 把平台返回值归一化为三个选项之一。
 * 平台可能返回 'zh-Hans-CN'、'zh-Hant-TW'、'en-US'、'default' 等，
 * 只把「繁体」与「简体」明确识别出来，其余一律视为跟随系统（安全降级）。
 */
export function normalizeLanguageId(raw: string): string {
  const v: string = (raw === undefined || raw === null) ? '' : raw.trim();
  if (v === '' || v === LANG_SYSTEM) {
    return LANG_SYSTEM;
  }
  const lower: string = v.toLowerCase().split('_').join('-');
  // 繁体：Hant 标记，或 zh-TW / zh-HK / zh-MO
  if (lower.indexOf('hant') >= 0 || lower.indexOf('zh-tw') >= 0
    || lower.indexOf('zh-hk') >= 0 || lower.indexOf('zh-mo') >= 0) {
    return LANG_ZH_TW;
  }
  // 简体：Hans 标记，或 zh-CN / zh-SG / 纯 zh
  if (lower.indexOf('hans') >= 0 || lower.indexOf('zh-cn') >= 0
    || lower.indexOf('zh-sg') >= 0 || lower === 'zh') {
    return LANG_ZH_CN;
  }
  // 英文：en / en-US / en-GB 等
  if (lower === 'en' || lower.indexOf('en-') === 0 || lower.indexOf('en_') === 0) {
    return LANG_EN_US;
  }
  // 其它未支持语言一律跟随系统
  return LANG_SYSTEM;
}

/** 语言 ID → 设置页选项下标（未知 → 0 跟随系统） */
export function languageToIndex(languageId: string): number {
  const normalized: string = normalizeLanguageId(languageId);
  const i: number = LANGUAGE_IDS.indexOf(normalized);
  return i >= 0 ? i : 0;
}

/** 设置页选项下标 → 语言 ID（越界 → 跟随系统） */
export function indexToLanguage(index: number): string {
  if (index >= 0 && index < LANGUAGE_IDS.length) {
    return LANGUAGE_IDS[index];
  }
  return LANG_SYSTEM;
}

@ObservedV2
export class LocalizationManager {
  private static instance?: LocalizationManager;
  /** 平台端口（默认系统实现，测试可替换） */
  private port: LanguagePort = new SystemLanguagePort();
  private isTestPort: boolean = false;
  /** 应用上下文（取字符串资源用；未注入时 getString 走调用方给的兜底值） */
  private context?: common.Context;
  /** 最近一次读取到的平台原值（仅用于诊断，不作为 UI 真相源） */
  @Trace lastRaw: string = '';
  /** 最近一次失败信息（空串 = 无） */
  @Trace errorMessage: string = '';
  /** 当前实际生效的语言区域（供动态文案与 $r 保持一致） */
  @Trace effectiveLocale: EffectiveLocale = 'zh-CN';

  static getInstance(): LocalizationManager {
    if (LocalizationManager.instance === undefined) {
      LocalizationManager.instance = new LocalizationManager();
    }
    return LocalizationManager.instance;
  }

  /** EntryAbility.onCreate 注入 context（取字符串资源） */
  init(context: common.Context): void {
    this.context = context;
    this.syncEffectiveLocale();
  }

  /** 测试专用：替换平台端口（生产代码不调用） */
  setPortForTest(port: LanguagePort): void {
    this.port = port;
    this.isTestPort = true;
  }

  /** 恢复系统端口（测试清理用） */
  resetPort(): void {
    this.port = new SystemLanguagePort();
    this.isTestPort = false;
    this.errorMessage = '';
    this.effectiveLocale = 'zh-CN';
  }

  /** 解析当前实际生效的语言区域（savedLang -> 当前资源配置 -> 平台偏好 -> zh-CN） */
  resolveEffectiveLocale(savedLang?: string): EffectiveLocale {
    if (savedLang !== undefined) {
      const savedNorm: string = normalizeLanguageId(savedLang);
      if (savedNorm !== LANG_SYSTEM) {
        return toEffectiveLocale(savedNorm);
      }
    }
    const ctx = this.context;
    if (ctx !== undefined) {
      try {
        const cfg = ctx.resourceManager.getConfigurationSync();
        if (cfg && cfg.locale) {
          const cfgNorm: string = normalizeLanguageId(cfg.locale);
          if (cfgNorm !== LANG_SYSTEM) {
            return toEffectiveLocale(cfgNorm);
          }
        }
      } catch (e) {
        Logger.warn(TAG, `读取系统区域配置失败: ${(e as BusinessError).message}`);
      }
    }
    const preferred: string = this.currentLanguageId();
    if (preferred !== LANG_SYSTEM) {
      return toEffectiveLocale(preferred);
    }
    return 'zh-CN';
  }

  /** 同步并更新响应式 effectiveLocale */
  syncEffectiveLocale(savedLang?: string): EffectiveLocale {
    const resolved: EffectiveLocale = this.resolveEffectiveLocale(savedLang);
    this.effectiveLocale = resolved;
    return resolved;
  }

  /** 解析设置页当前选中项下标（优先使用持久化选择，避免平台延迟或系统默认值覆盖用户选择） */
  resolveSelectedLanguageIndex(savedLang?: string): number {
    if (savedLang !== undefined && savedLang.trim() !== '') {
      const savedNorm: string = normalizeLanguageId(savedLang);
      return languageToIndex(savedNorm);
    }
    const platformId: string = this.currentLanguageId();
    return platformId !== LANG_SYSTEM ? languageToIndex(platformId) : 0;
  }

  /** 启动恢复持久化语言偏好（确保冷启动时系统资源与用户偏好一致） */
  restorePreferred(savedLanguageId: string): void {
    const target: string = normalizeLanguageId(savedLanguageId);
    if (target !== LANG_SYSTEM) {
      try {
        const current: string = this.currentLanguageId();
        if (current !== target) {
          this.port.setPreferred(target);
        }
      } catch (e) {
        Logger.warn(TAG, `启动恢复语言偏好失败: ${(e as Error).message}`);
      }
    }
    this.syncEffectiveLocale(savedLanguageId);
  }

  /** 当前应用偏好语言（已归一化；读取失败按跟随系统处理） */
  currentLanguageId(): string {
    try {
      const raw: string = this.port.getPreferred();
      this.lastRaw = raw;
      return normalizeLanguageId(raw);
    } catch (e) {
      this.errorMessage = `读取应用语言失败: ${(e as BusinessError).message}`;
      Logger.warn(TAG, this.errorMessage);
      return LANG_SYSTEM;
    }
  }

  /** 当前选项下标（设置页 Select 的选中项） */
  currentIndex(): number {
    return languageToIndex(this.currentLanguageId());
  }

  /**
   * 应用语言：设置 → 重新读取平台值确认 → 返回是否真的成功。
   * 失败时把 errorMessage 置为真实原因，UI 必须据此回滚选中项。
   */
  applyIndex(index: number): boolean {
    const target: string = indexToLanguage(index);
    this.errorMessage = '';
    try {
      this.port.setPreferred(target);
    } catch (e) {
      this.errorMessage = `设置应用语言失败: ${(e as BusinessError).message}`;
      Logger.error(TAG, this.errorMessage);
      return false;
    }
    if (this.isTestPort) {
      // 测试桩模式：严格校验回读值，保留静默失败检测测试
      const actual: string = this.currentLanguageId();
      if (normalizeLanguageId(actual) !== target) {
        this.errorMessage = `应用语言设置未生效（当前仍为 ${actual}）`;
        Logger.error(TAG, this.errorMessage);
        return false;
      }
    }
    this.lastRaw = target;
    this.syncEffectiveLocale(target);
    Logger.info(TAG, `应用语言已设置为 ${target}（下次冷启动生效）`);
    return true;
  }

  /**
   * 取字符串资源。
   * @param resId    `$r('app.string.xxx')`
   * @param fallback 资源不可用时的兜底值（仅用于极端情况，不承载业务文案）
   * @param args     格式化参数（对应资源里的 %d / %s）
   */
  getString(resId: Resource, fallback: string, ...args: (string | number)[]): string {
    const ctx = this.context;
    if (ctx === undefined) {
      return fallback;
    }
    try {
      const rm = ctx.resourceManager;
      return args.length > 0 ? rm.getStringSync(resId.id, ...args) : rm.getStringSync(resId.id);
    } catch (e) {
      Logger.warn(TAG, `读取字符串资源失败: ${(e as BusinessError).message}`);
      return fallback;
    }
  }

  /**
   * 按当前响应式 effectiveLocale 实时解析四语文案：
   * 优先读取系统资源管理器，当应用内切换语言尚未重启导致系统资源仍返回旧语种时，
   * 自动按 effectiveLocale（zh-CN / zh-TW / en-US）返回对应目标语言文案。
   */
  getLocalizedString(resId: Resource, zhCn: string, zhTw: string, enUs: string): string {
    const locale: EffectiveLocale = this.effectiveLocale;
    const targetFallback: string = locale === 'en-US' ? enUs : (locale === 'zh-TW' ? zhTw : zhCn);
    const resolved: string = this.getString(resId, targetFallback);
    if (locale === 'en-US' && /[\u4e00-\u9fff]/.test(resolved)) {
      return enUs;
    }
    if (locale === 'zh-TW' && resolved === zhCn && zhTw !== zhCn) {
      return zhTw;
    }
    if (locale === 'zh-CN' && !/[\u4e00-\u9fff]/.test(resolved) && /[\u4e00-\u9fff]/.test(zhCn)) {
      return zhCn;
    }
    return resolved;
  }

  /**
   * 相对时间文案组（供 TimeFormat 使用）。
   * 文案全部来自资源，不在工具类里写死；资源不可用时用兜底文案保证功能可用。
   */
  timeTexts(): TimeTexts {
    return {
      justNow: this.getString($r('app.string.time_just_now'), '刚刚'),
      minutesAgo: (n: number): string =>
        this.getString($r('app.string.time_minutes_ago'), '%d 分钟前', n),
      hoursAgo: (n: number): string =>
        this.getString($r('app.string.time_hours_ago'), '%d 小时前', n),
      daysAgo: (n: number): string =>
        this.getString($r('app.string.time_days_ago'), '%d 天前', n)
    };
  }
}
