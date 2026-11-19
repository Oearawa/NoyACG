/**
 * LogStore.ets —— 日志文件读写的最小封装（Phase 14-R）
 *
 * 只负责「沙盒内文本文件的读 / 写 / 目录创建」，全部异步，绝不抛异常给调用方。
 * 诊断日志与网络日志共用本封装，避免各自写一套文件逻辑。
 *
 * ★ 敏感信息过滤（I-000005）：writeTextFile 是诊断/网络日志落盘的统一出口，
 *   写入前对全文执行 LogSanitizer.sanitizeText —— Cookie 名/值、指纹（fp=）、
 *   Token、密码等明文凭据一律打码，生产路径不落盘任何可恢复登录态的字段。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { sanitizeText } from './LogSanitizer';

export enum LogExportStatus {
  SUCCESS = 'success',
  CANCELED = 'canceled',
  FAILED = 'failed'
}

export interface LogExportResult {
  status: LogExportStatus;
  fileName: string;
  uri: string;
}

export type DocumentSaveHook = (fileName: string) => Promise<string[]>;
export type UriTextWriterHook = (uri: string, content: string) => Promise<boolean>;

/** 判断 DocumentViewPicker 抛出的错误是否属于用户主动取消 */
function isPickerCanceledError(error: Object): boolean {
  const err = error as BusinessError;
  const msg: string = (err.message ?? '').toLowerCase();
  return err.code === 13900001 || msg.includes('cancel');
}

/**
 * 调用系统 DocumentViewPicker 让用户自选保存路径导出脱敏日志文本。
 */
export async function exportLogWithDocumentPicker(
  context: common.Context | undefined,
  fileName: string,
  rawContent: string,
  saveHook?: DocumentSaveHook,
  writeHook?: UriTextWriterHook
): Promise<LogExportResult> {
  if (saveHook === undefined && context === undefined) {
    return { status: LogExportStatus.FAILED, fileName: fileName, uri: '' };
  }
  let uris: string[] = [];
  try {
    if (saveHook !== undefined) {
      uris = await saveHook(fileName);
    } else {
      const documentSaveOptions: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      documentSaveOptions.newFileNames = [fileName];
      const documentPicker: picker.DocumentViewPicker =
        new picker.DocumentViewPicker(context as common.Context);
      uris = await documentPicker.save(documentSaveOptions);
    }
  } catch (e) {
    if (isPickerCanceledError(e as Object)) {
      return { status: LogExportStatus.CANCELED, fileName: fileName, uri: '' };
    }
    return { status: LogExportStatus.FAILED, fileName: fileName, uri: '' };
  }

  if (!Array.isArray(uris) || uris.length === 0) {
    return { status: LogExportStatus.CANCELED, fileName: fileName, uri: '' };
  }
  const targetUri: string = uris[0].trim();
  if (targetUri === '') {
    return { status: LogExportStatus.CANCELED, fileName: fileName, uri: '' };
  }
  const safeContent: string = sanitizeText(rawContent);
  const ok: boolean = writeHook !== undefined
    ? await writeHook(targetUri, safeContent)
    : await writeTextFile(targetUri, safeContent);
  return {
    status: ok ? LogExportStatus.SUCCESS : LogExportStatus.FAILED,
    fileName: fileName,
    uri: targetUri
  };
}

/** 读整个文本文件（不存在 / 失败 → 空串） */
export async function readTextFile(path: string): Promise<string> {
  try {
    if (!fs.accessSync(path)) {
      return '';
    }
    return await fs.readText(path);
  } catch (e) {
    return '';
  }
}

/** 覆盖写文本文件；返回是否成功（父目录不存在时自动创建） */
export async function writeTextFile(path: string, text: string): Promise<boolean> {
  try {
    const safeText: string = sanitizeText(text);
    const file: fs.File = fs.openSync(path,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, safeText);
    } finally {
      fs.closeSync(file);
    }
    return true;
  } catch (e) {
    return false;
  }
}

/** 确保目录存在（已存在时静默返回 true） */
export function ensureDir(path: string): boolean {
  try {
    if (fs.accessSync(path)) {
      return true;
    }
    fs.mkdirSync(path, true);
    return true;
  } catch (e) {
    const err = e as BusinessError;
    const msg: string = (err.message ?? '').toLowerCase();
    if (err.code === 13900015 || msg.includes('file exists') || msg.includes('eexist')) {
      return true;
    }
    return false;
  }
}

/**
 * 诊断类数据的统一目录：`<filesDir>/diagnostics`。
 * 与 cacheDir（图片临时缓存）严格分离 —— 清理图片缓存不会删掉日志。
 */
export function diagnosticsDir(context: common.Context): string {
  return `${context.filesDir}/diagnostics`;
}

/** 导出目录：`<filesDir>/exports` */
export function exportsDir(context: common.Context): string {
  return `${context.filesDir}/exports`;
}

/** 生成带时间戳的文件名（本地时间，便于用户按时间定位） */
export function timestampedFileName(prefix: string, extension: string): string {
  const now: Date = new Date();
  const pad = (value: number): string => (value < 10 ? `0${value}` : `${value}`);
  const stamp: string = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}` +
    `_${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
  return `${prefix}_${stamp}.${extension}`;
}

/** 时间戳 → `YYYY-MM-DD HH:mm:ss`（列表展示用，与系统时区一致） */
export function formatTimestamp(timestamp: number): string {
  if (timestamp <= 0) {
    return '';
  }
  const date: Date = new Date(timestamp);
  const pad = (value: number): string => (value < 10 ? `0${value}` : `${value}`);
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
    `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

/** 安全删除文件（不存在视为成功） */
export async function removeFile(path: string): Promise<boolean> {
  try {
    if (!fs.accessSync(path)) {
      return true;
    }
    await fs.unlink(path);
    return true;
  } catch (e) {
    const err = e as BusinessError;
    return false;
  }
}
