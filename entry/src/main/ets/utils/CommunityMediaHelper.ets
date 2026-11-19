/**
 * CommunityMediaHelper.ets —— 社区发帖相册选图、沙箱缓存转存与上传状态模型（阶段 3）
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { Logger } from './Logger';

const TAG: string = 'CommunityMediaHelper';

export const MAX_COMMUNITY_IMAGES: number = 9;

export enum UploadStatus {
  PENDING = 0,
  UPLOADING = 1,
  SUCCESS = 2,
  FAILED = 3
}

export class CommunityDraftImage {
  id: string = '';
  localUri: string = '';
  cachePath: string = '';
  internalUri: string = '';
  contentType: string = 'image/webp';
  status: UploadStatus = UploadStatus.PENDING;
  serverFile: string = '';
  errorMsg: string = '';

  constructor(
    id: string = '',
    localUri: string = '',
    cachePath: string = '',
    internalUri: string = '',
    contentType: string = 'image/webp'
  ) {
    this.id = id;
    this.localUri = localUri;
    this.cachePath = cachePath;
    this.internalUri = internalUri;
    this.contentType = contentType;
  }
}

export function inferImageExtension(uri: string): string {
  const clean: string = uri.split('?')[0].toLowerCase();
  if (clean.endsWith('.png')) {
    return 'png';
  }
  if (clean.endsWith('.jpg') || clean.endsWith('.jpeg')) {
    return 'jpg';
  }
  if (clean.endsWith('.gif')) {
    return 'gif';
  }
  return 'webp';
}

export function inferImageContentType(ext: string): string {
  const lower: string = ext.toLowerCase();
  if (lower === 'png') {
    return 'image/png';
  }
  if (lower === 'jpg' || lower === 'jpeg') {
    return 'image/jpeg';
  }
  if (lower === 'gif') {
    return 'image/gif';
  }
  return 'image/webp';
}

export function normalizeImageFileForCreatePost(file: string): string {
  const clean: string = file.trim();
  if (clean === '') {
    return '';
  }
  return clean.startsWith('image/') ? clean : `image/${clean}`;
}

export function buildCreatePostImageList(images: CommunityDraftImage[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < images.length; i++) {
    const img: CommunityDraftImage = images[i];
    if (img.status === UploadStatus.SUCCESS && img.serverFile !== '') {
      out.push(normalizeImageFileForCreatePost(img.serverFile));
    }
  }
  return out;
}

export async function pickAndCacheCommunityImages(
  context: common.Context,
  remainCount: number
): Promise<CommunityDraftImage[]> {
  if (remainCount <= 0) {
    return [];
  }
  const selectLimit: number = Math.min(MAX_COMMUNITY_IMAGES, remainCount);
  const photoPicker: picker.PhotoViewPicker = new picker.PhotoViewPicker(context);
  const options: picker.PhotoSelectOptions = new picker.PhotoSelectOptions();
  options.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
  options.maxSelectNumber = selectLimit;

  const result: picker.PhotoSelectResult = await photoPicker.select(options);
  const uris: string[] = result.photoUris ?? [];
  if (uris.length === 0) {
    return [];
  }

  const out: CommunityDraftImage[] = [];
  const now: number = Date.now();
  for (let i = 0; i < uris.length; i++) {
    const srcUri: string = uris[i];
    const ext: string = inferImageExtension(srcUri);
    const fileName: string = `community_${now}_${i}.${ext}`;
    const dstPath: string = `${context.cacheDir}/${fileName}`;
    let srcFile: fs.File | undefined = undefined;
    try {
      srcFile = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
      fs.copyFileSync(srcFile.fd, dstPath);
      const draft: CommunityDraftImage = new CommunityDraftImage(
        `${now}_${i}`,
        `file://${dstPath}`,
        dstPath,
        `internal://cache/${fileName}`,
        inferImageContentType(ext)
      );
      out.push(draft);
    } catch (e) {
      Logger.warn(TAG, `缓存社区图片失败: ${(e as Error).message}`);
    } finally {
      if (srcFile !== undefined) {
        try {
          fs.closeSync(srcFile);
        } catch (_e) {
          // 忽略关闭异常
        }
      }
    }
  }
  return out;
}
