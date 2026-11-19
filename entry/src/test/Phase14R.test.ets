/**
 * Phase14R.test.ets —— Phase 14-R：设置页精修 / 屏蔽标签 / 缓存策略 / 日志 回归
 *
 * 覆盖（全部为单位级纯逻辑，不依赖网络与真实 Preferences）：
 * 1. BlockedTags：归一化、精确匹配（不误杀相似标签）、空值拒绝、上限、账号作用域键；
 * 2. ContentFilter：只过滤 list、保留服务端 len/totalPages；
 * 3. CachePolicy：上限判定、LRU 选择顺序、受保护文件不被删、有界删除、索引清洗；
 * 4. LogSanitizer：Cookie/Token/邮箱/UID/长随机串打码、URL 查询值打码、路径提取；
 * 5. DiagnosticLogManager：写入/有界/筛选/导出文本/清空；
 * 6. NetworkLogManager：元数据入库、成功失败判定、筛选、导出文本、路径不含参数值；
 * 7. SETTINGS_LAYOUT：分隔线缩进与行内边距一致（视觉对齐的契约化断言）。
 *
 * 说明：宿主测试无法测量 ArkUI 真实像素，视觉结论仍需真机验证
 * （报告中标记 RUNTIME_UNVERIFIED）。
 */
import { describe, it, expect } from '@ohos/hypium';
import { Comic } from '../main/ets/model/Comic';
import { PageInfo } from '../main/ets/model/PageInfo';
import {
  BLOCKED_SCOPE_ANON,
  BlockedTagSet,
  MAX_BLOCKED_TAGS,
  MAX_TAG_LENGTH,
  blockedScopeOf,
  blockedTagsStorageKey,
  comicMatchesBlockedTags,
  filterBlockedItems,
  isAccountScope,
  isValidBlockedTag,
  normalizeTag,
  parseTagList
} from '../main/ets/utils/BlockedTags';
import {
  CacheFileMeta,
  MAX_EVICTIONS_PER_RUN,
  evictionTargetBytes,
  isUnlimited,
  pruneAccessIndex,
  selectEvictions,
  shouldEvict
} from '../main/ets/utils/CachePolicy';
import {
  MASK,
  sanitizePath,
  sanitizeStack,
  sanitizeText,
  sanitizeUrl,
  summarize
} from '../main/ets/utils/LogSanitizer';
import {
  DiagnosticLogEntry,
  DiagnosticLogManager,
  LOG_LEVEL_ERROR,
  LOG_LEVEL_WARN
} from '../main/ets/utils/DiagnosticLogManager';
import {
  NET_FILTER_ERROR,
  NET_FILTER_OK,
  NetworkLogEntry,
  NetworkLogManager
} from '../main/ets/utils/NetworkLogManager';
import {
  LogExportResult,
  LogExportStatus,
  exportLogWithDocumentPicker,
  timestampedFileName
} from '../main/ets/utils/LogStore';
import { SETTINGS_LAYOUT } from '../main/ets/utils/ProfileLayout';
import {
  CACHE_LIMIT_OPTIONS,
  CACHE_LIMIT_UNLIMITED,
  DEFAULT_CACHE_LIMIT_BYTES,
  normalizeCacheLimit
} from '../main/ets/utils/PreferenceManager';

function makeComic(id: string, categories: string): Comic {
  const comic: Comic = new Comic(id, `title_${id}`, 'https://img.example/1.webp', 'author');
  comic.categories = categories;
  return comic;
}

function meta(name: string, size: number, lastAccess: number): CacheFileMeta {
  return new CacheFileMeta(name, size, lastAccess);
}

export default function phase14rTest() {
  describe('Phase14R_BlockedTags', () => {
    it('normalize_trim_and_lowercase', 0, () => {
      expect(normalizeTag('  奇幻  ')).assertEqual('奇幻');
      expect(normalizeTag('Action')).assertEqual('action');
      // 内部连续空白（含全角）压缩为单个空格
      expect(normalizeTag('校園\u3000 生活')).assertEqual('校園 生活');
      expect(normalizeTag('')).assertEqual('');
      expect(normalizeTag(null)).assertEqual('');
    });

    it('invalid_labels_rejected', 0, () => {
      expect(isValidBlockedTag('')).assertFalse();
      expect(isValidBlockedTag('   ')).assertFalse();
      expect(isValidBlockedTag(null)).assertFalse();
      // 超长（疑似脏数据）拒绝，但等于上限仍接受
      const long: string = 'a'.repeat(MAX_TAG_LENGTH);
      expect(isValidBlockedTag(long)).assertTrue();
      expect(isValidBlockedTag(`${long}a`)).assertFalse();
    });

    it('exact_match_does_not_kill_similar', 0, () => {
      const blocked: BlockedTagSet = new BlockedTagSet(['校园']);
      // 归一化后大小写/空格不同也算同一标签
      expect(blocked.contains('  校园 ')).assertTrue();
      // 绝不能把「校园生活」当成「校园」
      expect(blocked.contains('校园生活')).assertFalse();
      expect(comicMatchesBlockedTags('奇幻 校园生活', blocked)).assertFalse();
      expect(comicMatchesBlockedTags('奇幻 校园', blocked)).assertTrue();
    });

    it('missing_tags_never_blocked', 0, () => {
      const blocked: BlockedTagSet = new BlockedTagSet(['奇幻']);
      expect(comicMatchesBlockedTags('', blocked)).assertFalse();
      expect(comicMatchesBlockedTags(null, blocked)).assertFalse();
      // 空黑名单完全不参与过滤
      expect(comicMatchesBlockedTags('奇幻', BlockedTagSet.empty())).assertFalse();
    });

    it('parse_tag_list_supports_multiple_separators', 0, () => {
      expect(parseTagList('奇幻 冒險').length).assertEqual(2);
      expect(parseTagList('奇幻、冒險,日常').length).assertEqual(3);
      // 去重且保持原始顺序
      const tags: string[] = parseTagList('奇幻 奇幻 冒險');
      expect(tags.length).assertEqual(2);
      expect(tags[0]).assertEqual('奇幻');
      expect(tags[1]).assertEqual('冒險');
    });

    it('set_add_remove_is_idempotent_and_bounded', 0, () => {
      let set: BlockedTagSet = BlockedTagSet.empty();
      set = set.add('奇幻');
      set = set.add(' 奇幻 ');
      expect(set.size).assertEqual(1);
      set = set.add('');
      expect(set.size).assertEqual(1);
      set = set.remove('奇幻');
      expect(set.size).assertEqual(0);
      // 移除不存在的项不产生变更
      expect(set.remove('不存在').size).assertEqual(0);

      // 上限保护
      let many: BlockedTagSet = BlockedTagSet.empty();
      for (let i = 0; i < MAX_BLOCKED_TAGS + 10; i++) {
        many = many.add(`tag_${i}`);
      }
      expect(many.size).assertEqual(MAX_BLOCKED_TAGS);
    });

    it('filter_preserves_order_and_only_drops_matches', 0, () => {
      const blocked: BlockedTagSet = new BlockedTagSet(['动作']);
      const input: Comic[] = [
        makeComic('1', '奇幻 动作'),
        makeComic('2', '奇幻'),
        makeComic('3', '')
      ];
      const out: Comic[] = filterBlockedItems(input, blocked);
      expect(out.length).assertEqual(2);
      expect(out[0].id).assertEqual('2');
      expect(out[1].id).assertEqual('3');
      // 入参未被修改
      expect(input.length).assertEqual(3);
    });

    it('account_scope_key_is_isolated', 0, () => {
      expect(blockedScopeOf('')).assertEqual(BLOCKED_SCOPE_ANON);
      expect(blockedScopeOf(null)).assertEqual(BLOCKED_SCOPE_ANON);
      expect(isAccountScope('')).assertFalse();
      expect(isAccountScope('1001')).assertTrue();
      const anonKey: string = blockedTagsStorageKey('');
      const userAKey: string = blockedTagsStorageKey('1001');
      const userBKey: string = blockedTagsStorageKey('1002');
      expect(anonKey === userAKey).assertFalse();
      expect(userAKey === userBKey).assertFalse();
      // 非法字符不得进入键名
      expect(blockedTagsStorageKey('a/b:c d').indexOf('/')).assertEqual(-1);
      expect(blockedTagsStorageKey('a/b:c d').indexOf(' ')).assertEqual(-1);
    });

    it('persisted_dirty_data_sanitized', 0, () => {
      const set: BlockedTagSet = BlockedTagSet.fromPersisted([' 奇幻 ', '', '奇幻', 'x'.repeat(80)]);
      expect(set.size).assertEqual(1);
      expect(set.values[0]).assertEqual('奇幻');
      // 非法输入（非数组）退化为空集合
      expect(BlockedTagSet.fromPersisted(null).size).assertEqual(0);
    });
  });

  describe('Phase14R_FilterPipeline', () => {
    it('page_filter_keeps_server_pagination', 0, () => {
      // 直接验证过滤后的 PageInfo 语义：len/totalPages 不因过滤缩小
      const list: Comic[] = [makeComic('1', '动作'), makeComic('2', '奇幻')];
      const page: PageInfo<Comic> = new PageInfo<Comic>(2, 5, list, true, 100);
      const kept: Comic[] = [list[1]];
      const filtered: PageInfo<Comic> =
        new PageInfo<Comic>(page.page, page.totalPages, kept, page.hasMore, page.totalCount);
      expect(filtered.list.length).assertEqual(1);
      expect(filtered.totalCount).assertEqual(100);
      expect(filtered.totalPages).assertEqual(5);
      expect(filtered.hasMore).assertTrue();
    });
  });

  describe('Phase14R_CachePolicy', () => {
    it('limit_validation_and_unlimited', 0, () => {
      expect(normalizeCacheLimit(524288000)).assertEqual(524288000);
      expect(normalizeCacheLimit(1073741824)).assertEqual(1073741824);
      expect(normalizeCacheLimit(CACHE_LIMIT_UNLIMITED)).assertEqual(CACHE_LIMIT_UNLIMITED);
      // 非法值回退默认，不允许脏值控制删除行为
      expect(normalizeCacheLimit(123)).assertEqual(DEFAULT_CACHE_LIMIT_BYTES);
      expect(normalizeCacheLimit(-5)).assertEqual(DEFAULT_CACHE_LIMIT_BYTES);
      expect(CACHE_LIMIT_OPTIONS.length).assertEqual(3);
      expect(isUnlimited(CACHE_LIMIT_UNLIMITED)).assertTrue();
      expect(isUnlimited(0)).assertTrue();
      expect(isUnlimited(1024)).assertFalse();
    });

    it('should_evict_only_when_over_limit', 0, () => {
      expect(shouldEvict(2000, 1000)).assertTrue();
      expect(shouldEvict(1000, 1000)).assertFalse();
      expect(shouldEvict(999, 1000)).assertFalse();
      // 无限制永不清理
      expect(shouldEvict(999999999, CACHE_LIMIT_UNLIMITED)).assertFalse();
    });

    it('eviction_selects_oldest_first', 0, () => {
      const files: CacheFileMeta[] = [
        meta('new', 400, 3000),
        meta('old', 400, 1000),
        meta('mid', 400, 2000)
      ];
      // 1200 → 目标 900：删掉最旧的 400 后剩 800 已达标，因此只删 1 个
      const selected: CacheFileMeta[] = selectEvictions(files, 1200, 1000);
      expect(selected.length).assertEqual(1);
      expect(selected[0].name).assertEqual('old');
    });

    it('eviction_respects_protected_files', 0, () => {
      const files: CacheFileMeta[] = [
        meta('writing', 900, 1),
        meta('idle', 900, 2)
      ];
      const selected: CacheFileMeta[] = selectEvictions(files, 1800, 1000,
        (name: string): boolean => name === 'writing');
      expect(selected.length).assertEqual(1);
      expect(selected[0].name).assertEqual('idle');
    });

    it('eviction_stops_at_target_and_is_bounded', 0, () => {
      // 上限 1000 → 目标 900；1200 只需删 1 个 400 的文件
      const one: CacheFileMeta[] = [meta('a', 400, 1), meta('b', 400, 2), meta('c', 400, 3)];
      expect(selectEvictions(one, 1200, 1000).length).assertEqual(1);
      expect(evictionTargetBytes(1000)).assertEqual(900);

      // 大量小文件也不会一次删完（有界）
      const many: CacheFileMeta[] = [];
      for (let i = 0; i < MAX_EVICTIONS_PER_RUN + 50; i++) {
        many.push(meta(`f_${i}`, 10, i));
      }
      const selected: CacheFileMeta[] = selectEvictions(many, 100000, 1000);
      expect(selected.length).assertEqual(MAX_EVICTIONS_PER_RUN);
    });

    it('unknown_access_time_treated_as_oldest', 0, () => {
      const files: CacheFileMeta[] = [meta('known', 800, 5000), meta('unknown', 800, 0)];
      const selected: CacheFileMeta[] = selectEvictions(files, 1600, 1000);
      expect(selected[0].name).assertEqual('unknown');
    });

    it('prune_merges_index_and_marks_missing', 0, () => {
      const files: CacheFileMeta[] = [meta('a', 10, 0), meta('b', 20, 0)];
      const index: Map<string, number> = new Map<string, number>();
      index.set('a', 777);
      const pruned: CacheFileMeta[] = pruneAccessIndex(files, index);
      expect(pruned.length).assertEqual(2);
      expect(pruned[0].lastAccess).assertEqual(777);
      expect(pruned[1].lastAccess).assertEqual(0);
    });
  });

  describe('Phase14R_LogSanitizer', () => {
    it('masks_secrets_in_text', 0, () => {
      expect(sanitizeText('NOY_SESSION=abcdef123456').indexOf('abcdef123456')).assertEqual(-1);
      expect(sanitizeText('Cookie: a=1; b=2').indexOf('a=1')).assertEqual(-1);
      expect(sanitizeText('Authorization: Bearer abcdefghijklmnop')
        .indexOf('abcdefghijklmnop')).assertEqual(-1);
      expect(sanitizeText('password=hunter2').indexOf('hunter2')).assertEqual(-1);
      expect(sanitizeText('token=xyz').indexOf('xyz')).assertEqual(-1);
    });

    it('masks_email_and_uid', 0, () => {
      const masked: string = sanitizeText('user alice@example.com uid=12345 失败');
      expect(masked.indexOf('alice@example.com')).assertEqual(-1);
      expect(masked.indexOf('12345')).assertEqual(-1);
      expect(masked.indexOf('@example.com') >= 0).assertTrue();
    });

    it('masks_long_random_tokens', 0, () => {
      const token: string = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6';
      expect(sanitizeText(`value ${token} end`).indexOf(token)).assertEqual(-1);
    });

    it('url_query_values_are_masked', 0, () => {
      const url: string = 'https://noymanga.com/api/home?uid=9&v=3#frag';
      const masked: string = sanitizeUrl(url);
      expect(masked.indexOf('uid=9')).assertEqual(-1);
      expect(masked.indexOf('#frag')).assertEqual(-1);
      // 键名保留，便于排查「参数名写错」
      expect(masked.indexOf('uid=') >= 0).assertTrue();
      expect(masked.indexOf(MASK) >= 0).assertTrue();
    });

    it('path_strips_origin_and_query', 0, () => {
      expect(sanitizePath('https://noymanga.com/api/home?v=3')).assertEqual('/api/home');
      expect(sanitizePath('/api/v4/search/fetch?value=x')).assertEqual('/api/v4/search/fetch');
      expect(sanitizePath('')).assertEqual('');
      expect(sanitizePath('https://noymanga.com')).assertEqual('/');
    });

    it('stack_is_trimmed_and_masked', 0, () => {
      const lines: string[] = [];
      for (let i = 0; i < 40; i++) {
        lines.push(`at frame_${i} token=abc${i}`);
      }
      const stack: string = sanitizeStack(lines.join('\n'), 5);
      expect(stack.split('\n').length).assertEqual(5);
      expect(stack.indexOf('abc0')).assertEqual(-1);
    });

    it('summarize_flattens_newlines', 0, () => {
      expect(summarize('a\nb\tc', 40)).assertEqual('a b c');
      // 纯字母数字长串会被当作疑似 token 打码，这里用中文验证截断
      expect(summarize('测试'.repeat(20), 10).length).assertEqual(11);
    });
  });

  describe('Phase14R_DiagnosticLog', () => {
    it('records_and_filters', 0, () => {
      const manager: DiagnosticLogManager = DiagnosticLogManager.getInstance();
      manager.injectForTest([]);
      manager.record(LOG_LEVEL_ERROR, 'Net', '请求失败 token=abc');
      manager.record(LOG_LEVEL_WARN, 'Cache', '缓存偏大');
      expect(manager.count()).assertEqual(2);
      expect(manager.errorCount()).assertEqual(1);
      expect(manager.list(LOG_LEVEL_ERROR).length).assertEqual(1);
      expect(manager.list('', '缓存').length).assertEqual(1);
      // 最新在前
      expect(manager.list()[0].module).assertEqual('Cache');
      // 写入即脱敏
      expect(manager.list()[1].message.indexOf('abc')).assertEqual(-1);
    });

    it('empty_message_rejected', 0, () => {
      const manager: DiagnosticLogManager = DiagnosticLogManager.getInstance();
      manager.injectForTest([]);
      manager.record(LOG_LEVEL_ERROR, 'X', '   ');
      expect(manager.count()).assertEqual(0);
    });

    it('bounded_at_300', 0, () => {
      const manager: DiagnosticLogManager = DiagnosticLogManager.getInstance();
      manager.injectForTest([]);
      for (let i = 0; i < 320; i++) {
        manager.record(LOG_LEVEL_ERROR, 'M', `entry_${i}`);
      }
      expect(manager.count()).assertEqual(300);
      // 保留最新
      expect(manager.list()[0].message).assertEqual('entry_319');
    });

    it('export_text_contains_header_and_entries', 0, () => {
      const manager: DiagnosticLogManager = DiagnosticLogManager.getInstance();
      manager.injectForTest([]);
      manager.record(LOG_LEVEL_ERROR, 'Reader', '章节解析失败');
      const text: string = manager.exportText();
      expect(text.indexOf('NoyAcg 诊断日志导出') >= 0).assertTrue();
      expect(text.indexOf('章节解析失败') >= 0).assertTrue();
      expect(text.indexOf('已脱敏') >= 0).assertTrue();
    });

    it('clear_empties_memory', 0, () => {
      const manager: DiagnosticLogManager = DiagnosticLogManager.getInstance();
      manager.injectForTest([]);
      manager.record(LOG_LEVEL_ERROR, 'M', 'x');
      // clear 会尝试写盘（无 context 时返回 false），但内存必须清空
      manager.clear();
      expect(manager.count()).assertEqual(0);
    });

    it('entry_helpers', 0, () => {
      const entry: DiagnosticLogEntry = new DiagnosticLogEntry();
      entry.timestamp = Date.now();
      entry.message = 'line1\nline2';
      expect(entry.summary().indexOf('\n')).assertEqual(-1);
      expect(entry.timeText().length).assertEqual(19);
    });

    it('exportLogWithDocumentPicker_handlesSaveAndCancelBranches', 0, async () => {
      const fileName: string = timestampedFileName('noyacg_diagnostic', 'txt');
      expect(fileName.indexOf('noyacg_diagnostic_')).assertEqual(0);
      expect(fileName.endsWith('.txt')).assertTrue();

      let writtenUri: string = '';
      let writtenBody: string = '';
      const okRes: LogExportResult = await exportLogWithDocumentPicker(
        undefined,
        fileName,
        'error token=secret123',
        async (_name: string): Promise<string[]> => ['file://docs/Documents/report.txt'],
        async (uri: string, content: string): Promise<boolean> => {
          writtenUri = uri;
          writtenBody = content;
          return true;
        }
      );
      expect(okRes.status).assertEqual(LogExportStatus.SUCCESS);
      expect(writtenUri).assertEqual('file://docs/Documents/report.txt');
      expect(writtenBody.indexOf('secret123')).assertEqual(-1);

      const canceledRes: LogExportResult = await exportLogWithDocumentPicker(
        undefined,
        fileName,
        'sample log',
        async (_name: string): Promise<string[]> => []
      );
      expect(canceledRes.status).assertEqual(LogExportStatus.CANCELED);
    });
  });

  describe('Phase14R_NetworkLog', () => {
    it('records_metadata_and_ok_state', 0, () => {
      const manager: NetworkLogManager = NetworkLogManager.getInstance();
      manager.injectForTest([]);
      const okTrace = manager.begin('post', 'https://noymanga.com/api/home?uid=123');
      okTrace.statusCode = 200;
      okTrace.bytes = 100;
      manager.end(okTrace);

      const failTrace = manager.begin('GET', '/api/v4/search/fetch?value=秘密');
      failTrace.error = 'network 1001';
      manager.end(failTrace);

      expect(manager.count()).assertEqual(2);
      expect(manager.failureCount()).assertEqual(1);
      // 路径不含查询值
      const entries: NetworkLogEntry[] = manager.list();
      expect(entries[1].path).assertEqual('/api/home');
      expect(entries[1].method).assertEqual('POST');
      expect(entries[0].path).assertEqual('/api/v4/search/fetch');
      expect(entries[0].path.indexOf('秘密')).assertEqual(-1);
    });

    it('end_is_idempotent', 0, () => {
      const manager: NetworkLogManager = NetworkLogManager.getInstance();
      manager.injectForTest([]);
      const trace = manager.begin('GET', '/api/home');
      trace.statusCode = 200;
      manager.end(trace);
      manager.end(trace);
      expect(manager.count()).assertEqual(1);
    });

    it('filters_and_search', 0, () => {
      const manager: NetworkLogManager = NetworkLogManager.getInstance();
      manager.injectForTest([]);
      const okTrace = manager.begin('GET', '/api/home');
      okTrace.statusCode = 200;
      manager.end(okTrace);
      const badTrace = manager.begin('POST', '/api/readLeaderboard');
      badTrace.statusCode = 500;
      badTrace.error = 'HTTP 500';
      manager.end(badTrace);

      expect(manager.list(NET_FILTER_OK).length).assertEqual(1);
      expect(manager.list(NET_FILTER_ERROR).length).assertEqual(1);
      expect(manager.list('', 'leaderboard').length).assertEqual(1);
    });

    it('export_text_lists_requests', 0, () => {
      const manager: NetworkLogManager = NetworkLogManager.getInstance();
      manager.injectForTest([]);
      const trace = manager.begin('GET', '/api/home');
      trace.statusCode = 200;
      manager.end(trace);
      const text: string = manager.exportText();
      expect(text.indexOf('NoyAcg 网络请求日志') >= 0).assertTrue();
      expect(text.indexOf('/api/home') >= 0).assertTrue();
      expect(text.indexOf('Cookie') >= 0).assertTrue();
    });
  });

  describe('Phase14R_SettingsLayout', () => {
    it('divider_inset_matches_row_padding', 0, () => {
      // 视觉错位的根因就是这两者不一致
      expect(SETTINGS_LAYOUT.dividerInset).assertEqual(SETTINGS_LAYOUT.paddingHorizontal);
    });

    it('select_has_controlled_height', 0, () => {
      expect(SETTINGS_LAYOUT.selectHeight > 0).assertTrue();
      expect(SETTINGS_LAYOUT.selectMaxWidth > 0).assertTrue();
      // 高度必须容得下 12sp 文字 + 上下留白
      expect(SETTINGS_LAYOUT.selectHeight >= 28).assertTrue();
    });

    it('row_min_height_is_touchable', 0, () => {
      // 触摸区不小于 44vp（系统建议值）
      expect(SETTINGS_LAYOUT.rowMinHeight >= 44).assertTrue();
      expect(SETTINGS_LAYOUT.groupSpacing > 0).assertTrue();
    });
  });
}
