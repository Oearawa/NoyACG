import { HdsNavDestination } from '@kit.UIDesignKit';
import { curves } from '@kit.ArkUI';
import { hdsTitleBarStyle } from '../utils/HdsMaterialPolicy';
/**
 * ProfilePage.ets —— 第一层：用户主页（UserPage · 状态管理 V2）
 *
 * ★ Phase 14-K 双层架构（本文件只负责第一层）：
 *   第一层 UserPage  = 用户资料 + 三个日常功能入口（消息/历史/下载）+ 唯一「设置」入口 + 关于信息
 *   第二层 SettingsPage = 全部应用配置（内容与偏好 / 存储管理 / 显示与外观 / 账户与隐私 / 高级）
 *
 * 本页**禁止**出现任何具体设置控件：内容分级、阅读方向、语言、分流、屏蔽标签、
 * 图片缓存清理、离线数据统计、主题、时间格式、隐私、高级网络配置 —— 全部在 SettingsPage。
 *
 * 历史沿革（避免重复踩坑）：
 * - 14-J1 曾用覆盖式 UserDrawer 做第二套导航 → 已删除（14-K2）；
 * - 14-J4 曾把存储/内容分级卡片放在本页 → 14-K 起全部移入 SettingsPage。
 *
 * Tab 形态与 NavDestination 形态共用同一个 ProfileBody，零重复 UI。
 */
import { bundleManager, common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { UserViewModel } from '../viewmodel/UserViewModel';
import { UserBadge } from '../model/UserInfo';
import {
  ProfileMenuEntry,
  DAILY_ACTIONS,
  SETTINGS_ENTRY,
  SHELF_ENTRY,
  OFFLINE_BOOKS_ENTRY,
  ROUTE_ABOUT,
  ROUTE_LOGIN
} from '../model/ProfileMenu';
import { AuthManager } from '../utils/AuthManager';
import { DailySignInManager } from '../utils/DailySignInManager';
import { AuthStatus } from '../api/AuthTypes';
import { ImageCacheManager } from '../utils/ImageCacheManager';
import { SafeAreaManager } from '../utils/SafeAreaManager';
import { ViewportState } from '../utils/ViewportState';
import { profileTabBottomClearanceVp } from '../utils/BottomInset';
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import { ThemeManager } from '../utils/ThemeManager';
import { buildPanelImmersiveMaterial } from '../utils/ImmersiveMaterial';
import {
  SPATIAL_PRESS_SCALE,
  resolveBarDividerColor,
  resolveFloatingPillMaterialTokens,
  resolvePanelMaterialTokens,
  resolveSettingsPillBorderColor,
  resolveSettingsPillSurfaceColor
} from '../utils/MaterialPolicy';
import { spatialDialogTransition } from '../utils/ImmersiveMotion';
import { LocalizationManager } from '../utils/LocalizationManager';
import {
  AppUpdateChecker,
  GITHUB_RELEASES_URL,
  GitHubReleaseInfo,
  UpdateCheckResult
} from '../utils/AppUpdateChecker';
import { openExternalUrlWithAbilityContext } from '../utils/ExternalLink';
import {
  springPressCurve,
  springPressOpacity,
  springPressScale
} from '../utils/SpringMotion';
import { HdsLightButton } from '../components/HdsLightButton';
import { Logger } from '../utils/Logger';
import { ABOUT_ROW_LAYOUT, LIST_ROW_LAYOUT } from '../utils/ProfileLayout';

const TAG: string = 'ProfilePage';

export function formatDeviceModelOnly(productModel?: string, marketName?: string): string {
  const model: string = productModel !== undefined ? productModel.trim() : '';
  if (model !== '') {
    return model;
  }
  const market: string = marketName !== undefined ? marketName.trim() : '';
  return market !== '' ? market : '—';
}
/** 版本号兜底值（与 AppScope/app.json5 的 versionName 保持一致） */
const VERSION_FALLBACK: string = '1.0.1';
/** 卡片统一圆角 */
const CARD_RADIUS: number = 16;
/** 卡片统一内边距 */
const CARD_PADDING: number = 14;
/** 入口行高度（点击热区即整行） */
const ROW_HEIGHT: number = 60;

/**
 * 用户主页主体（Tab 与独立路由页共用）。
 * @Param inTab true = 作为 Tab 内容，自行避让状态栏；false = 由外层标题栏承担安全区
 * @Param refreshTick 由 Index 在切到「用户」Tab 时自增，用于刷新未读与登录态（不高频轮询）
 */
@ComponentV2
export struct ProfileBody {
  @Param inTab: boolean = false;
  @Param refreshTick: number = 0;

  /**
   * 内容末尾留白（公式唯一来源 utils/BottomInset.profileContentEndInset）。
   * Tab 形态按悬浮底栏公式预留；独立路由形态没有导航栏，只留系统底部避让（P2-04）。
   */
  private navEndInset(): number {
    const vp: ViewportState = ViewportState.getInstance();
    return profileTabBottomClearanceVp(ThemeDims.BOTTOM_BAR_HEIGHT, this.inTab,
      vp.isBottomNav(), vp.bottomVp);
  }
  /** 用户资料视图模型（头像 / 用户名 / UID / 徽章 / 未读） */
  @Local userVm: UserViewModel = new UserViewModel();
  /** 应用版本（来自包信息，读取失败回退常量） */
  @Local appVersion: string = VERSION_FALLBACK;
  /** 头像 / 徽章可渲染地址（经统一图片防腐层解析） */
  @Local avatarUri: string = '';
  @Local badgeUris: string[] = [];
  /** 认证单例（@ObservedV2：登录/退出后资料卡自动刷新） */
  private auth: AuthManager = AuthManager.getInstance();
  @Local private signInMgr: DailySignInManager = DailySignInManager.getInstance();
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private pressedEntryKey: string = '';
  @Local private showLogoutModal: boolean = false;
  @Local private checkingUpdate: boolean = false;
  @Local private showUpdateModal: boolean = false;
  @Local private pendingRelease: GitHubReleaseInfo | null = null;
  @Local private versionRowPressed: boolean = false;
  private static hasAutoCheckedUpdate: boolean = false;
  private readonly panelMaterial = buildPanelImmersiveMaterial();
  /** 本地化入口（拼接动态文案 / Toast / 对话框） */
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();
  /** 全局路由栈：消息 / 历史 / 下载 / 设置 / 关于 / 登录 */
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.loadVersion();
    // 启动恢复可能早于本页创建：这里再触发一次（内部幂等）
    this.auth.initialize();
    this.refreshUser(true);
    if (!ProfileBody.hasAutoCheckedUpdate) {
      ProfileBody.hasAutoCheckedUpdate = true;
      void this.handleCheckUpdate(true);
    }
  }

  aboutToDisappear(): void {
    this.userVm.dispose();
  }

  /** 切回「用户」Tab 时刷新未读与登录态（原 Drawer 的打开时机；不做后台轮询） */
  @Monitor('refreshTick')
  onRefreshTick(): void {
    this.auth.initialize();
    this.refreshUser(false);
    this.userVm.refreshUnread();
  }

  @Monitor('signInMgr.stateRevision')
  onSignInMgrChanged(): void {
    if (this.signInMgr.signedInToday) {
      this.userVm.signedInToday = true;
      if (this.signInMgr.continuousDays > 0) {
        this.userVm.signInContinuous = this.signInMgr.continuousDays;
      }
      this.refreshUser(true);
    }
  }

  /** 拉取用户资料，并把头像/徽章经防腐层解析为可渲染地址 */
  private refreshUser(force: boolean): void {
    this.userVm.load(force).then(() => {
      this.resolveImages();
    }).catch((e: Error) => {
      Logger.warn(TAG, `用户资料加载异常: ${(e as Error).message}`);
    });
  }

  private async resolveImages(): Promise<void> {
    const info = this.userVm.userInfo;
    if (info === null) {
      this.avatarUri = '';
      this.badgeUris = [];
      return;
    }
    this.avatarUri = await this.safeImage(info.avatarUrl);
    const uris: string[] = [];
    for (let i = 0; i < this.userVm.badges.length; i++) {
      const badge: UserBadge = this.userVm.badges[i];
      uris.push(await this.safeImage(badge.minImg !== '' ? badge.minImg : badge.img));
    }
    this.badgeUris = uris;
  }

  /** 图片走统一缓存层（带 Referer、沙盒缓存）；失败降级直连，绝不阻断其它内容 */
  private async safeImage(url: string): Promise<string> {
    if (url === '') {
      return '';
    }
    try {
      return await ImageCacheManager.getInstance().getImage(url);
    } catch (e) {
      Logger.debug(TAG, `图片解析失败，降级直连: ${url}`);
      return url;
    }
  }

  /** 读取应用版本（bundleManager 同步接口，失败回退常量，绝不因取版本崩溃） */
  private loadVersion(): void {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName !== undefined && info.versionName !== '') {
        this.appVersion = info.versionName;
      }
    } catch (e) {
      Logger.warn(TAG, `读取应用版本失败，回退 ${VERSION_FALLBACK}`);
    }
  }

  private deviceModelName(): string {
    try {
      return formatDeviceModelOnly(deviceInfo.productModel, deviceInfo.marketName);
    } catch (_e) {
      return '—';
    }
  }

  // ==================== 展示辅助 ====================

  private displayName(): string {
    const info = this.userVm.userInfo;
    if (info !== null && info.username !== '') {
      return info.username;
    }
    const user = this.auth.user;
    if (user !== null && user.name !== '') {
      return user.name;
    }
    return this.lm.getString($r('app.string.profile_login'), '登录');
  }

  /** UID：优先真实 userinfo.Uid，其次脱敏会话 uid，未登录显示「游客」 */
  private uidText(): string {
    const info = this.userVm.userInfo;
    if (info !== null && info.uid !== '') {
      return this.lm.getString($r('app.string.profile_uid'), 'UID: %s', info.uid);
    }
    const user = this.auth.user;
    if (user !== null && user.uid !== '') {
      const uid: string = user.uid;
      return this.lm.getString($r('app.string.profile_uid'), 'UID: %s',
        uid.length > 6 ? `${uid.substring(0, 6)}…` : uid);
    }
    return this.lm.getString($r('app.string.profile_guest'), '游客');
  }

  private isAuthenticated(): boolean {
    return this.auth.status === AuthStatus.AUTHENTICATED
      || this.auth.status === AuthStatus.LOGGING_OUT;
  }

  /** 统一跳转（路由名来自 model/ProfileMenu 常量，页面内不拼字符串） */
  private openRoute(route: string): void {
    if (route === '') {
      return;
    }
    this.pageStack.pushPathByName(route, null);
  }

  // ==================== 页面骨架 ====================

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Scroll() {
        // 宽屏限宽居中：避免 2in1 / 平板上卡片被拉成超长一行
        Row() {
          Column({ space: 12 }) {
            this.ProfileCard()
            this.DailyActionsCard()
            this.SettingsRow()
            this.AboutCard()
            Column().width('100%').height(ThemeDims.SPACE_L)
            // Phase 15-R2：末尾留白与底栏悬浮高度同源（侧栏形态只留系统避让）
            Column().width('100%').height(this.navEndInset())
          }
          .width('100%')
          .constraintSize({ maxWidth: ThemeDims.CONTENT_MAX_WIDTH })
          .padding({
            left: ThemeDims.PAGE_PADDING,
            right: ThemeDims.PAGE_PADDING,
            top: this.inTab ? SafeAreaManager.topInsetNow() + 8 : 8,
            bottom: 20
          })
          .alignItems(LIST_ROW_LAYOUT.textColumnAlign)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
      .backgroundColor(ThemeColors.BG)

      if (this.showLogoutModal) {
        this.LogoutConfirmOverlay()
      }
      if (this.showUpdateModal && this.pendingRelease !== null) {
        this.UpdateDialogOverlay(this.pendingRelease)
      }
    }
    .width('100%')
    .height('100%')
  }

  // ==================== 用户资料 ====================

  @Builder
  ProfileCard() {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        // 圆形头像：真实头像缺失时用首字母/默认图标占位（不伪造图片）
        Stack() {
          if (this.avatarUri !== '') {
            Image(this.avatarUri)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .draggable(false)
          } else if (this.isAuthenticated()) {
            Text('N')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor(ThemeColors.ON_PRIMARY)
              .width('100%')
              .height('100%')
              .textAlign(TextAlign.Center)
              .backgroundColor(ThemeColors.PRIMARY)
          } else {
            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.person'))
                .fontSize(24)
                .fontColor([ThemeColors.TEXT_SECONDARY])
            }
            .width('100%')
            .height('100%')
            .backgroundColor(ThemeColors.SURFACE)
          }
        }
        .width(56)
        .height(56)
        .borderRadius(28)
        .border({
          width: 1,
          color: resolveBarDividerColor(this.theme.isDark)
        })
        .clip(true)

        Column({ space: 3 }) {
          Text(this.displayName())
            .fontSize(ThemeFonts.TITLE_SECTION)
            .fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.TEXT_STRONG)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.uidText())
            .fontSize(ThemeFonts.CAPTION + 1)
            .fontColor(ThemeColors.TEXT_MUTED)
            .maxLines(1)
          if (this.userVm.badges.length > 0) {
            this.BadgeRow()
          }
        }
        .alignItems(LIST_ROW_LAYOUT.textColumnAlign)
        .layoutWeight(LIST_ROW_LAYOUT.textColumnWeight)

        if (this.isAuthenticated()) {
          Row({ space: 8 }) {
            Row({ space: 4 }) {
              if (this.userVm.signingIn) {
                LoadingProgress().width(12).height(12).color(ThemeColors.PRIMARY)
              } else {
                SymbolGlyph(this.userVm.signedInToday
                  ? $r('sys.symbol.checkmark_circle_fill')
                  : $r('sys.symbol.calendar'))
                  .fontSize(13)
                  .fontColor([this.userVm.signedInToday ? ThemeColors.TEXT_SECONDARY : ThemeColors.PRIMARY])
              }
              Text(this.userVm.signedInToday
                ? (this.userVm.signInContinuous > 0
                  ? `${this.lm.getString($r('app.string.profile_checkin_done'), '今日已签')} · ${this.userVm.signInContinuous}d`
                  : this.lm.getString($r('app.string.profile_checkin_done'), '今日已签'))
                : this.lm.getString($r('app.string.profile_checkin_do'), '每日签到'))
                .fontSize(ThemeFonts.BODY_SMALL)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.userVm.signedInToday ? ThemeColors.TEXT_SECONDARY : ThemeColors.PRIMARY)
            }
            .alignItems(VerticalAlign.Center)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(resolveSettingsPillSurfaceColor(this.theme.isDark, false))
            .borderWidth(1)
            .borderColor(this.userVm.signedInToday
              ? resolveSettingsPillBorderColor(this.theme.isDark)
              : ThemeColors.PRIMARY)
            .borderRadius(14)
            .enabled(!this.userVm.signingIn)
            .onClick(() => {
              this.openCheckInModal();
            })

            Text(this.auth.status === AuthStatus.LOGGING_OUT
              ? $r('app.string.profile_logout_doing') : $r('app.string.profile_logout'))
              .fontSize(ThemeFonts.BODY_SMALL)
              .fontColor(this.auth.status === AuthStatus.LOGGING_OUT
                ? ThemeColors.TEXT_MUTED : ThemeColors.ERROR)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(resolveSettingsPillSurfaceColor(this.theme.isDark, false))
              .borderWidth(1)
              .borderColor(this.auth.status === AuthStatus.LOGGING_OUT
                ? ThemeColors.DIVIDER : ThemeColors.ERROR)
              .borderRadius(14)
              .enabled(this.auth.status !== AuthStatus.LOGGING_OUT)
              .onClick(() => {
                this.confirmLogout();
              })
          }
          .alignItems(VerticalAlign.Center)
        } else {
          Text($r('app.string.profile_login'))
            .fontSize(ThemeFonts.BODY_SMALL)
            .fontColor(ThemeColors.ON_PRIMARY)
            .padding({ left: 16, right: 16, top: 7, bottom: 7 })
            .backgroundColor(ThemeColors.PRIMARY)
            .borderRadius(15)
            .onClick(() => {
              this.openRoute(ROUTE_LOGIN);
            })
        }
      }
      .width('100%')
      .alignItems(LIST_ROW_LAYOUT.verticalAlign)

      // 账号状态（如实反映校验结果，不假装已登录）
      if (this.auth.status === AuthStatus.CHECKING) {
        Row({ space: 6 }) {
          LoadingProgress().width(13).height(13).color(ThemeColors.PRIMARY)
          Text($r('app.string.profile_checking'))
            .fontSize(ThemeFonts.CAPTION + 1)
            .fontColor(ThemeColors.TEXT_MUTED)
        }
        .width('100%')
      } else if (this.auth.status === AuthStatus.ERROR) {
        Row({ space: 8 }) {
          Text(this.auth.errorMessage === ''
            ? this.lm.getString($r('app.string.profile_check_failed'), '登录状态校验失败')
            : this.auth.errorMessage)
            .fontSize(ThemeFonts.CAPTION + 1)
            .fontColor(ThemeColors.ERROR)
            .maxLines(2)
            .layoutWeight(LIST_ROW_LAYOUT.textColumnWeight)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text($r('app.string.profile_retry'))
            .fontSize(ThemeFonts.CAPTION + 1)
            .fontColor(ThemeColors.PRIMARY)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .onClick(() => {
              this.auth.restoreSession(true);
            })
        }
        .width('100%')
      } else if (!this.isAuthenticated()) {
        Text($r('app.string.profile_login_hint'))
          .fontSize(ThemeFonts.CAPTION + 1)
          .fontColor(ThemeColors.TEXT_MUTED)
          .width('100%')
      }

      if (this.userVm.errorMessage !== '') {
        Text(this.userVm.errorMessage)
          .fontSize(ThemeFonts.CAPTION + 1)
          .fontColor(ThemeColors.ERROR)
          .maxLines(2)
          .width('100%')
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding(CARD_PADDING)
    .backgroundColor(ThemeColors.CARD)
    .border({
      width: 1,
      color: resolveBarDividerColor(this.theme.isDark)
    })
    .borderRadius(CARD_RADIUS)
  }

  /** 佩戴徽章（按服务端 show 顺序，最多 3 个，避免撑破一行） */
  @Builder
  BadgeRow() {
    Row({ space: 6 }) {
      ForEach(this.userVm.badges.slice(0, 3), (badge: UserBadge, index: number) => {
        Row({ space: 4 }) {
          if (index < this.badgeUris.length && this.badgeUris[index] !== '') {
            Image(this.badgeUris[index])
              .width(13)
              .height(13)
              .objectFit(ImageFit.Contain)
              .draggable(false)
          }
          Text(badge.name)
            .fontSize(ThemeFonts.CAPTION)
            .fontColor(ThemeColors.TEXT_SECONDARY)
            .maxLines(1)
        }
        .padding({ left: 6, right: 7, top: 2, bottom: 2 })
        .backgroundColor(ThemeColors.SURFACE)
        .borderRadius(9)
      }, (badge: UserBadge) => badge.id)
    }
    .width('100%')
  }

  // ==================== 日常功能入口 ====================

  /**
   * 三个日常入口：不设分组标题，直接以紧凑列表呈现（分隔线细分），
   * 页面上不出现任何分组式标题。
   */
  @Builder
  DailyActionsCard() {
    Column() {
      ForEach(DAILY_ACTIONS, (entry: ProfileMenuEntry, index: number) => {
        if (index > 0) {
          Divider()
            .color(ThemeColors.DIVIDER)
            .strokeWidth(1)
            .margin({ left: 62, right: CARD_PADDING })
        }
        this.ActionRow(entry)
        if (index === 0) {
          Divider()
            .color(ThemeColors.DIVIDER)
            .strokeWidth(1)
            .margin({ left: 62, right: CARD_PADDING })
          this.ActionRow(SHELF_ENTRY)
        }
        if (index === DAILY_ACTIONS.length - 1) {
          Divider()
            .color(ThemeColors.DIVIDER)
            .strokeWidth(1)
            .margin({ left: 62, right: CARD_PADDING })
          this.ActionRow(OFFLINE_BOOKS_ENTRY)
        }
      }, (entry: ProfileMenuEntry) => entry.key)
    }
    .width('100%')
    .backgroundColor(ThemeColors.CARD)
    .border({
      width: 1,
      color: resolvePanelMaterialTokens(this.theme.isDark).borderColor
    })
    .borderRadius(CARD_RADIUS)
    .clip(true)
  }

  /** 功能行：图标 + 统一底衬 + 标题 + 说明 +（未读角标）+ 矢量箭头；整行可点 */
  @Builder
  ActionRow(entry: ProfileMenuEntry) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(entry.iconRes)
          .fontSize(18)
          .fontColor([ThemeColors.PRIMARY])
      }
      .width(36)
      .height(36)
      .borderRadius(10)
      .backgroundColor(this.theme.isDark ? '#262B36' : '#EEF2F7')
      .border({
        width: 1,
        color: resolveFloatingPillMaterialTokens(this.theme.isDark).borderColor
      })

      Column({ space: 2 }) {
        Text(entry.titleRes)
          .fontSize(ThemeFonts.BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.TEXT)
          .maxLines(1)
        Text(entry.subtitleRes)
          .fontSize(ThemeFonts.CAPTION + 1)
          .fontColor(ThemeColors.TEXT_MUTED)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(LIST_ROW_LAYOUT.textColumnAlign)
      .layoutWeight(LIST_ROW_LAYOUT.textColumnWeight)

      if (entry.key === 'message' && this.userVm.unread.all > 0) {
        Text(this.userVm.unread.all > 99 ? '99+' : String(this.userVm.unread.all))
          .fontSize(ThemeFonts.CAPTION)
          .fontColor(ThemeColors.ON_PRIMARY)
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .backgroundColor(ThemeColors.ERROR)
          .borderRadius(9)
      }

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([ThemeColors.TEXT_MUTED])
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: CARD_PADDING, right: CARD_PADDING })
    .alignItems(LIST_ROW_LAYOUT.verticalAlign)
    .scale({
      x: this.pressedEntryKey === entry.key ? SPATIAL_PRESS_SCALE : 1.0,
      y: this.pressedEntryKey === entry.key ? SPATIAL_PRESS_SCALE : 1.0
    })
    .animation({ curve: curves.springMotion(0.24, 0.82) })
    .accessibilityText(`${this.lm.getString(entry.titleRes, entry.title)}：${this.lm.getString(entry.subtitleRes, entry.subtitle)}`)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressedEntryKey = entry.key;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressedEntryKey = '';
      }
    })
    .onClick(() => {
      this.openRoute(entry.route);
    })
  }

  // ==================== 唯一设置入口 ====================

  /** 设置入口：单行卡片，整行可点，进入第二层 SettingsPage */
  @Builder
  SettingsRow() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(SETTINGS_ENTRY.iconRes)
          .fontSize(18)
          .fontColor([ThemeColors.PRIMARY])
      }
      .width(36)
      .height(36)
      .borderRadius(10)
      .backgroundColor(this.theme.isDark ? '#262B36' : '#EEF2F7')
      .border({
        width: 1,
        color: resolveFloatingPillMaterialTokens(this.theme.isDark).borderColor
      })

      Text(SETTINGS_ENTRY.titleRes)
        .fontSize(ThemeFonts.BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemeColors.TEXT)
        .layoutWeight(LIST_ROW_LAYOUT.textColumnWeight)
        .maxLines(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([ThemeColors.TEXT_MUTED])
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: CARD_PADDING, right: CARD_PADDING })
    .alignItems(LIST_ROW_LAYOUT.verticalAlign)
    .backgroundColor(ThemeColors.CARD)
    .border({
      width: 1,
      color: resolvePanelMaterialTokens(this.theme.isDark).borderColor
    })
    .borderRadius(CARD_RADIUS)
    .scale({
      x: this.pressedEntryKey === 'settings' ? SPATIAL_PRESS_SCALE : 1.0,
      y: this.pressedEntryKey === 'settings' ? SPATIAL_PRESS_SCALE : 1.0
    })
    .animation({ curve: curves.springMotion(0.24, 0.82) })
    .accessibilityText($r('app.string.profile_settings_accessibility'))
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressedEntryKey = 'settings';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressedEntryKey = '';
      }
    })
    .onClick(() => {
      this.openRoute(SETTINGS_ENTRY.route);
    })
  }

  // ==================== 关于（紧凑信息） ====================

  @Builder
  AboutCard() {
    Column({ space: 4 }) {
      Row() {
        Text($r('app.string.profile_about'))
          .fontSize(ThemeFonts.BODY_SMALL + 1)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.TEXT_SECONDARY)
        Blank()
        Row({ space: 2 }) {
          Text($r('app.string.profile_about_license'))
            .fontSize(ThemeFonts.BODY_SMALL)
            .fontColor(ThemeColors.PRIMARY)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(12)
            .fontColor([ThemeColors.PRIMARY])
        }
        .padding({ left: 8, right: 2, top: 4, bottom: 4 })
        .accessibilityText($r('app.string.profile_about_license'))
        .onClick(() => {
          this.openRoute(ROUTE_ABOUT);
        })
      }
      .width('100%')
      .height(24)
      .alignItems(LIST_ROW_LAYOUT.verticalAlign)

      this.InfoRow($r('app.string.profile_data_source'), 'NoyAcg')
      this.VersionActionRow()
      this.InfoRow($r('app.string.profile_env'), this.deviceModelName())
    }
    .width('100%')
    .padding(CARD_PADDING)
    .backgroundColor(ThemeColors.CARD)
    .border({
      width: 1,
      color: resolvePanelMaterialTokens(this.theme.isDark).borderColor
    })
    .borderRadius(CARD_RADIUS)
  }

  @Builder
  VersionActionRow() {
    Row() {
      Text($r('app.string.profile_app_version'))
        .fontSize(ThemeFonts.BODY_SMALL + 1)
        .fontColor(ThemeColors.TEXT_MUTED)
        .flexShrink(0)
      Text(ABOUT_ROW_LAYOUT.labelSeparator)
        .fontSize(ThemeFonts.BODY_SMALL + 1)
        .fontColor(ThemeColors.TEXT_MUTED)
        .flexShrink(0)
      Row({ space: 4 }) {
        Text(this.checkingUpdate
          ? this.lm.getString($r('app.string.update_checking'), '检查中...')
          : this.appVersion)
          .fontSize(ThemeFonts.BODY_SMALL + 1)
          .fontColor(this.checkingUpdate ? this.theme.accent : ThemeColors.TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (!this.checkingUpdate) {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(12)
            .fontColor([ThemeColors.TEXT_MUTED])
        }
      }
      .layoutWeight(ABOUT_ROW_LAYOUT.valueWeight)
      .justifyContent(FlexAlign.End)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(32)
    .alignItems(ABOUT_ROW_LAYOUT.verticalAlign)
    .scale({
      x: springPressScale(this.versionRowPressed, !this.checkingUpdate),
      y: springPressScale(this.versionRowPressed, !this.checkingUpdate)
    })
    .opacity(springPressOpacity(this.versionRowPressed, !this.checkingUpdate))
    .animation({ curve: springPressCurve(this.versionRowPressed) })
    .onTouch((event: TouchEvent): void => {
      if (this.checkingUpdate) {
        this.versionRowPressed = false;
        return;
      }
      if (event.type === TouchType.Down) {
        this.versionRowPressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.versionRowPressed = false;
      }
    })
    .onClick((): void => {
      void this.handleCheckUpdate(false);
    })
  }

  private async handleCheckUpdate(silent: boolean): Promise<void> {
    if (this.checkingUpdate) {
      return;
    }
    if (!silent) {
      this.checkingUpdate = true;
    }
    try {
      const result: UpdateCheckResult = await AppUpdateChecker.checkForUpdate(this.appVersion);
      if (result.status === 'update_available' && result.release !== null) {
        this.pendingRelease = result.release;
        this.showUpdateModal = true;
        return;
      }
      if (silent) {
        return;
      }
      if (result.status === 'up_to_date') {
        this.toast(this.lm.getString(
          $r('app.string.update_up_to_date_fmt'),
          '当前已是最新版本 (v%s)',
          this.appVersion
        ));
      } else {
        this.toast(this.lm.getString(
          $r('app.string.update_check_failed'),
          '检查更新失败，请稍后重试'
        ));
      }
    } finally {
      if (!silent) {
        this.checkingUpdate = false;
      }
    }
  }

  private async openReleaseDownload(release: GitHubReleaseInfo): Promise<void> {
    const targetUrl: string = release.htmlUrl !== '' ? release.htmlUrl : GITHUB_RELEASES_URL;
    const hostCtx: common.Context | undefined = this.getUIContext().getHostContext();
    const abilityCtx: common.UIAbilityContext | undefined =
      hostCtx as common.UIAbilityContext | undefined;
    const ok: boolean = await openExternalUrlWithAbilityContext(targetUrl, abilityCtx);
    if (!ok) {
      this.toast(this.lm.getString(
        $r('app.string.update_open_browser_failed'),
        '未找到可用浏览器，请手动访问 GitHub Releases 下载'
      ));
    }
  }

  @Builder
  UpdateDialogOverlay(release: GitHubReleaseInfo) {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.55)')
        .transition(TransitionEffect.OPACITY.animation({ duration: 180 }))
        .onClick((): void => {
          this.showUpdateModal = false;
        })

      Column({ space: 12 }) {
        Text(this.lm.getString(
          $r('app.string.update_new_version_title_fmt'),
          '发现新版本 v%s',
          release.version
        ))
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(resolvePanelMaterialTokens(this.theme.isDark).foregroundStrongColor)
          .width('100%')

        Scroll() {
          Text(release.body !== ''
            ? release.body
            : this.lm.getString(
                $r('app.string.update_default_notes'),
                '包含功能优化与稳定性改进，建议前往 GitHub 下载最新版本。'
              ))
            .fontSize(13.5)
            .lineHeight(20)
            .fontColor(resolvePanelMaterialTokens(this.theme.isDark).foregroundSecondaryColor)
            .width('100%')
        }
        .constraintSize({ maxHeight: 200 })
        .scrollBar(BarState.Off)
        .width('100%')

        Row({ space: 10 }) {
          HdsLightButton({
            label: $r('app.string.common_cancel'),
            variant: 'neutral',
            fullWidth: true,
            minWidthVp: 0,
            heightVp: 40,
            radiusVp: 20,
            fontSizeFp: 14,
            onAction: (): void => {
              this.showUpdateModal = false;
            }
          })
          .layoutWeight(1)

          HdsLightButton({
            label: $r('app.string.update_github_download'),
            variant: 'accentSolid',
            fullWidth: true,
            minWidthVp: 0,
            heightVp: 40,
            radiusVp: 20,
            fontSizeFp: 14,
            onAction: (): void => {
              this.showUpdateModal = false;
              void this.openReleaseDownload(release);
            }
          })
          .layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 4 })
      }
      .width(304)
      .padding(20)
      .borderRadius(20)
      .backgroundColor(resolvePanelMaterialTokens(this.theme.isDark).solidFallbackColor)
      .borderWidth(0)
      .systemMaterial(this.panelMaterial)
      .transition(spatialDialogTransition())
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  InfoRow(label: ResourceStr, value: string) {
    Row() {
      Text(label)
        .fontSize(ThemeFonts.BODY_SMALL + 1)
        .fontColor(ThemeColors.TEXT_MUTED)
        .flexShrink(0)
      Text(ABOUT_ROW_LAYOUT.labelSeparator)
        .fontSize(ThemeFonts.BODY_SMALL + 1)
        .fontColor(ThemeColors.TEXT_MUTED)
        .flexShrink(0)
      Text(value)
        .fontSize(ThemeFonts.BODY_SMALL + 1)
        .fontColor(ThemeColors.TEXT)
        .layoutWeight(ABOUT_ROW_LAYOUT.valueWeight)
        .padding({ left: ABOUT_ROW_LAYOUT.valuePaddingStart })
        .textAlign(ABOUT_ROW_LAYOUT.valueTextAlign)
        .maxLines(ABOUT_ROW_LAYOUT.valueMaxLines)
        .textOverflow({ overflow: ABOUT_ROW_LAYOUT.valueOverflow })
    }
    .width('100%')
    .height(24)
    .alignItems(ABOUT_ROW_LAYOUT.verticalAlign)
  }

  // ==================== 登出（严格：服务端确认后才清本地） ====================

  private confirmLogout(): void {
    this.showLogoutModal = true;
  }

  @Builder
  LogoutConfirmOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.55)')
        .transition(TransitionEffect.OPACITY.animation({ duration: 180 }))
        .onClick(() => {
          this.showLogoutModal = false;
        })

      Column({ space: 12 }) {
        Text($r('app.string.dialog_logout_title'))
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(resolvePanelMaterialTokens(this.theme.isDark).foregroundStrongColor)
          .width('100%')

        Text($r('app.string.dialog_logout_body'))
          .fontSize(14)
          .fontColor(resolvePanelMaterialTokens(this.theme.isDark).foregroundSecondaryColor)
          .width('100%')

        Row({ space: 10 }) {
          Button({ type: ButtonType.Capsule }) {
            Text($r('app.string.common_cancel'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(resolvePanelMaterialTokens(this.theme.isDark).foregroundStrongColor)
          }
          .height(40)
          .layoutWeight(1)
          .backgroundColor(resolveFloatingPillMaterialTokens(this.theme.isDark).tintColor)
          .border({
            width: 1,
            color: resolveFloatingPillMaterialTokens(this.theme.isDark).borderColor
          })
          .onClick(() => {
            this.showLogoutModal = false;
          })

          Button({ type: ButtonType.Capsule }) {
            Text($r('app.string.dialog_logout_confirm'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
          }
          .height(40)
          .layoutWeight(1)
          .backgroundColor(ThemeColors.ERROR)
          .onClick(() => {
            this.showLogoutModal = false;
            void this.doLogout();
          })
        }
        .width('100%')
        .margin({ top: 4 })
      }
      .width(296)
      .padding(20)
      .borderRadius(20)
      .backgroundColor(resolvePanelMaterialTokens(this.theme.isDark).solidFallbackColor)
      .border({
        width: 1,
        color: resolveBarDividerColor(this.theme.isDark)
      })
      .systemMaterial(this.panelMaterial)
      .clip(true)
      .transition(spatialDialogTransition())
    }
    .width('100%')
    .height('100%')
  }

  private async doLogout(): Promise<void> {
    // 严格登出：服务端 ack 后才清本地会话；失败不假装成功（不得误清本地登录态）
    const ok: boolean = await this.auth.logoutWithServerAck();
    if (!ok) {
      const msg: string = this.auth.errorMessage !== '' ? this.auth.errorMessage
        : this.lm.getString($r('app.string.toast_logout_failed'), '登出失败，请重试');
      this.toast(msg);
      if (msg.indexOf('本地会话清理失败') >= 0) {
        this.clearUserState();
      }
      return;
    }
    this.clearUserState();
    this.toast(this.lm.getString($r('app.string.toast_logout_done'), '已退出登录'));
  }

  private clearUserState(): void {
    this.userVm.clear();
    this.avatarUri = '';
    this.badgeUris = [];
  }

  /** 打开官方签到卡片弹窗（支持随时查看连续天数、本周打卡进度与提醒时间设置） */
  private openCheckInModal(): void {
    this.signInMgr.openModal(this.userVm.signInContinuous, this.userVm.signedInToday);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (e) {
      Logger.warn(TAG, `Toast 展示失败: ${(e as Error).message}`);
    }
  }
}

/**
 * 独立路由形态：HdsNavDestination 根 + 原生标题栏。
 * 与 Tab 形态复用同一个 ProfileBody，保证 UI 与数据流唯一。
 */
@ComponentV2
export struct ProfilePage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();

  build() {
    HdsNavDestination() {
      Column() {
        ProfileBody({ inTab: false })
          .layoutWeight(LIST_ROW_LAYOUT.textColumnWeight)
      }
      .width('100%')
      .height('100%')
    }
    .withTheme({ enableThemeColorMode: true })
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      content: { title: { mainTitle: $r('app.string.profile_title') } },
      style: hdsTitleBarStyle()
    })
    .backgroundColor(ThemeColors.BG)
  }
}

/** 系统路由表构建函数：与 route_map.json 的 "ProfilePageBuilder" 对应 */
@Builder
export function ProfilePageBuilder(name: string, param?: object) {
  ProfilePage()
}
