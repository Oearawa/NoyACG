/**
 * CancelToken.ets —— 请求取消令牌（I-000004 断网检测与自动重试）
 *
 * 场景：HttpManager 的 GET 重试/挂起循环在「退避等待」「断网等待」阶段可被取消；
 * 取消传播：已经开始执行的底层请求由 rcp 取消码（1007900992）识别为已取消，绝不重试。
 *
 * 与 DownloadToken（download/DownloadPorts.ets）互不相关：
 * 下载层有自己的取消句柄，这里只管 HttpManager 的请求生命周期。
 */
export class CancelToken {
  private canceled: boolean = false;
  private listeners: (() => void)[] = [];

  isCanceled(): boolean {
    return this.canceled;
  }

  /** 触发取消：监听器同步执行；幂等（多次调用只生效一次） */
  cancel(): void {
    if (this.canceled) {
      return;
    }
    this.canceled = true;
    const pending: (() => void)[] = this.listeners.slice();
    this.listeners = [];
    for (let i = 0; i < pending.length; i++) {
      pending[i]();
    }
  }

  /**
   * 注册取消监听；若已取消则立即回调。
   * 返回反注册函数（退避计时结束等场景用于防止监听器残留）。
   */
  onCancel(listener: () => void): () => void {
    if (this.canceled) {
      listener();
      return (): void => {
      };
    }
    this.listeners.push(listener);
    return (): void => {
      const index: number = this.listeners.indexOf(listener);
      if (index >= 0) {
        this.listeners.splice(index, 1);
      }
    };
  }
}

/** 调用方取消请求（与网络失败语义分离：绝不重试、不算业务失败） */
export class RequestCanceledError extends Error {
  constructor(message: string = '请求已取消') {
    super(message);
    this.name = 'RequestCanceledError';
  }
}
