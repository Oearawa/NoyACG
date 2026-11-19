/**
 * BlockedTagManager.ets —— 标签黑名单门面（Phase 14-R）
 *
 * 职责边界：
 * - **持久化** 全部交给 PreferenceManager（工程唯一偏好管理器，禁止第二个）；
 * - 本类只负责「增 / 删 / 清空 + 变更广播」；
 * - `@Trace revision` 在每次变更后自增，列表页据此重新加载第 1 页，
 *   无需把变更回调层层往下传。
 *
 * 账号隔离：作用域由 PreferenceManager.applyBlockedTagScope() 决定（AuthManager 在
 * 登录/登出/会话恢复时调用），本类不自己判断登录态。
 */
import { PreferenceManager } from './PreferenceManager';
import {
  BlockedTagSet,
  MAX_BLOCKED_TAGS,
  isValidBlockedTag,
  normalizeTag
} from './BlockedTags';
import { Logger } from './Logger';

const TAG: string = 'BlockedTagManager';

@ObservedV2
export class BlockedTagManager {
  private static instance?: BlockedTagManager;

  /** 变更版本号：任何一次成功变更都自增（UI 用 @Monitor 触发重载） */
  @Trace revision: number = 0;
  /** 当前屏蔽值（归一化；与 Preferences 内存快照保持一致） */
  @Trace tags: string[] = [];
  /** 最近一次操作失败原因（空串 = 无错误） */
  @Trace errorMessage: string = '';
  /** 是否正在写入（防重入） */
  @Trace isSaving: boolean = false;

  private constructor() {
  }

  static getInstance(): BlockedTagManager {
    if (BlockedTagManager.instance === undefined) {
      BlockedTagManager.instance = new BlockedTagManager();
    }
    return BlockedTagManager.instance;
  }

  /** 从偏好内存快照同步到本地展示字段（页面进入时调用） */
  reload(): void {
    this.tags = PreferenceManager.getInstance().getBlockedTagsSync().toPersisted();
    this.errorMessage = '';
  }

  /** 当前屏蔽集合（过滤管线的读取入口） */
  blockedSet(): BlockedTagSet {
    return PreferenceManager.getInstance().getBlockedTagsSync();
  }

  isEmpty(): boolean {
    return this.tags.length === 0;
  }

  /** 当前作用域是否为账号维度（仅用于 UI 文案，不代表云同步） */
  isAccountScoped(): boolean {
    return PreferenceManager.getInstance().getBlockedScopeSync() !== 'anon';
  }

  /** 是否已达数量上限 */
  isFull(): boolean {
    return this.tags.length >= MAX_BLOCKED_TAGS;
  }

  /**
   * 加入一条屏蔽标签。
   * @returns true = 已生效（含「本来就存在」的幂等情形）；false = 非法输入或写入失败
   */
  async add(rawTag: string): Promise<boolean> {
    if (!isValidBlockedTag(rawTag)) {
      this.errorMessage = 'invalid';
      return false;
    }
    if (this.isSaving) {
      return false;
    }
    const current: BlockedTagSet = this.blockedSet();
    const next: BlockedTagSet = current.add(rawTag);
    if (next.size === current.size) {
      // 已存在：幂等成功，不重复写盘
      this.errorMessage = '';
      return true;
    }
    return await this.persist(next);
  }

  /** 移除一条屏蔽标签（不存在时视为成功） */
  async remove(rawTag: string): Promise<boolean> {
    const key: string = normalizeTag(rawTag);
    if (key === '') {
      this.errorMessage = 'invalid';
      return false;
    }
    if (this.isSaving) {
      return false;
    }
    const current: BlockedTagSet = this.blockedSet();
    const next: BlockedTagSet = current.remove(key);
    if (next.size === current.size) {
      this.errorMessage = '';
      return true;
    }
    return await this.persist(next);
  }

  /** 清空当前作用域的黑名单 */
  async clear(): Promise<boolean> {
    if (this.isSaving) {
      return false;
    }
    if (this.tags.length === 0) {
      return true;
    }
    return await this.persist(BlockedTagSet.empty());
  }

  /** 批量加入（来自漫画详情「屏蔽此标签」等场景；非法项自动跳过） */
  async addMany(rawTags: string[]): Promise<boolean> {
    if (this.isSaving) {
      return false;
    }
    let next: BlockedTagSet = this.blockedSet();
    const before: number = next.size;
    for (let i = 0; i < rawTags.length; i++) {
      next = next.add(rawTags[i]);
    }
    if (next.size === before) {
      return true;
    }
    return await this.persist(next);
  }

  private async persist(next: BlockedTagSet): Promise<boolean> {
    this.isSaving = true;
    this.errorMessage = '';
    try {
      const ok: boolean = await PreferenceManager.getInstance().setBlockedTags(next);
      this.tags = next.toPersisted();
      if (!ok) {
        // 内存已更新但未能落盘：如实报错，让 UI 提示「本次会话有效、重启后失效」
        this.errorMessage = 'not_persisted';
        Logger.warn(TAG, '标签黑名单未持久化（偏好未初始化或写入失败）');
      }
      this.revision++;
      return ok;
    } catch (e) {
      this.errorMessage = (e as Error).message;
      Logger.error(TAG, `标签黑名单写入异常: ${this.errorMessage}`);
      return false;
    } finally {
      this.isSaving = false;
    }
  }
}
