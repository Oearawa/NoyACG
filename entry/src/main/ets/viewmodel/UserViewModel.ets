/**
 * UserViewModel.ets —— 用户资料 / 徽章 / 未读 的视图模型（Phase 14-J1）
 *
 * 职责：协调 UserRepository 拉取资料 → 获得徽章图床 origin 后重解析头像/背景 →
 * 拉取未读计数；统一把「未登录」翻译为 needsLogin，把其它失败翻译为 errorMessage。
 *
 * 约束：
 * - 不展示 Integral（积分）—— 本阶段未确认真实积分能力；
 * - 徽章只取 data + show（不读 userinfo.Badge）；
 * - 单次 load 内串行请求，失败可降级（徽章/未读失败不阻断资料展示）。
 */
import { UserInfo, UserBadge } from '../model/UserInfo';
import { MessageCount } from '../model/Message';
import { UserRepository } from '../api/UserRepository';
import { AuthRequiredError } from '../api/ApiErrors';
import { HttpError } from '../api/HttpManager';
import { LocalizationManager } from '../utils/LocalizationManager';
import {
  SignInRecordResult,
  SignInResult,
  badgeImageOrigin,
  rebaseUserAssets
} from '../source/NoyAcgProtocol';
import { Logger } from '../utils/Logger';
import { PreferenceManager, localDateKey } from '../utils/PreferenceManager';

const TAG: string = 'UserViewModel';

@ObservedV2
export class UserViewModel {
  /** 用户资料（null = 未加载/未登录） */
  @Trace userInfo: UserInfo | null = null;
  /** 已佩戴徽章（按 show 顺序） */
  @Trace badges: UserBadge[] = [];
  /** 全部可用徽章（暂存，便于后续扩展；本阶段 UI 只用 badges） */
  @Trace allBadges: UserBadge[] = [];
  /** 未读消息计数 */
  @Trace unread: MessageCount = new MessageCount();
  /** 加载中 */
  @Trace loading: boolean = false;
  /** 错误信息（空 = 无） */
  @Trace errorMessage: string = '';
  /** 未登录/会话失效 */
  @Trace needsLogin: boolean = false;
  /** 今日是否已签到 */
  @Trace signedInToday: boolean = false;
  /** 正在执行签到请求（防连点） */
  @Trace signingIn: boolean = false;
  /** 连续签到天数 */
  @Trace signInContinuous: number = 0;
  /** 最近一次签到反馈提示文案 */
  @Trace signInToast: string = '';

  private repo: UserRepository;
  private disposed: boolean = false;

  constructor(repo?: UserRepository) {
    this.repo = repo ?? new UserRepository();
  }

  /** 未读总数（驱动抽屉角标） */
  get unreadTotal(): number {
    return this.unread.all;
  }

  /**
   * 加载用户资料（串行：资料 → 徽章 → 未读）。
   * @param force true = 强制重拉（打开抽屉时可按需调用）
   */
  async load(force: boolean = false): Promise<void> {
    if (this.loading) {
      return;
    }
    if (!force && this.userInfo !== null && !this.needsLogin) {
      return; // 已有数据且非强制，不重复请求
    }
    this.loading = true;
    this.errorMessage = '';
    this.needsLogin = false;
    try {
      const user: UserInfo = await this.repo.fetchUserInfo();

      // 徽章：拿到图床 origin 后重解析头像/背景；失败不阻断资料展示
      try {
        const badgeResult = await this.repo.fetchBadges();
        this.allBadges = badgeResult.all;
        this.badges = badgeResult.shown;
        const origin: string = badgeImageOrigin(badgeResult.all);
        if (origin !== '') {
          rebaseUserAssets(user, origin);
        }
      } catch (e) {
        if (e instanceof AuthRequiredError) {
          throw e;
        }
        Logger.warn(TAG, `徽章加载失败(忽略): ${(e as Error).message}`);
      }

      // 未读计数：失败不阻断
      try {
        this.unread = await this.repo.fetchMessageCount();
      } catch (e) {
        if (e instanceof AuthRequiredError) {
          throw e;
        }
        Logger.warn(TAG, `未读计数加载失败(忽略): ${(e as Error).message}`);
      }

      // 同步本地与服务端今日签到状态（失败不阻断资料展示）
      const prefs: PreferenceManager = PreferenceManager.getInstance();
      this.signedInToday = prefs.isSignedInTodaySync(user.uid);
      try {
        const record: SignInRecordResult = await this.repo.fetchSignInRecord();
        if (record.continuous > 0) {
          this.signInContinuous = record.continuous;
        }
        if (record.today) {
          this.signedInToday = true;
          await prefs.markSignedInToday(user.uid);
        }
      } catch (e) {
        if (e instanceof AuthRequiredError) {
          throw e;
        }
        Logger.warn(TAG, `签到记录查询失败(忽略): ${(e as Error).message}`);
      }

      if (this.disposed) {
        return;
      }
      this.userInfo = user;
    } catch (e) {
      if (this.disposed) {
        return;
      }
      if (e instanceof AuthRequiredError) {
        this.needsLogin = true;
        this.clearData();
      } else {
        this.errorMessage = e instanceof HttpError ? e.message : '用户资料加载失败';
      }
    } finally {
      this.loading = false;
    }
  }

  /** 仅刷新未读计数（打开抽屉/进入消息页时调用，不高频轮询） */
  async refreshUnread(): Promise<void> {
    try {
      const count: MessageCount = await this.repo.fetchMessageCount();
      if (!this.disposed) {
        this.unread = count;
      }
    } catch (e) {
      // 未读刷新失败静默：不打断抽屉其它内容
      Logger.debug(TAG, `未读计数刷新失败: ${(e as Error).message}`);
    }
  }

  /**
   * 执行每日签到：幂等防连点，成功后按 UID + YYYY-MM-DD 持久化并刷新用户资料。
   */
  async performSignIn(uidOverride?: string, dateOverride?: string): Promise<boolean> {
    const uid: string = (uidOverride ?? this.userInfo?.uid ?? '').trim();
    const dateKey: string = dateOverride ?? localDateKey();
    const prefs: PreferenceManager = PreferenceManager.getInstance();
    if (this.signingIn || this.signedInToday || (uid !== '' && prefs.isSignedInTodaySync(uid, dateKey))) {
      this.signedInToday = true;
      return false;
    }
    this.signingIn = true;
    this.signInToast = '';
    try {
      const res: SignInResult = await this.repo.signIn();
      this.signedInToday = true;
      if (res.continuous > 0) {
        this.signInContinuous = res.continuous;
      }
      if (uid !== '') {
        await prefs.markSignedInToday(uid, dateKey);
      }
      this.signInToast = res.message;
      if (res.status === 'SIGNED') {
        try {
          const updated: UserInfo = await this.repo.fetchUserInfo();
          const origin: string = badgeImageOrigin(this.allBadges);
          if (origin !== '') {
            rebaseUserAssets(updated, origin);
          }
          if (!this.disposed) {
            this.userInfo = updated;
          }
        } catch (_e) {
          // 资料刷新失败不影响已完成的签到结果
        }
      }
      return true;
    } catch (e) {
      if (e instanceof AuthRequiredError) {
        this.needsLogin = true;
        this.signInToast = LocalizationManager.getInstance().getString(
          $r('app.string.checkin_session_expired'),
          '登录已过期，请重新登录'
        );
      } else {
        this.signInToast = LocalizationManager.getInstance().getString(
          $r('app.string.checkin_failed_retry'),
          '签到失败，请稍后重试'
        );
      }
      Logger.warn(TAG, `每日签到失败: ${(e as Error).message}`);
      return false;
    } finally {
      this.signingIn = false;
    }
  }

  /** 清空用户相关状态（登出 / 会话失效时调用） */
  clearData(): void {
    this.userInfo = null;
    this.badges = [];
    this.allBadges = [];
    this.unread = new MessageCount();
    this.signedInToday = false;
    this.signInContinuous = 0;
    this.signInToast = '';
  }

  /** 登出后彻底复位（含错误态） */
  clear(): void {
    this.clearData();
    this.errorMessage = '';
    this.needsLogin = false;
  }

  /** 组件销毁守卫 */
  dispose(): void {
    this.disposed = true;
  }
}
