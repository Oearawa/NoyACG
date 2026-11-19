/**
 * CacheCleaner.ets —— 图片缓存「统计 / 清理」算法（文件系统端口化，可单测）
 *
 * 为什么单独抽一层：
 * 缓存清理是全工程风险最高的操作（删错目录 = 用户数据丢失），必须能用单元测试
 * 真实覆盖「多级目录 / 部分文件读取失败 / 在途下载 / 非图片文件」等分支。
 * 因此把「文件系统」抽象成 CacheFsPort 端口：
 * - 生产环境注入 SandboxCacheFs（@kit.CoreFileKit 的真实实现）；
 * - 单元测试注入内存桩（MemoryCacheFs），逐条验证删除范围与异常处理。
 *
 * 删除红线（本文件是唯一实现处）：
 * 1. 只删「文件名符合图片缓存命名规则」的文件；
 * 2. 只删文件，不删目录；
 * 3. 正在写入的文件（shouldSkip 返回 true）一律跳过；
 * 4. 单个条目失败只计入 failedCount，不中断整体流程。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 文件系统条目元信息（剔除业务无关字段，便于用桩实现替代） */
export class CacheStat {
  readonly isDirectory: boolean;
  readonly size: number;

  constructor(isDirectory: boolean, size: number) {
    this.isDirectory = isDirectory;
    this.size = size;
  }
}

/** 文件系统端口：缓存统计 / 清理所需要的最小能力集合 */
export interface CacheFsPort {
  /** 路径是否存在（不存在返回 false，不抛异常） */
  access(path: string): Promise<boolean>;
  /** 列出目录下的条目名（不含路径前缀） */
  list(path: string): Promise<string[]>;
  /** 获取条目元信息 */
  stat(path: string): Promise<CacheStat>;
  /** 删除单个文件 */
  unlink(path: string): Promise<void>;
}

/** 清空缓存结果（UI 只依赖该结构，不关心文件系统细节） */
export class CacheClearResult {
  /** 是否整体成功（单个文件删除失败不视为整体失败，但会记入 failedCount） */
  readonly success: boolean;
  /** 成功删除的文件数 */
  readonly deletedCount: number;
  /** 释放的字节数 */
  readonly freedBytes: number;
  /** 删除失败的个数（如文件被系统占用） */
  readonly failedCount: number;
  /** 整体失败原因（success = true 时为空串） */
  readonly errorMessage: string;
  /** 是否「部分失败」：流程走完但有文件未能删除（UI 必须如实提示，不能报成完全成功） */
  readonly hasPartialFailure: boolean;

  constructor(success: boolean, deletedCount: number, freedBytes: number,
    failedCount: number, errorMessage: string) {
    this.success = success;
    this.deletedCount = deletedCount;
    this.freedBytes = freedBytes;
    this.failedCount = failedCount;
    this.errorMessage = errorMessage;
    this.hasPartialFailure = success && failedCount > 0;
  }
}

/** 缓存服务对外契约（ViewModel 依赖抽象，便于单元测试注入桩实现） */
export interface CacheService {
  /** 统计图片缓存占用（字节） */
  getCacheSize(): Promise<number>;
  /** 清空图片缓存 */
  clearImageCache(): Promise<CacheClearResult>;
}

/**
 * 生产环境实现：应用沙盒内的真实文件系统（全部异步 API，不阻塞 UI 线程）。
 *
 * 每个方法都在本层 try/catch 并「补充路径上下文后原样上抛」：
 * - 不吞异常（上层 CacheCleaner 仍需按条目降级 / 计数）；
 * - 让「哪个路径、什么原因」进入最终错误信息，避免 UI 只看到「缓存清理失败」。
 */
export class SandboxCacheFs implements CacheFsPort {
  async access(path: string): Promise<boolean> {
    try {
      return await fs.access(path);
    } catch (e) {
      throw new Error(`access 失败 (${path}): ${(e as BusinessError).message}`);
    }
  }

  async list(path: string): Promise<string[]> {
    try {
      return await fs.listFile(path);
    } catch (e) {
      throw new Error(`listFile 失败 (${path}): ${(e as BusinessError).message}`);
    }
  }

  async stat(path: string): Promise<CacheStat> {
    try {
      const stat: fs.Stat = await fs.stat(path);
      return new CacheStat(stat.isDirectory(), stat.size);
    } catch (e) {
      throw new Error(`stat 失败 (${path}): ${(e as BusinessError).message}`);
    }
  }

  async unlink(path: string): Promise<void> {
    try {
      await fs.unlink(path);
    } catch (e) {
      throw new Error(`unlink 失败 (${path}): ${(e as BusinessError).message}`);
    }
  }
}

/** 统计累加器（内部使用） */
class ClearStats {
  deletedCount: number = 0;
  freedBytes: number = 0;
  failedCount: number = 0;
}

/**
 * 缓存统计 / 清理算法。
 * @param fsPort     文件系统端口
 * @param isCacheFile 文件名是否为图片缓存（由 ImageCacheManager 的命名规则提供）
 * @param shouldSkip  是否跳过某文件（在途下载保护，由 ImageCacheManager 提供）
 * @param onWarn      单条目异常回调（脱敏日志）
 */
export class CacheCleaner {
  private fsPort: CacheFsPort;
  private isCacheFile: (name: string) => boolean;
  private shouldSkip: (name: string) => boolean;
  private onWarn: (message: string) => void;

  constructor(fsPort: CacheFsPort, isCacheFile: (name: string) => boolean,
    shouldSkip: (name: string) => boolean, onWarn: (message: string) => void) {
    this.fsPort = fsPort;
    this.isCacheFile = isCacheFile;
    this.shouldSkip = shouldSkip;
    this.onWarn = onWarn;
  }

  /**
   * 递归统计目录内图片缓存文件总字节数。
   * 目录不存在返回 0；子目录递归；单个条目失败跳过。
   */
  async sum(dirPath: string): Promise<number> {
    const exists: boolean = await this.fsPort.access(dirPath);
    if (!exists) {
      return 0;
    }
    return await this.sumDir(dirPath);
  }

  private async sumDir(dirPath: string): Promise<number> {
    let total: number = 0;
    let names: string[] = [];
    try {
      names = await this.fsPort.list(dirPath);
    } catch (e) {
      this.onWarn(`目录读取失败，跳过: ${dirPath}`);
      return 0;
    }
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      const fullPath: string = `${dirPath}/${name}`;
      try {
        const stat: CacheStat = await this.fsPort.stat(fullPath);
        if (stat.isDirectory) {
          total += await this.sumDir(fullPath);
        } else if (this.isCacheFile(name)) {
          total += stat.size;
        }
      } catch (e) {
        this.onWarn(`条目统计失败，跳过: ${fullPath}`);
      }
    }
    return total;
  }

  /**
   * 递归清理目录内的图片缓存文件（只删文件，不删目录）。
   * 目录不存在视为「已清空」，返回成功。
   */
  async clear(dirPath: string): Promise<CacheClearResult> {
    let exists: boolean = false;
    try {
      exists = await this.fsPort.access(dirPath);
    } catch (e) {
      return new CacheClearResult(false, 0, 0, 0,
        `缓存目录不可访问: ${(e as Error).message}`);
    }
    if (!exists) {
      return new CacheClearResult(true, 0, 0, 0, '');
    }
    const stats: ClearStats = new ClearStats();
    try {
      await this.clearDir(dirPath, stats);
    } catch (e) {
      // 目录级异常：如实上报已完成的删除量 + 中断原因
      return new CacheClearResult(false, stats.deletedCount, stats.freedBytes,
        stats.failedCount, `缓存清理中断: ${(e as Error).message}`);
    }
    return new CacheClearResult(true, stats.deletedCount, stats.freedBytes,
      stats.failedCount, '');
  }

  private async clearDir(dirPath: string, stats: ClearStats): Promise<void> {
    const names: string[] = await this.fsPort.list(dirPath);
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      const fullPath: string = `${dirPath}/${name}`;
      let stat: CacheStat;
      try {
        stat = await this.fsPort.stat(fullPath);
      } catch (e) {
        stats.failedCount++;
        this.onWarn(`条目信息读取失败: ${fullPath}`);
        continue;
      }
      if (stat.isDirectory) {
        await this.clearDir(fullPath, stats);
        continue;
      }
      if (!this.isCacheFile(name)) {
        continue; // 非图片缓存文件：绝不触碰
      }
      if (this.shouldSkip(name)) {
        continue; // 在途下载：跳过，避免与写入竞争
      }
      try {
        const size: number = stat.size;
        await this.fsPort.unlink(fullPath);
        stats.deletedCount++;
        stats.freedBytes += size;
      } catch (e) {
        stats.failedCount++;
        this.onWarn(`缓存文件删除失败: ${name}`);
      }
    }
  }
}
