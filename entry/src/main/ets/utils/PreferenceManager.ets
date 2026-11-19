/**
 * PreferenceManager.ets —— 轻量级偏好设置管理器（单例 · 状态管理 V2）
 *
 * 基于 @kit.ArkData 的 Preferences（API 26 原生），只存「小体积、高频读、低频写」的
 * 用户偏好：阅读方向、搜索历史。禁止在此存放密码 / Cookie / Token 等敏感信息。
 *
 * 设计要点：
 * 1. 单例 + 幂等初始化：EntryAbility.onCreate 调用一次 init(context)，
 *    页面侧只读 sync 快照，避免每次翻页都触达 Preferences（IO 抖动）；
 * 2. 内存快照即真理源：写成功后才更新 @Trace 字段（UI 立即响应），
 *    写失败保留旧值并上抛错误，绝不出现「UI 显示已切换但磁盘没落」的假状态；
 * 3. 读取失败 / 非法值一律回退默认值（垂直阅读、空历史），不让脏数据卡死启动；
 * 4. 类被 @ObservedV2 装饰：阅读方向与搜索历史是跨页面共享的 UI 状态，
 *    用 @Trace 让 ProfilePage / ComicReader 直接响应变化，无需层层回调。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { TIME_FORMAT_ABSOLUTE, normalizeTimeFormat } from './TimeFormat';
import { THEME_MODE_SYSTEM, normalizeThemeMode } from './ThemeMode';
import { DEFAULT_THEME_ACCENT, ThemeAccentId, normalizeThemeAccent } from './ThemeAccent';
import { ReaderMode } from '../reader/ReaderTypes';
import { Logger } from './Logger';
import {
  BLOCKED_SCOPE_ANON,
  BlockedTagSet,
  blockedScopeOf,
  blockedTagsStorageKey
} from './BlockedTags';

const TAG: string = 'PreferenceManager';
/** 首选项文件名（应用私有沙盒内） */
const STORE_NAME: string = 'noyacg_settings';
/** 阅读方向键 */
const KEY_READ_DIRECTION: string = 'reader_direction';
/** 阅读器精确阅读模式键（默认由左至右 PAGE_LTR） */
const KEY_READER_MODE: string = 'reader_mode';

export function normalizeReaderMode(raw: string): ReaderMode {
  if (raw === ReaderMode.VERTICAL_STRIP) {
    return ReaderMode.VERTICAL_STRIP;
  }
  if (raw === ReaderMode.PAGE_RTL) {
    return ReaderMode.PAGE_RTL;
  }
  return ReaderMode.PAGE_LTR;
}
/** 搜索历史键（Array<string>，最近使用在前） */
const KEY_SEARCH_HISTORY: string = 'search_history';
/** 内容分级键（allow-adult 请求头取值） */
const KEY_CONTENT_RATING: string = 'content_rating';
/** 社区成人内容显式年龄确认标记（仅用户手动弹窗确认开启后才为 true，默认 false） */
const KEY_COMMUNITY_ADULT_CONFIRMED: string = 'community_adult_confirmed';
/** 导航栏可配置页签开关（默认全部开启） */
const KEY_NAV_SHOW_LATEST: string = 'nav_show_latest';
const KEY_NAV_SHOW_COMMUNITY: string = 'nav_show_community';
const KEY_NAV_SHOW_SHELF: string = 'nav_show_shelf';
/** 时间显示格式键（Phase 14-K） */
const KEY_TIME_FORMAT: string = 'time_format';
/** 主题模式键（Phase 14-M） */
const KEY_THEME_MODE: string = 'theme_mode';
/** 柔和主题强调色键 */
const KEY_THEME_ACCENT: string = 'theme_accent';
/** 应用语言偏好键 */
const KEY_APP_LANGUAGE: string = 'app_language';
/** 图片缓存容量上限键（Phase 14-R；-1 = 无限制） */
const KEY_CACHE_LIMIT: string = 'image_cache_limit_bytes';
/** 阅读器屏幕方向锁定键 */
const KEY_ORIENTATION_LOCK: string = 'reader_orientation_lock';
/** 阅读器音量键翻页开关键 */
const KEY_VOLUME_KEY_PAGE_TURN: string = 'reader_volume_key_page_turn';
/** 阅读器双击缩放开关键（默认开启） */
const KEY_DOUBLE_TAP_ZOOM: string = 'reader_double_tap_zoom';
/** 阅读器点击翻页动画开关键（默认开启） */
const KEY_PAGE_TURN_ANIMATION: string = 'reader_page_turn_animation';
/** 应用语言默认值（跟随系统） */
export const DEFAULT_APP_LANGUAGE: string = 'default';
/** 每日签到日期键前缀（按 UID 隔离） */
const KEY_SIGN_IN_DATE_PREFIX: string = 'daily_sign_in_date_';
/** 每日签到提醒开关键 */
const KEY_SIGN_IN_REMINDER_ENABLED: string = 'daily_sign_in_reminder_enabled';
/** 每日签到提醒时间键（HH:mm） */
const KEY_SIGN_IN_REMINDER_TIME: string = 'daily_sign_in_reminder_time';
/** 默认每日签到提醒时间 */
export const DEFAULT_SIGN_IN_REMINDER_TIME: string = '07:00';
/** 搜索历史最大条目数 */
const MAX_HISTORY_SIZE: number = 20;

export interface ReminderTimeParts {
  hour: number;
  minute: number;
}

/** 格式化 24 小时制提醒时间（HH:mm） */
export function formatReminderTime(hour: number, minute: number): string {
  const safeHour: number = Math.max(0, Math.min(23, Math.floor(Number.isFinite(hour) ? hour : 7)));
  const safeMinute: number = Math.max(0, Math.min(59, Math.floor(Number.isFinite(minute) ? minute : 0)));
  const hh: string = String(safeHour).padStart(2, '0');
  const mm: string = String(safeMinute).padStart(2, '0');
  return `${hh}:${mm}`;
}

/** 规范化 24 小时制提醒时间字符串，非法输入回退默认值 '07:00' */
export function normalizeReminderTime(value: string): string {
  if (!value || typeof value !== 'string') {
    return DEFAULT_SIGN_IN_REMINDER_TIME;
  }
  const trimmed: string = value.trim();
  const match: RegExpExecArray | null = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(trimmed);
  if (!match) {
    return DEFAULT_SIGN_IN_REMINDER_TIME;
  }
  return `${match[1]}:${match[2]}`;
}

/** 解析提醒时间为时分数字 */
export function parseReminderTime(value: string): ReminderTimeParts {
  const normalized: string = normalizeReminderTime(value);
  const parts: string[] = normalized.split(':');
  const hour: number = Number.parseInt(parts[0], 10);
  const minute: number = Number.parseInt(parts[1], 10);
  return {
    hour: Number.isFinite(hour) ? hour : 7,
    minute: Number.isFinite(minute) ? minute : 0
  };
}

/** 返回本地自然日 YYYY-MM-DD */
export function localDateKey(now: Date = new Date()): string {
  const y: number = now.getFullYear();
  const m: string = String(now.getMonth() + 1).padStart(2, '0');
  const d: string = String(now.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

/** 图片缓存容量上限默认值：1 GB（既有行为为「无硬上限」，给一个明确默认更安全） */
export const DEFAULT_CACHE_LIMIT_BYTES: number = 1073741824;
/** 「无限制」的内部值 */
export const CACHE_LIMIT_UNLIMITED: number = -1;
/** 允许的缓存上限取值（UI 只提供这三档；其他值一律回退默认） */
export const CACHE_LIMIT_OPTIONS: number[] = [524288000, 1073741824, CACHE_LIMIT_UNLIMITED];

/** 校验缓存上限：只接受三档合法值，其余回退默认（防止脏值让清理逻辑失控） */
export function normalizeCacheLimit(value: number): number {
  if (CACHE_LIMIT_OPTIONS.indexOf(value) >= 0) {
    return value;
  }
  return DEFAULT_CACHE_LIMIT_BYTES;
}

/** 阅读方向：垂直滚动 / 水平翻页 */
export enum ReadDirection {
  VERTICAL = 'vertical',
  HORIZONTAL = 'horizontal'
}

/** 阅读器屏幕方向锁定模式 */
export enum OrientationLockMode {
  SYSTEM = 'system',
  PORTRAIT = 'portrait',
  LANDSCAPE = 'landscape'
}

/**
 * 内容分级（allow-adult 请求头）。Phase 14-I 新增：
 * `false` = 全年龄（安全默认）、`true` = R18、`both` = 混合。
 * 首方实测：`false`/`true` 是两套互斥内容池；`/api/home` 不传头等同 `true`（默认 R18），
 * 因此业务层**必须**从本设置显式取值传递，绝不允许省略。
 */
export class ContentRating {
  static readonly ALL_AGES: string = 'false';
  static readonly ADULT: string = 'true';
  static readonly BOTH: string = 'both';
  /** 合法取值集合（用于校验，避免脏值发给服务端） */
  static readonly VALUES: string[] = [ContentRating.ALL_AGES, ContentRating.ADULT, ContentRating.BOTH];
}

@ObservedV2
export class PreferenceManager {
  private static instance?: PreferenceManager;

  /** Preferences 实例（init 完成后可用） */
  private store?: preferences.Preferences;
  /** 初始化任务（幂等：并发调用共享同一 Promise） */
  private initTask?: Promise<void>;

  /** 阅读方向（默认水平阅读，UI 直接观察） */
  @Trace readDirection: ReadDirection = ReadDirection.HORIZONTAL;
  /** 阅读器精确阅读模式（默认由左至右 PAGE_LTR） */
  @Trace readerMode: ReaderMode = ReaderMode.PAGE_LTR;
  /** 搜索历史（最近使用在前，最多 MAX_HISTORY_SIZE 条） */
  @Trace searchHistory: string[] = [];
  /** 内容分级（默认全年龄；业务层据此传 allow-adult 头） */
  @Trace contentRating: string = ContentRating.ALL_AGES;
  /** 社区成人内容显式确认标记（默认关闭；确认前社区请求一律传 allow-adult: false） */
  @Trace communityAdultConfirmed: boolean = false;
  /** 导航栏自定义页签开关（主页与用户固定开启） */
  @Trace navShowLatest: boolean = true;
  @Trace navShowCommunity: boolean = true;
  @Trace navShowShelf: boolean = true;
  /** 时间显示格式（Phase 14-K，默认绝对时间；历史/下载页据此格式化） */
  @Trace timeFormat: string = TIME_FORMAT_ABSOLUTE;
  /** 主题模式（Phase 14-M，默认跟随系统） */
  @Trace themeMode: string = THEME_MODE_SYSTEM;
  /** 柔和主题强调色（默认青瓷绿 celadon_sage） */
  @Trace themeAccent: ThemeAccentId = DEFAULT_THEME_ACCENT;
  /** 应用语言偏好（default 跟随系统 / zh-CN / zh-TW / en-US） */
  @Trace appLanguage: string = DEFAULT_APP_LANGUAGE;
  /**
   * 当前作用域的标签黑名单（Phase 14-R）。
   * 存的是**归一化后**的值；未登录 = 匿名作用域，登录后按 uid 隔离。
   */
  @Trace blockedTags: string[] = [];
  /** 当前标签黑名单所属作用域（anon 或 uid；仅用于 UI 提示，不参与网络请求） */
  @Trace blockedScope: string = BLOCKED_SCOPE_ANON;
  /** 图片缓存容量上限（字节；-1 = 无限制） */
  @Trace cacheLimitBytes: number = DEFAULT_CACHE_LIMIT_BYTES;
  /** 阅读器屏幕方向锁定偏好（默认跟随系统） */
  @Trace orientationLock: OrientationLockMode = OrientationLockMode.SYSTEM;
  /** 阅读器音量键翻页开关（默认关闭） */
  @Trace volumeKeyPageTurn: boolean = false;
  /** 阅读器双击缩放开关（默认开启） */
  @Trace doubleTapZoomEnabled: boolean = true;
  /** 阅读器点击翻页动画开关（默认开启） */
  @Trace pageTurnAnimationEnabled: boolean = true;
  /** 每日签到提醒开关（默认关闭） */
  @Trace signInReminderEnabled: boolean = false;
  /** 每日签到提醒时间（HH:mm，默认 '07:00'） */
  @Trace signInReminderTime: string = DEFAULT_SIGN_IN_REMINDER_TIME;

  private constructor() {
  }

  static getInstance(): PreferenceManager {
    if (PreferenceManager.instance === undefined) {
      PreferenceManager.instance = new PreferenceManager();
    }
    return PreferenceManager.instance;
  }

  /**
   * 初始化（EntryAbility.onCreate 调用一次）。
   * 幂等：重复调用返回同一 Promise；失败不抛给调用方（启动流程不能因偏好文件损坏而中断）。
   */
  init(context: common.Context): Promise<void> {
    if (this.initTask !== undefined) {
      return this.initTask;
    }
    this.initTask = this.doInit(context);
    return this.initTask;
  }

  private async doInit(context: common.Context): Promise<void> {
    try {
      const options: preferences.Options = { name: STORE_NAME };
      this.store = await preferences.getPreferences(context, options);
      this.loadFromStore();
      Logger.info(TAG,
        `偏好初始化完成: 方向=${this.readDirection}, 历史=${this.searchHistory.length}条`);
    } catch (e) {
      // 初始化失败：保留内存默认值，功能降级为「仅本次会话生效」
      Logger.error(TAG, `偏好初始化失败，使用默认值: ${(e as BusinessError).message}`);
    }
  }

  /** 等待初始化完成（页面在极端时序下需要确保拿到磁盘值时可 await） */
  async ensureReady(): Promise<boolean> {
    if (this.initTask !== undefined) {
      try {
        await this.initTask;
      } catch (e) {
        Logger.warn(TAG, `等待偏好初始化失败: ${(e as BusinessError).message}`);
      }
    }
    return this.store !== undefined;
  }

  /** 从磁盘读取全部偏好到内存快照（读失败 / 非法值均回退默认值） */
  private loadFromStore(): void {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    // ---------- 阅读方向与模式 ----------
    let direction: string = ReadDirection.HORIZONTAL;
    try {
      direction = store.getSync(KEY_READ_DIRECTION, ReadDirection.HORIZONTAL) as string;
    } catch (e) {
      Logger.warn(TAG, `读取阅读方向失败，回退水平: ${(e as BusinessError).message}`);
    }
    this.readDirection = direction === ReadDirection.VERTICAL
      ? ReadDirection.VERTICAL : ReadDirection.HORIZONTAL;

    const fallbackMode: string = this.readDirection === ReadDirection.VERTICAL
      ? ReaderMode.VERTICAL_STRIP : ReaderMode.PAGE_LTR;
    let savedReaderMode: string = fallbackMode;
    try {
      const rawMode: preferences.ValueType = store.getSync(KEY_READER_MODE, fallbackMode);
      if (typeof rawMode === 'string' && rawMode.trim() !== '') {
        savedReaderMode = rawMode.trim();
      }
    } catch (e) {
      Logger.warn(TAG, `读取阅读模式失败，回退由左至右: ${(e as BusinessError).message}`);
    }
    this.readerMode = normalizeReaderMode(savedReaderMode);

    // ---------- 搜索历史 ----------
    let history: string[] = [];
    try {
      const raw: preferences.ValueType = store.getSync(KEY_SEARCH_HISTORY, []);
      if (Array.isArray(raw)) {
        history = this.sanitizeHistory(raw as string[]);
      }
    } catch (e) {
      Logger.warn(TAG, `读取搜索历史失败，回退空历史: ${(e as BusinessError).message}`);
    }
    this.searchHistory = history;

    // ---------- 内容分级 ----------
    let rating: string = ContentRating.ALL_AGES;
    try {
      const rawRating: preferences.ValueType = store.getSync(KEY_CONTENT_RATING, ContentRating.ALL_AGES);
      if (typeof rawRating === 'string') {
        rating = rawRating;
      }
    } catch (e) {
      Logger.warn(TAG, `读取内容分级失败，回退全年龄: ${(e as BusinessError).message}`);
    }
    this.contentRating = ContentRating.VALUES.indexOf(rating) >= 0 ? rating : ContentRating.ALL_AGES;

    // ---------- 社区成人内容显式确认标记 ----------
    let adultConfirmed: boolean = false;
    try {
      const rawConfirmed: preferences.ValueType = store.getSync(KEY_COMMUNITY_ADULT_CONFIRMED, false);
      if (typeof rawConfirmed === 'boolean') {
        adultConfirmed = rawConfirmed;
      }
    } catch (e) {
      Logger.warn(TAG, `读取社区成人内容确认状态失败，回退关闭: ${(e as BusinessError).message}`);
    }
    this.communityAdultConfirmed = adultConfirmed;

    // ---------- 导航栏可配置页签 ----------
    let showLatest: boolean = true;
    let showCommunity: boolean = true;
    let showShelf: boolean = true;
    try {
      const rawLatest: preferences.ValueType = store.getSync(KEY_NAV_SHOW_LATEST, true);
      if (typeof rawLatest === 'boolean') {
        showLatest = rawLatest;
      }
      const rawCommunity: preferences.ValueType = store.getSync(KEY_NAV_SHOW_COMMUNITY, true);
      if (typeof rawCommunity === 'boolean') {
        showCommunity = rawCommunity;
      }
      const rawShelf: preferences.ValueType = store.getSync(KEY_NAV_SHOW_SHELF, true);
      if (typeof rawShelf === 'boolean') {
        showShelf = rawShelf;
      }
    } catch (e) {
      Logger.warn(TAG, '读取导航栏开关失败，沿用默认全开');
    }
    this.navShowLatest = showLatest;
    this.navShowCommunity = showCommunity;
    this.navShowShelf = showShelf;

    // ---------- 时间显示格式（Phase 14-K） ----------
    let timeFormat: string = TIME_FORMAT_ABSOLUTE;
    try {
      const rawFormat: preferences.ValueType = store.getSync(KEY_TIME_FORMAT, TIME_FORMAT_ABSOLUTE);
      if (typeof rawFormat === 'string') {
        timeFormat = rawFormat;
      }
    } catch (e) {
      Logger.warn(TAG, `读取时间格式失败，回退绝对时间: ${(e as BusinessError).message}`);
    }
    this.timeFormat = normalizeTimeFormat(timeFormat);

    // ---------- 主题模式（Phase 14-M） ----------
    let themeMode: string = THEME_MODE_SYSTEM;
    try {
      const rawTheme: preferences.ValueType = store.getSync(KEY_THEME_MODE, THEME_MODE_SYSTEM);
      if (typeof rawTheme === 'string') {
        themeMode = rawTheme;
      }
    } catch (e) {
      Logger.warn(TAG, `读取主题模式失败，回退跟随系统: ${(e as BusinessError).message}`);
    }
    this.themeMode = normalizeThemeMode(themeMode);

    // ---------- 柔和主题强调色 ----------
    let themeAccent: string = DEFAULT_THEME_ACCENT;
    try {
      const rawAccent: preferences.ValueType = store.getSync(KEY_THEME_ACCENT, DEFAULT_THEME_ACCENT);
      if (typeof rawAccent === 'string') {
        themeAccent = rawAccent;
      }
    } catch (e) {
      Logger.warn(TAG, `读取主题颜色失败，回退默认青瓷绿: ${(e as BusinessError).message}`);
    }
    this.themeAccent = normalizeThemeAccent(themeAccent);

    // ---------- 应用语言偏好 ----------
    let appLang: string = DEFAULT_APP_LANGUAGE;
    try {
      const rawLang: preferences.ValueType = store.getSync(KEY_APP_LANGUAGE, DEFAULT_APP_LANGUAGE);
      if (typeof rawLang === 'string' && rawLang.trim() !== '') {
        appLang = rawLang.trim();
      }
    } catch (e) {
      Logger.warn(TAG, `读取应用语言失败，回退跟随系统: ${(e as BusinessError).message}`);
    }
    this.appLanguage = appLang;

    // ---------- 图片缓存容量上限（Phase 14-R） ----------
    let cacheLimit: number = DEFAULT_CACHE_LIMIT_BYTES;
    try {
      const rawLimit: preferences.ValueType = store.getSync(KEY_CACHE_LIMIT, DEFAULT_CACHE_LIMIT_BYTES);
      if (typeof rawLimit === 'number') {
        cacheLimit = rawLimit;
      }
    } catch (e) {
      Logger.warn(TAG, `读取缓存容量上限失败，回退默认: ${(e as BusinessError).message}`);
    }
    this.cacheLimitBytes = normalizeCacheLimit(cacheLimit);

    // ---------- 标签黑名单（Phase 14-R，默认匿名作用域） ----------
    // 登录态在 AuthManager 恢复会话后通过 applyBlockedTagScope(uid) 再切换，
    // 这里只保证冷启动瞬间有可用的匿名配置，避免「已登录用户先看到匿名黑名单」。
    this.blockedScope = BLOCKED_SCOPE_ANON;
    this.blockedTags = this.readBlockedTags(BLOCKED_SCOPE_ANON).toPersisted();

    // ---------- 阅读器方向锁定与音量键翻页 ----------
    let orientation: string = OrientationLockMode.SYSTEM;
    try {
      const rawOri: preferences.ValueType = store.getSync(KEY_ORIENTATION_LOCK, OrientationLockMode.SYSTEM);
      if (typeof rawOri === 'string') {
        orientation = rawOri;
      }
    } catch (e) {
      Logger.warn(TAG, `读取方向锁定失败，回退跟随系统: ${(e as BusinessError).message}`);
    }
    if (orientation === OrientationLockMode.PORTRAIT) {
      this.orientationLock = OrientationLockMode.PORTRAIT;
    } else if (orientation === OrientationLockMode.LANDSCAPE) {
      this.orientationLock = OrientationLockMode.LANDSCAPE;
    } else {
      this.orientationLock = OrientationLockMode.SYSTEM;
    }

    let volumeTurn: boolean = false;
    try {
      const rawVol: preferences.ValueType = store.getSync(KEY_VOLUME_KEY_PAGE_TURN, false);
      if (typeof rawVol === 'boolean') {
        volumeTurn = rawVol;
      }
    } catch (e) {
      Logger.warn(TAG, `读取音量键翻页开关失败，回退关闭: ${(e as BusinessError).message}`);
    }
    this.volumeKeyPageTurn = volumeTurn;

    let doubleTapZoom: boolean = true;
    try {
      const rawDtz: preferences.ValueType = store.getSync(KEY_DOUBLE_TAP_ZOOM, true);
      if (typeof rawDtz === 'boolean') {
        doubleTapZoom = rawDtz;
      }
    } catch (e) {
      Logger.warn(TAG, `读取双击缩放开关失败，回退开启: ${(e as BusinessError).message}`);
    }
    this.doubleTapZoomEnabled = doubleTapZoom;

    let pageTurnAnim: boolean = true;
    try {
      const rawPta: preferences.ValueType = store.getSync(KEY_PAGE_TURN_ANIMATION, true);
      if (typeof rawPta === 'boolean') {
        pageTurnAnim = rawPta;
      }
    } catch (e) {
      Logger.warn(TAG, `读取翻页动画开关失败，回退开启: ${(e as BusinessError).message}`);
    }
    this.pageTurnAnimationEnabled = pageTurnAnim;

    // ---------- 每日签到提醒设置 ----------
    let reminderEnabled: boolean = false;
    try {
      const rawRemEnabled: preferences.ValueType = store.getSync(KEY_SIGN_IN_REMINDER_ENABLED, false);
      if (typeof rawRemEnabled === 'boolean') {
        reminderEnabled = rawRemEnabled;
      }
    } catch (e) {
      Logger.warn(TAG, `读取签到提醒开关失败，回退关闭: ${(e as BusinessError).message}`);
    }
    this.signInReminderEnabled = reminderEnabled;

    let reminderTime: string = DEFAULT_SIGN_IN_REMINDER_TIME;
    try {
      const rawRemTime: preferences.ValueType = store.getSync(
        KEY_SIGN_IN_REMINDER_TIME,
        DEFAULT_SIGN_IN_REMINDER_TIME
      );
      if (typeof rawRemTime === 'string') {
        reminderTime = rawRemTime;
      }
    } catch (e) {
      Logger.warn(TAG, `读取签到提醒时间失败，回退默认: ${(e as BusinessError).message}`);
    }
    this.signInReminderTime = normalizeReminderTime(reminderTime);
  }

  /** 读取指定作用域的标签黑名单（读失败 / 脏数据 → 空集合，不抛异常） */
  private readBlockedTags(scope: string): BlockedTagSet {
    const store = this.store;
    if (store === undefined) {
      return BlockedTagSet.empty();
    }
    const key: string = blockedTagsStorageKey(scope === BLOCKED_SCOPE_ANON ? '' : scope);
    try {
      const raw: preferences.ValueType = store.getSync(key, []);
      if (Array.isArray(raw)) {
        return BlockedTagSet.fromPersisted(raw as string[]);
      }
    } catch (e) {
      Logger.warn(TAG, `读取标签黑名单失败，回退空: ${(e as BusinessError).message}`);
    }
    return BlockedTagSet.empty();
  }

  // ==================== 阅读方向 ====================

  /** 同步读取阅读方向（内存快照，不触达磁盘；未初始化时返回默认水平阅读） */
  getReadDirectionSync(): ReadDirection {
    return this.readDirection;
  }

  /** 同步读取精确阅读模式（默认由左至右 PAGE_LTR） */
  getReaderModeSync(): ReaderMode {
    return this.readerMode;
  }

  /** 保存精确阅读模式并同步阅读方向 */
  async setReaderMode(mode: ReaderMode): Promise<boolean> {
    const next: ReaderMode = normalizeReaderMode(mode);
    const dir: ReadDirection = next === ReaderMode.VERTICAL_STRIP
      ? ReadDirection.VERTICAL : ReadDirection.HORIZONTAL;
    this.readerMode = next;
    this.readDirection = dir;
    const store = this.store;
    if (store === undefined) {
      return false;
    }
    try {
      store.putSync(KEY_READER_MODE, next);
      store.putSync(KEY_READ_DIRECTION, dir);
      await store.flush();
      Logger.info(TAG, `阅读模式已保存: ${next}`);
      return true;
    } catch (e) {
      Logger.error(TAG, `阅读模式保存失败: ${(e as BusinessError).message}`);
      return false;
    }
  }

  /**
   * 保存阅读方向：先落盘、成功后再更新内存快照。
   * @returns true = 保存成功；false = 未初始化或写入失败（内存保持旧值）
   */
  async setReadDirection(dir: ReadDirection): Promise<boolean> {
    const nextMode: ReaderMode = dir === ReadDirection.VERTICAL
      ? ReaderMode.VERTICAL_STRIP
      : (this.readerMode === ReaderMode.VERTICAL_STRIP ? ReaderMode.PAGE_LTR : this.readerMode);
    const store = this.store;
    if (store === undefined) {
      Logger.warn(TAG, '偏好尚未初始化，阅读方向仅本次会话生效');
      this.readDirection = dir; // 降级：本次会话仍可切换，重启后失效
      this.readerMode = nextMode;
      return false;
    }
    try {
      store.putSync(KEY_READ_DIRECTION, dir);
      store.putSync(KEY_READER_MODE, nextMode);
      await store.flush();
      this.readDirection = dir;
      this.readerMode = nextMode;
      Logger.info(TAG, `阅读方向已保存: ${dir}`);
      return true;
    } catch (e) {
      Logger.error(TAG, `阅读方向保存失败: ${(e as BusinessError).message}`);
      return false;
    }
  }

  // ==================== 搜索历史 ====================

  /** 同步读取搜索历史快照（最近使用在前） */
  getSearchHistory(): string[] {
    return this.searchHistory;
  }

  /**
   * 追加一条搜索历史：去重（同词只保留最新位置）、最近使用在前、超过上限截断。
   * @returns 更新后的历史（写入失败时返回旧快照）
   */
  async addSearchHistory(keyword: string): Promise<string[]> {
    const text: string = keyword.trim();
    if (text === '') {
      return this.searchHistory;
    }
    const next: string[] = [text];
    for (let i = 0; i < this.searchHistory.length; i++) {
      if (this.searchHistory[i] !== text) {
        next.push(this.searchHistory[i]);
      }
    }
    const limited: string[] = next.length > MAX_HISTORY_SIZE
      ? next.slice(0, MAX_HISTORY_SIZE) : next;
    const ok: boolean = await this.persistHistory(limited);
    if (ok) {
      this.searchHistory = limited;
    }
    return this.searchHistory;
  }

  /** 删除单条搜索历史 */
  async removeSearchHistory(keyword: string): Promise<string[]> {
    const clean: string = keyword.trim();
    if (clean === '') {
      return this.searchHistory.slice();
    }
    const next: string[] = [];
    for (let i = 0; i < this.searchHistory.length; i++) {
      if (this.searchHistory[i] !== clean) {
        next.push(this.searchHistory[i]);
      }
    }
    const ok: boolean = await this.persistHistory(next);
    if (ok) {
      this.searchHistory = next;
    }
    return this.searchHistory.slice();
  }

  /** 清空搜索历史 */
  async clearSearchHistory(): Promise<boolean> {
    const ok: boolean = await this.persistHistory([]);
    if (ok) {
      this.searchHistory = [];
    }
    return ok;
  }

  // ==================== 内容分级 ====================

  /** 同步读取内容分级快照（内存态；未初始化返回默认全年龄） */
  getContentRatingSync(): string {
    return this.contentRating;
  }

  /**
   * 保存内容分级：先校验合法取值 → 落盘成功后再更新内存快照。
   * @returns true = 保存成功；false = 非法值或未初始化/写入失败（内存保持旧值）
   */
  async setContentRating(rating: string): Promise<boolean> {
    if (ContentRating.VALUES.indexOf(rating) < 0) {
      Logger.warn(TAG, `非法内容分级值被拒绝: ${rating}`);
      return false;
    }
    const store = this.store;
    if (store === undefined) {
      Logger.warn(TAG, '偏好尚未初始化，内容分级仅本次会话生效');
      this.contentRating = rating;
      return false;
    }
    try {
      store.putSync(KEY_CONTENT_RATING, rating);
      await store.flush();
      this.contentRating = rating;
      Logger.info(TAG, `内容分级已保存: ${rating}`);
      return true;
    } catch (e) {
      Logger.error(TAG, `内容分级保存失败: ${(e as BusinessError).message}`);
      return false;
    }
  }

  // ==================== 时间显示格式（Phase 14-K） ====================

  /** 同步读取时间格式（内存快照；未初始化时返回默认绝对时间） */
  getTimeFormatSync(): string {
    return this.timeFormat;
  }

  /**
   * 保存时间格式：先落盘、成功后再更新内存快照。
   * @returns true = 保存成功；false = 未初始化或写入失败（内存保持旧值）
   */
  async setTimeFormat(mode: string): Promise<boolean> {
    const next: string = normalizeTimeFormat(mode);
    const store = this.store;
    if (store === undefined) {
      Logger.warn(TAG, '偏好尚未初始化，时间格式仅本次会话生效');
      this.timeFormat = next; // 降级：本次会话仍可切换，重启后失效
      return false;
    }
    try {
      store.putSync(KEY_TIME_FORMAT, next);
      await store.flush();
      this.timeFormat = next;
      Logger.info(TAG, `时间格式已保存: ${next}`);
      return true;
    } catch (e) {
      Logger.error(TAG, `时间格式保存失败: ${(e as BusinessError).message}`);
      return false;
    }
  }

  // ==================== 主题模式（Phase 14-M） ====================

  /** 同步读取主题模式（内存快照；未初始化时返回 system） */
  getThemeModeSync(): string {
    return this.themeMode;
  }

  /** 同步读取主题颜色（默认 celadon_sage） */
  getThemeAccentSync(): ThemeAccentId {
    return this.themeAccent;
  }

  /** 同步读取应用语言偏好 */
  getAppLanguageSync(): string {
    return this.appLanguage;
  }

  /** 持久化应用语言偏好 */
  async setAppLanguage(lang: string): Promise<boolean> {
    const next: string = lang.trim() === '' ? DEFAULT_APP_LANGUAGE : lang.trim();
    this.appLanguage = next;
    const store = this.store;
    if (store === undefined) {
      return false;
    }
    try {
      store.putSync(KEY_APP_LANGUAGE, next);
      await store.flush();
      Logger.info(TAG, `应用语言已保存: ${next}`);
      return true;
    } catch (e) {
      Logger.error(TAG, `应用语言保存失败: ${(e as BusinessError).message}`);
      return false;
    }
  }

  /** 保存柔和主题颜色 */
  async setThemeAccent(accent: string): Promise<boolean> {
    const next: ThemeAccentId = normalizeThemeAccent(accent);
    this.themeAccent = next;
    const store = this.store;
    if (store === undefined) {
      return false;
    }
    try {
      store.putSync(KEY_THEME_ACCENT, next);
      await store.flush();
      Logger.info(TAG, `主题颜色已保存: ${next}`);
      return true;
    } catch (e) {
      Logger.error(TAG, `主题颜色保存失败: ${(e as BusinessError).message}`);
      return false;
    }
  }

  /**
   * 保存主题模式：先落盘、成功后再更新内存快照。
   * @returns true = 保存成功；false = 未初始化或写入失败（内存保持旧值）
   */
  async setThemeMode(mode: string): Promise<boolean> {
    const next: string = normalizeThemeMode(mode);
    const store = this.store;
    if (store === undefined) {
      Logger.warn(TAG, '偏好尚未初始化，主题模式仅本次会话生效');
      this.themeMode = next;
      return false;
    }
    try {
      store.putSync(KEY_THEME_MODE, next);
      await store.flush();
      this.themeMode = next;
      Logger.info(TAG, `主题模式已保存: ${next}`);
      return true;
    } catch (e) {
      Logger.error(TAG, `主题模式保存失败: ${(e as BusinessError).message}`);
      return false;
    }
  }

  // ==================== 图片缓存容量上限（Phase 14-R） ====================

  /** 同步读取缓存容量上限（-1 = 无限制） */
  getCacheLimitBytesSync(): number {
    return this.cacheLimitBytes;
  }

  /**
   * 保存缓存容量上限：先校验三档合法值 → 落盘成功后更新内存快照。
   * @returns true = 保存成功；false = 非法值或写入失败（内存保持旧值）
   */
  async setCacheLimitBytes(bytes: number): Promise<boolean> {
    if (CACHE_LIMIT_OPTIONS.indexOf(bytes) < 0) {
      Logger.warn(TAG, `非法缓存上限被拒绝: ${bytes}`);
      return false;
    }
    const store = this.store;
    if (store === undefined) {
      this.cacheLimitBytes = bytes;
      return false;
    }
    try {
      store.putSync(KEY_CACHE_LIMIT, bytes);
      await store.flush();
      this.cacheLimitBytes = bytes;
      Logger.info(TAG, `缓存容量上限已保存: ${bytes}`);
      return true;
    } catch (e) {
      Logger.error(TAG, `缓存容量上限保存失败: ${(e as BusinessError).message}`);
      return false;
    }
  }

  // ==================== 标签黑名单（Phase 14-R） ====================

  /** 当前作用域的标签黑名单（内存快照） */
  getBlockedTagsSync(): BlockedTagSet {
    return BlockedTagSet.fromPersisted(this.blockedTags);
  }

  /** 当前作用域（anon 或 uid） */
  getBlockedScopeSync(): string {
    return this.blockedScope;
  }

  /**
   * 切换标签黑名单作用域到指定账号（null / 空串 = 匿名）。
   * 账号切换、登出都必须调用，否则会把 A 用户的屏蔽规则套到 B 用户。
   * @returns true = 已切换到目标作用域
   */
  applyBlockedTagScope(uid: string | null | undefined): boolean {
    const scope: string = blockedScopeOf(uid);
    if (scope === this.blockedScope) {
      return true;
    }
    this.blockedScope = scope;
    this.blockedTags = this.readBlockedTags(scope).toPersisted();
    Logger.info(TAG, `标签黑名单作用域切换: ${scope} (${this.blockedTags.length} 条)`);
    return true;
  }

  /**
   * 保存当前作用域的标签黑名单：先落盘、成功后再更新内存快照。
   * @returns true = 保存成功；false = 未初始化或写入失败（内存保持旧值）
   */
  async setBlockedTags(blocked: BlockedTagSet): Promise<boolean> {
    const next: string[] = blocked.toPersisted();
    const store = this.store;
    const key: string = blockedTagsStorageKey(
      this.blockedScope === BLOCKED_SCOPE_ANON ? '' : this.blockedScope);
    if (store === undefined) {
      Logger.warn(TAG, '偏好尚未初始化，标签黑名单仅本次会话生效');
      this.blockedTags = next;
      return false;
    }
    try {
      store.putSync(key, next);
      await store.flush();
      this.blockedTags = next;
      Logger.info(TAG, `标签黑名单已保存(${this.blockedScope}): ${next.length} 条`);
      return true;
    } catch (e) {
      Logger.error(TAG, `标签黑名单保存失败: ${(e as BusinessError).message}`);
      return false;
    }
  }

  /** 搜索历史落盘（统一入口，保证「先磁盘后内存」的写入顺序） */
  private async persistHistory(list: string[]): Promise<boolean> {
    const store = this.store;
    if (store === undefined) {
      Logger.warn(TAG, '偏好尚未初始化，搜索历史仅本次会话生效');
      return true; // 降级：内存态仍然生效
    }
    try {
      store.putSync(KEY_SEARCH_HISTORY, list);
      await store.flush();
      return true;
    } catch (e) {
      Logger.error(TAG, `搜索历史保存失败: ${(e as BusinessError).message}`);
      return false;
    }
  }

  /** 历史数据清洗：去空串、去重、截断超限（防止历史文件被外部污染后污染 UI） */
  private sanitizeHistory(raw: string[]): string[] {
    const result: string[] = [];
    for (let i = 0; i < raw.length; i++) {
      const item: string = typeof raw[i] === 'string' ? raw[i].trim() : '';
      if (item !== '' && result.indexOf(item) < 0) {
        result.push(item);
      }
      if (result.length >= MAX_HISTORY_SIZE) {
        break;
      }
    }
    return result;
  }

  async setOrientationLock(mode: OrientationLockMode): Promise<boolean> {
    this.orientationLock = mode;
    const store = this.store;
    if (store === undefined) {
      return true;
    }
    try {
      store.putSync(KEY_ORIENTATION_LOCK, mode);
      await store.flush();
      return true;
    } catch (e) {
      Logger.error(TAG, `方向锁定偏好保存失败: ${(e as BusinessError).message}`);
      return false;
    }
  }

  async setVolumeKeyPageTurn(enabled: boolean): Promise<boolean> {
    this.volumeKeyPageTurn = enabled;
    const store = this.store;
    if (store === undefined) {
      return true;
    }
    try {
      store.putSync(KEY_VOLUME_KEY_PAGE_TURN, enabled);
      await store.flush();
      return true;
    } catch (e) {
      Logger.error(TAG, `音量键翻页偏好保存失败: ${(e as BusinessError).message}`);
      return false;
    }
  }

  private signInDateByUid: Map<string, string> = new Map<string, string>();

  /** 查询指定 UID 在指定日期（默认今天）是否已签到 */
  isSignedInTodaySync(uid: string, dateKey: string = localDateKey()): boolean {
    const cleanUid: string = uid.trim();
    if (cleanUid === '') {
      return false;
    }
    const mem: string | undefined = this.signInDateByUid.get(cleanUid);
    if (mem !== undefined) {
      return mem === dateKey;
    }
    const store = this.store;
    if (store === undefined) {
      return false;
    }
    try {
      const saved: string = store.getSync(`${KEY_SIGN_IN_DATE_PREFIX}${cleanUid}`, '') as string;
      if (saved !== '') {
        this.signInDateByUid.set(cleanUid, saved);
      }
      return saved === dateKey;
    } catch (_e) {
      return false;
    }
  }

  /** 按 UID 持久化标记指定日期（默认今天）已签到 */
  async markSignedInToday(uid: string, dateKey: string = localDateKey()): Promise<boolean> {
    const cleanUid: string = uid.trim();
    if (cleanUid === '') {
      return false;
    }
    this.signInDateByUid.set(cleanUid, dateKey);
    const store = this.store;
    if (store === undefined) {
      return true;
    }
    try {
      store.putSync(`${KEY_SIGN_IN_DATE_PREFIX}${cleanUid}`, dateKey);
      await store.flush();
      return true;
    } catch (e) {
      Logger.error(TAG, `签到状态保存失败: ${(e as BusinessError).message}`);
      return false;
    }
  }

  /** 设置每日签到提醒开关并持久化 */
  async setSignInReminderEnabled(enabled: boolean): Promise<boolean> {
    const next: boolean = Boolean(enabled);
    this.signInReminderEnabled = next;
    const store = this.store;
    if (store === undefined) {
      return true;
    }
    try {
      store.putSync(KEY_SIGN_IN_REMINDER_ENABLED, next);
      await store.flush();
      return true;
    } catch (e) {
      Logger.error(TAG, `签到提醒开关保存失败: ${(e as BusinessError).message}`);
      return false;
    }
  }

  /** 设置每日签到提醒时间（HH:mm）并持久化 */
  async setSignInReminderTime(time: string): Promise<boolean> {
    const normalized: string = normalizeReminderTime(time);
    this.signInReminderTime = normalized;
    const store = this.store;
    if (store === undefined) {
      return true;
    }
    try {
      store.putSync(KEY_SIGN_IN_REMINDER_TIME, normalized);
      await store.flush();
      return true;
    } catch (e) {
      Logger.error(TAG, `签到提醒时间保存失败: ${(e as BusinessError).message}`);
      return false;
    }
  }

  /** 同步读取社区成人内容显式确认标记 */
  getCommunityAdultConfirmedSync(): boolean {
    return this.communityAdultConfirmed;
  }

  /** 设置并持久化社区成人内容显式确认标记 */
  async setCommunityAdultConfirmed(confirmed: boolean): Promise<boolean> {
    const next: boolean = Boolean(confirmed);
    this.communityAdultConfirmed = next;
    const store = this.store;
    if (store === undefined) {
      return true;
    }
    try {
      store.putSync(KEY_COMMUNITY_ADULT_CONFIRMED, next);
      await store.flush();
      return true;
    } catch (e) {
      Logger.error(TAG, `社区成人内容确认状态保存失败: ${(e as BusinessError).message}`);
      return false;
    }
  }

  private async persistBoolPref(key: string, value: boolean): Promise<boolean> {
    const store = this.store;
    if (store === undefined) {
      return true;
    }
    try {
      store.putSync(key, value);
      await store.flush();
      return true;
    } catch (e) {
      Logger.error(TAG, `导航栏开关保存失败(${key}): ${(e as BusinessError).message}`);
      return false;
    }
  }

  async setNavShowLatest(show: boolean): Promise<boolean> {
    const next: boolean = Boolean(show);
    this.navShowLatest = next;
    return this.persistBoolPref(KEY_NAV_SHOW_LATEST, next);
  }

  async setNavShowCommunity(show: boolean): Promise<boolean> {
    const next: boolean = Boolean(show);
    this.navShowCommunity = next;
    return this.persistBoolPref(KEY_NAV_SHOW_COMMUNITY, next);
  }

  async setNavShowShelf(show: boolean): Promise<boolean> {
    const next: boolean = Boolean(show);
    this.navShowShelf = next;
    return this.persistBoolPref(KEY_NAV_SHOW_SHELF, next);
  }

  getDoubleTapZoomEnabledSync(): boolean {
    return this.doubleTapZoomEnabled;
  }

  async setDoubleTapZoomEnabled(enabled: boolean): Promise<boolean> {
    const next: boolean = Boolean(enabled);
    this.doubleTapZoomEnabled = next;
    return this.persistBoolPref(KEY_DOUBLE_TAP_ZOOM, next);
  }

  getPageTurnAnimationEnabledSync(): boolean {
    return this.pageTurnAnimationEnabled;
  }

  async setPageTurnAnimationEnabled(enabled: boolean): Promise<boolean> {
    const next: boolean = Boolean(enabled);
    this.pageTurnAnimationEnabled = next;
    return this.persistBoolPref(KEY_PAGE_TURN_ANIMATION, next);
  }

  /** 释放内存快照（应用退出时调用；Preferences 实例由系统托管，无需手动关闭） */
  reset(): void {
    this.store = undefined;
    this.initTask = undefined;
    this.readDirection = ReadDirection.HORIZONTAL;
    this.readerMode = ReaderMode.PAGE_LTR;
    this.searchHistory = [];
    this.contentRating = ContentRating.ALL_AGES;
    this.communityAdultConfirmed = false;
    this.navShowLatest = true;
    this.navShowCommunity = true;
    this.navShowShelf = true;
    this.timeFormat = TIME_FORMAT_ABSOLUTE;
    this.themeMode = THEME_MODE_SYSTEM;
    this.themeAccent = DEFAULT_THEME_ACCENT;
    this.appLanguage = DEFAULT_APP_LANGUAGE;
    this.blockedTags = [];
    this.blockedScope = BLOCKED_SCOPE_ANON;
    this.cacheLimitBytes = DEFAULT_CACHE_LIMIT_BYTES;
    this.orientationLock = OrientationLockMode.SYSTEM;
    this.volumeKeyPageTurn = false;
    this.doubleTapZoomEnabled = true;
    this.pageTurnAnimationEnabled = true;
    this.signInReminderEnabled = false;
    this.signInReminderTime = DEFAULT_SIGN_IN_REMINDER_TIME;
    this.signInDateByUid.clear();
  }
}
