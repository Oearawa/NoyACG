import { HdsNavDestination } from '@kit.UIDesignKit';
import { bundleManager, common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hdsTitleBarStyle } from '../utils/HdsMaterialPolicy';
import { AuthManager } from '../utils/AuthManager';
import { AuthUser } from '../api/AuthTypes';
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import { LocalizationManager } from '../utils/LocalizationManager';
import { Logger } from '../utils/Logger';
import {
  APP_VERSION_NAME,
  GITHUB_REPO_OWNER,
  GITHUB_REPO_NAME,
  GITHUB_REPO_URL
} from '../utils/AppUpdateChecker';
import { openExternalUrlWithAbilityContext } from '../utils/ExternalLink';

const TAG: string = 'AboutPage';
const VERSION_FALLBACK: string = APP_VERSION_NAME;
const APP_DISPLAY_NAME: string = 'NoyAcg';
const REPO_DISPLAY_TEXT: string = `github.com/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}`;

@ComponentV2
export struct AboutPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();
  @Local appVersion: string = VERSION_FALLBACK;
  @Local deviceModel: string = '—';
  @Local uid: string = '—';
  private auth: AuthManager = AuthManager.getInstance();

  aboutToAppear(): void {
    this.loadVersion();
    this.loadDeviceModel();
    this.loadUid();
  }

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

  private loadDeviceModel(): void {
    try {
      const model: string = deviceInfo.productModel;
      if (model !== undefined && model.trim() !== '') {
        this.deviceModel = model.trim();
        return;
      }
      const market: string = deviceInfo.marketName;
      this.deviceModel = market !== undefined && market.trim() !== '' ? market.trim() : '—';
    } catch (e) {
      this.deviceModel = '—';
    }
  }

  private loadUid(): void {
    const user: AuthUser | null = this.auth.user;
    this.uid = user !== null && user.uid !== '' ? user.uid : '—';
  }

  private async openRepository(): Promise<void> {
    const hostCtx: common.Context | undefined = this.getUIContext().getHostContext();
    const abilityCtx: common.UIAbilityContext | undefined =
      hostCtx as common.UIAbilityContext | undefined;
    const ok: boolean = await openExternalUrlWithAbilityContext(GITHUB_REPO_URL, abilityCtx);
    if (!ok) {
      try {
        this.getUIContext().getPromptAction().showToast({
          message: this.lm.getString($r('app.string.update_open_browser_failed'), '未找到可用浏览器'),
          duration: 2000
        });
      } catch (e) {
        Logger.debug(TAG, `Toast 忽略: ${(e as Error).message}`);
      }
    }
  }

  build() {
    HdsNavDestination() {
      Column() {
        Scroll() {
          Column({ space: 14 }) {
            this.AppCard()
            this.InfoCard()
            this.SectionCard(
              $r('app.string.about_deps_title'),
              '第三方依赖',
              $r('app.string.about_deps_body'),
              ''
            )
            this.SectionCard(
              $r('app.string.about_acks_title'),
              '开源项目致谢',
              $r('app.string.about_acks_body'),
              ''
            )
            this.SectionCard(
              $r('app.string.about_inspiration_title'),
              '设计灵感',
              $r('app.string.about_inspiration_body'),
              ''
            )
          }
          .width('100%')
          .padding({ left: ThemeDims.PAGE_PADDING, right: ThemeDims.PAGE_PADDING, top: 8, bottom: 24 })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemeColors.BG)
    }
    .withTheme({ enableThemeColorMode: true })
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      content: { title: { mainTitle: this.lm.getString($r('app.string.profile_about'), '关于') } },
      style: hdsTitleBarStyle()
    })
    .backgroundColor(ThemeColors.BG)
  }

  @Builder
  AppCard() {
    Column({ space: 6 }) {
      Text(APP_DISPLAY_NAME)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.TEXT_STRONG)
      Text(this.lm.getString($r('app.string.about_version_fmt'), '版本 %s', this.appVersion))
        .fontSize(ThemeFonts.BODY_SMALL)
        .fontColor(ThemeColors.TEXT_SECONDARY)
      Text(this.lm.getString($r('app.string.about_desc'), 'NoyACG 第三方鸿蒙阅读客户端'))
        .fontSize(ThemeFonts.BODY_SMALL)
        .fontColor(ThemeColors.TEXT_TERTIARY)
        .lineHeight(20)
        .margin({ top: 2 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(ThemeColors.CARD)
    .borderRadius(ThemeDims.RADIUS_CARD)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  InfoCard() {
    Column({ space: 10 }) {
      this.InfoRow(this.lm.getString($r('app.string.profile_app_version'), '应用版本'), this.appVersion, false)
      this.InfoRow(this.lm.getString($r('app.string.profile_env'), '设备机型'), this.deviceModel, false)
      if (this.uid !== '—') {
        this.InfoRow(this.lm.getString($r('app.string.about_uid'), '当前 UID'), this.uid, false)
      }
      Row() {
        Text(this.lm.getString($r('app.string.about_repo_label'), '项目仓库'))
          .fontSize(ThemeFonts.BODY_SMALL)
          .fontColor(ThemeColors.TEXT_SECONDARY)
        Blank()
        Row({ space: 4 }) {
          Text(REPO_DISPLAY_TEXT)
            .fontSize(ThemeFonts.BODY_SMALL)
            .fontColor(ThemeColors.PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(12)
            .fontColor([ThemeColors.PRIMARY])
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height(26)
      .onClick((): void => {
        void this.openRepository();
      })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(ThemeColors.CARD)
    .borderRadius(ThemeDims.RADIUS_CARD)
  }

  @Builder
  SectionCard(titleRes: Resource, titleFallback: string, bodyRes: Resource, bodyFallback: string) {
    Column({ space: 8 }) {
      Text(this.lm.getString(titleRes, titleFallback))
        .fontSize(ThemeFonts.BODY_SMALL)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemeColors.TEXT_STRONG)
      Text(this.lm.getString(bodyRes, bodyFallback))
        .fontSize(ThemeFonts.BODY_SMALL)
        .fontColor(ThemeColors.TEXT_TERTIARY)
        .lineHeight(20)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(ThemeColors.CARD)
    .borderRadius(ThemeDims.RADIUS_CARD)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  InfoRow(label: string, value: string, highlight: boolean) {
    Row() {
      Text(label)
        .fontSize(ThemeFonts.BODY_SMALL)
        .fontColor(ThemeColors.TEXT_SECONDARY)
      Blank()
      Text(value)
        .fontSize(ThemeFonts.BODY_SMALL)
        .fontColor(highlight ? ThemeColors.PRIMARY : ThemeColors.TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(26)
  }
}

/** 系统路由表构建函数：与 route_map.json 的 "AboutPageBuilder" 对应 */
@Builder
export function AboutPageBuilder(name: string, param?: object) {
  AboutPage()
}
