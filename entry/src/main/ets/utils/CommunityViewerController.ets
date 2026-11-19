/**
 * CommunityViewerController.ets —— 社区全屏大图查看器状态控制器
 *
 * 提升至 Index.ets 最顶层 Stack 渲染，确保查看大图时完全覆盖底部 5 Tab / 侧边栏与状态栏，
 * 并统一响应系统侧滑返回关闭。
 */
@ObservedV2
export class CommunityViewerController {
  private static instance?: CommunityViewerController;

  @Trace imageUrl: string = '';

  static getInstance(): CommunityViewerController {
    if (CommunityViewerController.instance === undefined) {
      CommunityViewerController.instance = new CommunityViewerController();
    }
    return CommunityViewerController.instance;
  }

  isOpen(): boolean {
    return this.imageUrl !== '';
  }

  open(url: string): void {
    const clean: string = url.trim();
    if (clean !== '') {
      this.imageUrl = clean;
    }
  }

  close(): void {
    this.imageUrl = '';
  }

  closeIfOpen(): boolean {
    if (this.imageUrl !== '') {
      this.imageUrl = '';
      return true;
    }
    return false;
  }
}
