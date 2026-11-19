/**
 * MangaImage.ets —— 漫画页图片「防腐层」组件
 *
 * 阶段五：注入 ImageCacheManager（rcp 下载 + 防盗链 Header + MD5 沙盒缓存）。
 * 阶段七：新增 fillPage 形态，供阅读器「水平翻页」模式整页承载单页图。
 * Phase 14-O：改为「固定几何 Stack + 占位层/图片层叠加」：
 *   - 不再用 isImageLoading 切换 Column ↔ Image 根节点类型；
 *   - 同一 URL 已显示成功时跳过重新 resolve，避免文本状态更新把图片打回 Loading；
 *   - 引入请求代次，旧 URL 的慢响应不能覆盖新 URL；
 *   - 使用原生 contentTransition + 受控 opacity 做轻量淡入；
 *   - onComplete/onError 覆盖 URI 就绪到解码完成之间的空窗。
 *
 * 注意：网络图片不使用 syncLoad(true)，避免阻塞 UI 线程。
 */
import { ImageCacheManager, ImageLoadError } from '../utils/ImageCacheManager';
import { CancelToken, RequestCanceledError } from '../api/CancelToken';
import { formatImageDiagRecord, redactImageUrl, requiresAntiLeechReferer } from '../utils/ImageValidator';
import { IS_DEBUG_BUILD } from '../utils/BuildInfo';
import { shouldReloadImage } from '../utils/StableLayout';
import { ThemeColors } from '../utils/Theme';
import { Logger } from '../utils/Logger';

const TAG: string = 'MangaImage';

@ComponentV2
export struct MangaImage {
  @Param imageUrl: string = '';
  @Param fillPage: boolean = false;
  @Param coverRatio: number = 0;
  /** 阅读器流式图片的可信宽高比；0 = 无元数据，保持原有 minHeight 兜底。 */
  @Param streamAspectRatio: number = 0;
  /**
   * 固定尺寸封面填满模式（Phase 14-U2）：
   * 由外层容器显式控制宽高，内部不再用 aspectRatio 自撑高度，
   * 避免列表首帧宽度未测量时高度塌缩为 0（表现为「封面窄条」）。
   * objectFit 用 Cover 裁切填满。
   */
  @Param coverFill: boolean = false;
  /** 失败时是否允许点击占位层手动重试 */
  @Param allowTapRetry: boolean = true;
  /** 内容高斯模糊半径（仅用于剧透/敏感图内容遮罩，0 表示不模糊） */
  @Param blurRadius: number = 0;
  /** 诊断分组标签（如分类名/漫画ID，仅 Debug 脱敏日志使用） */
  @Param diagLabel: string = '';

  @Local localFileUri: string = '';
  @Local isImageLoading: boolean = true;
  @Local hasError: boolean = false;
  @Local imageOpacity: number = 0;

  /** 最近一次已成功解析的 URL（不作为第二套分页/业务状态，只用于幂等） */
  private loadedUrl: string = '';
  private requestGeneration: number = 0;
  private disposed: boolean = false;
  private activeCancelToken?: CancelToken;

  aboutToAppear(): void {
    this.disposed = false;
    this.resolve();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.requestGeneration++;
    this.cancelActiveRequest();
  }

  private cancelActiveRequest(): void {
    if (this.activeCancelToken !== undefined) {
      this.activeCancelToken.cancel();
      this.activeCancelToken = undefined;
    }
  }

  @Monitor('imageUrl', 'fillPage', 'coverRatio', 'streamAspectRatio')
  onImageParamsChange(monitor: IMonitor): void {
    if (!this.disposed) {
      this.resolve();
    }
  }

  private async resolve(forceReload: boolean = false): Promise<void> {
    const url: string = this.imageUrl;
    if (url === '') {
      this.cancelActiveRequest();
      this.localFileUri = '';
      this.loadedUrl = '';
      this.isImageLoading = false;
      this.hasError = false;
      this.imageOpacity = 0;
      return;
    }
    // 同一 URL 且已成功显示：父组件文本/评分/收藏状态更新不应重载图片。
    if (!forceReload && this.localFileUri !== '' &&
      !shouldReloadImage(url, url, this.loadedUrl, this.hasError)) {
      this.isImageLoading = false;
      this.imageOpacity = 1;
      return;
    }

    this.cancelActiveRequest();
    const token: CancelToken = new CancelToken();
    this.activeCancelToken = token;
    const gen: number = ++this.requestGeneration;
    this.loadedUrl = '';
    this.localFileUri = '';
    this.isImageLoading = true;
    this.hasError = false;
    this.imageOpacity = this.fillPage ? 1 : 0;
    try {
      const uri: string = await ImageCacheManager.getInstance().getImage(url, undefined, token);
      if (gen !== this.requestGeneration || this.disposed) {
        return;
      }
      this.localFileUri = uri;
      this.loadedUrl = url;
    } catch (e) {
      if (e instanceof RequestCanceledError || gen !== this.requestGeneration || this.disposed) {
        return;
      }
      const safeUrl: string = redactImageUrl(url);
      // 防盗链域名或明确的图片加载错误绝不降级为无 Referer 的系统 Image(url) 直连（实测必 403）
      if (requiresAntiLeechReferer(url) || e instanceof ImageLoadError) {
        Logger.warn(TAG, `resolve failed (${safeUrl}): ${(e as Error).message}`);
        this.isImageLoading = false;
        this.hasError = true;
        this.imageOpacity = 0;
        this.localFileUri = '';
        this.loadedUrl = '';
        return;
      }
      Logger.warn(TAG, `resolve failed, fallback to source: ${safeUrl}`);
      this.localFileUri = url;
      this.loadedUrl = url;
    } finally {
      if (this.activeCancelToken === token) {
        this.activeCancelToken = undefined;
      }
    }
  }

  private retryLoad(): void {
    if (!this.disposed && this.imageUrl !== '') {
      this.resolve(true);
    }
  }

  private handleImageComplete(): void {
    this.isImageLoading = false;
    this.hasError = false;
    this.imageOpacity = 1;
    if (IS_DEBUG_BUILD) {
      Logger.debug(TAG, formatImageDiagRecord(
        this.diagLabel, this.imageUrl, 'resolved', 200, 'image/*', 0, 'none', 'complete'));
    }
  }

  private handleImageError(error: ImageError): void {
    const failedUrl: string = this.imageUrl;
    this.isImageLoading = false;
    this.hasError = true;
    this.imageOpacity = 0;
    this.localFileUri = '';
    this.loadedUrl = '';
    ImageCacheManager.getInstance().recordDecodeFailure();
    ImageCacheManager.getInstance().invalidateCache(failedUrl);
    if (IS_DEBUG_BUILD) {
      Logger.debug(TAG, formatImageDiagRecord(
        this.diagLabel, failedUrl, 'evicted', 0, '-', 0, `decode:${error.message}`, 'onError'));
    }
    Logger.warn(TAG, `decode failed: ${redactImageUrl(failedUrl)}`);
  }

  @Builder
  PlaceholderLayer() {
    if (this.isImageLoading || this.hasError || this.localFileUri === '') {
      Column() {
        if (this.hasError) {
          Text('!')
            .fontSize(22)
            .fontColor(ThemeColors.TEXT_MUTED)
        } else {
          LoadingProgress()
            .width(22)
            .height(22)
            .color(ThemeColors.PLACEHOLDER)
        }
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.fillPage ? ThemeColors.BG : ThemeColors.SURFACE)
      .onClick(this.hasError && this.allowTapRetry ? (): void => {
        this.retryLoad();
      } : undefined)
    }
  }

  @Builder
  ImageLayer() {
    if (this.localFileUri !== '') {
      if (this.fillPage) {
        Image(this.localFileUri)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .backgroundColor(ThemeColors.BG)
          .draggable(false)
          .opacity(this.imageOpacity)
          .blur(this.blurRadius > 0 ? this.blurRadius : 0)
          .onComplete(() => {
            this.handleImageComplete();
          })
          .onError((error: ImageError) => {
            this.handleImageError(error);
          })
      } else {
        Image(this.localFileUri)
          .width('100%')
          .height('100%')
          .objectFit(this.coverRatio > 0 || this.coverFill ? ImageFit.Cover : ImageFit.Contain)
          .alt($r('app.media.placeholder'))
          .backgroundColor(ThemeColors.SURFACE)
          .draggable(false)
          .contentTransition(ContentTransitionEffect.OPACITY)
          .opacity(this.imageOpacity)
          .blur(this.blurRadius > 0 ? this.blurRadius : 0)
          .onComplete(() => {
            this.handleImageComplete();
          })
          .onError((error: ImageError) => {
            this.handleImageError(error);
          })
      }
    }
  }

  build() {
    if (this.coverFill) {
      // 固定尺寸封面：由外层容器控制宽高，内部 fill 100%，Cover 裁切
      Stack() {
        this.PlaceholderLayer()
        this.ImageLayer()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemeColors.SURFACE)
      .clip(true)
    } else if (this.coverRatio > 0) {
      Stack() {
        this.PlaceholderLayer()
        this.ImageLayer()
      }
      .width('100%')
      .aspectRatio(this.coverRatio)
      .backgroundColor(ThemeColors.SURFACE)
      .clip(true)
    } else if (this.fillPage) {
      Stack() {
        this.PlaceholderLayer()
        this.ImageLayer()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemeColors.BG)
    } else if (this.streamAspectRatio > 0) {
      Stack() {
        this.PlaceholderLayer()
        this.ImageLayer()
      }
      .width('100%')
      .aspectRatio(this.streamAspectRatio)
      .backgroundColor(ThemeColors.BG_DEEP)
    } else {
      // 无服务端尺寸元数据：占位与图片共用同一 minHeight，不伪装成已知最终比例。
      Stack() {
        this.PlaceholderLayer()
        this.ImageLayer()
      }
      .width('100%')
      .constraintSize({ minHeight: 180 })
      .backgroundColor(ThemeColors.BG_DEEP)
    }
  }
}
