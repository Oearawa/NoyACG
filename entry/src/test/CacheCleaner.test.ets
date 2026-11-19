/**
 * CacheCleaner.test.ets —— 缓存统计 / 清理算法单元测试
 *
 * 通过内存文件系统桩（MemoryCacheFs）真实驱动 CacheCleaner 的递归遍历与删除逻辑，
 * 覆盖任务书要求的全部边界：空目录、多级目录、WebP/JPG 统计、目录不存在、
 * 部分文件读取失败、清理成功 / 失败、下载在途文件保护、非图片文件不受影响。
 *
 * 说明：这里验证的是「算法与删除范围」，真实沙盒路径读写需真机/模拟器（见阶段报告）。
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { CacheCleaner, CacheClearResult, CacheFsPort, CacheStat } from '../main/ets/utils/CacheCleaner';
import { ImageCacheManager } from '../main/ets/utils/ImageCacheManager';

/** 32 位十六进制 MD5 前缀（与 ImageCacheManager 命名规则一致） */
const H1: string = '0123456789abcdef0123456789abcdef';
const H2: string = 'fedcba9876543210fedcba9876543210';
const H3: string = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

/** 内存文件系统桩：用 Map/Set 模拟目录树，可注入「stat 失败 / unlink 失败 / access 失败」 */
class MemoryCacheFs implements CacheFsPort {
  /** 文件路径 → 字节数 */
  files: Map<string, number> = new Map();
  /** 目录路径集合 */
  dirs: Set<string> = new Set();
  /** stat 抛错的路径（模拟读取失败） */
  statFailPaths: Set<string> = new Set();
  /** unlink 抛错的路径（模拟文件被占用） */
  unlinkFailPaths: Set<string> = new Set();
  /** access 是否抛错（模拟目录不可访问） */
  accessThrows: boolean = false;

  addFile(path: string, size: number): void {
    this.files.set(path, size);
    this.ensureParents(path);
  }

  addDir(path: string): void {
    this.dirs.add(path);
    this.ensureParents(`${path}/.keep`);
  }

  private ensureParents(filePath: string): void {
    const parts: string[] = filePath.split('/');
    parts.pop();
    while (parts.length > 0) {
      this.dirs.add(parts.join('/'));
      parts.pop();
    }
  }

  async access(path: string): Promise<boolean> {
    if (this.accessThrows) {
      throw new Error('permission denied');
    }
    return this.dirs.has(path) || this.files.has(path);
  }

  async list(path: string): Promise<string[]> {
    if (!this.dirs.has(path)) {
      throw new Error(`not a directory: ${path}`);
    }
    const names: string[] = [];
    const prefix: string = path.endsWith('/') ? path : `${path}/`;
    this.files.forEach((size: number, filePath: string) => {
      if (filePath.startsWith(prefix) && filePath.substring(prefix.length).indexOf('/') < 0) {
        names.push(filePath.substring(prefix.length));
      }
    });
    this.dirs.forEach((dirPath: string) => {
      if (dirPath !== path && dirPath.startsWith(prefix)
        && dirPath.substring(prefix.length).indexOf('/') < 0) {
        names.push(dirPath.substring(prefix.length));
      }
    });
    return names;
  }

  async stat(path: string): Promise<CacheStat> {
    if (this.statFailPaths.has(path)) {
      throw new Error(`stat failed: ${path}`);
    }
    if (this.dirs.has(path)) {
      return new CacheStat(true, 0);
    }
    const size: number | undefined = this.files.get(path);
    if (size === undefined) {
      throw new Error(`not found: ${path}`);
    }
    return new CacheStat(false, size);
  }

  async unlink(path: string): Promise<void> {
    if (this.unlinkFailPaths.has(path)) {
      throw new Error(`unlink failed: ${path}`);
    }
    this.files.delete(path);
  }
}

const ROOT: string = '/cache';

function makeCleaner(fs: MemoryCacheFs, skip: string[] = []): CacheCleaner {
  const warnings: string[] = [];
  return new CacheCleaner(
    fs,
    (name: string): boolean => ImageCacheManager.isImageCacheFile(name),
    (name: string): boolean => skip.indexOf(name) >= 0,
    (message: string): void => {
      warnings.push(message);
    });
}

export default function cacheCleanerTest() {
  describe('CacheCleaner', () => {
    let fs: MemoryCacheFs = new MemoryCacheFs();

    beforeEach(() => {
      fs = new MemoryCacheFs();
      fs.addDir(ROOT);
    });

    it('emptyDirectorySumIsZero', 0, async () => {
      const total: number = await makeCleaner(fs).sum(ROOT);
      expect(total).assertEqual(0);
    });

    it('sumsNestedDirectories', 0, async () => {
      fs.addFile(`${ROOT}/${H1}.jpg`, 100);
      fs.addDir(`${ROOT}/sub`);
      fs.addFile(`${ROOT}/sub/${H2}.webp`, 200);
      fs.addDir(`${ROOT}/sub/deep`);
      fs.addFile(`${ROOT}/sub/deep/${H3}.png`, 300);
      const total: number = await makeCleaner(fs).sum(ROOT);
      expect(total).assertEqual(600);
    });

    it('countsOnlyImageCacheFiles', 0, async () => {
      fs.addFile(`${ROOT}/${H1}.jpg`, 100);
      fs.addFile(`${ROOT}/${H2}.webp`, 50);
      // 以下都不属于图片缓存：不得计入
      fs.addFile(`${ROOT}/${H3}.jpeg`, 25);   // 写入侧已把 .jpeg 归一化为 .jpg
      fs.addFile(`${ROOT}/noyacg.db`, 9999);
      fs.addFile(`${ROOT}/download.cbz`, 9999);
      fs.addFile(`${ROOT}/notes.txt`, 9999);
      fs.addFile(`${ROOT}/0123456789abcdef.jpg`, 9999); // 长度不足 32 位
      const total: number = await makeCleaner(fs).sum(ROOT);
      expect(total).assertEqual(150);
    });

    it('missingDirectorySumIsZero', 0, async () => {
      const total: number = await makeCleaner(fs).sum('/not-exist');
      expect(total).assertEqual(0);
    });

    it('partialStatFailureSkipped', 0, async () => {
      fs.addFile(`${ROOT}/${H1}.jpg`, 100);
      fs.addFile(`${ROOT}/${H2}.jpg`, 200);
      fs.statFailPaths.add(`${ROOT}/${H2}.jpg`);
      const total: number = await makeCleaner(fs).sum(ROOT);
      // 单个条目读取失败不影响其他条目
      expect(total).assertEqual(100);
    });

    it('clearDeletesOnlyImageCache', 0, async () => {
      fs.addFile(`${ROOT}/${H1}.jpg`, 100);
      fs.addFile(`${ROOT}/${H2}.webp`, 200);
      fs.addFile(`${ROOT}/noyacg.db`, 4096);
      fs.addFile(`${ROOT}/book.cbz`, 8192);
      const result: CacheClearResult = await makeCleaner(fs).clear(ROOT);
      expect(result.success).assertTrue();
      expect(result.deletedCount).assertEqual(2);
      expect(result.freedBytes).assertEqual(300);
      expect(result.failedCount).assertEqual(0);
      // 数据库 / 下载文件仍在
      expect(fs.files.has(`${ROOT}/noyacg.db`)).assertTrue();
      expect(fs.files.has(`${ROOT}/book.cbz`)).assertTrue();
      expect(fs.files.has(`${ROOT}/${H1}.jpg`)).assertFalse();
    });

    it('clearRecursesIntoSubDirectories', 0, async () => {
      fs.addFile(`${ROOT}/${H1}.jpg`, 100);
      fs.addDir(`${ROOT}/sub`);
      fs.addFile(`${ROOT}/sub/${H2}.png`, 200);
      const result: CacheClearResult = await makeCleaner(fs).clear(ROOT);
      expect(result.deletedCount).assertEqual(2);
      expect(result.freedBytes).assertEqual(300);
      // 目录本身保留
      expect(fs.dirs.has(`${ROOT}/sub`)).assertTrue();
    });

    it('clearSkipsInFlightDownload', 0, async () => {
      fs.addFile(`${ROOT}/${H1}.jpg`, 100);
      fs.addFile(`${ROOT}/${H2}.jpg`, 200);
      const result: CacheClearResult = await makeCleaner(fs, [`${H2}.jpg`]).clear(ROOT);
      expect(result.deletedCount).assertEqual(1);
      // 正在写入的文件必须保留，避免与下载任务竞争
      expect(fs.files.has(`${ROOT}/${H2}.jpg`)).assertTrue();
    });

    it('clearCountsFailureAndContinues', 0, async () => {
      fs.addFile(`${ROOT}/${H1}.jpg`, 100);
      fs.addFile(`${ROOT}/${H2}.jpg`, 200);
      fs.unlinkFailPaths.add(`${ROOT}/${H2}.jpg`);
      const result: CacheClearResult = await makeCleaner(fs).clear(ROOT);
      expect(result.success).assertTrue();
      expect(result.deletedCount).assertEqual(1);
      expect(result.failedCount).assertEqual(1);
      expect(fs.files.has(`${ROOT}/${H2}.jpg`)).assertTrue();
    });

    it('clearMissingDirectorySucceeds', 0, async () => {
      const result: CacheClearResult = await makeCleaner(fs).clear('/not-exist');
      expect(result.success).assertTrue();
      expect(result.deletedCount).assertEqual(0);
      expect(result.errorMessage).assertEqual('');
    });

    it('clearAccessFailureReportsError', 0, async () => {
      fs.accessThrows = true;
      const result: CacheClearResult = await makeCleaner(fs).clear(ROOT);
      expect(result.success).assertFalse();
      expect(result.errorMessage.length > 0).assertTrue();
    });

    it('imageCacheFileRuleMatchesWriter', 0, () => {
      // 与写入侧 md5Hex + extOf 的产物严格一致（extOf 只会产出下列 5 种扩展名）
      expect(ImageCacheManager.isImageCacheFile(`${H1}.jpg`)).assertTrue();
      expect(ImageCacheManager.isImageCacheFile(`${H1}.png`)).assertTrue();
      expect(ImageCacheManager.isImageCacheFile(`${H1}.webp`)).assertTrue();
      expect(ImageCacheManager.isImageCacheFile(`${H1}.gif`)).assertTrue();
      expect(ImageCacheManager.isImageCacheFile(`${H1}.avif`)).assertTrue();
      // .jpeg 在写入前已被 extOf 归一化为 .jpg，不属于本应用产物 → 不匹配
      expect(ImageCacheManager.isImageCacheFile(`${H1}.jpeg`)).assertFalse();
      // 大写扩展名同样不会被写入侧产出 → 不匹配（不做盲目放宽）
      expect(ImageCacheManager.isImageCacheFile(`${H1}.JPG`)).assertFalse();
      expect(ImageCacheManager.isImageCacheFile(`${H1.toUpperCase()}.jpg`)).assertFalse();
      // 非图片缓存
      expect(ImageCacheManager.isImageCacheFile(`${H1}.db`)).assertFalse();
      expect(ImageCacheManager.isImageCacheFile('noyacg.db')).assertFalse();
      expect(ImageCacheManager.isImageCacheFile(`${H1}.jpg.part`)).assertFalse();
    });

    it('sumEqualsFreedBytesOnSameTree', 0, async () => {
      // 统计与清理必须使用同一套识别规则：同一棵树「算出来多少」就应「清掉多少」
      fs.addFile(`${ROOT}/${H1}.jpg`, 120);
      fs.addFile(`${ROOT}/${H2}.webp`, 80);
      fs.addFile(`${ROOT}/noyacg.db`, 4096);
      fs.addDir(`${ROOT}/sub`);
      fs.addFile(`${ROOT}/sub/${H3}.png`, 200);
      fs.addFile(`${ROOT}/sub/notes.txt`, 10);

      const before: number = await makeCleaner(fs).sum(ROOT);
      const result: CacheClearResult = await makeCleaner(fs).clear(ROOT);
      const after: number = await makeCleaner(fs).sum(ROOT);
      expect(before).assertEqual(400);
      expect(result.freedBytes).assertEqual(400);
      expect(after).assertEqual(0);
      // 非缓存文件与目录仍在
      expect(fs.files.has(`${ROOT}/noyacg.db`)).assertTrue();
      expect(fs.files.has(`${ROOT}/sub/notes.txt`)).assertTrue();
      expect(fs.dirs.has(`${ROOT}/sub`)).assertTrue();
    });

    it('sumsLargeTreeWithoutLoss', 0, async () => {
      // 大量文件（500 张）仍逐条精确累加：对应「缓存数量较大」场景
      for (let i = 0; i < 500; i++) {
        // 左补 0 保证 32 位且互不重复（用 'a' 补位可能与含 a 的十六进制后缀撞名）
        const hex: string = i.toString(16).padStart(32, '0');
        fs.addFile(`${ROOT}/${hex}.jpg`, 1000);
      }
      fs.addFile(`${ROOT}/noyacg.db`, 5000);
      const total: number = await makeCleaner(fs).sum(ROOT);
      expect(total).assertEqual(500 * 1000);
    });

    it('partialFailureIsReported', 0, async () => {
      fs.addFile(`${ROOT}/${H1}.jpg`, 100);
      fs.addFile(`${ROOT}/${H2}.jpg`, 200);
      fs.unlinkFailPaths.add(`${ROOT}/${H2}.jpg`);
      const result: CacheClearResult = await makeCleaner(fs).clear(ROOT);
      // 流程完成但有 1 个文件被占用：必须标记部分失败，UI 不得报「完全成功」
      expect(result.success).assertTrue();
      expect(result.failedCount).assertEqual(1);
      expect(result.hasPartialFailure).assertTrue();
      expect(result.deletedCount).assertEqual(1);
    });
  });
}
