/**
 * StandardPageScaffold.ets —— 二级页面公共骨架组件（@ComponentV2）
 *
 * 提供：
 * 1. 统一顶栏：左侧返回按钮（44×44vp 热区 >= 40vp）、标题、可选右侧插槽；
 *    顶部严格避让系统状态栏安全区 topVp，背景材质严格经 MaterialPolicy / ImmersiveMaterial 驱动；
 * 2. 统一四态容器：loading / error / empty / content，消除二级页面重复状态分支；
 * 3. 响应式内容限宽与底部安全区适配。
 */
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import { ThemeManager } from '../utils/ThemeManager';
import { buildBarImmersiveMaterial, buildInteractiveButtonMaterial } from '../utils/ImmersiveMaterial';
import {
  springPressCurve,
  springPressOpacity,
  springPressScale
} from '../utils/SpringMotion';
import {
  resolveBarDividerColor,
  resolveGlassCapsuleTintColor,
  solidFallbackColor
} from '../utils/MaterialPolicy';
import { ViewportState } from '../utils/ViewportState';
import { EmptyState, ErrorState, LoadingState } from './StatusViews';
import {
  SCAFFOLD_BACK_TARGET_VP,
  ScaffoldContentState,
  ScaffoldTopBarDecoration,
  resolveScaffoldState,
  resolveScaffoldTopBarDecoration,
  scaffoldConstrainedWidthVp,
  secondaryHeaderTotalHeightVp
} from '../utils/StandardScaffoldLayout';

@ComponentV2
export struct StandardPageScaffold {
  @Param title: string | Resource = '';
  @Param isLoading: boolean = false;
  @Param hasContent: boolean = true;
  @Param isEmpty: boolean = false;
  @Param errorMessage: string = '';
  @Param errorTitle: string | Resource = $r('app.string.state_error_default');
  @Param emptyIcon: Resource = $r('sys.symbol.doc_plaintext');
  @Param emptyTitle: string | Resource = '';
  @Param emptyMessage: string = '';
  @Param showSecondaryAction: boolean = false;
  @Param secondaryActionText: string = '';
  @Param maxContentWidth: number = 0;
  @Param transparentHeader: boolean = false;
  @Param inlineHeaderCenter: boolean = false;
  @Param showHeaderBottom: boolean = true;

  @Event onBack: () => void = (): void => {};
  @Event onRetry: () => void = (): void => {};
  @Event onSecondaryAction: () => void = (): void => {};
  @Event onWidthMeasured: (widthVp: number) => void = (_w: number): void => {};

  @BuilderParam headerCenter: () => void = this.emptyBuilder;
  @BuilderParam headerBottom: () => void = this.emptyBuilder;
  @BuilderParam rightAction: () => void = this.emptyBuilder;
  @BuilderParam content: () => void = this.emptyBuilder;

  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local containerWidth: number = ViewportState.getInstance().widthVp;
  @Local topInsetVp: number = ViewportState.getInstance().topVp;
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private isBackPressed: boolean = false;
  private readonly material = buildBarImmersiveMaterial(false);
  private readonly buttonMaterial = buildInteractiveButtonMaterial();

  private readonly syncViewport = (): void => {
    const vp: ViewportState = ViewportState.getInstance();
    if (Math.abs(vp.topVp - this.topInsetVp) >= 0.01) {
      this.topInsetVp = vp.topVp;
    }
  };

  aboutToAppear(): void {
    ViewportState.getInstance().addListener(this.syncViewport);
    this.syncViewport();
  }

  aboutToDisappear(): void {
    ViewportState.getInstance().removeListener(this.syncViewport);
  }

  @Builder
  emptyBuilder() {
  }

  private topSafeAreaVp(): number {
    return this.topInsetVp;
  }

  private currentState(): ScaffoldContentState {
    return resolveScaffoldState(this.isLoading, this.hasContent, this.errorMessage, this.isEmpty);
  }

  private topBarDecoration(): ScaffoldTopBarDecoration {
    return resolveScaffoldTopBarDecoration(
      this.transparentHeader,
      this.material !== undefined,
      resolveGlassCapsuleTintColor(this.theme.isDark)
    );
  }

  private handleBack(): void {
    this.onBack();
    if (this.pageStack.size() > 0) {
      this.pageStack.pop();
    }
  }

  build() {
    Column() {
      // 统一固定顶栏（避让状态栏安全区 + MaterialPolicy 材质）
      Column() {
        Row({ space: 12 }) {
          Button({ type: ButtonType.Circle, stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(18)
              .fontColor([this.theme.textPrimary])
          }
          .width(36)
          .height(36)
          .flexShrink(0)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .backgroundColor(this.theme.isDark ? '#252A36' : '#EEF2F6')
          .borderWidth(0)
          .systemMaterial(this.buttonMaterial)
          .scale({
            x: springPressScale(this.isBackPressed),
            y: springPressScale(this.isBackPressed)
          })
          .opacity(springPressOpacity(this.isBackPressed))
          .animation({ curve: springPressCurve(this.isBackPressed) })
          .responseRegion({ x: -4, y: -4, width: 44, height: 44 })
          .accessibilityText('返回')
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.isBackPressed = true;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.isBackPressed = false;
            }
          })
          .onClick(() => {
            this.handleBack();
          })

          if (this.inlineHeaderCenter) {
            Text(this.title)
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.theme.textPrimary)
              .maxLines(1)
              .flexShrink(0)

            Row() {
              this.headerCenter()
            }
            .layoutWeight(1)
            .margin({ left: ThemeDims.SPACE_S, right: ThemeDims.SPACE_S })
            .alignItems(VerticalAlign.Center)
          } else {
            Text(this.title)
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.theme.textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }

          Row() {
            this.rightAction()
          }
          .flexShrink(0)
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .height(secondaryHeaderTotalHeightVp(this.topSafeAreaVp(), this.inlineHeaderCenter))
        .padding({
          top: this.topSafeAreaVp(),
          left: 16,
          right: 16
        })
        .alignItems(VerticalAlign.Center)

        if (this.showHeaderBottom) {
          this.headerBottom()
        }
      }
      .width('100%')
      .backgroundColor(this.topBarDecoration().backgroundColor)
      .border({
        width: { bottom: this.topBarDecoration().bottomBorderWidthVp },
        color: this.topBarDecoration().bottomBorderWidthVp > 0
          ? resolveBarDividerColor(this.theme.isDark)
          : Color.Transparent
      })
      .systemMaterial(this.topBarDecoration().useSystemMaterial ? this.material : undefined)

      // 统一四态容器 + 响应式最大宽度约束
      Column() {
        if (this.currentState() === 'loading') {
          LoadingState()
        } else if (this.currentState() === 'error') {
          ErrorState({
            title: this.errorTitle,
            message: this.errorMessage,
            retry: (): void => {
              this.onRetry();
            },
            showSecondary: this.showSecondaryAction,
            secondaryText: this.secondaryActionText,
            secondary: (): void => {
              this.onSecondaryAction();
            }
          })
        } else if (this.currentState() === 'empty') {
          EmptyState({
            icon: this.emptyIcon,
            title: this.emptyTitle,
            message: this.emptyMessage
          })
        } else {
          this.content()
        }
      }
      .width('100%')
      .layoutWeight(1)
      .constraintSize({
        maxWidth: scaffoldConstrainedWidthVp(this.containerWidth, this.maxContentWidth)
      })
      .alignSelf(ItemAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeColors.BG)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const w: number = Number(newValue.width);
      if (!Number.isFinite(w) || w <= 0 || Math.abs(w - this.containerWidth) < 1) {
        return;
      }
      this.containerWidth = w;
      this.onWidthMeasured(w);
    })
  }
}
