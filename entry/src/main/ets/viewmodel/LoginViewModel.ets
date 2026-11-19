/**
 * LoginViewModel.ets —— 登录页视图模型（状态管理 V2）
 *
 * 职责：输入校验、防重复提交、把结果翻译成 UI 状态。
 * 安全约束：
 * - 密码只存在于本 VM 的内存字段，登录流程结束（成功或失败）立即清空；
 * - 不写 Preferences、不写日志、不进入任何持久化结构；
 * - 页面销毁后不再回写状态（disposed 守卫）。
 */
import { AuthErrorKind } from '../api/AuthTypes';
import { AuthManager } from '../utils/AuthManager';
import { LocalizationManager } from '../utils/LocalizationManager';
import { Logger } from '../utils/Logger';

const TAG: string = 'LoginViewModel';

@ObservedV2
export class LoginViewModel {
  /** 账号（非敏感，允许保留在输入框） */
  @Trace username: string = '';
  /** 密码（仅登录期间驻留内存，流程结束即清空） */
  @Trace password: string = '';
  /** 是否明文显示密码 */
  @Trace isPasswordVisible: boolean = false;
  /** 提交中（同时作为防重入锁） */
  @Trace isSubmitting: boolean = false;
  /** 表单校验错误（本地，不涉及网络） */
  @Trace validationError: string = '';
  /** 服务端/网络错误提示 */
  @Trace errorMessage: string = '';
  /** 最近一次失败原因（用于 UI 差异化提示） */
  @Trace errorKind: AuthErrorKind | null = null;

  private auth: AuthManager;
  private disposed: boolean = false;

  constructor(auth?: AuthManager) {
    this.auth = auth ?? AuthManager.getInstance();
  }

  /** 切换密码可见性 */
  togglePasswordVisible(): void {
    this.isPasswordVisible = !this.isPasswordVisible;
  }

  /** 本地校验：仅要求非空（不在客户端猜测账号规则） */
  validate(): boolean {
    const lm: LocalizationManager = LocalizationManager.getInstance();
    if (this.username.trim() === '') {
      this.validationError = lm.getString($r('app.string.login_err_empty_username'), '请输入账号');
      return false;
    }
    if (this.password === '') {
      this.validationError = lm.getString($r('app.string.login_err_empty_password'), '请输入密码');
      return false;
    }
    this.validationError = '';
    return true;
  }

  /**
   * 提交登录。
   * @returns true = 已登录（调用方负责返回上一页）
   */
  async submit(): Promise<boolean> {
    if (this.disposed || this.isSubmitting) {
      return false; // 防重复提交
    }
    if (!this.validate()) {
      return false;
    }
    this.isSubmitting = true;
    this.errorMessage = '';
    this.errorKind = null;
    try {
      const ok: boolean = await this.auth.login(this.username, this.password);
      if (this.disposed) {
        return false;
      }
      if (!ok) {
        this.errorKind = this.auth.errorKind;
        this.errorMessage = this.auth.errorMessage === ''
          ? LocalizationManager.getInstance().getString($r('app.string.login_err_failed'), '登录失败，请稍后重试')
          : this.auth.errorMessage;
        return false;
      }
      this.errorMessage = '';
      this.username = '';
      return true;
    } catch (e) {
      if (!this.disposed) {
        this.errorKind = AuthErrorKind.UNKNOWN;
        this.errorMessage = LocalizationManager.getInstance().getString(
          $r('app.string.login_err_exception'),
          '登录异常，请稍后重试'
        );
      }
      Logger.error(TAG, `登录异常: ${(e as Error).message}`);
      return false;
    } finally {
      // 无论成败，密码立即出栈（不保留在内存状态里）
      this.password = '';
      if (!this.disposed) {
        this.isSubmitting = false;
      }
    }
  }

  /** 页面销毁：标记 + 清空密码 */
  dispose(): void {
    this.disposed = true;
    this.password = '';
    this.isSubmitting = false;
  }
}
