import { ThemeManager } from './ThemeManager';
export {
  DEFAULT_THEME_ACCENT,
  THEME_ACCENT_PALETTES,
  ThemeAccentId,
  ThemeAccentPalette,
  ThemeAccentTone,
  findThemeAccentPalette,
  normalizeThemeAccent,
  resolveThemeAccentTone,
  themeAccentByIndex,
  themeAccentIndex,
  themeAccentName,
  themeAccentNames,
  themeAccentResource,
  themeAccentResources
} from './ThemeAccent';

/**
 * Theme.ets —— 全局视觉规范（Phase 14-B 建立，Phase 14-D 扩展为完整体系）
 *
 * 统一颜色 / 尺寸 / 字体三套规范，供全部页面组件引用。
 * 语义与工程存量一致（#E0E0E0 为主文本、#CF6679 为错误色），
 * 新页面一律引用本文件，存量页面渐进迁移。
 *
 * 深色主题（漫画阅读场景）：
 * 背景 BG(最深) → BG_DEEP(阅读器) → CARD(卡片) → SURFACE(标签/表面) 逐层变浅；
 * 文本 TEXT → TEXT_SECONDARY → TEXT_TERTIARY → TEXT_MUTED 四级灰度；
 * PRIMARY 紫色强调、RATING 评分、ERROR/SUCCESS/INFO 状态色。
 */
export class ThemeColors {
  // ★ Phase 14-M：全部改为「静态 getter」，转发到运行时调色板（ThemeManager.palette）。
  //   这样全应用 250+ 处 `ThemeColors.XXX` 调用点无需改动，且组件在 build() 中读取时
  //   会订阅调色板的 @Trace 字段 —— 切换主题后自动重绘。
  //   颜色值定义集中在 ThemeManager 的 DarkColors / LightColors 两套调色板中。

  /** 当前是否为深色模式（供侧栏等定制色调适配深浅色） */
  static get IS_DARK(): boolean {
    return ThemeManager.getInstance().palette.bg === '#121212';
  }

  // ===== 背景 =====
  /** 页面背景（主页面通用） */
  static get BG(): string {
    return ThemeManager.getInstance().palette.bg;
  }

  /** 阅读器 / 更深层背景 */
  static get BG_DEEP(): string {
    return ThemeManager.getInstance().palette.bgDeep;
  }

  /** 详情页自绘顶栏背景（介于 BG 与 CARD 之间） */
  static get TOP_BAR(): string {
    return ThemeManager.getInstance().palette.topBar;
  }

  /** 卡片背景 */
  static get CARD(): string {
    return ThemeManager.getInstance().palette.card;
  }

  /** 表面 / 标签 / 输入框背景 */
  static get SURFACE(): string {
    return ThemeManager.getInstance().palette.surface;
  }

  /** 主色淡表面（选中态 / 主色 10% 底） */
  static get SURFACE_PRIMARY(): string {
    return ThemeManager.getInstance().palette.surfacePrimary;
  }

  /** 次级卡片面（卡片内嵌小块 / 折叠详情底） */
  static get CARD_ALT(): string {
    return ThemeManager.getInstance().palette.cardAlt;
  }

  // ===== 文本（四级灰度） =====
  /** 主文本（正文 / 卡片信息） */
  static get TEXT(): string {
    return ThemeManager.getInstance().palette.text;
  }

  /** 强调文本（页面标题 / 卡片标题） */
  static get TEXT_STRONG(): string {
    return ThemeManager.getInstance().palette.textStrong;
  }

  /** 次级文本（描述 / 统计） */
  static get TEXT_SECONDARY(): string {
    return ThemeManager.getInstance().palette.textSecondary;
  }

  /** 辅助文本（标签 / 中间层灰） */
  static get TEXT_TERTIARY(): string {
    return ThemeManager.getInstance().palette.textTertiary;
  }

  /** 最弱文本（未选中 Tab / 禁用） */
  static get TEXT_MUTED(): string {
    return ThemeManager.getInstance().palette.textMuted;
  }

  // ===== 状态与强调 =====
  /** 主色（品牌强调色：按钮 / 选中态 / Loading） */
  static get PRIMARY(): string {
    return ThemeManager.getInstance().palette.primary;
  }

  /** 主色按压态 */
  static get PRIMARY_PRESSED(): string {
    return ThemeManager.getInstance().palette.primaryPressed;
  }

  /** 主色柔和描边 */
  static get ACCENT_SOFT_BORDER(): string {
    return ThemeManager.getInstance().palette.accentSoftBorder;
  }

  /** 评分高亮（星标 / 评分文字） */
  static get RATING(): string {
    return ThemeManager.getInstance().palette.rating;
  }

  /** 错误 / 警告 */
  static get ERROR(): string {
    return ThemeManager.getInstance().palette.error;
  }

  /** 成功状态 */
  static get SUCCESS(): string {
    return ThemeManager.getInstance().palette.success;
  }

  /** 信息 / 链接 */
  static get INFO(): string {
    return ThemeManager.getInstance().palette.info;
  }

  /** 连载中状态徽标底色 */
  static get STATUS_ONGOING(): string {
    return ThemeManager.getInstance().palette.statusOngoing;
  }

  /** 已完结状态徽标底色 */
  static get STATUS_COMPLETED(): string {
    return ThemeManager.getInstance().palette.statusCompleted;
  }

  // ===== 结构 =====
  /** 分割线 / 边框 */
  static get DIVIDER(): string {
    return ThemeManager.getInstance().palette.divider;
  }

  /** 占位内容（Loading 圈 / 空态图形） */
  static get PLACEHOLDER(): string {
    return ThemeManager.getInstance().palette.placeholder;
  }

  /** 角标遮罩（评分角标半透明黑底） */
  static get OVERLAY(): string {
    return ThemeManager.getInstance().palette.overlay;
  }

  // ===== 语义别名 =====
  /**
   * 悬浮导航栏底色（半透明）。
   * 深色主题用近黑的半透明，浅色主题用白色半透明：
   * 系统材质生效时由材质覆盖，不生效时也保证栏体与内容分离、文字可读。
   */
  static get NAV_BAR_SURFACE(): string {
    return ThemeManager.getInstance().isDark ? '#E61A1A1E' : '#E6FFFFFF';
  }

  /** 主色底上的文字色（深色底配亮紫时为近黑；浅色底配深紫时为白） */
  static get ON_PRIMARY(): string {
    return ThemeManager.getInstance().palette.onPrimary;
  }

  /** 封面图上的主文字 */
  static get ON_COVER(): string {
    return ThemeManager.getInstance().palette.onCover;
  }

  /** 封面图上的次级文字 */
  static get ON_COVER_SUB(): string {
    return ThemeManager.getInstance().palette.onCoverSub;
  }

  /** 封面底部渐变遮罩起点 */
  static get SCRIM_FROM(): string {
    return ThemeManager.getInstance().palette.scrimFrom;
  }

  /** 封面底部渐变遮罩终点 */
  static get SCRIM_TO(): string {
    return ThemeManager.getInstance().palette.scrimTo;
  }
}

/** 分级尺寸：S 紧凑 / M 常规 / L 分区 */
export class ThemeDims {
  // ===== 页面 =====
  /** 页面水平边距 */
  static readonly PAGE_PADDING: number = 16;
  /** 顶部栏高度 */
  static readonly TOP_BAR_HEIGHT: number = 56;
  /** 悬浮底栏栏体高度（vp）：内容末尾留白与原生栏高度对齐（栏体本身由系统绘制） */
  static readonly BOTTOM_BAR_HEIGHT: number = 56;
  /**
   * 官方悬浮栏宽度（vp）。
   * 4 个入口 × 86（参考 PiliPlus `_kIndicatorWidth`）= 344；直接交给
   * `FloatingTabBarStyle.barWidth` 的三个断点档位，栏体不再拉满屏宽。
   */
  static readonly BOTTOM_BAR_WIDTH: number = 344;
  /** 悬浮栏与屏幕左右边缘的最小间距（vp），对应 `barSideMargin` */
  static readonly BOTTOM_BAR_EDGE_MARGIN: number = 16;
  /**
   * 侧栏「栏体」宽度（宽窗口）。
   * 只是栏体本身，**不含**左右外边距；需要总宽度时用 NAV_RAIL_TOTAL_WIDTH。
   */
  static readonly NAV_RAIL_WIDTH: number = 64;
  /** 侧栏：栏体与屏幕左 / 右边缘（以及内容区）之间的外边距，左右对称（不贴边，对应 S2） */
  static readonly NAV_RAIL_MARGIN: number = 12;
  /**
   * 侧栏「总占位宽度」= 左外边距 + 栏体 + 右外边距（Phase 15-R2.1 P1-02）。
   * 布局唯一取值点：Row 内 SideRail 用本值定宽，Tabs 用 layoutWeight(1) 吃掉剩余宽度，
   * 两者之和恒等于父容器宽度——不再出现「各算一份」导致的右贴边或溢出。
   */
  static readonly NAV_RAIL_TOTAL_WIDTH: number =
    ThemeDims.NAV_RAIL_MARGIN * 2 + ThemeDims.NAV_RAIL_WIDTH;
  /** 侧栏：单个入口项高度 */
  static readonly NAV_RAIL_ITEM_HEIGHT: number = 50;
  /** 侧栏：入口项之间的固定间距 */
  static readonly NAV_RAIL_ITEM_GAP: number = 4;
  /** 侧栏：选中胶囊圆角 */
  static readonly NAV_RAIL_ITEM_RADIUS: number = 14;
  /** 侧栏：栏体容器圆角 */
  static readonly NAV_RAIL_RADIUS: number = 32;
  /** 侧栏：入口项水平内边距 */
  static readonly NAV_RAIL_ITEM_PADDING: number = 4;
  /**
   * 悬浮底栏的左右安全边距（vp）。
   * 栏体不再撑到屏幕边缘，两侧留出可点按/握持的空白区（Phase 15-R4）。
   */
  static readonly FLOATING_BAR_SIDE_MARGIN: number = 24;
  /** 导航图标尺寸（SymbolGlyph，底栏与侧栏共用） */
  static readonly NAV_ICON_SIZE: number = 22;
  /** 详情页等阅读型页面在 expanded 窗口的内容最大宽度（限宽居中，720vp 接近常见阅读列宽） */
  static readonly CONTENT_MAX_WIDTH: number = 720;

  // ===== 间距（S/M/L 三级） =====
  static readonly SPACE_S: number = 4;
  static readonly SPACE_M: number = 8;
  static readonly SPACE_L: number = 16;
  /** 瀑布流 / 网格列间距与行间距 */
  static readonly GRID_GAP: number = 6;

  // ===== 圆角 =====
  static readonly RADIUS_CARD: number = 8;
  static readonly RADIUS_TAG: number = 4;

  // ===== 漫画卡片 =====
  /** 漫画封面宽高比（宽/高 = 5/7，原版 aspect-5/7） */
  static readonly COVER_RATIO: number = 0.714;
  /** 卡片最小合理宽度（vp）：响应式列数计算依据 */
  static readonly CARD_MIN_WIDTH: number = 160;
  /** 瀑布流容器左右内边距（vp，单侧；列数计算扣除两侧） */
  static readonly GRID_H_PADDING: number = 8;
  /** 响应式列数下限（竖屏手机 2 列，对齐原版移动端） */
  static readonly GRID_MIN_COLUMNS: number = 2;
  /** 响应式列数上限（避免超宽窗口列数爆炸） */
  static readonly GRID_MAX_COLUMNS: number = 6;
  /**
   * 卡片信息区固定高度（vp）。推算依据（Phase 14-G）：
   * 内边距 top7+bottom9=16；标题 13px×2 行（行高≈1.4→36.4）；
   * 作者 11px×1 行（≈15.4）；统计 10px×1 行（≈14）；间距 space4×2=8。
   * 合计 ≈ 89.8，取整 90。
   */
  static readonly CARD_INFO_HEIGHT: number = 90;

  // ===== 图标 / 角标 =====
  static readonly ICON_SIZE: number = 22;
  static readonly BADGE_FONT: number = 9;

  // ===== 海报卡片（首页横向行，宽度按窗口类别） =====
  /** 海报卡宽度（compact 手机竖屏，~360vp 约可见 2.5 张） */
  static readonly POSTER_WIDTH_COMPACT: number = 132;
  /** 海报卡宽度（medium 手机横屏） */
  static readonly POSTER_WIDTH_MEDIUM: number = 168;
  /** 海报卡宽度（expanded 平板，~1000vp 约可见 4.5 张） */
  static readonly POSTER_WIDTH_EXPANDED: number = 196;

  // ===== Phase 14-O：图片/文本/列表稳定性 =====
  /** 单列漫画列表封面默认宽度 */
  static readonly LIST_COVER_WIDTH: number = 96;
  /** 网格封面首帧兜底高度：避免 onAreaChange 之前 coverHeight=0 造成卡片跳变 */
  static readonly COVER_FALLBACK_HEIGHT: number =
    ThemeDims.CARD_MIN_WIDTH / ThemeDims.COVER_RATIO;
  /** 单列列表右侧信息区稳定高度：与默认封面高度一致 */
  static readonly LIST_INFO_STABLE_HEIGHT: number =
    ThemeDims.LIST_COVER_WIDTH / ThemeDims.COVER_RATIO;
  /** 卡片标题行高 */
  static readonly TITLE_CARD_LINE_HEIGHT: number = 18;
  /** 元信息行高 */
  static readonly META_LINE_HEIGHT: number = 14;
  /** 简介行高 */
  static readonly DESC_LINE_HEIGHT: number = 17;
  /** 标签行最小高度 */
  static readonly TAG_ROW_MIN_HEIGHT: number = 22;
  /** 海报卡底部信息区最小高度 */
  static readonly POSTER_INFO_MIN_HEIGHT: number = 64;
  /** 长列表屏外节点缓存数量（少量缓冲，避免盲目提高内存） */
  static readonly LIST_CACHED_COUNT: number = 4;
  /** 预取当前可见项前后各 N 张图片 */
  static readonly PREFETCH_RADIUS: number = 2;
  /** 预取最大并发 */
  static readonly PREFETCH_MAX_CONCURRENCY: number = 2;
  /** 预取队列上限 */
  static readonly PREFETCH_QUEUE_LIMIT: number = 24;
}

/** 字体规范（vp；HarmonyOS 系统字体，随系统动态缩放） */
export class ThemeFonts {
  /** 页面大标题 */
  static readonly TITLE_PAGE: number = 21;
  /** 区域 / 自绘标题栏 */
  static readonly TITLE_SECTION: number = 17;
  /** 卡片标题 */
  static readonly TITLE_CARD: number = 13;
  /** 正文 */
  static readonly BODY: number = 14;
  /** 次级描述 */
  static readonly BODY_SMALL: number = 12;
  /** 辅助信息 / 统计 */
  static readonly CAPTION: number = 10;
}
