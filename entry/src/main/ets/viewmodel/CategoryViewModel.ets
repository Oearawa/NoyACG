/**
 * CategoryViewModel.ets —— 分类网格页状态机（Phase 14-N / 14-N1）
 *
 * 分类目录来自用户提供的 140185 视觉参考；不是服务端分类接口或分类 ID。
 * 封面只从真实 /api/home 返回的漫画中按 Comic.categories 匹配代表图；
 * 找不到就由 UI 显示明确占位，绝不拼接虚构 URL。
 * 点击后复用已验证的 SearchParam(mode=tag) 自动触发搜索。
 * 14-N1：仓库内没有已配置登录会话、也没有任何真实 mode=tag 成功响应，
 * 因此 12 个分类的真实搜索结果一律标记 API_UNVERIFIED，不填写返回数量或匹配结论。
 */
import { Comic } from '../model/Comic';
import { HomeFeed } from '../model/HomeFeed';
import { SearchParam, SEARCH_MODE_TAG } from '../model/NavParams';
import {
  CATEGORY_DEFINITIONS,
  CategoryDefinition,
  CategoryItem,
  buildCategorySearchParam,
  categoryCoverFor,
  categoryDefinitionByKey
} from '../model/DiscoveryModels';
import { DiscoveryRepository, HomeFeedPort } from '../api/DiscoveryRepository';
import { AuthRequiredError } from '../api/ApiErrors';
import { LocalizationManager } from '../utils/LocalizationManager';

export interface CategoryTextPort {
  getName(def: CategoryDefinition): string;
  getTag(def: CategoryDefinition): string;
}

/** 生产实现：文案全部来自三语言资源，fallback 为空，不新增硬编码中文。 */
export class DefaultCategoryTextPort implements CategoryTextPort {
  getName(def: CategoryDefinition): string {
    return LocalizationManager.getInstance().getString(def.nameRes, '');
  }

  getTag(def: CategoryDefinition): string {
    return LocalizationManager.getInstance().getString(def.tagRes, '');
  }
}

export const CATEGORY_STATUS_VERIFIED: string = 'VERIFIED';
export const CATEGORY_STATUS_PARTIAL: string = 'PARTIAL';
export const CATEGORY_STATUS_API_UNVERIFIED: string = 'API_UNVERIFIED';
export const CATEGORY_STATUS_FAILED: string = 'FAILED';

/** 未发起真实请求的标记；不得用 Mock 成功结果填充。 */
export const CATEGORY_REQUEST_NOT_RUN: string = 'NOT_RUN';
/** 返回数量未采集（未登录、无真实响应），不得写成 0 或其他虚构值。 */
export const CATEGORY_RETURN_COUNT_UNKNOWN: number = -1;

/** 单项分类的静态参数核对记录 + 真实 API 验证状态。 */
export interface CategorySearchVerification {
  key: string;
  /** 实际发给 /api/v4/search/fetch 的 value */
  keyword: string;
  mode: string;
  status: string;
  requestResult: string;
  returnCount: number;
  /** 是否通过静态参数链路核对 */
  paramValid: boolean;
  /** 是否存在重复 URL 编码/转义 */
  doubleEncoded: boolean;
  /** 是否满足 SearchPage.aboutToAppear 自动查询条件 */
  autoSearch: boolean;
}

/**
 * 逐项核对本地参数链路；真实服务端结果一律 API_UNVERIFIED。
 * 证据：fixtures/README.md:40-43（derived 样例非真实响应）、
 * LOGIN_PROTOCOL_AUDIT.md:15（无会话）、Phase14J3_REPORT.md:234（mode=tag 成功响应未取得）。
 */
export function verifyCategorySearchParam(item: CategoryItem): CategorySearchVerification {
  const param: SearchParam = buildCategorySearchParam(item.tag);
  const expected: string = item.tag.trim();
  const keyword: string = param.keyword;
  // 参数链路只有一次 trim；出现 '%' 转义或与原值不符即视为重复编码/改写
  const doubleEncoded: boolean = keyword !== expected || keyword.indexOf('%') >= 0;
  const paramValid: boolean = item.key !== '' && expected !== ''
    && keyword === expected && param.mode === SEARCH_MODE_TAG && !doubleEncoded;
  return {
    key: item.key,
    keyword: keyword,
    mode: param.mode,
    status: CATEGORY_STATUS_API_UNVERIFIED,
    requestResult: CATEGORY_REQUEST_NOT_RUN,
    returnCount: CATEGORY_RETURN_COUNT_UNKNOWN,
    paramValid: paramValid,
    doubleEncoded: doubleEncoded,
    autoSearch: keyword.trim() !== '' && param.mode === SEARCH_MODE_TAG
  };
}

export function verifyAllCategorySearchParams(items: CategoryItem[]): CategorySearchVerification[] {
  const rows: CategorySearchVerification[] = [];
  for (let i = 0; i < items.length; i++) {
    rows.push(verifyCategorySearchParam(items[i]));
  }
  return rows;
}

/** 12 项 key 必须唯一且都来自已登记定义，不允许出现未定义映射。 */
export function categoryMappingsAreUniqueAndDefined(items: CategoryItem[]): boolean {
  if (items.length !== CATEGORY_DEFINITIONS.length) {
    return false;
  }
  for (let i = 0; i < items.length; i++) {
    if (categoryDefinitionByKey(items[i].key) === null) {
      return false;
    }
    for (let j = i + 1; j < items.length; j++) {
      if (items[i].key === items[j].key || items[i].tag === items[j].tag) {
        return false;
      }
    }
  }
  return true;
}

/** 真实验证数量：无真实响应时恒为 0，不允许把静态参数核对计为 VERIFIED。 */
export function realVerifiedCategoryCount(rows: CategorySearchVerification[]): number {
  let count: number = 0;
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].status === CATEGORY_STATUS_VERIFIED) {
      count++;
    }
  }
  return count;
}

function collectHomeComics(feed: HomeFeed): Comic[] {
  const result: Comic[] = [];
  const groups: Comic[][] = [feed.favDay, feed.readDay, feed.fs, feed.proportion];
  for (let i = 0; i < groups.length; i++) {
    const group: Comic[] = groups[i];
    for (let j = 0; j < group.length; j++) {
      result.push(group[j]);
    }
  }
  return result;
}

@ObservedV2
export class CategoryViewModel {
  @Trace items: CategoryItem[] = [];
  @Trace isLoading: boolean = false;
  @Trace errorMessage: string = '';
  @Trace needsLogin: boolean = false;

  private repo: HomeFeedPort;
  private text: CategoryTextPort;
  private generation: number = 0;

  constructor(repo?: HomeFeedPort, text?: CategoryTextPort) {
    this.repo = repo ?? new DiscoveryRepository();
    this.text = text ?? new DefaultCategoryTextPort();
  }

  async load(): Promise<void> {
    const gen: number = ++this.generation;
    this.isLoading = true;
    this.errorMessage = '';
    this.needsLogin = false;
    try {
      const feed: HomeFeed = await this.repo.getHomeFeed();
      if (gen !== this.generation) {
        return;
      }
      const comics: Comic[] = collectHomeComics(feed);
      const result: CategoryItem[] = [];
      for (let i = 0; i < CATEGORY_DEFINITIONS.length; i++) {
        const def: CategoryDefinition = CATEGORY_DEFINITIONS[i];
        const name: string = this.text.getName(def);
        const tag: string = this.text.getTag(def);
        const cover: string = categoryCoverFor(tag, comics);
        result.push(new CategoryItem(def.key, name, tag, cover));
      }
      this.items = result;
      this.isLoading = false;
    } catch (e) {
      if (gen !== this.generation) {
        return;
      }
      this.errorMessage = e instanceof Error ? e.message : '';
      this.needsLogin = e instanceof AuthRequiredError;
      this.isLoading = false;
    }
  }

  searchParamFor(item: CategoryItem): SearchParam {
    return buildCategorySearchParam(item.tag);
  }

  retry(): void {
    this.load();
  }
}
