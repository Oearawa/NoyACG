import { HdsNavDestination } from '@kit.UIDesignKit';
import { bundleManager, common } from '@kit.AbilityKit';
import { uiMaterial } from '@kit.ArkUI';
import { hdsTitleBarStyle } from '../utils/HdsMaterialPolicy';
/**
 * SettingsPage.ets —— 第二层：设置页（Phase 14-K 双层架构 / 14-L 本地化 / 14-R 视觉精修）
 *
 * 定位：**所有应用配置的唯一集中管理页**。第一层 UserPage 只有「设置 ›」这一个入口。
 *
 * 五个分组（顺序固定）：
 *   1) 内容与偏好：内容分级 / 应用语言 / 服务器分流【未验证，Disabled】/ 屏蔽标签【14-R 真实入口】
 *   2) 存储管理：图片缓存【真实统计+清理】/ 离线数据【真实占用+入口】
 *   3) 显示与外观：时间格式化 / 主题
 *   4) 账户与隐私：隐私设定【API 未验证，Disabled】
 *   5) 高级：错误报告【14-R】/ 网络日志【14-R】/ 高级缓存配置【14-R】
 *
 * Phase 14-R 视觉修复要点（根因见 PHASE14R_REPORT.md）：
 *   - 说明文字左漂：内容类型容器缺水平内边距，提示 Text 又自带 12vp padding → 双重缩进；
 *   - 分隔线缩进与行内边距不一致（10 vs 12）；
 *   - 原生 Select 高度不受控，背景块 / 文字 / 箭头基线不齐；
 *   - 存储管理按钮为主色/错误色描边，抢过标题层级；
 *   - Disabled 行只写了「暂未支持」但仍可点。
 * 所有尺寸统一引用 SETTINGS_LAYOUT，不再散落裸数字。
 */
import { ContentRatingSelector } from '../components/ContentRatingSelector';
import { CapsuleSelect } from '../components/CapsuleSelect';
import { HdsLightButton } from '../components/HdsLightButton';
import { PreferenceManager } from '../utils/PreferenceManager';
import { ThemeManager } from '../utils/ThemeManager';
import { indexToThemeMode, themeModeToIndex } from '../utils/ThemeMode';
import {
  LocalizationManager,
  indexToLanguage,
  languageButtonLabel,
  languageOptionLabels
} from '../utils/LocalizationManager';
import { CacheViewModel } from '../viewmodel/CacheViewModel';
import { CacheClearResult } from '../utils/CacheCleaner';
import { BlockedTagManager } from '../utils/BlockedTagManager';
import { DiagnosticLogManager } from '../utils/DiagnosticLogManager';
import { NetworkLogManager } from '../utils/NetworkLogManager';
import {
  TIME_FORMAT_ABSOLUTE,
  TIME_FORMAT_RELATIVE,
  formatHistoryTime,
  normalizeTimeFormat
} from '../utils/TimeFormat';
import {
  ROUTE_DOWNLOAD,
  ROUTE_BLOCKED_TAGS,
  ROUTE_CACHE_SETTINGS,
  ROUTE_DIAGNOSTIC_LOG,
  ROUTE_NETWORK_LOG
} from '../model/ProfileMenu';
import { SafeAreaManager } from '../utils/SafeAreaManager';
import {
  ThemeAccentId,
  ThemeColors,
  ThemeDims,
  ThemeFonts,
  themeAccentByIndex,
  themeAccentIndex,
  themeAccentResource,
  themeAccentResources
} from '../utils/Theme';
import {
  resolveBarDividerColor,
  resolvePanelMaterialTokens,
  resolveSettingsPillBorderColor,
  resolveSettingsPillSurfaceColor
} from '../utils/MaterialPolicy';
import { buildPanelImmersiveMaterial } from '../utils/ImmersiveMaterial';
import { spatialDialogTransition } from '../utils/ImmersiveMotion';
import {
  APP_VERSION_NAME,
  AppUpdateChecker,
  GITHUB_RELEASES_URL,
  GitHubReleaseInfo,
  UpdateCheckResult
} from '../utils/AppUpdateChecker';
import { openExternalUrlWithAbilityContext } from '../utils/ExternalLink';
import { Logger } from '../utils/Logger';
import { LIST_ROW_LAYOUT, SETTINGS_LAYOUT, SETTINGS_TEXT_LAYOUT } from '../utils/ProfileLayout';

const TAG: string = 'SettingsPage';

export function formatSettingsCacheButtonLabel(
  isClearing: boolean,
  isCalculating: boolean,
  formattedSize: string
): string {
  if (isClearing) {
    return LocalizationManager.getInstance().getString($r('app.string.settings_cache_clearing_short'), '清理中...');
  }
  if (isCalculating) {
    return LocalizationManager.getInstance().getString($r('app.string.settings_cache_calc_short'), '计算中...');
  }
  return formattedSize;
}

@ComponentV2
export struct SettingsPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  /** 存储统计视图模型（图片缓存 + 离线数据，两套独立统计） */
  @Local vm: CacheViewModel = new CacheViewModel();
  /** 语言选择当前下标（来自平台真实状态；失败时用于回滚） */
  @Local languageIndex: number = 0;
  /** 主题选择当前下标（来自 PreferenceManager.themeMode） */
  @Local themeIndex: number = 0;
  /** 当前屏蔽标签数量（进入页面时同步，避免读到上一次的旧值） */
  @Local blockedCount: number = 0;
  /** 诊断日志条数（用于入口右侧展示真实数量） */
  @Local diagnosticCount: number = 0;
  /** 网络日志条数 */
  @Local networkCount: number = 0;
  @Local appVersion: string = APP_VERSION_NAME;
  @Local checkingUpdate: boolean = false;
  @Local showUpdateModal: boolean = false;
  @Local pendingRelease: GitHubReleaseInfo | null = null;
  private readonly panelMaterial: uiMaterial.Material | undefined = buildPanelImmersiveMaterial();
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  /** 偏好单例（@ObservedV2：时间格式与导航栏开关变化即时反映） */
  @Local private settings: PreferenceManager = PreferenceManager.getInstance();
  /** 本地化入口（动态文案 / 语言切换 / Toast） */
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();

  @Monitor('settings.appLanguage')
  onAppLanguagePreferenceChanged(): void {
    const savedLang: string = this.settings.appLanguage;
    this.languageIndex = this.lm.resolveSelectedLanguageIndex(savedLang);
    this.lm.syncEffectiveLocale(savedLang);
  }

  aboutToAppear(): void {
    // 进入设置页即刷新图片缓存占用
    this.vm.refresh();
    // 语言：优先持久化用户选择，避免平台默认值或系统语言覆盖
    const savedLang: string = this.settings.getAppLanguageSync();
    this.languageIndex = this.lm.resolveSelectedLanguageIndex(savedLang);
    this.lm.syncEffectiveLocale(savedLang);
    // 主题：以持久化偏好为准（ThemeManager 已在启动时按其恢复调色板）
    this.themeIndex = themeModeToIndex(this.settings.getThemeModeSync());
    // Phase 14-R：二级页入口的真实计数
    BlockedTagManager.getInstance().reload();
    this.blockedCount = BlockedTagManager.getInstance().tags.length;
    this.diagnosticCount = DiagnosticLogManager.getInstance().count();
    this.networkCount = NetworkLogManager.getInstance().count();
    this.loadAppVersion();
  }

  private loadAppVersion(): void {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName !== undefined && info.versionName !== '') {
        this.appVersion = info.versionName;
      }
    } catch (e) {
      Logger.debug(TAG, `读取应用版本失败，回退默认值: ${(e as Error).message}`);
    }
  }

  private refreshOnShown(): void {
    // 从二级页返回或页面重新显示时刷新计数与未完成的存储统计
    const savedLang: string = this.settings.getAppLanguageSync();
    this.languageIndex = this.lm.resolveSelectedLanguageIndex(savedLang);
    this.lm.syncEffectiveLocale(savedLang);
    BlockedTagManager.getInstance().reload();
    this.blockedCount = BlockedTagManager.getInstance().tags.length;
    this.diagnosticCount = DiagnosticLogManager.getInstance().count();
    this.networkCount = NetworkLogManager.getInstance().count();
    if (!this.vm.hasCalculated && !this.vm.isCalculating) {
      void this.vm.refresh();
    }
  }

  // ==================== 展示辅助 ====================

  private timeFormatIndex(): number {
    return normalizeTimeFormat(this.settings.timeFormat) === TIME_FORMAT_RELATIVE ? 1 : 0;
  }

  /** 时间格式预览：用真实格式化函数生成一行示例，让用户看到实际效果再决定 */
  private timeFormatPreview(): string {
    const sample: number = Date.now() - 3 * 60 * 60 * 1000;
    return formatHistoryTime(sample, this.settings.timeFormat, this.lm.timeTexts());
  }

  private async selectTimeFormat(index: number): Promise<void> {
    const mode: string = index === 1 ? TIME_FORMAT_RELATIVE : TIME_FORMAT_ABSOLUTE;
    const ok: boolean = await this.settings.setTimeFormat(mode);
    if (!ok) {
      this.toast(this.text($r('app.string.toast_time_format_partial'), '时间格式已切换，但可能未保存到本地'));
    }
  }

  /**
   * 应用语言切换（Phase 14-L）：
   * 调用系统「应用偏好语言」API → 立即回读平台值确认 → 成功/失败都同步 Select 选中项。
   * 语言由系统在**下次冷启动**按新语言解析资源，因此必须明确提示，不能假装即时切换。
   */
  private async selectLanguage(index: number): Promise<void> {
    const targetLang: string = indexToLanguage(index);
    const ok: boolean = this.lm.applyIndex(index);
    if (!ok) {
      this.languageIndex = this.lm.resolveSelectedLanguageIndex(this.settings.getAppLanguageSync());
      this.toast(this.text($r('app.string.toast_lang_failed'), '语言设置失败，已保留原设置'));
      return;
    }
    await this.settings.setAppLanguage(targetLang);
    this.languageIndex = index;
    this.toast(index === 0
      ? this.text($r('app.string.toast_lang_system'), '已设置为跟随系统语言，下次重新启动应用后生效。')
      : this.lm.getString($r('app.string.toast_lang_saved'),
        '语言设置已保存，应用将在下次重新启动后使用新语言。'));
  }

  private text(res: Resource, fallback: string): string {
    return this.lm.getString(res, fallback);
  }

  private openRoute(route: string): void {
    if (route === '') {
      return;
    }
    this.pageStack.pushPathByName(route, null);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (e) {
      Logger.warn(TAG, `Toast 展示失败: ${(e as Error).message}`);
    }
  }

  private async handleCheckUpdate(): Promise<void> {
    if (this.checkingUpdate) {
      return;
    }
    this.checkingUpdate = true;
    try {
      const result: UpdateCheckResult = await AppUpdateChecker.checkForUpdate(this.appVersion);
      if (result.status === 'update_available' && result.release !== null) {
        this.pendingRelease = result.release;
        this.showUpdateModal = true;
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
      this.checkingUpdate = false;
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

  // ==================== 页面骨架 ====================

  build() {
    HdsNavDestination() {
      Stack({ alignContent: Alignment.Center }) {
        Column() {
          Scroll() {
            Row() {
              Column({ space: 0 }) {
                this.PreferenceGroup()
                this.StorageGroup()
                this.AppearanceGroup()
                this.NavBarGroup()
                this.AdvancedGroup()
                Column().width('100%').height(ThemeDims.SPACE_L)
              }
              .width('100%')
              .constraintSize({ maxWidth: ThemeDims.CONTENT_MAX_WIDTH })
              .padding({
                left: ThemeDims.PAGE_PADDING,
                right: ThemeDims.PAGE_PADDING,
                top: 8,
                bottom: 20
              })
              .alignItems(SETTINGS_TEXT_LAYOUT.containerAlign)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
          }
          .layoutWeight(LIST_ROW_LAYOUT.textColumnWeight)
          .width('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .align(Alignment.Top)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(ThemeColors.BG)

        if (this.showUpdateModal && this.pendingRelease !== null) {
          this.UpdateDialogOverlay(this.pendingRelease)
        }
      }
      .width('100%')
      .height('100%')
    }
    .withTheme({ enableThemeColorMode: true })
    .onShown(() => {
      this.refreshOnShown();
    })
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      content: { title: { mainTitle: $r('app.string.settings_title') } },
      style: hdsTitleBarStyle()
    })
    .backgroundColor(ThemeColors.BG)
  }

  /** 统一顶栏：← 设置 */

  /** 分组标题（卡片上方外部，严格对齐卡片内 16vp 左边缘） */
  @Builder
  GroupTitle(title: Resource) {
    Text(title)
      .fontSize(ThemeFonts.BODY_SMALL + 1)
      .fontWeight(FontWeight.Medium)
      .fontColor(ThemeColors.TEXT_SECONDARY)
      .width('100%')
      .textAlign(TextAlign.Start)
      .padding({ left: 16, right: 16, top: 14, bottom: 6 })
  }

  @Builder
  GroupTitleText(title: string) {
    Text(title)
      .fontSize(ThemeFonts.BODY_SMALL + 1)
      .fontWeight(FontWeight.Medium)
      .fontColor(ThemeColors.TEXT_SECONDARY)
      .width('100%')
      .textAlign(TextAlign.Start)
      .padding({ left: 16, right: 16, top: 14, bottom: 6 })
  }

  /**
   * 分组内分隔线（Phase 14-R 修正）：
   * 左右缩进必须等于卡片行内边距，否则会出现「分隔线比标题短一截」的错位。
   */
  @Builder
  RowDivider() {
    Divider()
      .color(ThemeColors.DIVIDER)
      .strokeWidth(1)
      .margin({ left: SETTINGS_LAYOUT.dividerInset, right: SETTINGS_LAYOUT.dividerInset })
  }

  /**
   * 可操作导航行：标题 + 说明 + 右侧（可选计数）+ ›。
   */
  @Builder
  NavRow(title: Resource, desc: Resource, route: string, pillLabel: ResourceStr) {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.TEXT)
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(desc)
          .fontSize(12)
          .lineHeight(17)
          .fontColor(ThemeColors.TEXT_MUTED)
          .width('100%')
          .textAlign(TextAlign.Start)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      HdsLightButton({
        label: pillLabel,
        trailingIcon: $r('sys.symbol.chevron_right'),
        variant: 'neutral',
        onAction: () => {
          this.openRoute(route);
        }
      })
    }
    .width('100%')
    .padding({
      left: 16,
      right: 16,
      top: 12,
      bottom: 12
    })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.openRoute(route);
    })
  }

  /** 统一选择器圆角胶囊触发器（34vp 高、12vp 内边距、17vp 圆角、#EEF1F6 / #262A34 底色 + 12vp 下拉箭头） */
  @Builder
  SelectorCapsule(
    label: ResourceStr,
    options: ResourceStr[],
    selectedIndex: number,
    onSelect: (index: number) => void
  ) {
    CapsuleSelect({
      label: label,
      options: options,
      selectedIndex: selectedIndex,
      onSelect: onSelect
    })
  }

  /** 次级操作按钮（紧凑胶囊） */
  @Builder
  SecondaryButton(label: Resource, disabled: boolean, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor(disabled ? ThemeColors.TEXT_MUTED : ThemeColors.TEXT)
      .height(32)
      .padding({
        left: 12,
        right: 12
      })
      .textAlign(TextAlign.Center)
      .borderWidth(1)
      .borderColor(resolveSettingsPillBorderColor(this.theme.isDark))
      .borderRadius(16)
      .backgroundColor(resolveSettingsPillSurfaceColor(this.theme.isDark, false))
      .enabled(!disabled)
      .onClick(() => {
        action();
      })
  }

  // ==================== 1. 内容与偏好 ====================

  @Builder
  PreferenceGroup() {
    Column() {
      this.GroupTitle($r('app.string.group_prefs'))

      Column() {
        Column() {
          // 内容分级：真实控件（ContentRatingSelector → ContentRatingPolicy → PreferenceManager）
          ContentRatingSelector()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .alignItems(HorizontalAlign.Start)

        this.RowDivider()

        // 应用语言：真实控件（系统应用偏好语言，冷启动生效）
        Row({ space: 12 }) {
          Column({ space: 3 }) {
            Text($r('app.string.settings_language'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemeColors.TEXT)
              .width('100%')
              .textAlign(TextAlign.Start)
            Text($r('app.string.settings_language_hint'))
              .fontSize(12)
              .lineHeight(17)
              .fontColor(ThemeColors.TEXT_MUTED)
              .width('100%')
              .textAlign(TextAlign.Start)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          this.SelectorCapsule(
            this.languageLabel(),
            languageOptionLabels(this.text($r('app.string.lang_system'), '跟随系统')),
            this.languageIndex,
            (index: number): void => {
              void this.selectLanguage(index);
            }
          )
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        this.RowDivider()
        this.NavRow($r('app.string.settings_block_tags'),
          $r('app.string.settings_block_tags_desc'),
          ROUTE_BLOCKED_TAGS,
          $r('app.string.settings_manage_tags'))
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .backgroundColor(ThemeColors.CARD)
      .border({
        width: 1,
        color: resolveBarDividerColor(this.theme.isDark)
      })
      .borderRadius(SETTINGS_LAYOUT.cardRadius)
    }
    .width('100%')
  }

  /** 主题 Select 的当前值文案 */
  private themeLabel(): Resource {
    if (this.themeIndex === 1) {
      return $r('app.string.theme_light');
    }
    if (this.themeIndex === 2) {
      return $r('app.string.theme_dark');
    }
    return $r('app.string.theme_system');
  }

  /**
   * 主题切换（Phase 14-M）：
   * 先立即应用（视觉即时反馈）→ 再持久化；持久化失败则回滚到原模式，避免「看着变了但重启回退」。
   */
  private async selectTheme(index: number): Promise<void> {
    const nextMode: string = indexToThemeMode(index);
    const prevMode: string = this.settings.getThemeModeSync();
    const tm: ThemeManager = ThemeManager.getInstance();
    tm.applyMode(nextMode);
    this.themeIndex = themeModeToIndex(nextMode);
    const ok: boolean = await this.settings.setThemeMode(nextMode);
    if (!ok) {
      tm.applyMode(prevMode);
      this.themeIndex = themeModeToIndex(prevMode);
      this.toast(this.text($r('app.string.toast_theme_failed'), '主题切换失败，已恢复原设置'));
      return;
    }
    this.toast(this.text($r('app.string.toast_theme_saved'), '主题已切换'));
  }

  /** 语言 Select 的当前值文案（具体语言使用固定原生名称） */
  private languageLabel(): string {
    return languageButtonLabel(
      this.languageIndex,
      this.text($r('app.string.lang_system'), '跟随系统')
    );
  }

  // ==================== 2. 存储管理 ====================

  @Builder
  StorageGroup() {
    Column() {
      this.GroupTitle($r('app.string.group_storage'))

      Column() {
        // 图片缓存：左右严格对齐 + 单行胶囊
        Row({ space: 12 }) {
          Column({ space: 3 }) {
            Text($r('app.string.storage_cache'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemeColors.TEXT)
              .width('100%')
              .textAlign(TextAlign.Start)
            Text($r('app.string.storage_cache_desc'))
              .fontSize(12)
              .lineHeight(17)
              .fontColor(ThemeColors.TEXT_MUTED)
              .width('100%')
              .textAlign(TextAlign.Start)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.vm.errorMessage !== '') {
              Text(this.vm.errorMessage)
                .fontSize(12)
                .lineHeight(17)
                .fontColor(ThemeColors.ERROR)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          HdsLightButton({
            label: formatSettingsCacheButtonLabel(
              this.vm.isClearing,
              this.vm.isCalculating,
              this.vm.formattedSize()
            ),
            variant: 'neutral',
            isEnabled: !this.vm.isClearing && !this.vm.isCalculating,
            onAction: () => {
              this.confirmClearCache();
            }
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .backgroundColor(ThemeColors.CARD)
      .border({
        width: 1,
        color: resolveBarDividerColor(this.theme.isDark)
      })
      .borderRadius(SETTINGS_LAYOUT.cardRadius)
    }
    .width('100%')
  }

  /** 清理二次确认（只作用于图片缓存目录；不影响离线章节/收藏/进度） */
  private confirmClearCache(): void {
    if (this.vm.isClearing) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: this.text($r('app.string.dialog_clear_cache_title'), '清理图片缓存'),
      message: this.lm.getString($r('app.string.dialog_clear_cache_body'),
        '将删除约 %s 的图片缓存，书籍收藏、阅读进度与离线章节不受影响。', this.vm.formattedSize()),
      autoCancel: true,
      primaryButton: {
        value: this.text($r('app.string.common_cancel'), '取消'),
        action: () => {
        }
      },
      secondaryButton: {
        value: this.text($r('app.string.dialog_clear_confirm'), '清理'),
        fontColor: ThemeColors.ERROR,
        action: () => {
          this.doClearCache();
        }
      }
    });
  }

  private async doClearCache(): Promise<void> {
    const result: CacheClearResult | null = await this.vm.clear();
    if (result === null) {
      return;
    }
    const freed: string = CacheViewModel.formatBytes(result.freedBytes);
    if (!result.success) {
      this.toast(this.vm.errorMessage === ''
        ? this.text($r('app.string.toast_cache_failed'), '清理失败，请稍后重试') : this.vm.errorMessage);
      this.vm.refresh();
      return;
    }
    if (result.hasPartialFailure) {
      this.toast(this.lm.getString($r('app.string.toast_cache_partial'),
        '已清理 %s，%d 个文件未能删除', freed, result.failedCount));
    } else if (result.deletedCount === 0) {
      this.toast(this.text($r('app.string.toast_cache_empty'), '缓存已经是空的'));
    } else {
      this.toast(this.lm.getString($r('app.string.toast_cache_freed'), '已清理 %s', freed));
    }
    // 清理后重算真实占用；离线数据统计不受影响（两套目录独立）
    this.vm.refresh();
  }

  // ==================== 3. 显示与外观 ====================

  @Builder
  AppearanceGroup() {
    Column() {
      this.GroupTitle($r('app.string.group_appearance'))

      Column() {
        // 时间格式化
        Row({ space: 12 }) {
          Column({ space: 3 }) {
            Text($r('app.string.settings_time_format'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemeColors.TEXT)
              .width('100%')
              .textAlign(TextAlign.Start)
            Text($r('app.string.settings_time_format_desc'))
              .fontSize(12)
              .lineHeight(17)
              .fontColor(ThemeColors.TEXT_MUTED)
              .width('100%')
              .textAlign(TextAlign.Start)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          this.SelectorCapsule(
            this.timeFormatIndex() === 1 ? $r('app.string.time_rel') : $r('app.string.time_abs'),
            [$r('app.string.time_abs'), $r('app.string.time_rel')],
            this.timeFormatIndex(),
            (index: number): void => {
              this.selectTimeFormat(index);
            }
          )
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })

        this.RowDivider()

        // 主题模式
        Row({ space: 12 }) {
          Column({ space: 3 }) {
            Text($r('app.string.settings_theme_mode'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemeColors.TEXT)
              .width('100%')
              .textAlign(TextAlign.Start)
            Text($r('app.string.settings_theme_hint'))
              .fontSize(12)
              .lineHeight(17)
              .fontColor(ThemeColors.TEXT_MUTED)
              .width('100%')
              .textAlign(TextAlign.Start)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          this.SelectorCapsule(
            this.themeLabel(),
            [
              $r('app.string.theme_system'),
              $r('app.string.theme_light'),
              $r('app.string.theme_dark')
            ],
            this.themeIndex,
            (index: number): void => {
              this.selectTheme(index);
            }
          )
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })

        this.RowDivider()

        // 主题颜色：单行标准设置项 + 排行榜同款弹出式下拉菜单
        Row({ space: 12 }) {
          Column({ space: 3 }) {
            Text($r('app.string.settings_theme_accent'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemeColors.TEXT)
              .width('100%')
              .textAlign(TextAlign.Start)
            Text($r('app.string.settings_theme_accent_desc'))
              .fontSize(12)
              .lineHeight(17)
              .fontColor(ThemeColors.TEXT_MUTED)
              .width('100%')
              .textAlign(TextAlign.Start)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          this.SelectorCapsule(
            themeAccentResource(this.theme.accentId),
            themeAccentResources(),
            themeAccentIndex(this.theme.accentId),
            (index: number): void => {
              void this.selectAccent(themeAccentByIndex(index));
            }
          )
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .backgroundColor(ThemeColors.CARD)
      .border({
        width: 1,
        color: resolveBarDividerColor(this.theme.isDark)
      })
      .borderRadius(SETTINGS_LAYOUT.cardRadius)
    }
    .width('100%')
  }

  private async selectAccent(accentId: ThemeAccentId): Promise<void> {
    if (this.theme.accentId === accentId) {
      return;
    }
    this.theme.applyAccent(accentId);
    await this.settings.setThemeAccent(accentId);
  }

  // ==================== 3.5 导航栏自定义（3 列等宽胶囊开关） ====================

  @Builder
  NavBarGroup() {
    Column() {
      this.GroupTitle($r('app.string.group_navbar'))

      Column() {
        Column({ space: 3 }) {
          Text($r('app.string.settings_navbar_entries'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.TEXT)
            .width('100%')
            .textAlign(TextAlign.Start)
          Text($r('app.string.settings_navbar_entries_desc'))
            .fontSize(12)
            .fontColor(ThemeColors.TEXT_MUTED)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Grid() {
          GridItem() {
            HdsLightButton({
              label: this.text($r('app.string.nav_latest'), '最新'),
              leadingIcon: this.settings.navShowLatest
                ? $r('sys.symbol.checkmark') : $r('sys.symbol.clock'),
              variant: this.settings.navShowLatest ? 'accentSoft' : 'neutral',
              fullWidth: true,
              minWidthVp: 0,
              hPaddingVp: 10,
              fontSizeFp: 13,
              iconSizeVp: 12,
              onAction: () => {
                void this.settings.setNavShowLatest(!this.settings.navShowLatest);
              }
            })
          }
          GridItem() {
            HdsLightButton({
              label: this.text($r('app.string.nav_community'), '社区'),
              leadingIcon: this.settings.navShowCommunity
                ? $r('sys.symbol.checkmark') : $r('sys.symbol.message'),
              variant: this.settings.navShowCommunity ? 'accentSoft' : 'neutral',
              fullWidth: true,
              minWidthVp: 0,
              hPaddingVp: 10,
              fontSizeFp: 13,
              iconSizeVp: 12,
              onAction: () => {
                void this.settings.setNavShowCommunity(!this.settings.navShowCommunity);
              }
            })
          }
          GridItem() {
            HdsLightButton({
              label: this.text($r('app.string.nav_shelf'), '收藏'),
              leadingIcon: this.settings.navShowShelf
                ? $r('sys.symbol.checkmark') : $r('sys.symbol.bookmark'),
              variant: this.settings.navShowShelf ? 'accentSoft' : 'neutral',
              fullWidth: true,
              minWidthVp: 0,
              hPaddingVp: 10,
              fontSizeFp: 13,
              iconSizeVp: 12,
              onAction: () => {
                void this.settings.setNavShowShelf(!this.settings.navShowShelf);
              }
            })
          }
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(8)
        .width('100%')
        .height(34)
        .margin({ top: 10 })

        Text($r('app.string.settings_navbar_shelf_hint'))
          .fontSize(11.5)
          .fontColor(ThemeColors.TEXT_MUTED)
          .width('100%')
          .textAlign(TextAlign.Start)
          .margin({ top: 8 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor(ThemeColors.CARD)
      .border({
        width: 1,
        color: resolveBarDividerColor(this.theme.isDark)
      })
      .borderRadius(SETTINGS_LAYOUT.cardRadius)
    }
    .width('100%')
  }

  // ==================== 4. 高级 ====================

  @Builder
  AdvancedGroup() {
    Column() {
      this.GroupTitle($r('app.string.group_advanced'))

      Column() {
        this.NavRow($r('app.string.adv_report'), $r('app.string.adv_report_desc'),
          ROUTE_DIAGNOSTIC_LOG, $r('app.string.settings_view_logs'))
        this.RowDivider()
        this.NavRow($r('app.string.adv_log'), $r('app.string.adv_log_desc'),
          ROUTE_NETWORK_LOG, $r('app.string.settings_view_logs'))
        this.RowDivider()
        this.NavRow($r('app.string.adv_cache'), $r('app.string.adv_cache_desc'),
          ROUTE_CACHE_SETTINGS, $r('app.string.settings_configure'))
        this.RowDivider()
        this.CheckUpdateRow()
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .backgroundColor(ThemeColors.CARD)
      .border({
        width: 1,
        color: resolveBarDividerColor(this.theme.isDark)
      })
      .borderRadius(SETTINGS_LAYOUT.cardRadius)
    }
    .width('100%')
  }

  @Builder
  CheckUpdateRow() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text($r('app.string.settings_check_update'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.TEXT_STRONG)
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(this.lm.getString(
          $r('app.string.settings_current_version_fmt'),
          '当前版本 v%s',
          this.appVersion
        ))
          .fontSize(12)
          .lineHeight(17)
          .fontColor(ThemeColors.TEXT_MUTED)
          .width('100%')
          .textAlign(TextAlign.Start)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      HdsLightButton({
        label: this.checkingUpdate
          ? $r('app.string.settings_checking_update')
          : $r('app.string.settings_check_update_btn'),
        variant: 'neutral',
        isEnabled: !this.checkingUpdate,
        onAction: (): void => {
          void this.handleCheckUpdate();
        }
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
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
}

/** 系统路由表构建函数：与 route_map.json 的 "SettingsPageBuilder" 对应 */
@Builder
export function SettingsPageBuilder(name: string, param?: object) {
  SettingsPage()
}
