/**
 * CategoryImageLoading.test.ets —— 分类页与图片加载全链路回归测试矩阵（Phase 4）
 *
 * 覆盖：
 * 1. URL 校验与协议映射：合法/非法/空/相对/已编码/中文/query/签名/bigtaglist cover=0；
 * 2. 网络与有界重试：200 / 403 / 404 / 429(Retry-After) / 500 / 503 / 超时 / 断网恢复 / 取消；
 * 3. 图片魔数与解码前校验：JPEG / PNG / WebP / GIF / AVIF / 错误 MIME / 非图片响应 / 截断 / 0 字节；
 * 4. 缓存行为：冷热缓存 / query 隔离 / 坏响应不落盘 / 损坏自愈清理；
 * 5. 生命周期与并发：同 URL 多消费者去重 / 部分取消不误杀 / 全部取消中止底层 / 并发上限(6) / 乱序守卫。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  IMAGE_FORMAT_AVIF,
  IMAGE_FORMAT_EMPTY,
  IMAGE_FORMAT_GIF,
  IMAGE_FORMAT_JPEG,
  IMAGE_FORMAT_PNG,
  IMAGE_FORMAT_TEXT,
  IMAGE_FORMAT_TRUNCATED,
  IMAGE_FORMAT_UNKNOWN,
  IMAGE_FORMAT_WEBP,
  detectImageFormat,
  formatImageDiagRecord,
  isMimeCompatibleWithImage,
  isSupportedImageFormat,
  redactImageUrl,
  redactImageUrlWithParamKeys,
  requiresAntiLeechReferer,
  validateImageUrl
} from '../main/ets/utils/ImageValidator';
import {
  ImageCacheManager,
  ImageLoadError,
  ImageMetricsSnapshot
} from '../main/ets/utils/ImageCacheManager';
import { HttpBytesResult, HttpError } from '../main/ets/api/HttpManager';
import { CancelToken, RequestCanceledError } from '../main/ets/api/CancelToken';
import { RequestGate, RequestSlot, Transport } from '../main/ets/api/RequestGate';
import {
  RETRY_AFTER_CAP_MS,
  RETRY_MAX_ATTEMPTS,
  classifyRetry,
  parseRetryAfterMs,
  resolveRetryDelayMs
} from '../main/ets/api/RetryPolicy';
import { buildCoverUrl, parseBigTagList, RawBigTagEnvelope } from '../main/ets/source/NoyAcgProtocol';
import { shouldReloadImage } from '../main/ets/utils/StableLayout';

function makeWebpBytes(): Uint8Array {
  // RIFF....WEBP + 4 bytes payload
  return new Uint8Array([
    0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00,
    0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20
  ]);
}

function makeJpegBytes(): Uint8Array {
  return new Uint8Array([
    0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46,
    0x49, 0x46, 0x00, 0x01, 0x01, 0x00
  ]);
}

function makePngBytes(): Uint8Array {
  return new Uint8Array([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52
  ]);
}

function makeGifBytes(): Uint8Array {
  return new Uint8Array([
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00,
    0x01, 0x00, 0x80, 0x00, 0x00
  ]);
}

function makeAvifBytes(): Uint8Array {
  return new Uint8Array([
    0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70,
    0x61, 0x76, 0x69, 0x66, 0x00, 0x00, 0x00, 0x00
  ]);
}

function makeHtmlBytes(): Uint8Array {
  const text: string = '<html><body>403 Forbidden</body></html>';
  const arr: Uint8Array = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) {
    arr[i] = text.charCodeAt(i);
  }
  return arr;
}

class FlakyGateTransport implements Transport<string> {
  attempts: number = 0;
  failUntilAttempt: number = 0;
  statusToThrow: number = 503;
  retryHint: string = 'http';
  retryAfterMs?: number;

  async execute(slot: RequestSlot<string>): Promise<void> {
    this.attempts++;
    if (this.attempts <= this.failUntilAttempt) {
      slot.done = false;
      slot.errorObj = new HttpError(this.statusToThrow, 'simulated error',
        this.retryHint, this.retryAfterMs);
      return;
    }
    slot.done = true;
    slot.value = 'ok';
  }
}

class GateLatch {
  release: () => void = (): void => {
  };
}

function resetImageManager(): ImageCacheManager {
  const mgr: ImageCacheManager = ImageCacheManager.getInstance();
  mgr.clearMemoryForTest();
  mgr.resetCountersForTest();
  mgr.resetMetricsForTest();
  mgr.setTestDownloaderForTest(undefined);
  return mgr;
}

export default function categoryImageLoadingTest() {
  describe('CategoryImage_URLValidationAndMapping', () => {
    it('validatesAbsoluteRelativeEmptyAndMalformedUrls', 0, () => {
      const valid = validateImageUrl('https://img.noymanga.com/42604/m1.webp');
      expect(valid.valid).assertTrue();
      expect(valid.scheme).assertEqual('https');
      expect(valid.host).assertEqual('img.noymanga.com');
      expect(valid.path).assertEqual('/42604/m1.webp');
      expect(valid.hasQuery).assertFalse();

      expect(validateImageUrl('').valid).assertFalse();
      expect(validateImageUrl('   ').valid).assertFalse();
      expect(validateImageUrl('/42604/m1.webp').valid).assertFalse();
      expect(validateImageUrl('javascript:alert(1)').valid).assertFalse();
      expect(validateImageUrl('https://').valid).assertFalse();
      expect(validateImageUrl('https://img.noymanga.com/a b.webp').valid).assertFalse();
      expect(validateImageUrl('file:///data/cache/a.webp').isLocalFile).assertTrue();
    });

    it('preservesEncodedPathChineseCharsAndSignedQueryWithoutRedactionLeak', 0, () => {
      const encoded: string = 'https://img.noymanga.com/path%201/%E5%88%86%E9%A1%9E/m1.webp?Expires=1700000&Signature=secretToken';
      const parsed = validateImageUrl(encoded);
      expect(parsed.valid).assertTrue();
      expect(parsed.normalizedUrl).assertEqual(encoded);
      expect(parsed.hasQuery).assertTrue();

      const redacted: string = redactImageUrl(encoded);
      expect(redacted.indexOf('secretToken') < 0).assertTrue();
      expect(redacted.indexOf('?<redacted>') >= 0).assertTrue();

      const keyOnly: string = redactImageUrlWithParamKeys(encoded);
      expect(keyOnly.indexOf('secretToken') < 0).assertTrue();
      expect(keyOnly.indexOf('Expires&Signature') >= 0).assertTrue();

      const diagLine: string = formatImageDiagRecord(
        '奇幻', encoded, 'network-ok', 200, 'image/webp', 2048, 'none', 'ok');
      expect(diagLine.indexOf('奇幻') >= 0).assertTrue();
      expect(diagLine.indexOf('secretToken') < 0).assertTrue();
      expect(diagLine.indexOf('Expires&Signature') >= 0).assertTrue();
    });

    it('treatsCoverBidZeroAsMissingInBigTagListAndBuildCoverUrl', 0, () => {
      expect(buildCoverUrl('0')).assertEqual('');
      expect(buildCoverUrl(' 0 ')).assertEqual('');
      expect(buildCoverUrl('-5')).assertEqual('');
      expect(buildCoverUrl('42604')).assertEqual('https://img.noymanga.com/42604/m1.webp');
      expect(buildCoverUrl('123', 'stream')).assertEqual('https://stream.noyteam.online/-123/cover.webp');

      const envelope: RawBigTagEnvelope = {
        status: 'ok',
        data: [
          { tag: 'ZeroCover', search: ['ZeroCover'], cover: 0 },
          { tag: 'ValidCover', search: ['ValidCover'], cover: 42604 }
        ]
      };
      const items = parseBigTagList(envelope);
      expect(items.length).assertEqual(2);
      expect(items[0].hasCover).assertFalse();
      expect(items[0].cover).assertEqual('');
      expect(items[0].coverBid).assertEqual(-1);
      expect(items[1].hasCover).assertTrue();
      expect(items[1].cover).assertEqual('https://img.noymanga.com/42604/m1.webp');
    });

    it('identifiesAntiLeechDomains', 0, () => {
      expect(requiresAntiLeechReferer('https://img.noymanga.com/1/m1.webp')).assertTrue();
      expect(requiresAntiLeechReferer('https://stream.noyteam.online/-1/cover.webp')).assertTrue();
      expect(requiresAntiLeechReferer('https://cdn.example.com/1.webp')).assertFalse();
    });
  });

  describe('CategoryImage_FormatAndMimeDetection', () => {
    it('detectsSupportedImageFormatsByMagicBytes', 0, () => {
      expect(detectImageFormat(makeJpegBytes())).assertEqual(IMAGE_FORMAT_JPEG);
      expect(detectImageFormat(makePngBytes())).assertEqual(IMAGE_FORMAT_PNG);
      expect(detectImageFormat(makeWebpBytes())).assertEqual(IMAGE_FORMAT_WEBP);
      expect(detectImageFormat(makeGifBytes())).assertEqual(IMAGE_FORMAT_GIF);
      expect(detectImageFormat(makeAvifBytes())).assertEqual(IMAGE_FORMAT_AVIF);
      expect(isSupportedImageFormat(IMAGE_FORMAT_WEBP)).assertTrue();
      expect(isSupportedImageFormat(IMAGE_FORMAT_AVIF)).assertTrue();
    });

    it('rejectsEmptyTruncatedHtmlAndUnknownPayloads', 0, () => {
      expect(detectImageFormat(new Uint8Array(0))).assertEqual(IMAGE_FORMAT_EMPTY);
      expect(detectImageFormat(new Uint8Array([0x52, 0x49, 0x46]))).assertEqual(IMAGE_FORMAT_TRUNCATED);
      expect(detectImageFormat(makeHtmlBytes())).assertEqual(IMAGE_FORMAT_TEXT);
      expect(detectImageFormat(new Uint8Array(16).fill(0x11))).assertEqual(IMAGE_FORMAT_UNKNOWN);
    });

    it('validatesMimeCompatibilityWithDetectedFormat', 0, () => {
      expect(isMimeCompatibleWithImage('image/webp', IMAGE_FORMAT_WEBP)).assertTrue();
      expect(isMimeCompatibleWithImage('application/octet-stream', IMAGE_FORMAT_JPEG)).assertTrue();
      expect(isMimeCompatibleWithImage(undefined, IMAGE_FORMAT_PNG)).assertTrue();
      expect(isMimeCompatibleWithImage('text/html; charset=UTF-8', IMAGE_FORMAT_WEBP)).assertFalse();
      expect(isMimeCompatibleWithImage('application/json', IMAGE_FORMAT_JPEG)).assertFalse();
      expect(isMimeCompatibleWithImage('image/webp', IMAGE_FORMAT_TEXT)).assertFalse();
    });
  });

  describe('CategoryImage_NetworkAndRetryPolicy', () => {
    it('classifiesRetryableAndNonRetryableImageErrors', 0, () => {
      expect(classifyRetry(new HttpError(403, 'forbidden', 'http')).retryable).assertFalse();
      expect(classifyRetry(new HttpError(404, 'not found', 'http')).retryable).assertFalse();
      expect(classifyRetry(new HttpError(410, 'gone', 'http')).retryable).assertFalse();
      expect(classifyRetry(new HttpError(408, 'timeout', 'http')).retryable).assertTrue();
      expect(classifyRetry(new HttpError(429, 'rate limit', 'http')).retryable).assertTrue();
      expect(classifyRetry(new HttpError(500, 'server err', 'http')).retryable).assertTrue();
      expect(classifyRetry(new HttpError(502, 'bad gateway', 'http')).retryable).assertTrue();
      expect(classifyRetry(new HttpError(503, 'unavailable', 'http')).retryable).assertTrue();
      expect(classifyRetry(new HttpError(-1, 'dns/tls', 'network')).retryable).assertTrue();
      expect(classifyRetry(new HttpError(1007900992, 'canceled', 'cancel')).retryable).assertFalse();
    });

    it('stopsAfterMaxAttemptsOnPersistent503', 0, async () => {
      const gate: RequestGate = new RequestGate();
      const transport: FlakyGateTransport = new FlakyGateTransport();
      transport.failUntilAttempt = 99;
      transport.statusToThrow = 503;
      transport.retryAfterMs = 5;
      let failed: boolean = false;
      try {
        await gate.run('GET', 'img:persistent503', transport);
      } catch (e) {
        failed = true;
      }
      expect(failed).assertTrue();
      expect(transport.attempts).assertEqual(RETRY_MAX_ATTEMPTS);
    });

    it('parsesAndCapsRetryAfterHeader', 0, () => {
      expect(parseRetryAfterMs('2')).assertEqual(2000);
      expect(parseRetryAfterMs('999')).assertEqual(RETRY_AFTER_CAP_MS);
      expect(parseRetryAfterMs('invalid')).assertUndefined();
      const err: HttpError = new HttpError(429, 'too many', 'http', 3000);
      expect(resolveRetryDelayMs(err, 500)).assertEqual(3000);
    });

    it('recoversFromTransient503WithinBoundedAttempts', 0, async () => {
      const gate: RequestGate = new RequestGate();
      const transport: FlakyGateTransport = new FlakyGateTransport();
      transport.failUntilAttempt = 2;
      transport.statusToThrow = 503;
      transport.retryAfterMs = 10;
      const result: string = await gate.run('GET', 'img:test', transport);
      expect(result).assertEqual('ok');
      expect(transport.attempts).assertEqual(3);
    });

    it('doesNotRetry404AndHonorsCancelDuringOfflineWait', 0, async () => {
      const gate: RequestGate = new RequestGate();
      const transport: FlakyGateTransport = new FlakyGateTransport();
      transport.failUntilAttempt = 5;
      transport.statusToThrow = 404;
      let failed404: boolean = false;
      try {
        await gate.run('GET', 'img:404', transport);
      } catch (e) {
        failed404 = true;
      }
      expect(failed404).assertTrue();
      expect(transport.attempts).assertEqual(1);

      gate.setOffline();
      const token: CancelToken = new CancelToken();
      let canceled: boolean = false;
      const pending = gate.run('GET', 'img:offline', transport, token).catch((e: Object) => {
        if (e instanceof RequestCanceledError) {
          canceled = true;
        }
      });
      token.cancel();
      await pending;
      expect(canceled).assertTrue();
    });

    it('replaysSuspendedGetOnNetworkRecovery', 0, async () => {
      const gate: RequestGate = new RequestGate();
      const transport: FlakyGateTransport = new FlakyGateTransport();
      gate.setOffline();
      const promise: Promise<string> = gate.run('GET', 'img:recover', transport);
      expect(transport.attempts).assertEqual(0);
      gate.setOnline();
      const value: string = await promise;
      expect(value).assertEqual('ok');
      expect(transport.attempts).assertEqual(1);
    });
  });

  describe('CategoryImage_CacheConcurrencyAndCancellation', () => {
    it('isolatesCacheByQueryParamsAndRejectsNonImageWithoutCaching', 0, async () => {
      const mgr: ImageCacheManager = resetImageManager();
      let fetchCount: number = 0;
      mgr.setTestDownloaderForTest(async (url: string, _token: CancelToken): Promise<HttpBytesResult> => {
        fetchCount++;
        if (url.indexOf('bad=1') >= 0) {
          return new HttpBytesResult(makeHtmlBytes(), 200, 'text/html');
        }
        return new HttpBytesResult(makeWebpBytes(), 200, 'image/webp');
      });

      const uri1: string = await mgr.getImage('https://img.noymanga.com/1/m1.webp?v=1');
      const uri2: string = await mgr.getImage('https://img.noymanga.com/1/m1.webp?v=2');
      expect(uri1 !== uri2).assertTrue();
      expect(fetchCount).assertEqual(2);

      // 热缓存命中
      const uri1Again: string = await mgr.getImage('https://img.noymanga.com/1/m1.webp?v=1');
      expect(uri1Again).assertEqual(uri1);
      expect(fetchCount).assertEqual(2);

      // 非图片响应（HTML 200 及 0 字节 200）均被拒绝且不缓存
      let decodeFailed: boolean = false;
      try {
        await mgr.getImage('https://img.noymanga.com/2/m1.webp?bad=1');
      } catch (e) {
        if (e instanceof ImageLoadError && e.kind === 'decode') {
          decodeFailed = true;
        }
      }
      expect(decodeFailed).assertTrue();
      expect(mgr.getMemoryKeysForTest().indexOf('https://img.noymanga.com/2/m1.webp?bad=1') < 0).assertTrue();

      mgr.setTestDownloaderForTest(async (_url: string, _token: CancelToken): Promise<HttpBytesResult> => {
        fetchCount++;
        return new HttpBytesResult(new Uint8Array(0), 200, 'image/webp');
      });
      let emptyFailed: boolean = false;
      try {
        await mgr.getImage('https://img.noymanga.com/3/m1.webp?empty=1');
      } catch (e) {
        if (e instanceof ImageLoadError && e.kind === 'decode') {
          emptyFailed = true;
        }
      }
      expect(emptyFailed).assertTrue();
      expect(mgr.getMemoryKeysForTest().indexOf('https://img.noymanga.com/3/m1.webp?empty=1') < 0).assertTrue();

      const metrics: ImageMetricsSnapshot = mgr.getMetrics();
      expect(metrics.successCount).assertEqual(3);
      expect(metrics.decodeFailureCount).assertEqual(2);
      mgr.setTestDownloaderForTest(undefined);
    });

    it('evictsCorruptedCacheAndRecoversOnRefetch', 0, async () => {
      const mgr: ImageCacheManager = resetImageManager();
      const targetUrl: string = 'https://img.noymanga.com/88/m1.webp';
      mgr.setMemoryCacheForTest(targetUrl, 'file://corrupt/88.webp');
      expect(await mgr.getImage(targetUrl)).assertEqual('file://corrupt/88.webp');

      await mgr.invalidateCache(targetUrl);
      mgr.recordDecodeFailure();
      expect(mgr.getMemoryKeysForTest().indexOf(targetUrl) < 0).assertTrue();

      let refetched: boolean = false;
      mgr.setTestDownloaderForTest(async (_url: string, _token: CancelToken): Promise<HttpBytesResult> => {
        refetched = true;
        return new HttpBytesResult(makeWebpBytes(), 200, 'image/webp');
      });
      const recoveredUri: string = await mgr.getImage(targetUrl);
      expect(refetched).assertTrue();
      expect(recoveredUri.startsWith('file://')).assertTrue();
      mgr.setTestDownloaderForTest(undefined);
    });

    it('guardsAgainstAsyncOutOfOrderSlowAndFastResponses', 0, async () => {
      const mgr: ImageCacheManager = resetImageManager();
      const slowUrl: string = 'https://img.noymanga.com/101/m1.webp';
      const fastUrl: string = 'https://img.noymanga.com/102/m1.webp';
      const slowLatch: GateLatch = new GateLatch();

      mgr.setTestDownloaderForTest(async (url: string, token: CancelToken): Promise<HttpBytesResult> => {
        if (url === slowUrl) {
          await new Promise<void>((resolve: () => void, reject: (err: Object) => void) => {
            slowLatch.release = resolve;
            token.onCancel((): void => reject(new RequestCanceledError()));
          });
        }
        return new HttpBytesResult(makeWebpBytes(), 200, 'image/webp');
      });

      let displayedUrl: string = '';
      const tokenSlow: CancelToken = new CancelToken();
      let slowApplied: boolean = false;
      const pSlow = mgr.getImage(slowUrl, undefined, tokenSlow).then((_uri: string) => {
        if (!tokenSlow.isCanceled()) {
          slowApplied = true;
          displayedUrl = slowUrl;
        }
      }).catch(() => {
        // 预期被取消
      });

      // 组件快速切换到新 URL，取消旧请求
      tokenSlow.cancel();
      const fastUri: string = await mgr.getImage(fastUrl);
      displayedUrl = fastUrl;
      expect(fastUri.startsWith('file://')).assertTrue();

      slowLatch.release();
      await pSlow;
      expect(slowApplied).assertFalse();
      expect(displayedUrl).assertEqual(fastUrl);
      mgr.setTestDownloaderForTest(undefined);
    });

    it('deduplicatesSharedConsumersAndProtectsAgainstPartialCancel', 0, async () => {
      const mgr: ImageCacheManager = resetImageManager();
      let fetchCalls: number = 0;
      let underlyingCanceled: boolean = false;
      const latch: GateLatch = new GateLatch();

      mgr.setTestDownloaderForTest(async (_url: string, token: CancelToken): Promise<HttpBytesResult> => {
        fetchCalls++;
        token.onCancel((): void => {
          underlyingCanceled = true;
        });
        await new Promise<void>((resolve: () => void) => {
          latch.release = resolve;
        });
        return new HttpBytesResult(makeWebpBytes(), 200, 'image/webp');
      });

      const url: string = 'https://img.noymanga.com/42604/m1.webp';
      const tokenA: CancelToken = new CancelToken();
      const tokenB: CancelToken = new CancelToken();
      const pA: Promise<string> = mgr.getImage(url, undefined, tokenA);
      const pB: Promise<string> = mgr.getImage(url, undefined, tokenB);

      // 等待 downloader 启动
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 10));
      expect(fetchCalls).assertEqual(1);

      // 仅取消消费者 A：消费者 B 仍存活，不能中止底层请求
      tokenA.cancel();
      let aCanceled: boolean = false;
      try {
        await pA;
      } catch (e) {
        if (e instanceof RequestCanceledError) {
          aCanceled = true;
        }
      }
      expect(aCanceled).assertTrue();
      expect(underlyingCanceled).assertFalse();

      // 放行下载，消费者 B 正常成功
      latch.release();
      const uriB: string = await pB;
      expect(uriB.startsWith('file://')).assertTrue();
      mgr.setTestDownloaderForTest(undefined);
    });

    it('cancelsUnderlyingDownloadWhenAllConsumersCancel', 0, async () => {
      const mgr: ImageCacheManager = resetImageManager();
      let underlyingCanceled: boolean = false;

      mgr.setTestDownloaderForTest(async (_url: string, token: CancelToken): Promise<HttpBytesResult> => {
        return await new Promise<HttpBytesResult>((_resolve, reject) => {
          token.onCancel((): void => {
            underlyingCanceled = true;
            reject(new RequestCanceledError());
          });
        });
      });

      const url: string = 'https://img.noymanga.com/42651/m1.webp';
      const tokenA: CancelToken = new CancelToken();
      const tokenB: CancelToken = new CancelToken();
      const pA = mgr.getImage(url, undefined, tokenA).catch(() => 'canceled');
      const pB = mgr.getImage(url, undefined, tokenB).catch(() => 'canceled');

      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 10));
      tokenA.cancel();
      expect(underlyingCanceled).assertFalse();
      tokenB.cancel();
      await pA;
      await pB;
      expect(underlyingCanceled).assertTrue();
      mgr.setTestDownloaderForTest(undefined);
    });

    it('boundsForegroundConcurrencyToPreventConnectionStorm', 0, async () => {
      const mgr: ImageCacheManager = resetImageManager();
      let running: number = 0;
      let maxObserved: number = 0;

      mgr.setTestDownloaderForTest(async (_url: string, _token: CancelToken): Promise<HttpBytesResult> => {
        running++;
        if (running > maxObserved) {
          maxObserved = running;
        }
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, 20));
        running--;
        return new HttpBytesResult(makeWebpBytes(), 200, 'image/webp');
      });

      const tasks: Promise<string>[] = [];
      for (let i = 1; i <= 12; i++) {
        tasks.push(mgr.getImage(`https://img.noymanga.com/${i}/m1.webp`));
      }
      await Promise.all(tasks);
      expect(maxObserved <= 6).assertTrue();
      expect(maxObserved > 1).assertTrue();
      mgr.setTestDownloaderForTest(undefined);
    });

    it('guardsAgainstOutOfOrderReloadOnUrlChange', 0, () => {
      expect(shouldReloadImage('https://img.noymanga.com/1/m1.webp',
        'https://img.noymanga.com/2/m1.webp',
        'https://img.noymanga.com/1/m1.webp', false)).assertTrue();
      expect(shouldReloadImage('https://img.noymanga.com/1/m1.webp',
        'https://img.noymanga.com/1/m1.webp',
        'https://img.noymanga.com/1/m1.webp', false)).assertFalse();
    });
  });
}
