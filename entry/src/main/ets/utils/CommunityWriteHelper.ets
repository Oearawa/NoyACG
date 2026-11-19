/**
 * CommunityWriteHelper.ets —— 社区发帖与编辑纯校验工具（无 ArkUI 依赖，可离线单测）
 */
import { CommunityDraftImage, UploadStatus } from './CommunityMediaHelper';

export const COMMUNITY_QUICK_STICKERS: string[] = [
  '[noygirl:yeah]',
  '[noygirl:hi]',
  '[noygirl:good]',
  '[noygirl:cry]',
  '[noygirl:angry]',
  '[noygirl:sleep]'
];

/** 校验发帖/编辑表单：返回空串表示合法，否则返回错误提示 */
export function validatePostDraft(title: string, content: string): string {
  if (title.trim() === '') {
    return '请输入帖子标题';
  }
  if (content.trim() === '') {
    return '请输入帖子正文';
  }
  return '';
}

export function hasPendingOrFailedUploads(images: CommunityDraftImage[]): boolean {
  for (let i = 0; i < images.length; i++) {
    const st: UploadStatus = images[i].status;
    if (st === UploadStatus.PENDING || st === UploadStatus.UPLOADING || st === UploadStatus.FAILED) {
      return true;
    }
  }
  return false;
}

export function canSubmitPost(
  title: string,
  content: string,
  images: CommunityDraftImage[],
  submitting: boolean
): boolean {
  if (submitting) {
    return false;
  }
  if (validatePostDraft(title, content) !== '') {
    return false;
  }
  return !hasPendingOrFailedUploads(images);
}

export function appendStickerTag(content: string, tag: string): string {
  return `${content}${tag}`;
}
