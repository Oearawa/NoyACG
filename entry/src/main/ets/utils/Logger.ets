/**
 * Logger.ets —— 统一日志工具
 *
 * 基于 hilog 封装，统一 domain 与 TAG 前缀，
 * 便于在 DevEco Studio 的 Log 窗口按「NoyAcg」过滤本应用日志。
 *
 * Phase 14-R：error / warn 额外写入应用内诊断日志（DiagnosticLogManager），
 * 使「设置 → 错误报告」能在应用内查看问题；hilog 行为完全不变。
 * 注意：诊断日志的写入内部**不再调用 Logger**，不存在递归。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DiagnosticLogManager, LOG_LEVEL_ERROR } from './DiagnosticLogManager';
import { isReportableAppError } from './ErrorFilter';

export class Logger {
  /** 日志域标识（合法范围 0x0 ~ 0xFFFF） */
  private static readonly DOMAIN: number = 0x0011;
  /** 全局 TAG */
  private static readonly TAG: string = 'NoyAcg';

  static debug(module: string, message: string): void {
    hilog.debug(Logger.DOMAIN, Logger.TAG, '%{public}s', `[${module}] ${message}`);
  }

  static info(module: string, message: string): void {
    hilog.info(Logger.DOMAIN, Logger.TAG, '%{public}s', `[${module}] ${message}`);
  }

  static warn(module: string, message: string): void {
    hilog.warn(Logger.DOMAIN, Logger.TAG, '%{public}s', `[${module}] ${message}`);
  }

  static error(module: string, message: string): void {
    hilog.error(Logger.DOMAIN, Logger.TAG, '%{public}s', `[${module}] ${message}`);
    Logger.capture(LOG_LEVEL_ERROR, module, message);
  }

  /** 记录 error 并附带堆栈（业务 catch 分支使用；堆栈由诊断日志脱敏后保存） */
  static errorWithStack(module: string, message: string, error: Error | null | undefined): void {
    hilog.error(Logger.DOMAIN, Logger.TAG, '%{public}s', `[${module}] ${message}`);
    const stack: string = error === null || error === undefined || error.stack === undefined
      ? '' : error.stack;
    Logger.capture(LOG_LEVEL_ERROR, module, message, stack);
  }

  /**
   * 写入应用内诊断日志（仅保留可上报的应用级错误）。
   * 任何异常都吞掉 —— 日志系统故障绝不能反向影响业务。
   */
  private static capture(level: string, module: string, message: string, stack?: string): void {
    try {
      if (!isReportableAppError(level, module, message, stack)) {
        return;
      }
      DiagnosticLogManager.getInstance().record(level, module, message, stack);
    } catch (e) {
      // 诊断日志不可用时静默降级到 hilog
    }
  }
}
