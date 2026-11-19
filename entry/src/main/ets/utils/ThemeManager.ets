/**
 * ThemeManager.ets —— 运行时主题（Phase 14-M）
 *
 * 为什么这么做：
 * 改造前 `Theme.ets` 里是 `static readonly` 十六进制常量，编译期就固定成深色，
 * 想换肤必须改代码。本文件把「颜色值」变成可变的调色板（@ObservedV2 + @Trace），
 * 而 `Theme.ets` 的 `ThemeColors` 改成**静态 getter** 转发到当前调色板：
 *   - 全应用 250+ 处 `ThemeColors.XXX` 调用点**一行都不用改**；
 *   - 组件在 build() 里读到的就是当前模式的颜色，读取会订阅对应 @Trace 字段，
 *     因此切换模式时相关组件自动重绘（V2 的依赖追踪是运行时读取即订阅）。
 *
 * 唯一真相源：
 *   - 模式：`PreferenceManager.themeMode`（key `theme_mode`）
 *   - 生效颜色：本文件的单例调色板（就地改字段，不替换对象，否则订阅会失效）
 *
 * 系统深浅色：通过 `SystemModePort` 隔离（默认读 ability 配置的 colorMode），
 * 宿主测试可注入桩验证「跟随系统」的换算逻辑。
 */
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  THEME_MODE_DARK,
  THEME_MODE_LIGHT,
  THEME_MODE_SYSTEM,
  normalizeThemeMode,
  resolveDark
} from './ThemeMode';
import {
  DEFAULT_THEME_ACCENT,
  ThemeAccentId,
  ThemeAccentTone,
  normalizeThemeAccent,
  resolveThemeAccentTone
} from './ThemeAccent';
import { Logger } from './Logger';

const TAG: string = 'ThemeManager';

/** 深色调色板（Phase 14-K 之前的既有视觉，作为深色基准） */
class DarkColors {
  static readonly bg: string = '#121212';
  static readonly bgDeep: string = '#0C0C0E';
  static readonly topBar: string = '#16161A';
  static readonly card: string = '#1E1E22';
  static readonly surface: string = '#2A2A2E';
  static readonly surfacePrimary: string = '#1D302A';
  static readonly text: string = '#E0E0E0';
  static readonly textStrong: string = '#F5F5F5';
  static readonly textSecondary: string = '#9E9E9E';
  static readonly textTertiary: string = '#BDBDBD';
  static readonly textMuted: string = '#8A8A8E';
  static readonly primary: string = '#7EC4AF';
  static readonly rating: string = '#FFD54F';
  static readonly error: string = '#CF6679';
  static readonly success: string = '#81C784';
  static readonly info: string = '#90CAF9';
  static readonly statusOngoing: string = '#43A047';
  static readonly statusCompleted: string = '#1E88E5';
  static readonly divider: string = '#3A3A40';
  static readonly placeholder: string = '#5A5A60';
  static readonly overlay: string = '#B3000000';
  static readonly onPrimary: string = '#121212';
  static readonly onCover: string = '#FFFFFF';
  static readonly onCoverSub: string = '#E0E0E0';
  static readonly scrimFrom: string = '#00000000';
  static readonly scrimTo: string = '#D9000000';
  static readonly cardAlt: string = '#1A1A1E';
}

/**
 * 浅色调色板（Phase 14-M 新增）。
 * 取值原则：低视觉负担的浅灰底 + 白色卡片 + 深色高对比文本；
 * 主色改为更深的紫色以保证「浅底上仍可辨认」；语义色整体压暗以维持对比度。
 */
class LightColors {
  static readonly bg: string = '#F5F6F8';
  static readonly bgDeep: string = '#FFFFFF';
  static readonly topBar: string = '#FFFFFF';
  static readonly card: string = '#FFFFFF';
  static readonly surface: string = '#EDEFF2';
  static readonly surfacePrimary: string = '#E7F2EE';
  static readonly text: string = '#1F2124';
  static readonly textStrong: string = '#111316';
  static readonly textSecondary: string = '#5A5F66';
  static readonly textTertiary: string = '#41464D';
  static readonly textMuted: string = '#6E747C';
  static readonly primary: string = '#3D7A68';
  static readonly rating: string = '#A05A00';
  static readonly error: string = '#B3261E';
  static readonly success: string = '#1E7B34';
  static readonly info: string = '#0B5FBF';
  static readonly statusOngoing: string = '#2E7D32';
  static readonly statusCompleted: string = '#1565C0';
  static readonly divider: string = '#DDE1E6';
  static readonly placeholder: string = '#A8AEB6';
  static readonly overlay: string = '#B3000000';
  static readonly onPrimary: string = '#FFFFFF';
  static readonly onCover: string = '#FFFFFF';
  static readonly onCoverSub: string = '#EFEFEF';
  static readonly scrimFrom: string = '#00000000';
  static readonly scrimTo: string = '#D9000000';
  static readonly cardAlt: string = '#F0F2F5';
}

/**
 * 当前生效调色板（单一实例，字段就地更新）。
 * 注意：必须是 @ObservedV2 + @Trace，否则切换模式时读它的组件不会重绘。
 */
@ObservedV2
export class ThemePalette {
  @Trace bg: string = DarkColors.bg;
  @Trace bgDeep: string = DarkColors.bgDeep;
  @Trace topBar: string = DarkColors.topBar;
  @Trace card: string = DarkColors.card;
  @Trace surface: string = DarkColors.surface;
  @Trace surfacePrimary: string = DarkColors.surfacePrimary;
  @Trace text: string = DarkColors.text;
  @Trace textStrong: string = DarkColors.textStrong;
  @Trace textSecondary: string = DarkColors.textSecondary;
  @Trace textTertiary: string = DarkColors.textTertiary;
  @Trace textMuted: string = DarkColors.textMuted;
  @Trace primary: string = DarkColors.primary;
  @Trace primaryPressed: string = '#6BB39D';
  @Trace accentSoftBorder: string = '#2F4D44';
  @Trace rating: string = DarkColors.rating;
  @Trace error: string = DarkColors.error;
  @Trace success: string = DarkColors.success;
  @Trace info: string = DarkColors.info;
  @Trace statusOngoing: string = DarkColors.statusOngoing;
  @Trace statusCompleted: string = DarkColors.statusCompleted;
  @Trace divider: string = DarkColors.divider;
  @Trace placeholder: string = DarkColors.placeholder;
  @Trace overlay: string = DarkColors.overlay;
  @Trace onPrimary: string = DarkColors.onPrimary;
  @Trace onCover: string = DarkColors.onCover;
  @Trace onCoverSub: string = DarkColors.onCoverSub;
  @Trace scrimFrom: string = DarkColors.scrimFrom;
  @Trace scrimTo: string = DarkColors.scrimTo;
  @Trace cardAlt: string = DarkColors.cardAlt;
}

/** 系统深浅色端口（隔离平台配置读取，便于测试） */
export interface SystemModePort {
  /** 系统当前是否深色 */
  isSystemDark(): boolean;
}

/** 生产实现：读 ability 配置里的 colorMode（异常时按深色处理，保持既有观感） */
class AbilitySystemModePort implements SystemModePort {
  private context?: common.Context;

  bind(context: common.Context): void {
    this.context = context;
  }

  isSystemDark(): boolean {
    const ctx = this.context;
    if (ctx === undefined) {
      return true;
    }
    try {
      // API 26：resourceManager.getConfigurationSync().colorMode
      // （Context 上没有 config 字段，必须走资源管理器读当前配置）
      const cfg: resourceManager.Configuration = ctx.resourceManager.getConfigurationSync();
      return cfg.colorMode === resourceManager.ColorMode.DARK;
    } catch (e) {
      Logger.warn(TAG, `读取系统深浅色失败，按深色处理: ${(e as BusinessError).message}`);
      return true;
    }
  }
}

/** 窗口系统栏回调（由 EntryAbility 注入，用于同步状态栏图标颜色） */
export type SystemBarApplier = (isDark: boolean) => void;

@ObservedV2
export class ThemeManager {
  private static instance?: ThemeManager;

  /** 用户选择的模式（system/light/dark） */
  @Trace mode: string = THEME_MODE_SYSTEM;
  /** 用户选择的柔和主题色板 */
  @Trace accentId: ThemeAccentId = DEFAULT_THEME_ACCENT;
  /** 当前实际生效是否深色（跟随系统时由系统配置决定） */
  @Trace isDark: boolean = true;
  /** 当前生效调色板（唯一实例，就地更新） */
  readonly palette: ThemePalette = new ThemePalette();

  get accent(): string {
    return this.palette.primary;
  }

  get accentPressed(): string {
    return this.palette.primaryPressed;
  }

  get accentSoft(): string {
    return this.palette.surfacePrimary;
  }

  get accentBorder(): string {
    return this.palette.accentSoftBorder;
  }

  get onAccent(): string {
    return this.palette.onPrimary;
  }

  get textPrimary(): string {
    return this.isDark ? '#F1F5F9' : '#1E293B';
  }

  get textSecondary(): string {
    return this.isDark ? '#94A3B8' : '#64748B';
  }

  get border(): string {
    return this.isDark ? '#334155' : '#CBD5E1';
  }

  private systemPort: SystemModePort = new AbilitySystemModePort();
  private systemBarApplier?: SystemBarApplier;

  static getInstance(): ThemeManager {
    if (ThemeManager.instance === undefined) {
      ThemeManager.instance = new ThemeManager();
    }
    return ThemeManager.instance;
  }

  /** EntryAbility.onCreate 注入 context（读系统深浅色） */
  init(context: common.Context): void {
    const port = this.systemPort;
    if (port instanceof AbilitySystemModePort) {
      port.bind(context);
    }
  }

  /** EntryAbility 注入状态栏适配器（主题切换时同步图标颜色） */
  setSystemBarApplier(applier: SystemBarApplier): void {
    this.systemBarApplier = applier;
  }

  /** 测试专用：替换系统深浅色端口 */
  setSystemModePortForTest(port: SystemModePort): void {
    this.systemPort = port;
  }

  /** 测试专用：恢复生产端口 */
  resetSystemModePort(): void {
    this.systemPort = new AbilitySystemModePort();
  }

  /**
   * 应用模式（唯一入口）：
   * 1) 归一化 → 2) 用系统端口换算实际深浅 → 3) 就地更新调色板 → 4) 同步状态栏。
   * 不在此处写偏好（持久化由调用方经 PreferenceManager 完成，避免两处各写一次）。
   */
  applyMode(mode: string): void {
    this.mode = normalizeThemeMode(mode);
    this.applyPalette(this.systemPort.isSystemDark());
    Logger.info(TAG, `主题模式=${this.mode} 生效=${this.isDark ? 'dark' : 'light'}`);
  }

  /** 仅重新解析「跟随系统」下的实际深浅（系统深浅色变化时调用） */
  onSystemColorModeChanged(): void {
    if (normalizeThemeMode(this.mode) !== THEME_MODE_SYSTEM) {
      return;
    }
    this.applyPalette(this.systemPort.isSystemDark());
  }

  /** 切换柔和主题色板并立即同步调色板 */
  applyAccent(accent: string): void {
    this.accentId = normalizeThemeAccent(accent);
    this.applyPalette(this.systemPort.isSystemDark());
    Logger.info(TAG, `主题色=${this.accentId} 生效=${this.isDark ? 'dark' : 'light'}`);
  }

  /** 启动恢复：读取持久化模式与主题色（不写回偏好） */
  restore(mode: string, accent: string = DEFAULT_THEME_ACCENT): void {
    this.accentId = normalizeThemeAccent(accent);
    this.applyMode(mode);
  }

  /**
   * 内部：按实际深浅就地刷新调色板字段（不替换对象，保证订阅有效）。
   *
   * Phase 15-R2.1 P2-02：所有字段**先比后写**。
   * @Trace 的写入本身就会通知订阅方重绘，写同值同样触发；而语言 / 显示大小 /
   * 折叠等无关配置也会走到这里，全量重写会造成整树无效刷新（转场期间尤其明显）。
   */
  private applyPalette(systemDark: boolean): void {
    const targetDark: boolean = resolveDark(this.mode, systemDark);
    this.assignPalette(this.palette, targetDark);
    // 系统栏只在真实深浅变化时同步（窗口级调用，代价高）
    if (this.isDark !== targetDark) {
      this.isDark = targetDark;
      const applier = this.systemBarApplier;
      if (applier !== undefined) {
        try {
          applier(targetDark);
        } catch (e) {
          Logger.warn(TAG, `状态栏适配失败: ${(e as BusinessError).message}`);
        }
      }
    }
  }

  /** 逐字段比较后写入：值相同不赋值，避免无效的 @Trace 通知 */
  private assignPalette(p: ThemePalette, dark: boolean): void {
    const tone: ThemeAccentTone = resolveThemeAccentTone(this.accentId, dark);
    const bg: string = dark ? DarkColors.bg : LightColors.bg;
    const bgDeep: string = dark ? DarkColors.bgDeep : LightColors.bgDeep;
    const topBar: string = dark ? DarkColors.topBar : LightColors.topBar;
    const card: string = dark ? DarkColors.card : LightColors.card;
    const surface: string = dark ? DarkColors.surface : LightColors.surface;
    const surfacePrimary: string = tone.softBg;
    const text: string = dark ? DarkColors.text : LightColors.text;
    const textStrong: string = dark ? DarkColors.textStrong : LightColors.textStrong;
    const textSecondary: string = dark ? DarkColors.textSecondary : LightColors.textSecondary;
    const textTertiary: string = dark ? DarkColors.textTertiary : LightColors.textTertiary;
    const textMuted: string = dark ? DarkColors.textMuted : LightColors.textMuted;
    const primary: string = tone.primary;
    const primaryPressed: string = tone.primaryPressed;
    const accentSoftBorder: string = tone.softBorder;
    const rating: string = dark ? DarkColors.rating : LightColors.rating;
    const error: string = dark ? DarkColors.error : LightColors.error;
    const success: string = dark ? DarkColors.success : LightColors.success;
    const info: string = dark ? DarkColors.info : LightColors.info;
    const statusOngoing: string = dark ? DarkColors.statusOngoing : LightColors.statusOngoing;
    const statusCompleted: string = dark ? DarkColors.statusCompleted : LightColors.statusCompleted;
    const divider: string = dark ? DarkColors.divider : LightColors.divider;
    const placeholder: string = dark ? DarkColors.placeholder : LightColors.placeholder;
    const overlay: string = dark ? DarkColors.overlay : LightColors.overlay;
    const onPrimary: string = tone.onPrimary;
    const onCover: string = dark ? DarkColors.onCover : LightColors.onCover;
    const onCoverSub: string = dark ? DarkColors.onCoverSub : LightColors.onCoverSub;
    const scrimFrom: string = dark ? DarkColors.scrimFrom : LightColors.scrimFrom;
    const scrimTo: string = dark ? DarkColors.scrimTo : LightColors.scrimTo;
    const cardAlt: string = dark ? DarkColors.cardAlt : LightColors.cardAlt;
    if (p.bg !== bg) {
      p.bg = bg;
    }
    if (p.bgDeep !== bgDeep) {
      p.bgDeep = bgDeep;
    }
    if (p.topBar !== topBar) {
      p.topBar = topBar;
    }
    if (p.card !== card) {
      p.card = card;
    }
    if (p.surface !== surface) {
      p.surface = surface;
    }
    if (p.surfacePrimary !== surfacePrimary) {
      p.surfacePrimary = surfacePrimary;
    }
    if (p.text !== text) {
      p.text = text;
    }
    if (p.textStrong !== textStrong) {
      p.textStrong = textStrong;
    }
    if (p.textSecondary !== textSecondary) {
      p.textSecondary = textSecondary;
    }
    if (p.textTertiary !== textTertiary) {
      p.textTertiary = textTertiary;
    }
    if (p.textMuted !== textMuted) {
      p.textMuted = textMuted;
    }
    if (p.primary !== primary) {
      p.primary = primary;
    }
    if (p.primaryPressed !== primaryPressed) {
      p.primaryPressed = primaryPressed;
    }
    if (p.accentSoftBorder !== accentSoftBorder) {
      p.accentSoftBorder = accentSoftBorder;
    }
    if (p.rating !== rating) {
      p.rating = rating;
    }
    if (p.error !== error) {
      p.error = error;
    }
    if (p.success !== success) {
      p.success = success;
    }
    if (p.info !== info) {
      p.info = info;
    }
    if (p.statusOngoing !== statusOngoing) {
      p.statusOngoing = statusOngoing;
    }
    if (p.statusCompleted !== statusCompleted) {
      p.statusCompleted = statusCompleted;
    }
    if (p.divider !== divider) {
      p.divider = divider;
    }
    if (p.placeholder !== placeholder) {
      p.placeholder = placeholder;
    }
    if (p.overlay !== overlay) {
      p.overlay = overlay;
    }
    if (p.onPrimary !== onPrimary) {
      p.onPrimary = onPrimary;
    }
    if (p.onCover !== onCover) {
      p.onCover = onCover;
    }
    if (p.onCoverSub !== onCoverSub) {
      p.onCoverSub = onCoverSub;
    }
    if (p.scrimFrom !== scrimFrom) {
      p.scrimFrom = scrimFrom;
    }
    if (p.scrimTo !== scrimTo) {
      p.scrimTo = scrimTo;
    }
    if (p.cardAlt !== cardAlt) {
      p.cardAlt = cardAlt;
    }
  }

  /** 便捷判断（UI 需要条件样式时使用） */
  isLightMode(): boolean {
    return !this.isDark;
  }

  /** 模式是否强制（非跟随系统）——仅供诊断展示 */
  isForced(): boolean {
    return normalizeThemeMode(this.mode) !== THEME_MODE_SYSTEM;
  }

  /** 供日志/诊断使用的模式名 */
  modeLabel(): string {
    const m: string = normalizeThemeMode(this.mode);
    return m === THEME_MODE_DARK ? 'dark' : (m === THEME_MODE_LIGHT ? 'light' : 'system');
  }
}
