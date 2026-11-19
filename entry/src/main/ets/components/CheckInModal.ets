/**
 * CheckInModal.ets —— 每日签到居中卡片弹窗（官方设计规范重构版）
 *
 * 特性：
 * - 启动自动检测未签到弹窗与个人中心点击入口共用同一组件与数据流；
 * - 严格使用纯色高对比度表面与深浅色主题自适应，零模糊 API；
 * - 所有图标统一采用 HarmonyOS 原生单色矢量 SymbolGlyph，零 Unicode Emoji；
 * - 支持本周一至周日（Mon~Sun）打卡状态、7 天额外积分规则提示、签到提醒开关及 24 小时制时间选择。
 */
import { AuthManager } from '../utils/AuthManager';
import {
  DailySignInManager,
  WEEKDAY_LABELS,
  buildWeekCheckInDays,
  countWeekCheckedDays,
  weekdayMonFirstFromDate
} from '../utils/DailySignInManager';
import { Logger } from '../utils/Logger';
import {
  PreferenceManager,
  ReminderTimeParts,
  formatReminderTime,
  localDateKey,
  parseReminderTime
} from '../utils/PreferenceManager';
import { ThemeColors } from '../utils/Theme';
import { ThemeManager } from '../utils/ThemeManager';
import { LocalizationManager } from '../utils/LocalizationManager';
import { buildPanelImmersiveMaterial } from '../utils/ImmersiveMaterial';
import { resolvePanelMaterialTokens } from '../utils/MaterialPolicy';
import { spatialDialogTransition } from '../utils/ImmersiveMotion';
import { uiMaterial, curves } from '@kit.ArkUI';

const TAG: string = 'CheckInModal';

@ComponentV2
export struct CheckInModal {
  @Local private signInMgr: DailySignInManager = DailySignInManager.getInstance();
  @Local private prefs: PreferenceManager = PreferenceManager.getInstance();
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private i18n: LocalizationManager = LocalizationManager.getInstance();
  @Local private btnPressed: boolean = false;
  private auth: AuthManager = AuthManager.getInstance();
  private autoCloseTimer: number = -1;
  private readonly panelMaterial: uiMaterial.Material | undefined = buildPanelImmersiveMaterial();

  aboutToDisappear(): void {
    if (this.autoCloseTimer >= 0) {
      clearTimeout(this.autoCloseTimer);
      this.autoCloseTimer = -1;
    }
  }

  private isDarkTheme(): boolean {
    return this.theme.palette.bg === '#121212';
  }

  private cardBg(): string {
    return this.isDarkTheme() ? '#1E2025' : '#FFFFFF';
  }

  private cardBorder(): string {
    return this.isDarkTheme() ? '#2E323D' : '#E2E8F0';
  }

  private subCardBg(): string {
    return this.isDarkTheme() ? '#262930' : '#F5F7FA';
  }

  private capsuleBg(): string {
    return this.isDarkTheme() ? '#2A2D35' : '#F1F3F6';
  }

  private iconCircleBg(): string {
    return this.isDarkTheme() ? '#323640' : '#E8ECF2';
  }

  private emblemBg(): string {
    return this.isDarkTheme() ? '#2A253B' : '#EFEAFD';
  }

  private checkedActionBg(): string {
    return this.isDarkTheme() ? '#2B2E36' : '#E5E7EB';
  }

  private checkedActionTextColor(): string {
    return this.isDarkTheme() ? '#8E95A5' : '#94A3B8';
  }

  private isDayChecked(weekdayMonFirst: number): boolean {
    const days: boolean[] = buildWeekCheckInDays(
      weekdayMonFirstFromDate(),
      this.signInMgr.continuousDays,
      this.signInMgr.signedInToday
    );
    return weekdayMonFirst >= 0 && weekdayMonFirst < days.length ? days[weekdayMonFirst] : false;
  }

  private weekCheckedCount(): number {
    const days: boolean[] = buildWeekCheckInDays(
      weekdayMonFirstFromDate(),
      this.signInMgr.continuousDays,
      this.signInMgr.signedInToday
    );
    return countWeekCheckedDays(days);
  }

  private showToast(message: string): void {
    if (message === '') {
      return;
    }
    try {
      this.getUIContext().getPromptAction().showToast({
        message: message,
        duration: 2000
      });
    } catch (e) {
      Logger.debug(TAG, `Toast 展示忽略: ${(e as Error).message}`);
    }
  }

  private async onToggleReminder(isOn: boolean): Promise<void> {
    if (isOn === this.prefs.signInReminderEnabled) {
      return;
    }
    await this.prefs.setSignInReminderEnabled(isOn);
    if (isOn) {
      this.showToast(LocalizationManager.getInstance().getString(
        $r('app.string.checkin_reminder_on_fmt'),
        '已开启每日签到提醒（%s）',
        this.prefs.signInReminderTime
      ));
    } else {
      this.showToast(LocalizationManager.getInstance().getString(
        $r('app.string.checkin_reminder_off'),
        '已关闭签到提醒'
      ));
    }
  }

  private openTimePicker(): void {
    const parts: ReminderTimeParts = parseReminderTime(this.prefs.signInReminderTime);
    const initialDate: Date = new Date();
    initialDate.setHours(parts.hour, parts.minute, 0, 0);
    try {
      this.getUIContext().showTimePickerDialog({
        selected: initialDate,
        useMilitaryTime: true,
        onAccept: (value: TimePickerResult) => {
          const nextHour: number = value.hour !== undefined ? value.hour : parts.hour;
          const nextMinute: number = value.minute !== undefined ? value.minute : parts.minute;
          const formatted: string = formatReminderTime(nextHour, nextMinute);
          void this.prefs.setSignInReminderTime(formatted).then(() => {
            this.showToast(LocalizationManager.getInstance().getString(
              $r('app.string.checkin_reminder_updated_fmt'),
              '提醒时间已设为 %s',
              formatted
            ));
          });
        }
      });
    } catch (e) {
      Logger.warn(TAG, `打开时间选择器失败: ${(e as Error).message}`);
    }
  }

  private async onConfirmSignIn(): Promise<void> {
    if (this.signInMgr.signedInToday || this.signInMgr.signingIn) {
      return;
    }
    const uid: string = this.auth.user !== null ? this.auth.user.uid : '';
    const ok: boolean = await this.signInMgr.confirmSignIn(uid, localDateKey(), false);
    if (this.signInMgr.toastMessage !== '') {
      this.showToast(this.signInMgr.toastMessage);
    }
    if (ok) {
      if (this.autoCloseTimer >= 0) {
        clearTimeout(this.autoCloseTimer);
      }
      this.autoCloseTimer = setTimeout((): void => {
        this.autoCloseTimer = -1;
        this.signInMgr.dismissPrompt();
      }, 900);
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 深色半透明遮罩（点击空白处关闭弹窗）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.55)')
        .transition(TransitionEffect.OPACITY.animation({ duration: 180 }))
        .onClick(() => {
          if (!this.signInMgr.signingIn) {
            this.signInMgr.dismissPrompt();
          }
        })

      // 外层安全滚动：竖屏居中展示，矮屏横屏也可完整滚动触达按钮
      Scroll() {
        Column() {
          this.CheckInCard()
        }
        .width('100%')
        .padding({ left: 24, right: 24, top: 20, bottom: 20 })
        .alignItems(HorizontalAlign.Center)
        .onClick(() => {
          if (!this.signInMgr.signingIn) {
            this.signInMgr.dismissPrompt();
          }
        })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Center)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  CheckInCard() {
    Column() {
      this.TopStatsRow()
      this.WeeklyCalendarCard()
      this.BonusBannerCard()
      this.ReminderCard()
      this.ActionButton()
      this.FooterHint()
    }
    .width('100%')
    .constraintSize({ maxWidth: 400 })
    .padding(18)
    .backgroundColor(this.cardBg())
    .borderRadius(24)
    .borderWidth(1)
    .borderColor(this.cardBorder())
    .systemMaterial(this.panelMaterial)
    .shadow({
      radius: resolvePanelMaterialTokens(this.isDarkTheme()).shadowRadius,
      color: resolvePanelMaterialTokens(this.isDarkTheme()).shadowColor,
      offsetX: 0,
      offsetY: 12
    })
    .clip(true)
    .transition(spatialDialogTransition())
    .alignItems(HorizontalAlign.Center)
    // 拦截卡片内部点击，避免穿透到底部遮罩误关闭弹窗
    .onClick(() => {
    })
  }

  @Builder
  TopStatsRow() {
    Row() {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text(this.i18n.getString($r('app.string.checkin_streak_label'), '连续\n签到'))
            .fontSize(13)
            .lineHeight(17)
            .fontColor(ThemeColors.TEXT_SECONDARY)
            .margin({ bottom: 4 })

          Text(`${this.signInMgr.continuousDays}`)
            .fontSize(38)
            .fontWeight(FontWeight.Bold)
            .lineHeight(42)
            .fontColor(ThemeColors.TEXT_STRONG)

          Text(this.i18n.getString($r('app.string.checkin_days_unit'), '天'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.TEXT_SECONDARY)
            .margin({ bottom: 5 })
        }
        .alignItems(VerticalAlign.Bottom)

        Row() {
          Text(this.i18n.getString(
            $r('app.string.checkin_week_fmt'),
            '本周 %1$d/%2$d 天',
            this.weekCheckedCount(),
            7
          ))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.TEXT)
        }
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .borderRadius(14)
        .backgroundColor(this.capsuleBg())
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 右侧纯矢量签到徽章（零 Emoji、零多余位图）
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(76)
          .height(76)
          .borderRadius(38)
          .backgroundColor(this.emblemBg())

        SymbolGlyph($r('sys.symbol.calendar'))
          .fontSize(36)
          .fontColor([ThemeColors.PRIMARY])

        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.star_fill'))
            .fontSize(12)
            .fontColor(['#FFFFFF'])
        }
        .width(24)
        .height(24)
        .borderRadius(12)
        .backgroundColor(ThemeColors.PRIMARY)
        .position({ x: 54, y: 6 })
      }
      .width(84)
      .height(84)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  WeeklyCalendarCard() {
    Row() {
      ForEach(WEEKDAY_LABELS, (label: string, idx: number) => {
        Column({ space: 8 }) {
          Text(label)
            .fontSize(12)
            .fontWeight(this.isDayChecked(idx) ? FontWeight.Bold : FontWeight.Regular)
            .fontColor(this.isDayChecked(idx) ? ThemeColors.TEXT_STRONG : ThemeColors.TEXT_SECONDARY)
            .opacity(this.isDayChecked(idx) ? 1.0 : 0.72)

          SymbolGlyph(this.isDayChecked(idx)
            ? $r('sys.symbol.checkmark_circle_fill')
            : $r('sys.symbol.checkmark_circle'))
            .fontSize(24)
            .fontColor([this.isDayChecked(idx) ? ThemeColors.PRIMARY : ThemeColors.TEXT_MUTED])
            .opacity(this.isDayChecked(idx) ? 1.0 : 0.24)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
      }, (label: string) => label)
    }
    .width('100%')
    .margin({ top: 14 })
    .padding({ left: 10, right: 10, top: 14, bottom: 14 })
    .borderRadius(16)
    .backgroundColor(this.subCardBg())
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  BonusBannerCard() {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.gift'))
        .fontSize(18)
        .fontColor([ThemeColors.PRIMARY])

      Text(this.i18n.getString($r('app.string.checkin_bonus_banner'), '每签到 7 天可获得额外积分！'))
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemeColors.TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([ThemeColors.TEXT_SECONDARY])
    }
    .width('100%')
    .margin({ top: 10 })
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(14)
    .backgroundColor(this.subCardBg())
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.showToast(this.i18n.getString(
        $r('app.string.checkin_bonus_toast'),
        '连续签到每满 7 天可额外获得积分奖励'
      ));
    })
  }

  @Builder
  ReminderCard() {
    Column() {
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.bell_fill'))
            .fontSize(18)
            .fontColor([ThemeColors.TEXT_STRONG])
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor(this.iconCircleBg())

        Column({ space: 2 }) {
          Text(this.i18n.getString($r('app.string.checkin_reminder_title'), '签到提醒'))
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.TEXT_STRONG)

          Text(this.i18n.getString($r('app.string.checkin_reminder_desc'), '每日定时提醒你签到'))
            .fontSize(12)
            .fontColor(ThemeColors.TEXT_SECONDARY)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12, right: 8 })

        Toggle({ type: ToggleType.Switch, isOn: this.prefs.signInReminderEnabled })
          .selectedColor(ThemeColors.PRIMARY)
          .onChange((isOn: boolean) => {
            void this.onToggleReminder(isOn);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Text(this.i18n.getString($r('app.string.checkin_reminder_time'), '提醒时间'))
          .fontSize(14)
          .fontColor(ThemeColors.TEXT)
          .layoutWeight(1)

        Row({ space: 6 }) {
          Text(this.prefs.signInReminderTime)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.TEXT_SECONDARY)

          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(14)
            .fontColor([ThemeColors.TEXT_SECONDARY])
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .margin({ top: 14 })
      .padding({ top: 4, bottom: 2 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.openTimePicker();
      })
    }
    .width('100%')
    .margin({ top: 10 })
    .padding(14)
    .borderRadius(16)
    .backgroundColor(this.subCardBg())
  }

  @Builder
  ActionButton() {
    Button({ type: ButtonType.Capsule }) {
      Row({ space: 6 }) {
        if (this.signInMgr.signingIn) {
          LoadingProgress().width(16).height(16).color('#FFFFFF')
        }
        Text(this.signInMgr.signedInToday
          ? this.i18n.getString($r('app.string.checkin_btn_done'), '已签到')
          : (this.signInMgr.signingIn
            ? this.i18n.getString($r('app.string.checkin_btn_doing'), '签到中...')
            : this.i18n.getString($r('app.string.checkin_btn_do'), '立即签到')))
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.signInMgr.signedInToday ? this.checkedActionTextColor() : '#FFFFFF')
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(46)
    .margin({ top: 16 })
    .borderWidth(0)
    .backgroundColor(this.signInMgr.signedInToday ? this.checkedActionBg() : ThemeColors.PRIMARY)
    .enabled(!this.signInMgr.signedInToday && !this.signInMgr.signingIn)
    .scale({ x: this.btnPressed ? 0.965 : 1.0, y: this.btnPressed ? 0.965 : 1.0 })
    .onTouch((event: TouchEvent): void => {
      if (this.signInMgr.signedInToday || this.signInMgr.signingIn) {
        this.btnPressed = false;
        return;
      }
      if (event.type === TouchType.Down) {
        this.getUIContext().animateTo({ curve: curves.springMotion(0.32, 0.72) }, (): void => {
          this.btnPressed = true;
        });
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.getUIContext().animateTo({ curve: curves.springMotion(0.36, 0.74) }, (): void => {
          this.btnPressed = false;
        });
      }
    })
    .onClick(() => {
      void this.onConfirmSignIn();
    })
  }

  @Builder
  FooterHint() {
    Row({ space: 4 }) {
      Text(this.i18n.getString($r('app.string.checkin_footer_hint'), '可获得积分或更多随机礼品'))
        .fontSize(12)
        .fontColor(ThemeColors.TEXT_SECONDARY)

      SymbolGlyph($r('sys.symbol.star_circle'))
        .fontSize(14)
        .fontColor([ThemeColors.TEXT_SECONDARY])
    }
    .margin({ top: 10 })
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }
}
