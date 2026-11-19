/**
 * DownloadStorage.ets —— 永久下载目录 / 文件管理（Phase 12）
 *
 * 目录布局（应用沙盒 filesDir，**不是 cacheDir**）：
 *   ${filesDir}/Downloads/${safe(bookId)}/${safe(chapterId)}/000001.webp ...
 *   〜 .part 为写入中的临时文件，提交时用 fs.rename 原子替换。
 *
 * 与临时图片缓存的隔离是双重的：
 * 1. **路径隔离**：永久下载在 filesDir/Downloads，缓存清理只递归 cacheDir；
 * 2. **命名隔离**：下载文件名是「6 位序号.扩展名」，缓存清理只认「32 位 MD5.扩展名」，
 *    即使目录布局异常重叠也不会误删（见缓存隔离测试）。
 *
 * 稳定顺序映射：文件名前缀是补零序号，离线读取按序号数值升序，
 * 与下载时的页码顺序完全一致，不依赖文件系统返回顺序。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs, statfs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../utils/Logger';
import { detectImageFormat, isSupportedImageFormat } from '../utils/ImageValidator';
import {
  DOWNLOAD_ROOT_DIR,
  DOWNLOAD_TEMP_SUFFIX,
  DownloadError,
  DownloadFsPort,
  DownloadImagePort,
  DownloadInterrupted,
  DownloadToken,
  MIN_FREE_SPACE_BYTES,
  MIN_IMAGE_BYTES
} from './DownloadPorts';

const TAG: string = 'DownloadStorage';

/** 离线图片条目（路径 + 序号 + 大小） */
export class OfflineImageEntry {
  readonly index: number;
  readonly path: string;
  readonly size: number;
  readonly uri: string;

  constructor(index: number, path: string, size: number, uri: string) {
    this.index = index;
    this.path = path;
    this.size = size;
    this.uri = uri;
  }
}

/** 章节完整性校验结果 */
export class ChapterVerifyResult {
  /** 是否 1..expectedCount 全部存在且大小合法 */
  readonly complete: boolean;
  /** 实际有效的图片数 */
  readonly validCount: number;
  /** 期望图片数 */
  readonly expectedCount: number;
  /** 缺失/损坏的序号（1 起） */
  readonly missingIndexes: number[];
  /** 按序号升序的有效图片条目 */
  readonly entries: OfflineImageEntry[];
  readonly message: string;

  constructor(complete: boolean, validCount: number, expectedCount: number,
    missingIndexes: number[], entries: OfflineImageEntry[], message: string) {
    this.complete = complete;
    this.validCount = validCount;
    this.expectedCount = expectedCount;
    this.missingIndexes = missingIndexes;
    this.entries = entries;
    this.message = message;
  }
}

/** 路径段净化：只允许字母数字与 - _，其它字符替换为下划线（防目录穿越） */
export function safePathSegment(raw: string): string {
  let result: string = '';
  for (let i = 0; i < raw.length; i++) {
    const ch: string = raw[i];
    if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
      || (ch >= '0' && ch <= '9') || ch === '-' || ch === '_') {
      result += ch;
    } else {
      result += '_';
    }
  }
  return result === '' ? 'unknown' : result;
}

/** 6 位补零序号（支持最多 999999 页，足够单章节使用） */
export function pageStem(index: number): string {
  const n: number = Math.max(1, Math.floor(index + 1));
  return String(n).padStart(6, '0');
}

/** 从 URL 提取图片扩展名（与 ImageCacheManager 的规则一致，默认 webp） */
export function imageExtension(url: string): string {
  const path: string = url.split('?')[0];
  const match: RegExpMatchArray | null = path.match(/\.(jpe?g|png|webp|gif|avif)$/i);
  if (match === null) {
    return 'webp';
  }
  const ext: string = match[1].toLowerCase();
  return ext === 'jpeg' ? 'jpg' : ext;
}

/** 工程既有用法：ArkUI Image 接受 `file://${沙盒绝对路径}`（Phase 7 起已构建验证） */
export function fileUriOf(path: string): string {
  return `file://${path}`;
}

export class DownloadStorage {
  private fsPort: DownloadFsPort;
  private rootDir: string;

  constructor(fsPort: DownloadFsPort, rootDir: string = '') {
    this.fsPort = fsPort;
    this.rootDir = rootDir;
  }

  /** 生产入口：使用 context.filesDir（永久目录，不随缓存清理被系统回收） */
  static createDefault(context: common.Context,
    fsPort: DownloadFsPort = new SandboxDownloadFs()): DownloadStorage {
    return new DownloadStorage(fsPort, `${context.filesDir}/${DOWNLOAD_ROOT_DIR}`);
  }

  get root(): string {
    return this.rootDir;
  }

  bookDir(bookId: string): string {
    return `${this.rootDir}/${safePathSegment(bookId)}`;
  }

  chapterDir(bookId: string, chapterId: string): string {
    return `${this.rootDir}/${safePathSegment(bookId)}/${safePathSegment(chapterId)}`;
  }

  imagePath(bookId: string, chapterId: string, index: number, url: string): string {
    return `${this.chapterDir(bookId, chapterId)}/${pageStem(index)}.${imageExtension(url)}`;
  }

  /** 校验单个文件是否大小合法且通过图片魔数检测（若端口支持 readHeader） */
  async isValidImageFile(path: string): Promise<boolean> {
    const size: number = await this.fsPort.fileSize(path);
    if (size < MIN_IMAGE_BYTES) {
      return false;
    }
    if (this.fsPort.readHeader !== undefined) {
      const header: Uint8Array | null = await this.fsPort.readHeader(path, 16);
      if (header === null || header.length === 0) {
        return false;
      }
      const fmt: string = detectImageFormat(header);
      if (!isSupportedImageFormat(fmt)) {
        return false;
      }
    }
    return true;
  }

  /** 该序号图片是否已完整落盘（不同扩展名都检查，且校验大小与魔数） */
  async hasImage(bookId: string, chapterId: string, index: number): Promise<boolean> {
    const dir: string = this.chapterDir(bookId, chapterId);
    const names: string[] = await this.fsPort.listFiles(dir);
    const stem: string = pageStem(index);
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      if (name.indexOf(stem + '.') === 0 && name.indexOf(DOWNLOAD_TEMP_SUFFIX) < 0) {
        if (await this.isValidImageFile(`${dir}/${name}`)) {
          return true;
        }
      }
    }
    return false;
  }

  /**
   * 下载并保存单张图片。
   * 顺序：确认目录 → 重复检测 → 临时文件流式写入 → 取消/空文件检查 → 原子提交 → 提交后大小复核。
   * 任何失败都删除残留临时文件、保留已完成图片、抛出可诊断异常。
   *
   * @returns 实际写入字节数；已存在时返回 0（不重复下载）
   */
  async saveImage(url: string, bookId: string, chapterId: string, index: number,
    fetcher: DownloadImagePort, token: DownloadToken,
    headers: Record<string, string> = {}): Promise<number> {
    const dir: string = this.chapterDir(bookId, chapterId);
    await this.fsPort.ensureDir(dir);

    if (await this.hasImage(bookId, chapterId, index)) {
      Logger.debug(TAG, `图片已存在，跳过: ${bookId}/${chapterId}#${index + 1}`);
      return 0;
    }

    const finalPath: string = this.imagePath(bookId, chapterId, index, url);
    const tempPath: string = `${finalPath}${DOWNLOAD_TEMP_SUFFIX}`;
    try {
      if (await this.fsPort.exists(tempPath)) {
        await this.fsPort.remove(tempPath); // 清理上次异常退出留下的残留
      }
      const bytes: number = await fetcher.fetch(url, tempPath, headers, token);
      if (token.isCanceled) {
        throw new DownloadInterrupted();
      }
      if (bytes < MIN_IMAGE_BYTES) {
        throw new DownloadError('EMPTY_FILE', `图片内容为空: ${bookId}/${chapterId}#${index + 1}`);
      }
      if (!(await this.isValidImageFile(tempPath))) {
        throw new DownloadError('INVALID_IMAGE',
          `图片魔数校验失败（疑似错误页或损坏文件）: ${bookId}/${chapterId}#${index + 1}`);
      }
      // 原子提交：写入过程中任务绝不标记为完成
      await this.fsPort.commit(tempPath, finalPath);
      const committed: number = await this.fsPort.fileSize(finalPath);
      if (committed < MIN_IMAGE_BYTES || committed !== bytes) {
        await this.fsPort.remove(finalPath);
        throw new DownloadError('SIZE_MISMATCH',
          `文件完整性校验失败: ${bookId}/${chapterId}#${index + 1} (期望${bytes}B 实际${committed}B)`);
      }
      return bytes;
    } catch (e) {
      // 失败清理：无论何种原因，临时文件都不能残留
      try {
        await this.fsPort.remove(tempPath);
      } catch (cleanupError) {
        Logger.warn(TAG, `临时文件清理失败: ${(cleanupError as Error).message}`);
      }
      if (e instanceof DownloadInterrupted) {
        throw new DownloadInterrupted((e as Error).message);
      }
      if (e instanceof DownloadError) {
        throw new DownloadError((e as DownloadError).causeKind, (e as Error).message);
      }
      throw new DownloadError('IO', `图片保存失败: ${(e as Error).message}`);
    }
  }

  /** 列出章节内所有有效图片，按序号数值升序（不依赖文件系统枚举顺序） */
  async listChapterImages(bookId: string, chapterId: string): Promise<OfflineImageEntry[]> {
    const dir: string = this.chapterDir(bookId, chapterId);
    const names: string[] = await this.fsPort.listFiles(dir);
    const result: OfflineImageEntry[] = [];
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      if (name.indexOf(DOWNLOAD_TEMP_SUFFIX) >= 0) {
        continue; // 临时文件不是有效图片
      }
      const dot: number = name.indexOf('.');
      if (dot <= 0) {
        continue;
      }
      const stem: string = name.substring(0, dot);
      const index: number = Number(stem);
      if (!Number.isFinite(index) || index < 1) {
        continue;
      }
      const path: string = `${dir}/${name}`;
      if (await this.isValidImageFile(path)) {
        const size: number = await this.fsPort.fileSize(path);
        result.push(new OfflineImageEntry(index, path, size, fileUriOf(path)));
      }
    }
    result.sort((a: OfflineImageEntry, b: OfflineImageEntry): number => a.index - b.index);
    return result;
  }

  /**
   * 校验章节完整性：1..expectedCount 每个序号都必须有且仅有一个有效文件，
   * 且序号必须连续。缺图不静默跳过，明确返回 missingIndexes。
   */
  async verifyChapter(bookId: string, chapterId: string,
    expectedCount: number): Promise<ChapterVerifyResult> {
    const entries: OfflineImageEntry[] = await this.listChapterImages(bookId, chapterId);
    const missing: number[] = [];
    if (expectedCount <= 0) {
      return new ChapterVerifyResult(false, entries.length, 0, [], entries,
        '章节图片总数未知，无法确认完整性');
    }
    for (let n = 1; n <= expectedCount; n++) {
      let found: boolean = false;
      for (let i = 0; i < entries.length; i++) {
        if (entries[i].index === n) {
          found = true;
          break;
        }
      }
      if (!found) {
        missing.push(n);
      }
    }
    // 超出期望数量的多余文件也视为不完整（可能是旧版本残留）
    const extras: boolean = entries.length > expectedCount;
    const complete: boolean = missing.length === 0 && !extras
      && entries.length === expectedCount;
    const message: string = complete ? ''
      : `章节不完整：应有 ${expectedCount} 张，有效 ${entries.length} 张` +
        (missing.length > 0 ? `，缺失 ${missing.length} 张` : '') +
        (extras ? '，存在多余文件' : '');
    return new ChapterVerifyResult(complete, entries.length, expectedCount,
      missing, entries, message);
  }

  /** 删除某章节的全部下载文件（任务记录由 Repository 单独处理） */
  async deleteChapter(bookId: string, chapterId: string): Promise<void> {
    await this.fsPort.removeDirRecursive(this.chapterDir(bookId, chapterId));
  }

  /** 级联删除整部漫画的全部离线文件 */
  async deleteBook(bookId: string): Promise<void> {
    await this.fsPort.removeDirRecursive(this.bookDir(bookId));
  }

  /** 统计单部漫画离线占用字节数 */
  async getBookSize(bookId: string): Promise<number> {
    return await this.fsPort.totalSize(this.bookDir(bookId));
  }

  /** 检查剩余可用磁盘空间是否满足安全余量（默认 200MB） */
  async hasEnoughDiskSpace(minFreeBytes: number = MIN_FREE_SPACE_BYTES): Promise<boolean> {
    if (this.fsPort.availableBytes === undefined) {
      return true;
    }
    const free: number = await this.fsPort.availableBytes(this.rootDir);
    if (free < 0) {
      return true;
    }
    return free >= minFreeBytes;
  }

  /** 永久下载占用（与图片缓存统计完全独立） */
  async getTotalSize(): Promise<number> {
    return await this.fsPort.totalSize(this.rootDir);
  }

  /** 列出磁盘离线根目录下的全部漫画目录名（bookId） */
  async listDiskBookIds(): Promise<string[]> {
    return await this.fsPort.listFiles(this.rootDir);
  }

  /** 列出指定漫画目录下的全部章节目录名（chapterId） */
  async listDiskChapterIds(bookId: string): Promise<string[]> {
    return await this.fsPort.listFiles(this.bookDir(bookId));
  }

  /** 直接从磁盘章节目录扫描并按序号升序返回已落盘图片条目（不依赖任务数据库） */
  async listDiskChapterImages(bookId: string, chapterId: string): Promise<OfflineImageEntry[]> {
    const dir: string = this.chapterDir(bookId, chapterId);
    const names: string[] = await this.fsPort.listFiles(dir);
    const entries: OfflineImageEntry[] = [];
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      if (name.indexOf(DOWNLOAD_TEMP_SUFFIX) >= 0) {
        continue;
      }
      const match: RegExpMatchArray | null = name.match(/^(\d+)\.(jpe?g|png|webp|gif|avif)$/i);
      if (match === null) {
        continue;
      }
      const idx: number = Number(match[1]);
      if (!Number.isFinite(idx) || idx <= 0) {
        continue;
      }
      const path: string = `${dir}/${name}`;
      const size: number = await this.fsPort.fileSize(path);
      if (size < MIN_IMAGE_BYTES) {
        continue;
      }
      entries.push(new OfflineImageEntry(idx, path, size, `file://${path}`));
    }
    entries.sort((a: OfflineImageEntry, b: OfflineImageEntry) => a.index - b.index);
    return entries;
  }

  /** 统计单章节磁盘占用字节数 */
  async getChapterSize(bookId: string, chapterId: string): Promise<number> {
    return await this.fsPort.totalSize(this.chapterDir(bookId, chapterId));
  }

  /** 递归删除离线下载根目录下的全部漫画与残留文件 */
  async deleteAll(): Promise<void> {
    const entries: string[] = await this.fsPort.listFiles(this.rootDir);
    for (let i = 0; i < entries.length; i++) {
      const child: string = `${this.rootDir}/${entries[i]}`;
      await this.fsPort.removeDirRecursive(child);
    }
  }
}

export function isAlreadyExistsError(e: Object): boolean {
  const err = e as BusinessError;
  if (err !== undefined && err !== null && err.code === 13900015) {
    return true;
  }
  const msg: string = ((e as Error)?.message ?? '').toLowerCase();
  return msg.includes('file exists') || msg.includes('eexist');
}

/**
 * 生产文件系统实现：`@kit.CoreFileKit` 的 `fileIo`（API 26 导出名，
 * 不是旧教程里的 `fs`）。全部异步优先，写入用短时同步 fd 操作（小 chunk）。
 */
export class SandboxDownloadFs implements DownloadFsPort {
  /** isDirectory() 在 SDK 中声明可能抛异常；统一收口，避免新增编译警告 */
  private static isDirectory(stat: fs.Stat): boolean {
    try {
      return stat.isDirectory();
    } catch (e) {
      return false;
    }
  }

  async ensureDir(path: string): Promise<void> {
    if (path.trim() === '') {
      return;
    }
    try {
      if (await fs.access(path)) {
        return;
      }
    } catch (_e) {
      // ignore access miss
    }
    try {
      await fs.mkdir(path, true);
    } catch (e) {
      if (isAlreadyExistsError(e)) {
        return;
      }
      try {
        if (await fs.access(path)) {
          return;
        }
      } catch (_ignore) {
        // fall through to throw
      }
      throw new DownloadError('IO', `创建下载目录失败 (${path}): ${(e as BusinessError).message}`);
    }
  }

  async exists(path: string): Promise<boolean> {
    try {
      return await fs.access(path);
    } catch (e) {
      return false;
    }
  }

  async fileSize(path: string): Promise<number> {
    try {
      const stat: fs.Stat = await fs.stat(path);
      return stat.isDirectory() ? -1 : stat.size;
    } catch (e) {
      return -1;
    }
  }

  async appendChunk(path: string, chunk: ArrayBuffer): Promise<number> {
    let file: fs.File | undefined = undefined;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      let current: number = 0;
      try {
        const stat: fs.Stat = await fs.stat(path);
        current = stat.size;
      } catch (e) {
        current = 0;
      }
      // API 26：WriteOptions 未作为 fileIo 命名空间成员导出，直接传结构字面量
      const written: number = fs.writeSync(file.fd, chunk,
        { offset: current, length: chunk.byteLength });
      return current + written;
    } catch (e) {
      throw new DownloadError('IO',
        `写入临时文件失败 (${path}): ${(e as BusinessError).message}`);
    } finally {
      if (file !== undefined) {
        try {
          fs.closeSync(file);
        } catch (e) {
          Logger.warn(TAG, `关闭临时文件失败: ${(e as BusinessError).message}`);
        }
      }
    }
  }

  async commit(tempPath: string, finalPath: string): Promise<void> {
    try {
      // fs.rename 在同一文件系统内为原子替换；已存在则覆盖
      await fs.rename(tempPath, finalPath);
    } catch (e) {
      throw new DownloadError('IO',
        `原子提交失败 (${tempPath}): ${(e as BusinessError).message}`);
    }
  }

  async remove(path: string): Promise<void> {
    let exists: boolean = false;
    try {
      exists = await fs.access(path);
    } catch (e) {
      return; // 文件不存在（access 抛 ENOENT）→ 静默成功，符合接口契约
    }
    if (!exists) {
      return;
    }
    try {
      await fs.unlink(path);
    } catch (e) {
      throw new DownloadError('IO', `删除文件失败 (${path}): ${(e as BusinessError).message}`);
    }
  }

  async removeDirRecursive(path: string): Promise<void> {
    let exists: boolean = false;
    try {
      exists = await fs.access(path);
    } catch (e) {
      return;
    }
    if (!exists) {
      return;
    }
    let names: string[] = [];
    try {
      names = await fs.listFile(path);
    } catch (e) {
      throw new DownloadError('IO', `读取下载目录失败 (${path}): ${(e as BusinessError).message}`);
    }
    for (let i = 0; i < names.length; i++) {
      const child: string = `${path}/${names[i]}`;
      let stat: fs.Stat;
      try {
        stat = await fs.stat(child);
      } catch (e) {
        continue;
      }
      if (SandboxDownloadFs.isDirectory(stat)) {
        await this.removeDirRecursive(child);
      } else {
        await this.remove(child);
      }
    }
    try {
      await fs.rmdir(path);
    } catch (e) {
      throw new DownloadError('IO', `删除章节目录失败 (${path}): ${(e as BusinessError).message}`);
    }
  }

  async listFiles(dirPath: string): Promise<string[]> {
    try {
      const exists: boolean = await fs.access(dirPath);
      if (!exists) {
        return [];
      }
      return await fs.listFile(dirPath);
    } catch (e) {
      return [];
    }
  }

  async totalSize(dirPath: string): Promise<number> {
    let total: number = 0;
    const entries: string[] = await this.listFiles(dirPath);
    for (let i = 0; i < entries.length; i++) {
      const child: string = `${dirPath}/${entries[i]}`;
      let stat: fs.Stat;
      try {
        stat = await fs.stat(child);
      } catch (e) {
        continue;
      }
      if (SandboxDownloadFs.isDirectory(stat)) {
        total += await this.totalSize(child);
      } else {
        total += stat.size;
      }
    }
    return total;
  }

  async readHeader(path: string, maxBytes: number): Promise<Uint8Array | null> {
    let file: fs.File | undefined;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const buf: ArrayBuffer = new ArrayBuffer(Math.max(1, maxBytes));
      const readLen: number = fs.readSync(file.fd, buf);
      if (readLen <= 0) {
        return null;
      }
      return new Uint8Array(buf, 0, readLen);
    } catch (_e) {
      return null;
    } finally {
      if (file !== undefined) {
        try {
          fs.closeSync(file);
        } catch (_e2) {
          // ignore
        }
      }
    }
  }

  async availableBytes(dirPath: string): Promise<number> {
    try {
      await this.ensureDir(dirPath);
      return await statfs.getFreeSize(dirPath);
    } catch (_e) {
      return -1;
    }
  }
}
