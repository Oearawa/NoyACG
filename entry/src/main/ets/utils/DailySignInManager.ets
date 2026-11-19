/**
 * DailySignInManager.ets —— 启动自动检查每日签到与会话内单次弹窗协调器
 *
 * 职责：
 * - 在冷启动会话恢复确认已登录（或登录成功）后，异步检查今日签到状态；
 * - 本地已记录今日已签时直接跳过网络请求；未登录或网络异常时静默忽略，不打扰用户；
 * - 同一次会话内按 `uid + YYYY-MM-DD` 最多检查并提示 1 次，避免反复弹窗；
 * - 弹窗确认签到后同步持久化与 `stateRevision`，联动个人中心状态即时更新。
 */
import { UserRepository } from '../api/UserRepository';
import { AuthRequiredError } from '../api/ApiErrors';
import { SignInRecordResult, SignInResult } from '../source/NoyAcgProtocol';
import { PreferenceManager, localDateKey } from './PreferenceManager';
import { LocalizationManager } from './LocalizationManager';
import { Logger } from './Logger';

const TAG: string = 'DailySignInManager';

export const WEEKDAY_LABELS: string[] = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/**
 * 将 Date 转为周一为 0、周日为 6 的索引（0..6）。
 */
export function weekdayMonFirstFromDate(date: Date = new Date()): number {
  const jsDay: number = date.getDay();
  return (jsDay + 6) % 7;
}

/**
 * 根据今日星期索引（0=Mon..6=Sun）、连续签到天数与今日是否已签到，
 * 推算本周一至周日（Mon..Sun）共 7 天的打卡布尔数组。
 * - 若 checkedInToday === true：今天（todayIdx）已打卡（即使 streakDays 传入 0 也至少标记今天为 true），
 *   并从今天往前推 Math.max(1, streakDays) - 1 天（落在本周 0..todayIdx 范围内）置为 true；
 * - 若 checkedInToday === false：今天（todayIdx）未打卡，从昨天（todayIdx - 1）往前推 streakDays 天
 *   （落在本周 0..todayIdx-1 范围内）置为 true。
 */
export function buildWeekCheckInDays(
  todayWeekdayMonFirst: number,
  streakDays: number,
  checkedInToday: boolean
): boolean[] {
  const result: boolean[] = [false, false, false, false, false, false, false];
  const safeToday: number = Math.max(0, Math.min(6, Math.floor(
    Number.isFinite(todayWeekdayMonFirst) ? todayWeekdayMonFirst : 0
  )));
  const safeStreak: number = Math.max(0, Math.floor(Number.isFinite(streakDays) ? streakDays : 0));

  if (checkedInToday) {
    const effectiveStreak: number = Math.max(1, safeStreak);
    const startIdx: number = Math.max(0, safeToday - (effectiveStreak - 1));
    for (let i: number = startIdx; i <= safeToday; i++) {
      result[i] = true;
    }
  } else if (safeStreak > 0 && safeToday > 0) {
    const endIdx: number = safeToday - 1;
    const startIdx: number = Math.max(0, endIdx - (safeStreak - 1));
    for (let i: number = startIdx; i <= endIdx; i++) {
      result[i] = true;
    }
  }
  return result;
}

/**
 * 统计本周已签到天数（0..7）。
 */
export function countWeekCheckedDays(days: boolean[]): number {
  if (!days || days.length === 0) {
    return 0;
  }
  let count: number = 0;
  for (let i: number = 0; i < days.length && i < 7; i++) {
    if (days[i]) {
      count += 1;
    }
  }
  return count;
}

@ObservedV2
export class DailySignInManager {
  private static instance?: DailySignInManager;

  /** 是否展示「每日签到」弹窗 */
  @Trace showPrompt: boolean = false;
  /** 弹窗内签到请求进行中 */
  @Trace signingIn: boolean = false;
  /** 已知连续签到天数 */
  @Trace continuousDays: number = 0;
  /** 今日是否已签到 */
  @Trace signedInToday: boolean = false;
  /** 最近一次操作提示文案 */
  @Trace toastMessage: string = '';
  /** 状态版本号（供个人中心等监听联动） */
  @Trace stateRevision: number = 0;

  private repo: UserRepository;
  private checking: boolean = false;
  private checkedUidDateKey: string = '';

  constructor(repo?: UserRepository) {
    this.repo = repo ?? new UserRepository();
  }

  static getInstance(): DailySignInManager {
    if (DailySignInManager.instance === undefined) {
      DailySignInManager.instance = new DailySignInManager();
    }
    return DailySignInManager.instance;
  }

  /**
   * 启动时异步检查签到状态：
   * @returns true 表示本次确认未签到并已打开弹窗；false 表示跳过或已签到/异常静默忽略。
   */
  async checkDailySignInOnLaunch(uid: string, dateKey: string = localDateKey()): Promise<boolean> {
    const cleanUid: string = uid.trim();
    if (cleanUid === '') {
      return false;
    }
    const sessionKey: string = `${cleanUid}_${dateKey}`;
    if (this.checking || this.checkedUidDateKey === sessionKey) {
      return false;
    }

    const prefs: PreferenceManager = PreferenceManager.getInstance();
    if (prefs.isSignedInTodaySync(cleanUid, dateKey)) {
      this.checkedUidDateKey = sessionKey;
      this.signedInToday = true;
      return false;
    }

    this.checking = true;
    this.checkedUidDateKey = sessionKey;
    try {
      const record: SignInRecordResult = await this.repo.fetchSignInRecord();
      if (record.continuous > 0) {
        this.continuousDays = record.continuous;
      }
      if (record.today) {
        this.signedInToday = true;
        await prefs.markSignedInToday(cleanUid, dateKey);
        this.stateRevision++;
        return false;
      }
      this.signedInToday = false;
      this.showPrompt = true;
      return true;
    } catch (e) {
      Logger.debug(TAG, `启动签到检查静默忽略: ${(e as Error).message}`);
      return false;
    } finally {
      this.checking = false;
    }
  }

  /**
   * 统一打开签到卡片弹窗（启动自动弹窗与个人中心点击均共用本弹窗）
   */
  openModal(continuousDays?: number, signedInToday?: boolean): void {
    if (continuousDays !== undefined && Number.isFinite(continuousDays) && continuousDays >= 0) {
      this.continuousDays = Math.floor(continuousDays);
    }
    if (signedInToday !== undefined) {
      this.signedInToday = signedInToday;
    }
    this.showPrompt = true;
    void this.refreshRecordSilently();
  }

  /** 打开弹窗时后台静默同步最新连续签到天数与今日签到态，不关闭弹窗 */
  private async refreshRecordSilently(): Promise<void> {
    const startRevision: number = this.stateRevision;
    try {
      const record: SignInRecordResult = await this.repo.fetchSignInRecord();
      if (this.signingIn || this.stateRevision !== startRevision) {
        return;
      }
      if (record.continuous >= 0) {
        this.continuousDays = record.continuous;
      }
      this.signedInToday = record.today;
      this.stateRevision++;
    } catch (e) {
      Logger.debug(TAG, `静默刷新签到记录忽略: ${(e as Error).message}`);
    }
  }

  /** 关闭弹窗（本轮会话不再重复弹出） */
  dismissPrompt(): void {
    this.showPrompt = false;
  }

  /** 在弹窗中点击「立即签到」 */
  async confirmSignIn(
    uid: string,
    dateKey: string = localDateKey(),
    closeOnSuccess: boolean = true
  ): Promise<boolean> {
    const cleanUid: string = uid.trim();
    if (this.signingIn) {
      return false;
    }
    this.signingIn = true;
    this.toastMessage = '';
    try {
      const res: SignInResult = await this.repo.signIn();
      this.signedInToday = true;
      if (res.continuous > 0) {
        this.continuousDays = res.continuous;
      } else if (this.continuousDays <= 0) {
        this.continuousDays = 1;
      }
      if (cleanUid !== '') {
        await PreferenceManager.getInstance().markSignedInToday(cleanUid, dateKey);
      }
      if (closeOnSuccess) {
        this.showPrompt = false;
      }
      this.toastMessage = res.message;
      this.stateRevision++;
      return true;
    } catch (e) {
      if (e instanceof AuthRequiredError) {
        this.toastMessage = LocalizationManager.getInstance().getString(
          $r('app.string.checkin_session_expired'),
          '登录已过期，请重新登录'
        );
      } else {
        this.toastMessage = LocalizationManager.getInstance().getString(
          $r('app.string.checkin_failed_retry'),
          '签到失败，请稍后重试'
        );
      }
      Logger.warn(TAG, `弹窗签到失败: ${(e as Error).message}`);
      return false;
    } finally {
      this.signingIn = false;
    }
  }

  /** 供单测重置状态 */
  resetForTest(): void {
    this.showPrompt = false;
    this.signingIn = false;
    this.continuousDays = 0;
    this.signedInToday = false;
    this.toastMessage = '';
    this.stateRevision = 0;
    this.checking = false;
    this.checkedUidDateKey = '';
  }
}
