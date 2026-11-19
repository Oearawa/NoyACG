/**
 * ContentRatingPolicy.ets —— 内容分级全局策略（单例 · @ObservedV2）
 *
 * Phase 14-J1 新增。职责：把「内容分级」收敛为 App 内**唯一**的运行时真相源：
 *
 *   PreferenceManager（持久化）
 *          ↓ 载入
 *   ContentRatingPolicy（本文件，内存态 + 变更通知）
 *          ↓ 读取
 *   HttpManager（统一注入 allow-adult 请求头，仅站内 /api 请求）
 *          ↓
 *   NoyAcg API
 *
 * 设计要点：
 * 1. 不新建第二套内容分级状态 —— 持久化仍用 PreferenceManager.contentRating；
 * 2. 取值只接受 `false | true | both`，非法值一律回退 `false`（全年龄）；
 * 3. 变更后同步通知订阅者（HomeViewModel 等），由订阅者主动刷新受影响数据；
 * 4. 只描述「站内 API 请求头」语义，不涉及图片 CDN / 图床 / 外部域名。
 */
import { ContentRating, PreferenceManager } from './PreferenceManager';

/** 内容分级变更监听器（无参，订阅方自行重新拉取数据） */
export type ContentRatingListener = () => void;

@ObservedV2
export class ContentRatingPolicy {
  private static instance?: ContentRatingPolicy;

  /** 当前生效的内容分级（'false' | 'true' | 'both'），UI 可直接观察 */
  @Trace current: string = ContentRating.ALL_AGES;
  /**
   * 变更代数（Phase 14-S）：每次**真实变更**自增。
   * 页面/ViewModel 用它判断「我上次加载时的分级是否已经过期」，
   * 从而在重新进入页面（而不是依赖常驻监听）时也能正确刷新。
   */
  @Trace revision: number = 0;

  /** 是否已从持久化载入（避免每次读取都触达 Preference） */
  private loaded: boolean = false;
  /** 变更监听器集合 */
  private listeners: ContentRatingListener[] = [];

  private constructor() {
  }

  static getInstance(): ContentRatingPolicy {
    if (ContentRatingPolicy.instance === undefined) {
      ContentRatingPolicy.instance = new ContentRatingPolicy();
    }
    return ContentRatingPolicy.instance;
  }

  /** 同步版本号到 AppStorage（供跨页面/组件响应式感知） */
  private syncAppStorageRevision(): void {
    try {
      AppStorage.setOrCreate('contentRatingRevision', this.revision);
    } catch (_e) {
      // 单元测试无 ArkUI 运行时上下文时忽略
    }
  }

  /** 从 PreferenceManager 载入当前分级（EntryAbility.onCreate 调用一次；幂等） */
  loadFromPreference(): void {
    this.current = ContentRatingPolicy.sanitize(
      PreferenceManager.getInstance().getContentRatingSync());
    this.loaded = true;
    this.syncAppStorageRevision();
  }

  /**
   * 前台恢复时的分级一致性检查（Phase 14-T1）。
   *
   * 背景：内容分级**正常路径**只在设置页通过 `set()` 修改，且 `set()` 会同步更新本单例内存态，
   * 所以「后台期间分级被改」在单进程内不会发生。但为稳健起见，应用回到前台时重新读一次
   * 持久化值，若与内存态不一致（例如未来接入其它写入通道 / 多窗口 / 系统备份恢复），
   * 就广播一次变更，让前台可见的 RatingBridge 订阅者按新分级重新请求。
   *
   * 幂等且廉价：仅一次 Preference 同步读 + 一次字符串比较；未变化时不广播、不触发任何请求。
   */
  reconcileFromPreference(): boolean {
    const persisted: string = ContentRatingPolicy.sanitize(
      PreferenceManager.getInstance().getContentRatingSync());
    if (persisted === this.current) {
      return false;
    }
    this.current = persisted;
    this.loaded = true;
    this.revision++;
    this.syncAppStorageRevision();
    this.notify();
    return true;
  }

  /** 读取当前分级（未初始化则先载入；任何异常回退全年龄） */
  resolve(): string {
    if (!this.loaded) {
      this.loadFromPreference();
    }
    return ContentRatingPolicy.sanitize(this.current);
  }

  /**
   * 切换内容分级：先校验 → 落盘 → 更新内存 → 通知订阅者。
   * @returns true = 已生效（内存态一定更新；落盘失败也算本次生效）
   */
  async set(rating: string): Promise<boolean> {
    const next: string = ContentRatingPolicy.sanitize(rating);
    const changed: boolean = next !== this.current;
    // 落盘（PreferenceManager 内部会校验合法值；无 store 时降级为本次会话生效）
    await PreferenceManager.getInstance().setContentRating(next);
    this.current = next;
    this.loaded = true;
    if (changed) {
      this.revision++;
      this.syncAppStorageRevision();
      this.notify();
    }
    return true;
  }

  /** 订阅变更（同一监听器不重复注册） */
  onChange(listener: ContentRatingListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  /** 取消订阅 */
  offChange(listener: ContentRatingListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  /** 通知全部订阅者（任一监听器异常不影响其它监听器） */
  private notify(): void {
    // 复制一份，防止监听器在回调中增删导致遍历错乱
    const snapshot: ContentRatingListener[] = this.listeners.slice();
    for (let i = 0; i < snapshot.length; i++) {
      try {
        snapshot[i]();
      } catch (e) {
        // 监听器自行记录日志；这里吞掉以保证其它订阅者仍被通知
      }
    }
  }

  /** 合法值收敛：只允许真实协议三值，其余一律全年龄 */
  static sanitize(value: string): string {
    if (value === ContentRating.ADULT || value === ContentRating.BOTH) {
      return value;
    }
    return ContentRating.ALL_AGES;
  }

  /** 当前变更代数（浅读，不做任何副作用） */
  revisionNow(): number {
    return this.revision;
  }

  /** 供测试重置内存态（不触达磁盘） */
  resetForTest(): void {
    this.current = ContentRating.ALL_AGES;
    this.loaded = false;
    this.revision = 0;
    this.syncAppStorageRevision();
    this.listeners = [];
  }
}
