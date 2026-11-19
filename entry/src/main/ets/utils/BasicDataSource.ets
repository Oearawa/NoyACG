/**
 * BasicDataSource.ets —— LazyForEach 通用懒加载数据源基类
 *
 * 职责：实现 ArkUI 原生 IDataSource 接口，作为 List / WaterFlow + LazyForEach
 * 的数据供给方。长列表（漫画封面墙、阅读器长图）必须走本方案做「按需创建节点」，
 * 严禁直接 ForEach 全量加载导致 OOM。
 *
 * 使用示例（阶段三首页）：
 *   class HomeDataSource extends BasicDataSource<Comic> {}
 *   LazyForEach(this.dataSource, (item: Comic) => { ComicCard({ comic: item }) },
 *     (item: Comic) => item.id)   // key 生成器务必返回稳定唯一值
 *
 * 通知机制说明：
 *   调用 pushData/deleteData 等业务方法后自动调用对应 notifyDataXxx；
 *   Phase 14-O 起 pushDataList 使用逐条 onDataAdd，setDataStable 支持
 *   「共同前缀字段变化 + 尾部追加/删除」的增量更新，避免整表 onDataReloaded。
 */
import { planStableListUpdate, ListUpdatePlan } from './StableLayout';
export class BasicDataSource<T> implements IDataSource {
  /** 内部数据数组（严禁直接暴露引用供外部修改，统一走本类方法保证通知成对出现） */
  private dataArray: T[] = [];
  /** 已注册的变更监听器（由 LazyForEach 内部注册） */
  private listeners: DataChangeListener[] = [];

  // ==================== IDataSource 必须实现的四个方法 ====================

  /** 数据源总条数：LazyForEach 据此决定滚动加载范围 */
  totalCount(): number {
    return this.dataArray.length;
  }

  /** 按下标取数据（LazyForEach 创建/复用节点时回调） */
  getData(index: number): Object {
    // API 26 的 IDataSource.getData 声明为 any，ArkTS 侧统一以 Object 返回，
    // 泛型 T → Object 需显式断言（items 均为 class 实例或基础类型，运行期安全）
    return this.dataArray[index] as Object;
  }

  /** 注册数据变更监听器（LazyForEach 挂载时由框架调用） */
  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) >= 0) {
      return;
    }
    this.listeners.push(listener);
  }

  /** 注销数据变更监听器（LazyForEach 卸载时由框架调用） */
  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  // ==================== 变更通知（触发 LazyForEach 局部刷新） ====================

  /** 全量刷新：整表数据被替换时使用（如刷新首页第一页） */
  notifyDataReload(): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }

  /** 通知「下标 index 处新增了一条数据」 */
  notifyDataAdd(index: number): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataAdd(index);
    });
  }

  /** 通知「下标 index 处删除了一条数据」 */
  notifyDataDelete(index: number): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataDelete(index);
    });
  }

  /** 通知「下标 index 处数据内容变化」（如刷新某条漫画的封面/标题） */
  notifyDataChange(index: number): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataChange(index);
    });
  }

  /** 通知「数据从 from 移动到 to」（如拖拽排序） */
  notifyDataMove(from: number, to: number): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataMove(from, to);
    });
  }

  // ==================== 业务常用增删改查 ====================

  /** 类型安全的按下标读取（IDataSource.getData 返回 Object，此为泛型便捷版） */
  get(index: number): T {
    return this.dataArray[index];
  }

  /** 获取内部数组引用（只读场景，如 forEach 遍历；修改请走本类方法） */
  getDataArray(): T[] {
    return this.dataArray;
  }

  /** 整表替换（仅用于数据集整体变化 / 重排 / 重复 key 等无法安全增量复用的场景） */
  setData(list: T[]): void {
    this.dataArray = list;
    this.notifyDataReload();
  }

  /** 显式重载整表数据并派发 onDataReloaded() 通知（语义别名） */
  reloadData(list: T[]): void {
    this.setData(list);
  }

  /**
   * 稳定 key 增量替换：同 key 同顺序时只更新指纹变化的条目；
   * 尾部追加走 onDataAdd，尾部删除走 onDataDelete。
   * 中间插入/重排/重复 key 会回退到 setData，避免错误复用旧图片节点。
   */
  setDataStable(
    list: T[],
    keyOf: (item: T) => string,
    fingerprintOf: (item: T) => string
  ): void {
    const plan: ListUpdatePlan = planStableListUpdate(this.dataArray, list, keyOf, fingerprintOf);
    if (plan.fullReload) {
      this.setData(list);
      return;
    }
    for (let i = 0; i < plan.changed.length; i++) {
      const index: number = plan.changed[i];
      this.dataArray[index] = list[index];
      this.notifyDataChange(index);
    }
    for (let i = 0; i < plan.removed.length; i++) {
      this.deleteData(plan.removed[i]);
    }
    for (let i = 0; i < plan.added.length; i++) {
      const index: number = plan.added[i];
      this.dataArray.push(list[index]);
      this.notifyDataAdd(this.dataArray.length - 1);
    }
  }

  /** 追加单条（阅读器逐章追加图片时高频使用） */
  pushData(item: T): void {
    this.dataArray.push(item);
    this.notifyDataAdd(this.dataArray.length - 1);
  }

  /** 批量追加：逐条 onDataAdd，旧节点不再随分页追加被整表重建。 */
  pushDataList(items: T[]): void {
    if (items.length === 0) {
      return;
    }
    for (let i = 0; i < items.length; i++) {
      this.dataArray.push(items[i]);
      this.notifyDataAdd(this.dataArray.length - 1);
    }
  }

  /** 指定下标插入 */
  insertData(index: number, item: T): void {
    if (index < 0 || index > this.dataArray.length) {
      return;
    }
    this.dataArray.splice(index, 0, item);
    this.notifyDataAdd(index);
  }

  /** 删除指定下标数据 */
  deleteData(index: number): void {
    if (index < 0 || index >= this.dataArray.length) {
      return;
    }
    this.dataArray.splice(index, 1);
    this.notifyDataDelete(index);
  }

  /** 更新指定下标数据 */
  updateData(index: number, item: T): void {
    if (index < 0 || index >= this.dataArray.length) {
      return;
    }
    this.dataArray[index] = item;
    this.notifyDataChange(index);
  }

  /** 清空全部数据（重置列表/退出阅读器时调用，及时释放节点） */
  clear(): void {
    this.dataArray = [];
    this.notifyDataReload();
  }

  /** 查询某条数据的下标（不存在返回 -1） */
  indexOf(item: T): number {
    return this.dataArray.indexOf(item);
  }

  /** 是否为空 */
  isEmpty(): boolean {
    return this.dataArray.length === 0;
  }
}
