/**
 * BackInterceptRegistry.ets —— 全局系统返回（侧滑返回）LIFO 拦截栈（零 ArkUI 依赖，可离线单测）
 *
 * 用于确保浮层、弹窗、抽屉、搜索栏、大图查看器等按后进先出顺序优先消费系统返回事件，
 * 避免未关闭浮层时直接退出页面或退出应用。
 */

export type BackInterceptHandler = () => boolean;

interface BackInterceptEntry {
  key: string;
  handler: BackInterceptHandler;
}

export class BackInterceptStack {
  private entries: BackInterceptEntry[] = [];

  register(key: string, handler: BackInterceptHandler): void {
    if (key === '') {
      return;
    }
    this.unregister(key);
    this.entries.push({ key: key, handler: handler });
  }

  unregister(key: string): void {
    if (key === '') {
      return;
    }
    const next: BackInterceptEntry[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].key !== key) {
        next.push(this.entries[i]);
      }
    }
    this.entries = next;
  }

  hasHandlers(): boolean {
    return this.entries.length > 0;
  }

  size(): number {
    return this.entries.length;
  }

  clear(): void {
    this.entries = [];
  }

  /** 从栈顶向下依次尝试消费返回事件；命中即返回 true */
  dispatchBack(): boolean {
    for (let i = this.entries.length - 1; i >= 0; i--) {
      const entry: BackInterceptEntry = this.entries[i];
      if (entry.handler()) {
        return true;
      }
    }
    return false;
  }
}

export class BackInterceptRegistry {
  private static instance?: BackInterceptStack;

  static getInstance(): BackInterceptStack {
    if (BackInterceptRegistry.instance === undefined) {
      BackInterceptRegistry.instance = new BackInterceptStack();
    }
    return BackInterceptRegistry.instance;
  }
}
