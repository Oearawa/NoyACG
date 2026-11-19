/**
 * LruStringCache.ets —— 有界 LRU 字符串缓存（Phase 14-O）
 *
 * ImageCacheManager 用它保存 url → file:// URI 映射。
 * 命中会把 key 移到队尾，淘汰永远从队头取最久未使用的条目。
 */
export class LruStringCache {
  private limit: number;
  private cache: Map<string, string> = new Map<string, string>();
  private order: string[] = [];

  constructor(limit: number) {
    this.limit = limit > 0 ? Math.floor(limit) : 1;
  }

  get(key: string): string | undefined {
    const value: string | undefined = this.cache.get(key);
    if (value === undefined) {
      return undefined;
    }
    this.touch(key);
    return value;
  }

  set(key: string, value: string): void {
    if (this.cache.has(key)) {
      this.touch(key);
    } else {
      this.order.push(key);
    }
    this.cache.set(key, value);
    while (this.order.length > this.limit) {
      const oldest: string | undefined = this.order.shift();
      if (oldest !== undefined) {
        this.cache.delete(oldest);
      }
    }
  }

  has(key: string): boolean {
    return this.cache.has(key);
  }

  delete(key: string): boolean {
    if (!this.cache.has(key)) {
      return false;
    }
    this.cache.delete(key);
    const index: number = this.order.indexOf(key);
    if (index >= 0) {
      this.order.splice(index, 1);
    }
    return true;
  }

  clear(): void {
    this.cache.clear();
    this.order = [];
  }

  size(): number {
    return this.cache.size;
  }

  keys(): string[] {
    const result: string[] = [];
    for (let i = 0; i < this.order.length; i++) {
      result.push(this.order[i]);
    }
    return result;
  }

  private touch(key: string): void {
    const index: number = this.order.indexOf(key);
    if (index >= 0) {
      this.order.splice(index, 1);
      this.order.push(key);
    }
  }
}
