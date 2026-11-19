/**
 * DatabaseManager.ets —— 原生关系型数据库管理器（单例）
 *
 * 基于 @ohos.data.relationalStore（API 26 原生，零第三方依赖）：
 * - Favorite 表：comic_id 主键 / title / cover_url / add_time
 * - History  表：**旧版**（Phase 1–10），comic_id 主键，同漫画只保留一条
 * - HistoryV2 表：**Phase 11**，复合主键 (comic_id, chapter_id)，支持分章节进度隔离
 *
 * ── Phase 11 迁移说明（任务书 Step 9）──────────────────────────────
 * 旧 History 表以 comic_id 为主键，同一本漫画打开不同章节会互相覆盖，
 * 无法满足「章节进度隔离」。本阶段**不修改旧表结构**（避免破坏已安装用户的数据），
 * 而是新增 HistoryV2 表并在初始化时做一次幂等迁移：
 *   INSERT INTO HistoryV2 ... SELECT ... FROM History h
 *   WHERE NOT EXISTS (SELECT 1 FROM HistoryV2 v WHERE v.comic_id=h.comic_id AND v.chapter_id=h.chapter_id)
 * 「仅补不覆盖」保证：迁移后用户继续阅读产生的新进度不会被旧数据回退覆盖；
 * 重复启动重复执行结果相同。旧表保留（可回滚 / 可审计），不再写入。
 *
 * 工程约束（收官战硬性要求）：
 * 1. 全部方法为异步 Promise；2. ResultSet 一律 try-finally close()；
 * 3. init() 幂等去重；4. close() 在 EntryAbility.onDestroy 释放句柄。
 */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { DownloadStatus, DownloadTask, downloadTaskKey } from '../model/DownloadTask';
import { DownloadRepositoryPort } from '../download/DownloadPorts';
import { HistoryMetadata } from './ComicMetaCache';
import { Logger } from './Logger';

const TAG: string = 'DatabaseManager';
const DB_NAME: string = 'noyacg.db';

/**
 * 逻辑 Schema 版本（Phase 12 起显式记录）。
 * v1 = Favorite + History；v2 = + HistoryV2（Phase 11）；v3 = + DownloadTask（Phase 12）。
 * 本项目不使用破坏性升级：所有表都用 `CREATE TABLE IF NOT EXISTS` 幂等建立，
 * 旧表结构与数据一律保留，`init()` 重复调用也安全（不会在每次进页面时重建）。
 */
export const DB_SCHEMA_VERSION: number = 3;

/**
 * 下载任务表 DDL（导出供静态回归断言）。
 * 复合主键 (book_id, chapter_id) 保证「不同漫画即使章节 id 相同也分别保存」。
 * 迁移策略：`IF NOT EXISTS` 即可重复执行；不 ALTER、不 DROP、不覆盖任何用户数据。
 */
export const DOWNLOAD_TASK_DDL: string = `CREATE TABLE IF NOT EXISTS DownloadTask (
        book_id TEXT NOT NULL,
        chapter_id TEXT NOT NULL,
        book_title TEXT NOT NULL DEFAULT '',
        chapter_title TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL,
        total_images INTEGER NOT NULL DEFAULT 0,
        completed_images INTEGER NOT NULL DEFAULT 0,
        failed_images INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        last_error TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (book_id, chapter_id)
      )`;

/**
 * 新表 DDL（导出为常量供静态回归测试断言，避免「改了 SQL 但没人发现」）。
 * 复合主键 (comic_id, chapter_id) 是「不同章节进度隔离」的根本保证。
 */
export const HISTORY_V2_DDL: string = `CREATE TABLE IF NOT EXISTS HistoryV2 (
        comic_id TEXT NOT NULL,
        chapter_id TEXT NOT NULL,
        chapter_title TEXT NOT NULL,
        page_index INTEGER NOT NULL DEFAULT 1,
        total_pages INTEGER NOT NULL DEFAULT 0,
        update_time INTEGER NOT NULL,
        PRIMARY KEY (comic_id, chapter_id)
      )`;

/**
 * 旧 → 新迁移 SQL：`WHERE NOT EXISTS` 保证「只补不覆盖」且幂等，
 * 迁移后用户新产生的进度不会被旧表数据回退。
 */
export const HISTORY_V2_MIGRATION_SQL: string = `INSERT INTO HistoryV2
        (comic_id, chapter_id, chapter_title, page_index, total_pages, update_time)
        SELECT h.comic_id, h.chapter_id, h.chapter_title, h.page_index, 0, h.update_time
        FROM History h
        WHERE NOT EXISTS (
          SELECT 1 FROM HistoryV2 v
          WHERE v.comic_id = h.comic_id AND v.chapter_id = h.chapter_id
        )`;

/** 收藏记录（Favorite 表行结构） */
export interface FavoriteRecord {
  comicId: string;
  title: string;
  coverUrl: string;
  addTime: number;
}

/**
 * 阅读历史记录（HistoryV2 表行结构）。
 * Phase 11 新增 `totalPages`（可选，旧数据缺省 0 = 未知），
 * 主键由「comic_id」改为「(comic_id, chapter_id)」。
 */
export interface HistoryRecord {
  comicId: string;
  chapterId: string;
  chapterTitle: string;
  pageIndex: number;
  /** 该章节总页数（0 = 未知/旧数据）；可选以兼容 Phase 1–10 的调用方 */
  totalPages?: number;
  updateTime: number;
  /** 作品元数据（可选，向后兼容旧版仅有 comicId 的记录） */
  title?: string;
  coverUrl?: string;
  author?: string;
  tags?: string;
  isCompleted?: boolean;
  views?: number;
  favorites?: number;
}

/**
 * 阅读/收藏本地存储端口（Phase 11）：
 * ViewModel 只依赖本接口，单元测试可注入桩实现，无需真机数据库。
 * ArkTS 不支持结构类型隐式赋值，生产类必须显式 `implements`。
 */
export interface ReadingStorePort {
  isFavorite(comicId: string): Promise<boolean>;
  toggleFavorite(comicId: string, title: string, coverUrl: string): Promise<boolean>;
  /** 该书最近阅读的一条记录（跨章节按 update_time 取最新） */
  getHistory(comicId: string): Promise<HistoryRecord | null>;
  /** 精确查某章节进度（无记录返回 null）——章节切换不串页码的关键 */
  getHistoryForChapter(comicId: string, chapterId: string): Promise<HistoryRecord | null>;
  /** 该书全部章节进度（按 update_time 降序），供详情页标记已读章节 */
  getHistories(comicId: string): Promise<HistoryRecord[]>;
  /** 写入进度；失败必须抛出，由调用方决定是否提示（不得伪造成功） */
  saveHistory(record: HistoryRecord): Promise<void>;
}

export class DatabaseManager implements ReadingStorePort, DownloadRepositoryPort {
  private static instance?: DatabaseManager;
  /** 数据库句柄（init 完成后可用） */
  private store?: relationalStore.RdbStore;
  /** 初始化任务（幂等去重：并发调用共享同一 Promise） */
  private initTask?: Promise<void>;

  private constructor() {
  }

  static getInstance(): DatabaseManager {
    if (DatabaseManager.instance === undefined) {
      DatabaseManager.instance = new DatabaseManager();
    }
    return DatabaseManager.instance;
  }

  /**
   * 初始化：建库建表 + 旧 History → HistoryV2 幂等迁移
   * （EntryAbility.onCreate 调用；非阻塞，内部自行异步完成）。
   */
  init(context: common.Context): Promise<void> {
    if (this.initTask !== undefined) {
      return this.initTask;
    }
    this.initTask = this.doInit(context);
    return this.initTask;
  }

  private async doInit(context: common.Context): Promise<void> {
    const config: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
    await store.executeSql(`CREATE TABLE IF NOT EXISTS Favorite (
      comic_id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      cover_url TEXT NOT NULL,
      add_time INTEGER NOT NULL
    )`);
    // 旧表：保留原结构不动，只为迁移提供数据源（已安装用户的数据不会丢）
    await store.executeSql(`CREATE TABLE IF NOT EXISTS History (
      comic_id TEXT PRIMARY KEY,
      chapter_id TEXT NOT NULL,
      chapter_title TEXT NOT NULL,
      page_index INTEGER NOT NULL DEFAULT 1,
      update_time INTEGER NOT NULL
    )`);
    // 新表：复合主键隔离章节；total_pages 表达总页数，旧数据默认 0（未知）
    // 显式异常处理：建表失败必须上抛让 init 失败，不能静默退化成「无进度表」
    try {
      await store.executeSql(HISTORY_V2_DDL);
    } catch (e) {
      throw new Error(`创建 HistoryV2 表失败: ${(e as Error).message}`);
    }
    await this.migrateHistory(store);
    await this.ensureHistoryMetaColumns(store);
    // Phase 12：下载任务表（幂等迁移，不触碰 Favorite / History / HistoryV2 的任何数据）
    try {
      await store.executeSql(DOWNLOAD_TASK_DDL);
    } catch (e) {
      throw new Error(`创建 DownloadTask 表失败: ${(e as Error).message}`);
    }
    this.store = store;
    Logger.info(TAG, `数据库初始化完成 (schema v${DB_SCHEMA_VERSION})`);
  }

  /**
   * 旧 → 新迁移：**只补不覆盖**。
   * 不加 version 标记也能保证幂等；NOT EXISTS 确保新表里更新过的进度不被旧数据回退。
   */
  private async migrateHistory(store: relationalStore.RdbStore): Promise<void> {
    try {
      await store.executeSql(HISTORY_V2_MIGRATION_SQL);
      Logger.info(TAG, 'History → HistoryV2 迁移检查完成（幂等）');
    } catch (e) {
      // 迁移失败不阻断应用启动：新表仍可写，旧数据可在后续启动重试
      Logger.error(TAG, `历史记录迁移失败（不影响新记录写入）: ${(e as Error).message}`);
    }
  }

  /** 幂等补齐 HistoryV2 作品元数据列（已存在列时静默忽略） */
  private async ensureHistoryMetaColumns(store: relationalStore.RdbStore): Promise<void> {
    const alters: string[] = [
      "ALTER TABLE HistoryV2 ADD COLUMN title TEXT NOT NULL DEFAULT ''",
      "ALTER TABLE HistoryV2 ADD COLUMN cover_url TEXT NOT NULL DEFAULT ''",
      "ALTER TABLE HistoryV2 ADD COLUMN author TEXT NOT NULL DEFAULT ''",
      "ALTER TABLE HistoryV2 ADD COLUMN tags TEXT NOT NULL DEFAULT ''",
      'ALTER TABLE HistoryV2 ADD COLUMN is_completed INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE HistoryV2 ADD COLUMN views INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE HistoryV2 ADD COLUMN favorites INTEGER NOT NULL DEFAULT 0'
    ];
    for (let i = 0; i < alters.length; i++) {
      try {
        await store.executeSql(alters[i]);
      } catch (_e) {
        // 列已存在时 SQLite 会抛出 duplicate column name，忽略即可
      }
    }
  }

  /** 所有公开方法的前置：确保建库完成，返回可用句柄 */
  private async ensureReady(): Promise<relationalStore.RdbStore> {
    if (this.initTask !== undefined) {
      await this.initTask;
    }
    if (this.store === undefined) {
      throw new Error('数据库尚未初始化（请在 EntryAbility.onCreate 调用 init）');
    }
    return this.store;
  }

  /**
   * 读取可选的整数列：列缺失/读取失败返回 0（= 未知）。
   * Phase 11 新增列 `total_pages` 走这里，避免为「未知页数」引入新的 may-throw 告警。
   */
  private static readLongOrUnknown(resultSet: relationalStore.ResultSet, column: string): number {
    try {
      return resultSet.getLong(resultSet.getColumnIndex(column));
    } catch (e) {
      return 0;
    }
  }

  /** ResultSet 行 → HistoryRecord（统一列映射，避免各处字段漂移） */
  private static readStringOrEmpty(resultSet: relationalStore.ResultSet, column: string): string {
    try {
      return resultSet.getString(resultSet.getColumnIndex(column));
    } catch (_e) {
      return '';
    }
  }

  private static readHistoryRow(resultSet: relationalStore.ResultSet): HistoryRecord {
    return {
      comicId: resultSet.getString(resultSet.getColumnIndex('comic_id')),
      chapterId: resultSet.getString(resultSet.getColumnIndex('chapter_id')),
      chapterTitle: resultSet.getString(resultSet.getColumnIndex('chapter_title')),
      pageIndex: resultSet.getLong(resultSet.getColumnIndex('page_index')),
      totalPages: DatabaseManager.readLongOrUnknown(resultSet, 'total_pages'),
      updateTime: resultSet.getLong(resultSet.getColumnIndex('update_time')),
      title: DatabaseManager.readStringOrEmpty(resultSet, 'title'),
      coverUrl: DatabaseManager.readStringOrEmpty(resultSet, 'cover_url'),
      author: DatabaseManager.readStringOrEmpty(resultSet, 'author'),
      tags: DatabaseManager.readStringOrEmpty(resultSet, 'tags'),
      isCompleted: DatabaseManager.readLongOrUnknown(resultSet, 'is_completed') === 1,
      views: DatabaseManager.readLongOrUnknown(resultSet, 'views'),
      favorites: DatabaseManager.readLongOrUnknown(resultSet, 'favorites')
    };
  }

  private static readonly HISTORY_COLUMNS: string[] = [
    'comic_id', 'chapter_id', 'chapter_title', 'page_index', 'total_pages', 'update_time',
    'title', 'cover_url', 'author', 'tags', 'is_completed', 'views', 'favorites'
  ];

  // ==================== 收藏（Favorite，本地功能，非服务端接口） ====================

  async toggleFavorite(comicId: string, title: string, coverUrl: string): Promise<boolean> {
    const store = await this.ensureReady();
    if (await this.isFavorite(comicId)) {
      const delPredicates = new relationalStore.RdbPredicates('Favorite');
      delPredicates.equalTo('comic_id', comicId);
      await store.delete(delPredicates);
      Logger.debug(TAG, `取消收藏: ${comicId}`);
      return false;
    }
    const values: relationalStore.ValuesBucket = {
      'comic_id': comicId,
      'title': title,
      'cover_url': coverUrl,
      'add_time': Date.now()
    };
    await store.insert('Favorite', values);
    Logger.debug(TAG, `添加收藏: ${comicId}`);
    return true;
  }

  async isFavorite(comicId: string): Promise<boolean> {
    const store = await this.ensureReady();
    const predicates = new relationalStore.RdbPredicates('Favorite');
    predicates.equalTo('comic_id', comicId);
    const resultSet = await store.query(predicates, ['comic_id']);
    try {
      return resultSet.goToFirstRow();
    } finally {
      resultSet.close();
    }
  }

  /** 获取全部收藏（按收藏时间倒序，最新在前） */
  async getAllFavorites(): Promise<FavoriteRecord[]> {
    const store = await this.ensureReady();
    const predicates = new relationalStore.RdbPredicates('Favorite');
    predicates.orderByDesc('add_time');
    const resultSet = await store.query(predicates,
      ['comic_id', 'title', 'cover_url', 'add_time']);
    const result: FavoriteRecord[] = [];
    try {
      while (resultSet.goToNextRow()) {
        result.push({
          comicId: resultSet.getString(resultSet.getColumnIndex('comic_id')),
          title: resultSet.getString(resultSet.getColumnIndex('title')),
          coverUrl: resultSet.getString(resultSet.getColumnIndex('cover_url')),
          addTime: resultSet.getLong(resultSet.getColumnIndex('add_time'))
        });
      }
    } finally {
      resultSet.close();
    }
    return result;
  }

  // ==================== 阅读历史（HistoryV2） ====================

  /**
   * 保存阅读进度（UPSERT：复合主键 (comic_id, chapter_id) 冲突时覆盖该章节记录）。
   * 同章节更新页码不会产生重复记录；不同章节互不覆盖。
   * 写失败会**抛出**，绝不静默当作成功。
   */
  async saveHistory(record: HistoryRecord): Promise<void> {
    const store = await this.ensureReady();
    if (record.comicId === '' || record.chapterId === '') {
      throw new Error('保存阅读进度需要 comicId 与 chapterId');
    }
    let title: string = record.title ?? '';
    let coverUrl: string = record.coverUrl ?? '';
    let author: string = record.author ?? '';
    let tags: string = record.tags ?? '';
    let isCompleted: boolean = record.isCompleted ?? false;
    let views: number = record.views ?? 0;
    let favorites: number = record.favorites ?? 0;
    if (title === '' || coverUrl === '') {
      const existing: HistoryRecord | null = await this.getHistory(record.comicId);
      if (existing !== null) {
        if (title === '') {
          title = existing.title ?? '';
        }
        if (coverUrl === '') {
          coverUrl = existing.coverUrl ?? '';
        }
        if (author === '') {
          author = existing.author ?? '';
        }
        if (tags === '') {
          tags = existing.tags ?? '';
        }
        if (!isCompleted && existing.isCompleted === true) {
          isCompleted = true;
        }
        if (views === 0 && (existing.views ?? 0) > 0) {
          views = existing.views ?? 0;
        }
        if (favorites === 0 && (existing.favorites ?? 0) > 0) {
          favorites = existing.favorites ?? 0;
        }
      }
    }
    const values: relationalStore.ValuesBucket = {
      'comic_id': record.comicId,
      'chapter_id': record.chapterId,
      'chapter_title': record.chapterTitle,
      'page_index': Math.max(record.pageIndex, 1),
      'total_pages': Math.max(record.totalPages ?? 0, 0),
      'update_time': Date.now(),
      'title': title,
      'cover_url': coverUrl,
      'author': author,
      'tags': tags,
      'is_completed': isCompleted ? 1 : 0,
      'views': Math.max(views, 0),
      'favorites': Math.max(favorites, 0)
    };
    await store.insert('HistoryV2', values, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
  }

  /** 回写某漫画全部历史记录的作品元数据 */
  async updateHistoryMetadata(comicId: string, meta: HistoryMetadata): Promise<void> {
    if (comicId === '' || meta.title === '') {
      return;
    }
    const store = await this.ensureReady();
    const predicates = new relationalStore.RdbPredicates('HistoryV2');
    predicates.equalTo('comic_id', comicId);
    const values: relationalStore.ValuesBucket = {
      'title': meta.title,
      'cover_url': meta.coverUrl,
      'author': meta.author,
      'tags': meta.tags,
      'is_completed': meta.isCompleted ? 1 : 0,
      'views': Math.max(meta.views, 0),
      'favorites': Math.max(meta.favorites, 0)
    };
    await store.update(values, predicates);
  }

  /** 删除单本漫画的全部阅读历史 */
  async removeHistory(comicId: string): Promise<void> {
    if (comicId === '') {
      return;
    }
    const store = await this.ensureReady();
    const predV2 = new relationalStore.RdbPredicates('HistoryV2');
    predV2.equalTo('comic_id', comicId);
    await store.delete(predV2);
    const predV1 = new relationalStore.RdbPredicates('History');
    predV1.equalTo('comic_id', comicId);
    await store.delete(predV1);
  }

  /** 清空全部阅读历史 */
  async clearAllHistories(): Promise<void> {
    const store = await this.ensureReady();
    await store.delete(new relationalStore.RdbPredicates('HistoryV2'));
    await store.delete(new relationalStore.RdbPredicates('History'));
  }

  /** 精确查某章节进度（无记录返回 null）；查询/游标异常统一上抛，不伪装成「无记录」 */
  async getHistoryForChapter(comicId: string, chapterId: string): Promise<HistoryRecord | null> {
    const store = await this.ensureReady();
    const predicates = new relationalStore.RdbPredicates('HistoryV2');
    predicates.equalTo('comic_id', comicId).equalTo('chapter_id', chapterId);
    let opened: relationalStore.ResultSet | undefined = undefined;
    try {
      const rs: relationalStore.ResultSet = await store.query(predicates,
        DatabaseManager.HISTORY_COLUMNS);
      opened = rs;
      if (rs.goToNextRow()) {
        return DatabaseManager.readHistoryRow(rs);
      }
      return null;
    } catch (e) {
      throw new Error(`查询章节进度失败: ${(e as Error).message}`);
    } finally {
      const toClose: relationalStore.ResultSet | undefined = opened;
      if (toClose !== undefined) {
        try {
          toClose.close();
        } catch (e) {
          Logger.warn(TAG, `释放游标失败: ${(e as Error).message}`);
        }
      }
    }
  }

  /** 该书全部章节进度（按最近阅读时间降序） */
  async getHistories(comicId: string): Promise<HistoryRecord[]> {
    const store = await this.ensureReady();
    const predicates = new relationalStore.RdbPredicates('HistoryV2');
    predicates.equalTo('comic_id', comicId).orderByDesc('update_time');
    const resultSet = await store.query(predicates, DatabaseManager.HISTORY_COLUMNS);
    const result: HistoryRecord[] = [];
    try {
      while (resultSet.goToNextRow()) {
        result.push(DatabaseManager.readHistoryRow(resultSet));
      }
    } finally {
      resultSet.close();
    }
    return result;
  }

  /** 该书最近阅读的一条记录（兼容 Phase 1–10 的 getHistory 语义，无历史返回 null） */
  async getHistory(comicId: string): Promise<HistoryRecord | null> {
    const all: HistoryRecord[] = await this.getHistories(comicId);
    return all.length > 0 ? all[0] : null;
  }

  /**
   * 全站最近阅读历史（Phase 14-J1，个人中心「历史记录」入口）。
   * 按 update_time 降序取前 limit 条。HistoryV2 不存书名/封面，
   * 列表只能展示 comicId + 章节名 + 时间；点击进入详情页再取真实作品信息。
   */
  async getRecentHistories(limit: number = 50): Promise<HistoryRecord[]> {
    const store = await this.ensureReady();
    const predicates = new relationalStore.RdbPredicates('HistoryV2');
    predicates.orderByDesc('update_time');
    const max: number = limit > 0 ? limit : 50;
    let opened: relationalStore.ResultSet | undefined = undefined;
    try {
      const resultSet: relationalStore.ResultSet =
        await store.query(predicates, DatabaseManager.HISTORY_COLUMNS);
      opened = resultSet;
      const result: HistoryRecord[] = [];
      const seenComicIds: Set<string> = new Set<string>();
      while (resultSet.goToNextRow()) {
        const row: HistoryRecord = DatabaseManager.readHistoryRow(resultSet);
        if (seenComicIds.has(row.comicId)) {
          continue;
        }
        seenComicIds.add(row.comicId);
        result.push(row);
        if (result.length >= max) {
          break;
        }
      }
      return result;
    } catch (e) {
      throw new Error(`查询最近阅读历史失败: ${(e as Error).message}`);
    } finally {
      const toClose: relationalStore.ResultSet | undefined = opened;
      if (toClose !== undefined) {
        try {
          toClose.close();
        } catch (e) {
          Logger.warn(TAG, `释放游标失败: ${(e as Error).message}`);
        }
      }
    }
  }

  // ==================== 下载任务（DownloadTask，Phase 12） ====================

  /** 字符串 → 状态枚举；未知值按 FAILED 处理（可恢复，不伪造已完成） */
  private static toDownloadStatus(raw: string): DownloadStatus {
    switch (raw) {
      case DownloadStatus.QUEUED:
      case DownloadStatus.PREPARING:
      case DownloadStatus.DOWNLOADING:
      case DownloadStatus.PAUSED:
      case DownloadStatus.COMPLETED:
      case DownloadStatus.FAILED:
      case DownloadStatus.CANCELED:
      case DownloadStatus.INCOMPLETE:
        return raw as DownloadStatus;
      default:
        return DownloadStatus.FAILED;
    }
  }

  /** ResultSet 行 → DownloadTask（整体包异常处理，列缺失时明确上抛） */
  private static readDownloadTaskRow(resultSet: relationalStore.ResultSet): DownloadTask {
    try {
      const bookId: string = resultSet.getString(resultSet.getColumnIndex('book_id'));
      const chapterId: string = resultSet.getString(resultSet.getColumnIndex('chapter_id'));
      const task: DownloadTask = new DownloadTask(bookId, chapterId,
        resultSet.getString(resultSet.getColumnIndex('book_title')),
        resultSet.getString(resultSet.getColumnIndex('chapter_title')));
      task.status = DatabaseManager.toDownloadStatus(
        resultSet.getString(resultSet.getColumnIndex('status')));
      task.totalImages = resultSet.getLong(resultSet.getColumnIndex('total_images'));
      task.completedImages = resultSet.getLong(resultSet.getColumnIndex('completed_images'));
      task.failedImages = resultSet.getLong(resultSet.getColumnIndex('failed_images'));
      task.createdAt = resultSet.getLong(resultSet.getColumnIndex('created_at'));
      task.updatedAt = resultSet.getLong(resultSet.getColumnIndex('updated_at'));
      task.lastError = resultSet.getString(resultSet.getColumnIndex('last_error'));
      return task;
    } catch (e) {
      throw new Error(`读取下载任务行失败: ${(e as Error).message}`);
    }
  }

  private static readonly DOWNLOAD_COLUMNS: string[] = [
    'book_id', 'chapter_id', 'book_title', 'chapter_title', 'status',
    'total_images', 'completed_images', 'failed_images',
    'created_at', 'updated_at', 'last_error'
  ];

  /** 新增或更新任务（复合主键冲突时覆盖同一章节记录，绝不产生重复任务） */
  async upsert(task: DownloadTask): Promise<void> {
    const store = await this.ensureReady();
    const values: relationalStore.ValuesBucket = {
      'book_id': task.bookId,
      'chapter_id': task.chapterId,
      'book_title': task.bookTitle,
      'chapter_title': task.chapterTitle,
      'status': task.status,
      'total_images': Math.max(task.totalImages, 0),
      'completed_images': Math.max(task.completedImages, 0),
      'failed_images': Math.max(task.failedImages, 0),
      'created_at': task.createdAt,
      'updated_at': task.updatedAt,
      'last_error': task.lastError
    };
    try {
      await store.insert('DownloadTask', values,
        relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    } catch (e) {
      throw new Error(`保存下载任务失败 (${downloadTaskKey(task.bookId, task.chapterId)}): ` +
        `${(e as Error).message}`);
    }
  }

  /** 精确查询任务（无记录返回 null）；查询异常上抛，不伪装成「无任务」 */
  async get(bookId: string, chapterId: string): Promise<DownloadTask | null> {
    const store = await this.ensureReady();
    const predicates = new relationalStore.RdbPredicates('DownloadTask');
    predicates.equalTo('book_id', bookId).equalTo('chapter_id', chapterId);
    let opened: relationalStore.ResultSet | undefined = undefined;
    try {
      const rs: relationalStore.ResultSet = await store.query(predicates,
        DatabaseManager.DOWNLOAD_COLUMNS);
      opened = rs;
      if (rs.goToNextRow()) {
        return DatabaseManager.readDownloadTaskRow(rs);
      }
      return null;
    } catch (e) {
      throw new Error(`查询下载任务失败: ${(e as Error).message}`);
    } finally {
      const toClose: relationalStore.ResultSet | undefined = opened;
      if (toClose !== undefined) {
        try {
          toClose.close();
        } catch (e) {
          Logger.warn(TAG, `释放游标失败: ${(e as Error).message}`);
        }
      }
    }
  }

  /** 全部任务（按创建时间倒序） */
  async list(): Promise<DownloadTask[]> {
    const store = await this.ensureReady();
    const predicates = new relationalStore.RdbPredicates('DownloadTask');
    predicates.orderByDesc('created_at');
    let opened: relationalStore.ResultSet | undefined = undefined;
    try {
      const rs: relationalStore.ResultSet = await store.query(predicates,
        DatabaseManager.DOWNLOAD_COLUMNS);
      opened = rs;
      const result: DownloadTask[] = [];
      while (rs.goToNextRow()) {
        result.push(DatabaseManager.readDownloadTaskRow(rs));
      }
      return result;
    } catch (e) {
      throw new Error(`列出下载任务失败: ${(e as Error).message}`);
    } finally {
      const toClose: relationalStore.ResultSet | undefined = opened;
      if (toClose !== undefined) {
        try {
          toClose.close();
        } catch (e) {
          Logger.warn(TAG, `释放游标失败: ${(e as Error).message}`);
        }
      }
    }
  }

  /** 删除任务记录（不删文件，由 DownloadManager 显式区分两者） */
  async remove(bookId: string, chapterId: string): Promise<void> {
    const store = await this.ensureReady();
    const predicates = new relationalStore.RdbPredicates('DownloadTask');
    predicates.equalTo('book_id', bookId).equalTo('chapter_id', chapterId);
    try {
      await store.delete(predicates);
    } catch (e) {
      throw new Error(`删除下载任务失败: ${(e as Error).message}`);
    }
  }

  /** 清除已完成/已取消的任务**记录**（不动任何文件），返回删除条数 */
  async clearFinished(): Promise<number> {
    const all: DownloadTask[] = await this.list();
    let count: number = 0;
    for (let i = 0; i < all.length; i++) {
      const task: DownloadTask = all[i];
      if (task.status === DownloadStatus.COMPLETED
        || task.status === DownloadStatus.CANCELED) {
        await this.remove(task.bookId, task.chapterId);
        count++;
      }
    }
    return count;
  }

  // ==================== 生命周期 ====================

  /** 释放数据库句柄（EntryAbility.onDestroy 调用，防止句柄泄漏） */
  close(): void {
    if (this.store !== undefined) {
      this.store.close();
      this.store = undefined;
      this.initTask = undefined;
      Logger.info(TAG, '数据库句柄已释放');
    }
  }
}
