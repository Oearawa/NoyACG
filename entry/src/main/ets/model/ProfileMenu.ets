/**
 * ProfileMenu.ets —— 用户主页功能入口模型（Phase 14-K 双层架构）
 *
 * 双层职责（本阶段确立，务必保持）：
 *   第一层 UserPage：只放「日常使用的入口」+ 一个设置入口 + 关于信息；
 *   第二层 SettingsPage：集中所有应用配置（内容与偏好 / 存储 / 显示外观 / 隐私 / 高级）。
 *
 * 为什么入口仍然集中成数据表：
 * 之前几轮反复出现「同一功能两个入口」的问题。入口收敛成纯数据后，
 * UI 只负责渲染，单元测试可以直接断言：
 *   - 日常入口恰好三项（消息 / 历史 / 下载），route 唯一且已注册；
 *   - 设置入口只有一个，指向 SettingsPage；
 *   - 不得出现邀请码 / 积分 / 登出等不属于「日常入口」的项（登出在资料卡里）。
 *
 * 约束：route 必须是 route_map.json 中已注册的系统路由名。
 */

/** 单个入口定义 */
export class ProfileMenuEntry {
  /** 稳定标识（测试断言与无障碍文案使用，不直接展示） */
  key: string = '';
  /** 前置图标符号名（非空字符串，供测试断言） */
  icon: string = '';
  /** 前置矢量图标资源（SymbolGlyph 渲染用） */
  iconRes: Resource = $r('sys.symbol.envelope');
  /** 入口标题（资源；渲染用，随系统语言解析） */
  titleRes: Resource = $r('app.string.menu_message');
  /** 入口说明（资源） */
  subtitleRes: Resource = $r('app.string.menu_message_desc');
  /**
   * 标题 / 说明的简体兜底文本。
   * 仅用于：① 无障碍文案拼接（需要纯文本）；② 单元测试断言文案是否符合产品要求。
   * 渲染一律使用 titleRes / subtitleRes，不直接显示这两个字段。
   */
  title: string = '';
  subtitle: string = '';
  /** 目标路由（route_map.json 注册名，空串 = 无目标，不允许） */
  route: string = '';

  constructor(key: string, icon: string, iconRes: Resource, titleRes: Resource, subtitleRes: Resource,
    title: string, subtitle: string, route: string) {
    this.key = key;
    this.icon = icon;
    this.iconRes = iconRes;
    this.titleRes = titleRes;
    this.subtitleRes = subtitleRes;
    this.title = title;
    this.subtitle = subtitle;
    this.route = route;
  }
}

/** 路由名常量：与 route_map.json 一一对应，避免页面里散落字符串 */
export const ROUTE_MESSAGE: string = 'MessagePage';
export const ROUTE_SHELF: string = 'ShelfPage';
export const ROUTE_HISTORY: string = 'HistoryPage';
export const ROUTE_DOWNLOAD: string = 'DownloadPage';
export const ROUTE_OFFLINE_BOOKS: string = 'OfflineBooksPage';
export const ROUTE_SETTINGS: string = 'SettingsPage';
export const ROUTE_ABOUT: string = 'AboutPage';
export const ROUTE_LOGIN: string = 'LoginPage';
/** Phase 14-R：设置页二级页面 */
export const ROUTE_BLOCKED_TAGS: string = 'BlockedTagsPage';
export const ROUTE_CACHE_SETTINGS: string = 'CacheSettingsPage';
export const ROUTE_DIAGNOSTIC_LOG: string = 'DiagnosticLogPage';
export const ROUTE_NETWORK_LOG: string = 'NetworkLogPage';

/**
 * 第一层「日常功能」三项（顺序即渲染顺序）。
 * 说明文案为产品指定文案，不随数据变化；未读角标由 ProfilePage 从 UserViewModel 取真实值叠加。
 */
export const DAILY_ACTIONS: ProfileMenuEntry[] = [
  new ProfileMenuEntry('message', 'sys.symbol.envelope', $r('sys.symbol.envelope'),
    $r('app.string.menu_message'), $r('app.string.menu_message_desc'),
    '消息中心', '评论回复 / 社区回复 / 系统消息', ROUTE_MESSAGE),
  new ProfileMenuEntry('history', 'sys.symbol.clock', $r('sys.symbol.clock'),
    $r('app.string.menu_history'), $r('app.string.menu_history_desc'),
    '阅读历史', '接着上次的进度继续阅读', ROUTE_HISTORY),
  new ProfileMenuEntry('downloads', 'sys.symbol.arrow_down_circle', $r('sys.symbol.arrow_down_circle'),
    $r('app.string.menu_download'), $r('app.string.menu_download_desc'),
    '下载管理', '离线章节、下载任务与文件清理', ROUTE_DOWNLOAD)
];

/**
 * 第一层唯一的设置入口（第二层 SettingsPage 的唯一入口）。
 * subtitle 为空串：该行只展示「设置 ›」，不堆叠说明文字。
 */
export const SETTINGS_ENTRY: ProfileMenuEntry =
  new ProfileMenuEntry('settings', 'sys.symbol.gearshape', $r('sys.symbol.gearshape'),
    $r('app.string.menu_settings'), $r('app.string.settings_title'),
    '设置', '', ROUTE_SETTINGS);

/** 个人中心并列「离线阅读」入口（独立路由 OfflineBooksPage） */
export const OFFLINE_BOOKS_ENTRY: ProfileMenuEntry =
  new ProfileMenuEntry('offline_books', 'sys.symbol.book', $r('sys.symbol.book'),
    $r('app.string.menu_offline_books'), $r('app.string.menu_offline_books_desc'),
    '离线阅读', '查看并离线阅读已下载的漫画', ROUTE_OFFLINE_BOOKS);

/** 个人中心并列「我的收藏」入口（独立路由 ShelfPage，隐藏底栏收藏 Tab 时仍可完整访问） */
export const SHELF_ENTRY: ProfileMenuEntry =
  new ProfileMenuEntry('shelf', 'sys.symbol.bookmark', $r('sys.symbol.bookmark'),
    $r('app.string.menu_shelf'), $r('app.string.menu_shelf_desc'),
    '我的收藏', '账号收藏与本地书架管理', ROUTE_SHELF);

/** 第一层全部导航入口（三项目常功能；设置入口单独渲染，不计入本表） */
export function allProfileEntries(): ProfileMenuEntry[] {
  const list: ProfileMenuEntry[] = [];
  for (let i = 0; i < DAILY_ACTIONS.length; i++) {
    list.push(DAILY_ACTIONS[i]);
  }
  return list;
}

/** 按 key 查找日常入口（未找到返回 null，UI 直接跳过渲染） */
export function findDailyAction(key: string): ProfileMenuEntry | null {
  for (let i = 0; i < DAILY_ACTIONS.length; i++) {
    if (DAILY_ACTIONS[i].key === key) {
      return DAILY_ACTIONS[i];
    }
  }
  return null;
}

/** 按 key 取目标路由（未找到返回空串） */
export function routeOfDailyAction(key: string): string {
  const entry: ProfileMenuEntry | null = findDailyAction(key);
  return entry === null ? '' : entry.route;
}
