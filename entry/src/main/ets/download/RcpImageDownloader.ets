/**
 * RcpImageDownloader.ets —— 生产图片下载端口实现（Phase 12）
 *
 * 采用 API 26 RCP 的**流式**能力，避免大图一次性驻留内存：
 * `HttpManager.streamToSink()` 把 `Request.destination` 设为 `IncomingDataCallback`，
 * 每个 chunk 立刻经 `DownloadFsPort.appendChunk()` 追加到 `.part` 临时文件。
 *
 * 取消语义（任务书 Step 5）：
 * - 已发出的请求**不能**靠改状态取消；这里在 Request 创建瞬间用
 *   `DownloadToken.onCancel()` 注册 `rcp.Session.cancel(request)`；
 * - 暂停/取消 → token.cancel() → 真正取消 RCP 请求 → fetch 抛 1007900992
 *   → 归一化为 `DownloadInterrupted`，不计入失败图片数；
 * - 不依赖「无法停止的 Promise.all 并发模式」：并发上限由 DownloadManager 统一控制，
 *   每个在途请求都有独立 token 可取消。
 *
 * ⚠ 本文件是真实 RCP / 真机文件系统实现；本地单元测试用内存端口替代，
 * 不触网、不写沙盒，也不宣称验证了真实 HTTP 下载（见 PHASE12_REPORT.md）。
 */
import { rcp } from '@kit.RemoteCommunicationKit';
import { HttpManager, HttpError } from '../api/HttpManager';
import { Logger } from '../utils/Logger';
import {
  DownloadError,
  DownloadFsPort,
  DownloadImagePort,
  DownloadInterrupted,
  DownloadToken
} from './DownloadPorts';
import { SandboxDownloadFs } from './DownloadStorage';

const TAG: string = 'RcpImageDownloader';

export class RcpImageDownloader implements DownloadImagePort {
  private fsPort: DownloadFsPort;
  private http: HttpManager;

  constructor(fsPort?: DownloadFsPort, http?: HttpManager) {
    this.fsPort = fsPort ?? new SandboxDownloadFs();
    this.http = http ?? HttpManager.getInstance();
  }

  async fetch(url: string, tempPath: string, headers: Record<string, string>,
    token: DownloadToken): Promise<number> {
    const maxAttempts: number = 2;
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      if (token.isCanceled) {
        throw new DownloadInterrupted();
      }
      try {
        return await this.fetchOnce(url, tempPath, headers, token);
      } catch (e) {
        if (e instanceof DownloadInterrupted || token.isCanceled) {
          throw new DownloadInterrupted();
        }
        const err = e as DownloadError;
        if (attempt >= maxAttempts || err.causeKind === 'IO') {
          throw err;
        }
        await this.fsPort.remove(tempPath);
        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, 250);
        });
      }
    }
    return 0;
  }

  private async fetchOnce(url: string, tempPath: string, headers: Record<string, string>,
    token: DownloadToken): Promise<number> {
    if (token.isCanceled) {
      throw new DownloadInterrupted();
    }
    let written: number = 0;
    let writeFailure: DownloadError | null = null;

    const sink = async (chunk: ArrayBuffer): Promise<void> => {
      if (token.isCanceled || writeFailure !== null) {
        return; // 已取消/已出错：丢弃后续 chunk，但请求仍会走完或由 cancel 中止
      }
      try {
        written = await this.fsPort.appendChunk(tempPath, chunk);
      } catch (e) {
        writeFailure = e instanceof DownloadError
          ? e : new DownloadError('IO', `分块写入失败: ${(e as Error).message}`);
      }
    };

    try {
      await this.http.streamToSink(url, headers, sink,
        (request: rcp.Request): void => {
          token.onCancel((): void => {
            this.http.cancelRequest(request);
          });
        });
    } catch (e) {
      if (token.isCanceled) {
        throw new DownloadInterrupted();
      }
      const reason: string = e instanceof HttpError ? e.message : (e as Error).message;
      Logger.warn(TAG, `图片请求失败: ${reason}`);
      throw new DownloadError('NETWORK', `图片下载失败: ${reason}`);
    }

    if (token.isCanceled) {
      throw new DownloadInterrupted();
    }
    if (writeFailure !== null) {
      const failure: DownloadError = writeFailure;
      throw new DownloadError(failure.causeKind, failure.message);
    }
    return written;
  }
}
