/**
 * ChapterImageProvider.ets —— 阅读器统一图片来源（Phase 12）
 *
 * 目标：阅读器只需 `ChapterImageSet`，不必知道图片来自网络还是本地。
 * - 在线：包装既有 `IComicSource.getChapterImages()`（string[] 契约不变）；
 * - 离线：`OfflineChapterSource` 返回同一模型的 `file://` 列表；
 * - 组合来源：本地完整 → 离线；本地存在但不完整 → 明确不完整；本地不存在 → 在线。
 *
 * 「本地不完整」**不**静默回退到在线下载，因为那会掩盖「删除后仍显示旧路径」等风险；
 * 阅读器会显示明确提示与重试入口。离线路径全程不检查登录态、不触发在线搜索。
 */
import { IComicSource } from '../source/IComicSource';
import { noyAcgSource } from '../source/NoyAcgSource';
import { DownloadFactory } from './DownloadFactory';
import { OfflineChapterSource } from './OfflineChapterSource';
import { ChapterImageProvider, ChapterImageSet } from './DownloadPorts';
import { Logger } from '../utils/Logger';

const TAG: string = 'ChapterImageProvider';

/** 在线来源适配器（不改动 IComicSource 的 string[] 返回契约） */
export class OnlineChapterImageProvider implements ChapterImageProvider {
  private source: IComicSource;

  constructor(source: IComicSource) {
    this.source = source;
  }

  async getChapterImages(bookId: string, chapterId: string): Promise<ChapterImageSet> {
    const urls: string[] = await this.source.getChapterImages(bookId, chapterId);
    return ChapterImageSet.online(urls);
  }
}

/** 本地优先 + 在线兜底的组合来源 */
export class CompositeChapterImageProvider implements ChapterImageProvider {
  private offline: OfflineChapterSource;
  private online: ChapterImageProvider;

  constructor(offline: OfflineChapterSource, online: ChapterImageProvider) {
    this.offline = offline;
    this.online = online;
  }

  async getChapterImages(bookId: string, chapterId: string): Promise<ChapterImageSet> {
    const local = await this.offline.lookup(bookId, chapterId);
    if (local.exists) {
      if (local.complete) {
        Logger.info(TAG, `命中离线章节 ${bookId}/${chapterId}: ${local.images.length} 张`);
        return ChapterImageSet.local(local.images);
      }
      // 文件被删除/损坏：绝不回退到网络掩盖问题，也不返回残缺列表
      return ChapterImageSet.incomplete(local.message === ''
        ? '本地章节不完整，请重新下载' : local.message);
    }
    // 异常原样透传：AuthRequiredError / ProtocolError / HttpError 的类型语义必须保留，
    // 由阅读器 VM 精确区分「需要登录」与「网络/协议错误」。
    return await this.online.getChapterImages(bookId, chapterId);
  }
}

export class ChapterImageProviders {
  /** 生产默认来源；未注入下载上下文时退化为纯在线，绝不误报离线可用 */
  static createDefault(): ChapterImageProvider {
    const services = DownloadFactory.get();
    if (services === undefined) {
      return new OnlineChapterImageProvider(noyAcgSource);
    }
    return new CompositeChapterImageProvider(services.offline,
      new OnlineChapterImageProvider(noyAcgSource));
  }

  /** 单元测试/兼容：只用注入的源（跳过离线检查） */
  static onlineOnly(source: IComicSource): ChapterImageProvider {
    return new OnlineChapterImageProvider(source);
  }

  /** 单元测试：强制离线来源（验证不完整/删除后的行为） */
  static offlineOnly(offline: OfflineChapterSource): ChapterImageProvider {
    return new CompositeChapterImageProvider(offline,
      new OnlineChapterImageProvider(noyAcgSource));
  }
}
