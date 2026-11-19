/**
 * AppUpdateChecker.ets —— GitHub Release 版本检测与语义化版本比较
 *
 * - 仓库地址：https://github.com/Oearawa/NoyACG
 * - Releases 页面：https://github.com/Oearawa/NoyACG/releases
 * - 最新 Release API：https://api.github.com/repos/Oearawa/NoyACG/releases/latest
 * - 404（尚未发布 Release）优雅视为「当前已是最新版本」，不报错崩溃；
 * - 跳转下载严格通过 ExternalLink 拉起系统默认浏览器，绝不内置 WebView。
 */
import { http } from '@kit.NetworkKit';
import { Logger } from './Logger';

const TAG: string = 'AppUpdateChecker';

export const GITHUB_REPO_OWNER: string = 'Oearawa';
export const GITHUB_REPO_NAME: string = 'NoyACG';
export const APP_VERSION_NAME: string = '1.0.1';
export const APP_VERSION_CODE: number = 1000001;
export const GITHUB_REPO_URL: string = `https://github.com/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}`;
export const GITHUB_RELEASES_URL: string = `${GITHUB_REPO_URL}/releases`;
export const GITHUB_LATEST_RELEASE_API: string =
  `https://api.github.com/repos/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}/releases/latest`;
export const UPDATE_REQUEST_TIMEOUT_MS: number = 8000;

export type UpdateCheckStatus = 'update_available' | 'up_to_date' | 'error';

export interface GitHubReleaseInfo {
  tagName: string;
  version: string;
  name: string;
  body: string;
  htmlUrl: string;
}

export interface UpdateCheckResult {
  status: UpdateCheckStatus;
  hasUpdate: boolean;
  currentVersion: string;
  release: GitHubReleaseInfo | null;
  errorMessage: string;
}

interface RawGitHubRelease {
  tag_name?: string;
  name?: string;
  body?: string;
  html_url?: string;
  draft?: boolean;
}

/** 剥离 v/V 前缀与预发布/构建后缀，提取纯数字版本号核心 */
export function stripVersionPrefix(raw: string): string {
  const trimmed: string = raw.trim();
  if (trimmed === '') {
    return '';
  }
  const noV: string = (trimmed.startsWith('v') || trimmed.startsWith('V'))
    ? trimmed.substring(1).trim()
    : trimmed;
  const dashIdx: number = noV.indexOf('-');
  const plusIdx: number = noV.indexOf('+');
  let cutIdx: number = noV.length;
  if (dashIdx >= 0 && dashIdx < cutIdx) {
    cutIdx = dashIdx;
  }
  if (plusIdx >= 0 && plusIdx < cutIdx) {
    cutIdx = plusIdx;
  }
  return noV.substring(0, cutIdx).trim();
}

function parseVersionParts(version: string): number[] {
  const core: string = stripVersionPrefix(version);
  if (core === '') {
    return [0];
  }
  const rawParts: string[] = core.split('.');
  const nums: number[] = [];
  for (let i = 0; i < rawParts.length; i++) {
    const parsed: number = parseInt(rawParts[i], 10);
    nums.push(Number.isFinite(parsed) && parsed >= 0 ? parsed : 0);
  }
  return nums;
}

/**
 * 语义化版本比较：
 * - current < remote 返回 -1
 * - current == remote 返回 0
 * - current > remote 返回 1
 */
export function compareSemver(current: string, remote: string): number {
  const a: number[] = parseVersionParts(current);
  const b: number[] = parseVersionParts(remote);
  const len: number = Math.max(a.length, b.length);
  for (let i = 0; i < len; i++) {
    const va: number = i < a.length ? a[i] : 0;
    const vb: number = i < b.length ? b[i] : 0;
    if (va < vb) {
      return -1;
    }
    if (va > vb) {
      return 1;
    }
  }
  return 0;
}

export function parseGitHubReleaseJson(rawJson: string): GitHubReleaseInfo | null {
  if (rawJson.trim() === '') {
    return null;
  }
  try {
    const parsed: RawGitHubRelease = JSON.parse(rawJson) as RawGitHubRelease;
    if (parsed === null || parsed === undefined || parsed.draft === true) {
      return null;
    }
    const tagName: string = typeof parsed.tag_name === 'string' ? parsed.tag_name.trim() : '';
    const version: string = stripVersionPrefix(tagName);
    if (version === '') {
      return null;
    }
    const name: string = typeof parsed.name === 'string' ? parsed.name.trim() : tagName;
    const body: string = typeof parsed.body === 'string' ? parsed.body.trim() : '';
    const htmlUrl: string = typeof parsed.html_url === 'string' && parsed.html_url.trim() !== ''
      ? parsed.html_url.trim()
      : GITHUB_RELEASES_URL;
    return {
      tagName: tagName,
      version: version,
      name: name,
      body: body,
      htmlUrl: htmlUrl
    };
  } catch (e) {
    Logger.warn(TAG, `解析 GitHub Release JSON 失败: ${(e as Error).message}`);
    return null;
  }
}

export function evaluateReleaseUpdate(
  currentVersion: string,
  statusCode: number,
  responseBody: string
): UpdateCheckResult {
  if (statusCode === 404) {
    return {
      status: 'up_to_date',
      hasUpdate: false,
      currentVersion: currentVersion,
      release: null,
      errorMessage: ''
    };
  }
  if (statusCode < 200 || statusCode >= 300) {
    return {
      status: 'error',
      hasUpdate: false,
      currentVersion: currentVersion,
      release: null,
      errorMessage: `HTTP ${statusCode}`
    };
  }
  const release: GitHubReleaseInfo | null = parseGitHubReleaseJson(responseBody);
  if (release === null) {
    return {
      status: 'error',
      hasUpdate: false,
      currentVersion: currentVersion,
      release: null,
      errorMessage: 'invalid release payload'
    };
  }
  const hasNew: boolean = compareSemver(currentVersion, release.version) < 0;
  return {
    status: hasNew ? 'update_available' : 'up_to_date',
    hasUpdate: hasNew,
    currentVersion: currentVersion,
    release: release,
    errorMessage: ''
  };
}

export class AppUpdateChecker {
  static async checkForUpdate(
    currentVersion: string,
    timeoutMs: number = UPDATE_REQUEST_TIMEOUT_MS
  ): Promise<UpdateCheckResult> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(GITHUB_LATEST_RELEASE_API, {
        method: http.RequestMethod.GET,
        header: {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'NoyAcg-HarmonyOS'
        },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs
      });
      const bodyStr: string = typeof resp.result === 'string' ? resp.result : '';
      return evaluateReleaseUpdate(currentVersion, resp.responseCode, bodyStr);
    } catch (e) {
      const msg: string = (e as Error).message ?? 'network error';
      Logger.warn(TAG, `检查更新请求失败: ${msg}`);
      return {
        status: 'error',
        hasUpdate: false,
        currentVersion: currentVersion,
        release: null,
        errorMessage: msg
      };
    } finally {
      req.destroy();
    }
  }
}
