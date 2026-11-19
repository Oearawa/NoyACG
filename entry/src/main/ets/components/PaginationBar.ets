/**
 * PaginationBar.ets —— 通用数字分页组件（Phase 14-N / 14-N1）
 *
 * 受控组件：分页状态全部由外部 ViewModel 提供，本组件只展示与回调。
 * 支持动态页码窗口、边界禁用、数字跳页弹窗、加载防重与窄宽屏适配。
 * 14-N1：统计文案由 countMode 决定（serverTotal / localLoaded / unknown），
 * 不把本地已获取条数冒充服务端总量；未知总量时不显示任何虚构数字。
 * 不直接发起网络请求，不保存第二套分页状态。
 */
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import { ThemeManager } from '../utils/ThemeManager';
import { LocalizationManager } from '../utils/LocalizationManager';
import {
  resolveBarDividerColor,
  resolveGlassCapsuleBorderColor,
  resolveGlassCapsuleShadowColor,
  resolveGlassCapsuleTintColor
} from '../utils/MaterialPolicy';
import { buildBarImmersiveMaterial } from '../utils/ImmersiveMaterial';
import {
  springPressCurve,
  springPressOpacity,
  springPressScale
} from '../utils/SpringMotion';
import {
  PaginationWindow,
  PaginationStats,
  PAGINATION_CAPSULE_BOTTOM_GAP_VP,
  PAGINATION_CAPSULE_HEIGHT_VP,
  isPaginationWideLayout,
  paginationButtonCount,
  computePaginationWindow,
  computeCompactBarWindow,
  parseJumpPage,
  canChangePage,
  COUNT_MODE_UNKNOWN,
  STAT_LABEL_TOTAL,
  STAT_LABEL_LOADED,
  STAT_LABEL_PAGES,
  STAT_LABEL_LOCAL_PAGES,
  resolvePaginationStats
} from '../utils/Pagination';

const PAGE_BUTTON_SIZE: number = 34;

@ComponentV2
export struct PaginationBar {
  /** 当前页（从 1 开始，由 ViewModel 提供） */
  @Param currentPage: number = 1;
  /** 总页数（由真实总量计算或服务端的合法值） */
  @Param totalPages: number = 0;
  /**
   * 统计口径：serverTotal = 服务端真实总量；localLoaded = 本次已获取条数 + 本地页数；
   * unknown = 总量未知，不显示虚构数字。默认 unknown（安全缺省，不冒充服务端总量）。
   */
  @Param countMode: string = COUNT_MODE_UNKNOWN;
  /** 统计数量：含义由 countMode 决定，不单独假定为服务端总量 */
  @Param totalCount: number = 0;
  /** 请求进行中：禁用所有翻页与跳页 */
  @Param loading: boolean = false;
  /** 紧凑单行模式（横屏/宽屏使用，收紧垂直占高） */
  @Param compact: boolean = false;
  /** 底部系统安全区内边距（vp），用于贴底悬浮时避让导航条 */
  @Param bottomSafeInset: number = 0;
  /** 是否启用 MaterialPolicy 悬浮材质背景 */
  @Param useMaterialSurface: boolean = false;
  /** 页码变化（按钮 / 箭头 / 跳页统一走这里） */
  @Event onPageChange: (page: number) => void = (page: number) => {};
  /** 跳页专用回调；未提供时仍可通过 onPageChange 完成跳转 */
  @Event onJumpToPage: (page: number) => void = (page: number) => {};

  @Local containerWidth: number = 0;
  @Local dialogId: number = -1;
  @Local jumpInput: string = '';
  @Local jumpError: string = '';
  @Local submitting: boolean = false;
  @Local private pressedKey: string = '';

  private lm: LocalizationManager = LocalizationManager.getInstance();
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  private readonly material = buildBarImmersiveMaterial(false);

  private isWideMode(): boolean {
    return isPaginationWideLayout(this.containerWidth, this.compact);
  }

  private btnMinWidth(): number {
    return this.isWideMode() ? PAGE_BUTTON_SIZE : 26;
  }

  private btnHeight(): number {
    return this.isWideMode() ? PAGE_BUTTON_SIZE : 30;
  }

  private btnPadH(): number {
    return this.isWideMode() ? 8 : 6;
  }

  private btnFontSize(): number {
    return this.isWideMode() ? 13 : 12;
  }

  private ellipsisWidth(): number {
    return this.isWideMode() ? 18 : 12;
  }

  private window(): PaginationWindow {
    if (!this.isWideMode()) {
      return computeCompactBarWindow(this.currentPage, this.totalPages);
    }
    const rawLimit: number = paginationButtonCount(this.containerWidth);
    const maxButtons: number = Math.min(5, rawLimit);
    return computePaginationWindow(
      this.currentPage,
      this.totalPages,
      maxButtons
    );
  }

  private stats(): PaginationStats {
    return resolvePaginationStats(this.countMode, this.totalCount, this.totalPages);
  }

  /** 数量文案：本地分页明确写「已获取 N 条」，服务端分页才写「总量 N」。 */
  private totalText(): string {
    const s: PaginationStats = this.stats();
    if (!s.showCountNumber) {
      return this.lm.getString($r('app.string.pagination_unknown'), '');
    }
    if (s.countLabel === STAT_LABEL_TOTAL) {
      return this.lm.getString($r('app.string.pagination_total'), '', s.count);
    }
    if (s.countLabel === STAT_LABEL_LOADED) {
      return this.lm.getString($r('app.string.pagination_loaded'), '', s.count);
    }
    return this.lm.getString($r('app.string.pagination_unknown'), '');
  }

  /** 页数文案：本地分页明确写「本地页数 N」，避免被误读为服务端总页数。 */
  private pagesText(): string {
    const s: PaginationStats = this.stats();
    if (!s.showPages) {
      return '';
    }
    if (s.pagesLabel === STAT_LABEL_PAGES) {
      return this.lm.getString($r('app.string.pagination_pages'), '', s.pages);
    }
    if (s.pagesLabel === STAT_LABEL_LOCAL_PAGES) {
      return this.lm.getString($r('app.string.pagination_local_pages'), '', s.pages);
    }
    return '';
  }

  private async openJumpDialog(): Promise<void> {
    if (this.loading || this.totalPages <= 0 || this.submitting) {
      return;
    }
    this.jumpInput = '';
    this.jumpError = '';
    this.submitting = true;
    try {
      const id: number = await this.getUIContext().getPromptAction().openCustomDialog({
        builder: () => {
          this.JumpDialogContent();
        },
        alignment: DialogAlignment.Center,
        isModal: true,
        autoCancel: false
      });
      this.dialogId = id;
    } catch (e) {
      this.dialogId = -1;
      this.submitting = false;
    }
  }

  private closeJumpDialog(): void {
    if (this.dialogId >= 0) {
      try {
        this.getUIContext().getPromptAction().closeCustomDialog(this.dialogId);
      } catch (e) {
        this.dialogId = -1;
      }
      this.dialogId = -1;
    }
    this.jumpInput = '';
    this.jumpError = '';
    this.submitting = false;
  }

  private submitJump(): void {
    if (this.loading || this.submitting === false) {
      return;
    }
    const target: number = parseJumpPage(this.jumpInput, this.totalPages);
    if (!canChangePage(this.loading, this.currentPage, this.totalPages, target)) {
      const raw: string = this.jumpInput.trim();
      const numeric: number = Number(raw);
      this.jumpError = raw === '' || !Number.isFinite(numeric) || !Number.isInteger(numeric)
        ? this.lm.getString($r('app.string.pagination_jump_invalid'), '')
        : this.lm.getString($r('app.string.pagination_jump_range'), '', this.totalPages);
      return;
    }
    this.closeJumpDialog();
    this.onJumpToPage(target);
    this.onPageChange(target);
  }

  @Builder
  PageButtonsStrip() {
    Row() {
      this.PrevButton()
      if (this.window().showFirst) {
        this.PageButton(1)
      }
      if (this.window().showStartEllipsis) {
        Text('…')
          .fontSize(this.btnFontSize())
          .fontColor(ThemeColors.TEXT_MUTED)
          .width(this.ellipsisWidth())
          .height(this.btnHeight())
          .textAlign(TextAlign.Center)
      }
      ForEach(this.window().pages, (page: number) => {
        this.PageButton(page)
      }, (page: number) => String(page))
      if (this.window().showEndEllipsis) {
        Text('…')
          .fontSize(this.btnFontSize())
          .fontColor(ThemeColors.TEXT_MUTED)
          .width(this.ellipsisWidth())
          .height(this.btnHeight())
          .textAlign(TextAlign.Center)
      }
      if (this.window().showLast) {
        this.PageButton(this.totalPages)
      }
      this.NextButton()
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.SpaceEvenly)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  JumpButton() {
    Text(`${this.currentPage}/${Math.max(this.totalPages, 1)}`)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.theme.accent)
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .height(32)
      .padding({ left: 10, right: 10 })
      .borderRadius(16)
      .borderWidth(0)
      .backgroundColor(this.theme.accentSoft)
      .accessibilityText($r('app.string.pagination_jump_title'))
      .flexShrink(0)
      .scale({
        x: springPressScale(this.pressedKey === 'jump', this.totalPages > 0 && !this.loading),
        y: springPressScale(this.pressedKey === 'jump', this.totalPages > 0 && !this.loading)
      })
      .opacity(springPressOpacity(this.pressedKey === 'jump', this.totalPages > 0 && !this.loading))
      .animation({ curve: springPressCurve(this.pressedKey === 'jump') })
      .enabled(this.totalPages > 0 && !this.loading)
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressedKey = 'jump';
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressedKey = '';
        }
      })
      .onClick(() => {
        this.openJumpDialog();
      })
  }

  @Builder
  BarContent() {
    Row({ space: 6 }) {
      this.PageButtonsStrip()

      Divider()
        .vertical(true)
        .height(18)
        .strokeWidth(1)
        .color(resolveBarDividerColor(this.theme.isDark))

      this.JumpButton()
    }
    .width('100%')
    .height(48)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Row() {
      Row() {
        this.BarContent()
      }
      .width('100%')
      .height(48)
      .padding({ left: 8, right: 8 })
      .borderRadius(24)
      .backgroundColor(resolveGlassCapsuleTintColor(this.theme.isDark))
      .border({
        width: 1,
        color: resolveGlassCapsuleBorderColor(this.theme.isDark)
      })
      .shadow({
        radius: 24,
        color: resolveGlassCapsuleShadowColor(this.theme.isDark),
        offsetX: 0,
        offsetY: 6
      })
      .systemMaterial(this.useMaterialSurface ? this.material : undefined)
      .constraintSize({ maxWidth: this.isWideMode() ? 520 : '100%' })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({
      left: 16,
      right: 16,
      bottom: (this.bottomSafeInset > 0 ? this.bottomSafeInset : 0) + PAGINATION_CAPSULE_BOTTOM_GAP_VP
    })
    .hitTestBehavior(HitTestMode.Transparent)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const w: number = Number(newValue.width);
      if (Number.isFinite(w) && w > 0 && Math.abs(w - this.containerWidth) >= 1) {
        this.containerWidth = w;
      }
    })
  }

  @Builder
  PageButton(page: number) {
    Text(String(page))
      .fontSize(this.btnFontSize())
      .fontWeight(page === this.currentPage ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(page === this.currentPage ? this.theme.onAccent : this.theme.textPrimary)
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .constraintSize({ minWidth: this.btnMinWidth() })
      .height(this.btnHeight())
      .padding({ left: this.btnPadH(), right: this.btnPadH() })
      .borderRadius(this.btnHeight() / 2)
      .borderWidth(0)
      .backgroundColor(page === this.currentPage ? this.theme.accent : ThemeColors.CARD)
      .scale({
        x: springPressScale(this.pressedKey === `p_${page}`, canChangePage(this.loading, this.currentPage, this.totalPages, page)),
        y: springPressScale(this.pressedKey === `p_${page}`, canChangePage(this.loading, this.currentPage, this.totalPages, page))
      })
      .opacity(springPressOpacity(this.pressedKey === `p_${page}`, !this.loading))
      .animation({ curve: springPressCurve(this.pressedKey === `p_${page}`) })
      .enabled(canChangePage(this.loading, this.currentPage, this.totalPages, page))
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressedKey = `p_${page}`;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressedKey = '';
        }
      })
      .onClick(() => {
        this.onPageChange(page);
      })
  }

  @Builder
  PrevButton() {
    Text('<')
      .fontSize(this.btnFontSize())
      .fontColor(ThemeColors.TEXT)
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .constraintSize({ minWidth: this.btnMinWidth() })
      .height(this.btnHeight())
      .padding({ left: this.btnPadH(), right: this.btnPadH() })
      .borderRadius(this.btnHeight() / 2)
      .borderWidth(0)
      .backgroundColor(ThemeColors.CARD)
      .accessibilityText($r('app.string.pagination_prev'))
      .scale({
        x: springPressScale(this.pressedKey === 'prev', !this.loading && this.window().canPrev),
        y: springPressScale(this.pressedKey === 'prev', !this.loading && this.window().canPrev)
      })
      .opacity(springPressOpacity(this.pressedKey === 'prev', !this.loading && this.window().canPrev))
      .animation({ curve: springPressCurve(this.pressedKey === 'prev') })
      .enabled(!this.loading && this.window().canPrev)
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressedKey = 'prev';
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressedKey = '';
        }
      })
      .onClick(() => {
        this.onPageChange(this.currentPage - 1);
      })
  }

  @Builder
  NextButton() {
    Text('>')
      .fontSize(this.btnFontSize())
      .fontColor(ThemeColors.TEXT)
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .constraintSize({ minWidth: this.btnMinWidth() })
      .height(this.btnHeight())
      .padding({ left: this.btnPadH(), right: this.btnPadH() })
      .borderRadius(this.btnHeight() / 2)
      .borderWidth(0)
      .backgroundColor(ThemeColors.CARD)
      .accessibilityText($r('app.string.pagination_next'))
      .scale({
        x: springPressScale(this.pressedKey === 'next', !this.loading && this.window().canNext),
        y: springPressScale(this.pressedKey === 'next', !this.loading && this.window().canNext)
      })
      .opacity(springPressOpacity(this.pressedKey === 'next', !this.loading && this.window().canNext))
      .animation({ curve: springPressCurve(this.pressedKey === 'next') })
      .enabled(!this.loading && this.window().canNext)
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressedKey = 'next';
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressedKey = '';
        }
      })
      .onClick(() => {
        this.onPageChange(this.currentPage + 1);
      })
  }

  @Builder
  JumpDialogContent() {
    Column({ space: 12 }) {
      Text($r('app.string.pagination_jump_title'))
        .fontSize(ThemeFonts.TITLE_SECTION)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemeColors.TEXT_STRONG)
        .width('100%')
        .textAlign(TextAlign.Start)

      TextInput({ text: this.jumpInput, placeholder: $r('app.string.pagination_jump_placeholder') })
        .type(InputType.Number)
        .maxLength(6)
        .width('100%')
        .height(40)
        .padding({ left: 12, right: 12 })
        .borderRadius(ThemeDims.RADIUS_CARD)
        .backgroundColor(ThemeColors.SURFACE)
        .fontColor(ThemeColors.TEXT)
        .placeholderColor(ThemeColors.TEXT_MUTED)
        .onChange((value: string) => {
          this.jumpInput = value;
          this.jumpError = '';
        })

      if (this.jumpError !== '') {
        Text(this.jumpError)
          .fontSize(ThemeFonts.CAPTION)
          .fontColor(ThemeColors.ERROR)
          .width('100%')
          .textAlign(TextAlign.Start)
      }

      Row({ space: 12 }) {
        Text($r('app.string.common_cancel'))
          .fontSize(ThemeFonts.BODY)
          .fontColor(ThemeColors.TEXT_SECONDARY)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 10, bottom: 10 })
          .backgroundColor(ThemeColors.SURFACE)
          .borderRadius(ThemeDims.RADIUS_CARD)
          .onClick(() => {
            this.closeJumpDialog();
          })

        Text($r('app.string.pagination_jump_confirm'))
          .fontSize(ThemeFonts.BODY)
          .fontColor(ThemeColors.ON_PRIMARY)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 10, bottom: 10 })
          .backgroundColor(ThemeColors.PRIMARY)
          .borderRadius(ThemeDims.RADIUS_CARD)
          .onClick(() => {
            this.submitJump();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(20)
    .backgroundColor(ThemeColors.CARD)
    .borderRadius(ThemeDims.RADIUS_CARD * 2)
  }
}
