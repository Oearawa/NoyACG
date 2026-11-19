import { HdsNavDestination } from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
/**
 * LoginPage.ets —— 原生登录页（统一 HDS 光感无勾边胶囊风格 · 状态管理 V2）
 *
 * 设计约束：
 * - 纯 ArkUI 组件，无 WebView、无 HTML 套壳；
 * - 统一 StandardPageScaffold 顶栏（52vp）与响应式居中卡片（最大宽度 440vp）；
 * - 所有按钮均为无外描边（borderWidth: 0）并接入 SpringMotion 非线性弹簧动效；
 * - 注册入口通过 HarmonyOS 官方 UIAbilityContext.openLink 拉起系统浏览器访问官方注册页。
 */
import { LoginViewModel } from '../viewmodel/LoginViewModel';
import { AuthManager } from '../utils/AuthManager';
import { openExternalRegisterUrlWithAbilityContext } from '../utils/ExternalLink';
import { LocalizationManager } from '../utils/LocalizationManager';
import { ThemeColors } from '../utils/Theme';
import { ThemeManager } from '../utils/ThemeManager';
import {
  springPressCurve,
  springPressOpacity,
  springPressScale
} from '../utils/SpringMotion';
import { StandardPageScaffold } from '../components/StandardPageScaffold';
import { HdsLightButton } from '../components/HdsLightButton';
import { Logger } from '../utils/Logger';

const TAG: string = 'LoginPage';

@ComponentV2
export struct LoginPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local vm: LoginViewModel = new LoginViewModel();
  @Local private focusedField: string = '';
  @Local private registerPressed: boolean = false;
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();

  /** 认证单例：仅用于读取「已登录」以处理重复进入的情况 */
  private auth: AuthManager = AuthManager.getInstance();

  aboutToAppear(): void {
    if (this.auth.isAuthenticated) {
      Logger.info(TAG, '已处于登录态，关闭登录页');
      this.pageStack.pop();
    }
  }

  aboutToDisappear(): void {
    this.vm.dispose();
  }

  private activeErrorMessage(): string {
    if (this.vm.validationError !== '') {
      return this.vm.validationError;
    }
    return this.vm.errorMessage;
  }

  private errorTextColor(): string {
    return this.theme.isDark ? '#F87171' : '#DC2626';
  }

  private errorBannerBg(): string {
    return this.theme.isDark ? '#3B1D22' : '#FEE2E2';
  }

  private inputContainerBg(): string {
    return this.theme.isDark ? '#1B1F29' : '#F4F6FA';
  }

  @Builder
  BrandHeader() {
    Column({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.person_shield'))
          .fontSize(30)
          .fontColor([this.theme.accent])
      }
      .width(64)
      .height(64)
      .borderRadius(20)
      .backgroundColor(this.theme.accentSoft)
      .borderWidth(0)

      Text('NoyAcg')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme.textPrimary)

      Text($r('app.string.login_subtitle'))
        .fontSize(13)
        .fontColor(this.theme.textSecondary)
        .textAlign(TextAlign.Center)
        .lineHeight(19)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 12, bottom: 20 })
  }

  @Builder
  UsernameField() {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.person'))
        .fontSize(17)
        .fontColor([this.focusedField === 'username' ? this.theme.accent : this.theme.textSecondary])

      TextInput({
        text: this.vm.username,
        placeholder: this.lm.getString($r('app.string.login_username_ph'), '账号 / 用户名')
      })
        .type(InputType.Normal)
        .layoutWeight(1)
        .height(44)
        .fontSize(14)
        .fontColor(this.theme.textPrimary)
        .placeholderColor(this.theme.textSecondary)
        .backgroundColor(Color.Transparent)
        .borderWidth(0)
        .padding({ left: 0, right: 0 })
        .maxLength(64)
        .enabled(!this.vm.isSubmitting)
        .enterKeyType(EnterKeyType.Next)
        .onFocus((): void => {
          this.focusedField = 'username';
        })
        .onBlur((): void => {
          if (this.focusedField === 'username') {
            this.focusedField = '';
          }
        })
        .onChange((value: string): void => {
          this.vm.username = value;
        })

      if (this.vm.username !== '' && !this.vm.isSubmitting) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
            .fontSize(16)
            .fontColor([this.theme.textSecondary])
        }
        .width(36)
        .height(40)
        .onClick((): void => {
          this.vm.username = '';
        })
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: 14, right: 8 })
    .borderRadius(14)
    .backgroundColor(this.inputContainerBg())
    .borderWidth(this.focusedField === 'username' ? 1.5 : 0)
    .borderColor(this.theme.accent)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  PasswordField() {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.lock'))
        .fontSize(17)
        .fontColor([this.focusedField === 'password' ? this.theme.accent : this.theme.textSecondary])

      TextInput({
        text: this.vm.password,
        placeholder: this.lm.getString($r('app.string.login_password_ph'), '密码')
      })
        .type(InputType.Password)
        .layoutWeight(1)
        .height(44)
        .fontSize(14)
        .fontColor(this.theme.textPrimary)
        .placeholderColor(this.theme.textSecondary)
        .backgroundColor(Color.Transparent)
        .borderWidth(0)
        .padding({ left: 0, right: 0 })
        .maxLength(128)
        .enabled(!this.vm.isSubmitting)
        .enterKeyType(EnterKeyType.Done)
        .onFocus((): void => {
          this.focusedField = 'password';
        })
        .onBlur((): void => {
          if (this.focusedField === 'password') {
            this.focusedField = '';
          }
        })
        .onChange((value: string): void => {
          this.vm.password = value;
        })
        .onSubmit((): void => {
          void this.doSubmit();
        })
    }
    .width('100%')
    .height(48)
    .padding({ left: 14, right: 8 })
    .borderRadius(14)
    .backgroundColor(this.inputContainerBg())
    .borderWidth(this.focusedField === 'password' ? 1.5 : 0)
    .borderColor(this.theme.accent)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  ErrorBanner(message: string) {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
        .fontSize(15)
        .fontColor([this.errorTextColor()])

      Text(message)
        .fontSize(12.5)
        .fontColor(this.errorTextColor())
        .layoutWeight(1)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(12)
    .backgroundColor(this.errorBannerBg())
    .borderWidth(0)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  RegisterPrompt() {
    Row({ space: 2 }) {
      Text($r('app.string.login_no_account'))
        .fontSize(13.5)
        .fontColor(this.theme.textSecondary)

      Row({ space: 4 }) {
        Text($r('app.string.login_register_now'))
          .fontSize(13.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.accent)
        SymbolGlyph($r('sys.symbol.arrow_up_right'))
          .fontSize(12)
          .fontColor([this.theme.accent])
      }
      .padding({ left: 6, right: 6, top: 8, bottom: 8 })
      .borderRadius(12)
      .borderWidth(0)
      .scale({
        x: springPressScale(this.registerPressed),
        y: springPressScale(this.registerPressed)
      })
      .opacity(springPressOpacity(this.registerPressed))
      .animation({ curve: springPressCurve(this.registerPressed) })
      .onTouch((event: TouchEvent): void => {
        if (event.type === TouchType.Down) {
          this.registerPressed = true;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.registerPressed = false;
        }
      })
      .onClick((): void => {
        void this.openOfficialRegister();
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .margin({ top: 16 })
  }

  @Builder
  LoginContent() {
    Scroll() {
      Column() {
        Column() {
          this.BrandHeader()

          Column({ space: 14 }) {
            this.UsernameField()
            this.PasswordField()

            if (this.activeErrorMessage() !== '') {
              this.ErrorBanner(this.activeErrorMessage())
            }

            Column() {
              HdsLightButton({
                label: this.vm.isSubmitting
                  ? $r('app.string.login_submitting')
                  : $r('app.string.login_submit'),
                variant: 'accentSolid',
                fullWidth: true,
                heightVp: 44,
                radiusVp: 22,
                fontSizeFp: 15,
                isEnabled: !this.vm.isSubmitting,
                onAction: (): void => {
                  void this.doSubmit();
                }
              })
            }
            .width('100%')
            .padding({ top: 4 })
          }
          .width('100%')
          .padding(18)
          .borderRadius(16)
          .backgroundColor(ThemeColors.CARD)
          .borderWidth(0)

          this.RegisterPrompt()
        }
        .width('100%')
        .constraintSize({ maxWidth: 440 })
        .padding({ left: 20, right: 20, top: 16, bottom: 32 })
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
  }

  build() {
    HdsNavDestination() {
      StandardPageScaffold({
        title: $r('app.string.login_title'),
        showHeaderBottom: false,
        maxContentWidth: 440,
        onBack: (): void => {
          this.pageStack.pop();
        },
        content: (): void => {
          this.LoginContent();
        }
      })
    }
    .hideTitleBar(true)
    .withTheme({ enableThemeColorMode: true })
  }

  /** 提交登录：成功后提示并返回；失败由 VM 呈现具体原因 */
  private async doSubmit(): Promise<void> {
    if (this.vm.isSubmitting) {
      return;
    }
    const ok: boolean = await this.vm.submit();
    if (ok) {
      this.toast(this.lm.getString($r('app.string.login_success'), '登录成功'));
      this.pageStack.pop();
      return;
    }
    if (this.vm.errorKind !== null) {
      Logger.info(TAG, `登录未通过: ${this.vm.errorKind}`);
    }
  }

  /** 拉起系统浏览器访问 NoyAcg 官方注册网址 */
  private async openOfficialRegister(): Promise<void> {
    const hostCtx: common.Context | undefined = this.getUIContext().getHostContext();
    const abilityCtx: common.UIAbilityContext | undefined =
      hostCtx as common.UIAbilityContext | undefined;
    const ok: boolean = await openExternalRegisterUrlWithAbilityContext(abilityCtx);
    if (!ok) {
      this.toast(this.lm.getString(
        $r('app.string.login_register_open_failed'),
        '未找到可用浏览器，请手动访问 NoyAcg 官网注册'
      ));
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1800 });
    } catch (e) {
      Logger.warn(TAG, `Toast 展示失败: ${(e as Error).message}`);
    }
  }
}

/** 系统路由表构建函数：与 route_map.json 的 "LoginPageBuilder" 对应 */
@Builder
export function LoginPageBuilder(name: string, param?: object) {
  LoginPage()
}
