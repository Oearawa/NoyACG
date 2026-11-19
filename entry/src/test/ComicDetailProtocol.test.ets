/**
 * ComicDetailProtocol.test.ets —— Phase 11 详情/章节数据层测试
 *
 * 全部样例都是 `*.derived.json` 派生的**非抓包**数据（除 `*.auth-required.json` 真实抓包），
 * 见 fixtures/README.md。本套件验证「拿到响应体之后」的映射、排序与异常分支，
 * 不联网、不依赖设备，也不声称验证了登录后的真实接口响应。
 *
 * 覆盖：正常详情 / 缺失可选字段 / 空详情 / 错误类型 / 章节分组 / 空分组 /
 * 特殊章节名称 / 非预期字段类型 / 分组展开折叠 / 跨分组 ID / 读图 URL 规则。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  NOY_IMG_ORIGIN,
  RawBookDetailEnvelope,
  RawChapterEnvelope,
  RawChapterGroup,
  buildChapterImageUrl,
  flattenChapters,
  parseBookDetail,
  parseBookDetailJson,
  parseChapterGroups,
  parseChapterImages
} from '../main/ets/source/NoyAcgProtocol';
import {
  BOOK_MODE_CHAPTERS,
  BOOK_MODE_SINGLE,
  BOOK_MODE_UNKNOWN,
  DETAIL_VALUE_UNKNOWN
} from '../main/ets/model/ComicDetail';
import { Chapter } from '../main/ets/model/Chapter';
import { ChapterGroup } from '../main/ets/model/ChapterGroup';
import { ChapterRow } from '../main/ets/model/ChapterRow';
import { AuthRequiredError, ProtocolError } from '../main/ets/api/ApiErrors';
import {
  BOOK_DETAIL_AUTH_REQUIRED,
  BOOK_DETAIL_BAD_TYPES_DERIVED,
  BOOK_DETAIL_FULL_DERIVED,
  BOOK_DETAIL_MINIMAL_DERIVED,
  BOOK_DETAIL_SINGLE_DERIVED,
  CHAPTER_GROUPS_DERIVED,
  CHAPTER_IMAGES_AUTH_REQUIRED,
  CHAPTER_IMAGES_ZERO_CID_DERIVED
} from './fixtures/FixtureData';

function catchError(fn: () => void): Error | null {
  try {
    fn();
    return null;
  } catch (e) {
    return e as Error;
  }
}

function asDetail(text: string): RawBookDetailEnvelope {
  try {
    return JSON.parse(text) as RawBookDetailEnvelope;
  } catch (e) {
    throw new ProtocolError(`fixture 不是合法 JSON: ${(e as Error).message}`);
  }
}

function asChapter(text: string): RawChapterEnvelope {
  try {
    return JSON.parse(text) as RawChapterEnvelope;
  } catch (e) {
    throw new ProtocolError(`fixture 不是合法 JSON: ${(e as Error).message}`);
  }
}

function asGroups(text: string): RawChapterGroup {
  try {
    return JSON.parse(text) as RawChapterGroup;
  } catch (e) {
    throw new ProtocolError(`fixture 不是合法 JSON: ${(e as Error).message}`);
  }
}

export default function comicDetailProtocolTest() {
  describe('ComicDetailProtocol', () => {
    // ==================== 详情模型 ====================

    it('fullDetailMapsAllFirstPartyFields', 0, () => {
      const detail = parseBookDetailJson(BOOK_DETAIL_FULL_DERIVED, 'fallback');
      expect(detail.id).assertEqual('900201');
      expect(detail.title).assertEqual('範例作品 C');
      expect(detail.author).assertEqual('範例作者 C');
      expect(detail.alias).assertEqual('別名 C');
      expect(detail.description.indexOf('非真實資料') >= 0).assertTrue();
      expect(detail.cover).assertEqual(`${NOY_IMG_ORIGIN}/900201/m1.webp`);
      expect(detail.rating).assertEqual(88);
      expect(detail.ratingCount).assertEqual(5);
      expect(detail.favorites).assertEqual(9);
      expect(detail.isCompleted === true).assertTrue();
      expect(detail.mode).assertEqual(BOOK_MODE_CHAPTERS);
      expect(detail.publishYear).assertEqual('2023');
      expect(detail.updatedAtRaw).assertEqual(1735689600);
      expect(detail.updatedAt).assertEqual('2025-01-01');
      expect(detail.tags.length).assertEqual(2);
      expect(detail.characters[0]).assertEqual('角色甲');
      expect(detail.originals[0]).assertEqual('原作甲');
      expect(detail.groups.length).assertEqual(3);
      expect(detail.chapters.length).assertEqual(4);
    });

    it('minimalDetailLeavesMissingFieldsUnknown', 0, () => {
      const detail = parseBookDetailJson(BOOK_DETAIL_MINIMAL_DERIVED, 'fallback');
      expect(detail.id).assertEqual('900301');
      expect(detail.title).assertEqual('最小欄位作品');
      // 缺失字段必须是「明确的未知」，不能变成 0 分 / 已完结 / 假章节
      expect(detail.rating).assertEqual(DETAIL_VALUE_UNKNOWN);
      expect(detail.ratingCount).assertEqual(DETAIL_VALUE_UNKNOWN);
      expect(detail.favorites).assertEqual(DETAIL_VALUE_UNKNOWN);
      expect(detail.isCompleted === null).assertTrue();
      expect(detail.mode).assertEqual(BOOK_MODE_UNKNOWN);
      expect(detail.updatedAt).assertEqual('');
      expect(detail.alias).assertEqual('');
      expect(detail.groups.length).assertEqual(0);
      expect(detail.chapters.length).assertEqual(0);
      expect(detail.hasChapters).assertFalse();
      expect(detail.isSingleBook).assertFalse();
    });

    it('singleBookModeZeroHasNoChaptersButIsReadable', 0, () => {
      const detail = parseBookDetailJson(BOOK_DETAIL_SINGLE_DERIVED, 'fallback');
      expect(detail.mode).assertEqual(BOOK_MODE_SINGLE);
      expect(detail.isSingleBook).assertTrue();
      expect(detail.chapters.length).assertEqual(0);
      expect(detail.hasChapters).assertFalse();
    });

    it('badTypesDoNotCrashOrFabricate', 0, () => {
      const detail = parseBookDetailJson(BOOK_DETAIL_BAD_TYPES_DERIVED, 'fallback');
      expect(detail.id).assertEqual('900303');
      expect(detail.title).assertEqual('');          // number → 不渲染
      expect(detail.author).assertEqual('');         // object → 不渲染
      expect(detail.description).assertEqual('');    // array → 不渲染
      expect(detail.rating).assertEqual(DETAIL_VALUE_UNKNOWN);
      expect(detail.ratingCount).assertEqual(DETAIL_VALUE_UNKNOWN);
      expect(detail.isCompleted === null).assertTrue();
      expect(detail.mode).assertEqual(BOOK_MODE_UNKNOWN);
      expect(detail.updatedAt).assertEqual('');
      expect(detail.tags.length).assertEqual(0);
      expect(detail.groups.length).assertEqual(0);   // categories 非数组 → 空
      expect(detail.chapters.length).assertEqual(0);
    });

    it('detailAuthRequiredIsDetected', 0, () => {
      const err: Error | null = catchError(() => {
        parseBookDetailJson(BOOK_DETAIL_AUTH_REQUIRED, '1');
      });
      expect(err instanceof AuthRequiredError).assertTrue();
    });

    it('chapterImagesAuthRequiredIsDetected', 0, () => {
      const err: Error | null = catchError(() => {
        parseChapterImages(asChapter(CHAPTER_IMAGES_AUTH_REQUIRED), '1', '2');
      });
      expect(err instanceof AuthRequiredError).assertTrue();
    });

    it('detailMissingBookInfoRejected', 0, () => {
      const err: Error | null = catchError(() => {
        parseBookDetailJson('{"book":{}}', '1');
      });
      expect(err instanceof ProtocolError).assertTrue();
    });

    it('detailNonJsonRejected', 0, () => {
      const err: Error | null = catchError(() => {
        parseBookDetailJson('<html>error</html>', '1');
      });
      expect(err instanceof ProtocolError).assertTrue();
    });

    it('detailEmptyEnvelopeRejected', 0, () => {
      const err: Error | null = catchError(() => {
        parseBookDetail(undefined, '1');
      });
      expect(err instanceof ProtocolError).assertTrue();
    });

    it('fallbackIdUsedWhenBidMissing', 0, () => {
      const envelope: RawBookDetailEnvelope = asDetail('{"book":{"info":{"Bookname":"無 Bid"}}}');
      const detail = parseBookDetail(envelope, 'route-77');
      expect(detail.id).assertEqual('route-77');
      expect(detail.cover).assertEqual(`${NOY_IMG_ORIGIN}/route-77/m1.webp`);
    });

    // ==================== 章节分组 ====================

    it('groupsPreserveCategoryOrderAndEmptyGroups', 0, () => {
      const groups: ChapterGroup[] = parseChapterGroups(asGroups(CHAPTER_GROUPS_DERIVED));
      // 无 id 的分组被跳过（无法定位 data），其余保留 categories 顺序
      expect(groups.length).assertEqual(2);
      expect(groups[0].id).assertEqual('a');
      expect(groups[0].name).assertEqual('分組 A');
      expect(groups[1].id).assertEqual('b');
      expect(groups[1].name).assertEqual('分組 #b'); // 客户端兜底，不是服务端字段
      expect(groups[1].count).assertEqual(0);        // data['b'] 非数组 → 空分组
    });

    it('groupUsesNumericSortNotTitleStringSort', 0, () => {
      const groups: ChapterGroup[] = parseChapterGroups(asGroups(CHAPTER_GROUPS_DERIVED));
      const chapters = groups[0].chapters;
      expect(chapters.length).assertEqual(3);
      // sort 10 / 2 / 3 → 期望 2,3,10；若按标题字符串排序会把「第 10 话」排前
      expect(chapters[0].title).assertEqual('第 2 话');
      expect(chapters[1].title).assertEqual('章節 #3');
      expect(chapters[2].title).assertEqual('第 10 话');
      expect(chapters[2].sort).assertEqual(10);
    });

    it('groupChapterFallbackNameAndOptionalFields', 0, () => {
      const groups: ChapterGroup[] = parseChapterGroups(asGroups(CHAPTER_GROUPS_DERIVED));
      const third = groups[0].chapters[1];
      expect(third.id).assertEqual('3');
      expect(third.title).assertEqual('章節 #3');
      expect(third.groupId).assertEqual('a');
      expect(third.groupName).assertEqual('分組 A');
      expect(third.pageCount).assertEqual(7);          // "7" 数字字符串
      expect(third.updatedAt).assertEqual('2024-01-02'); // created_at unix 秒 → YYYY-MM-DD（Phase 14-I）
    });

    it('groupsUndefinedOrInvalidShapeReturnEmpty', 0, () => {
      expect(parseChapterGroups(undefined).length).assertEqual(0);
      expect(parseChapterGroups({}).length).assertEqual(0);
      expect(parseChapterGroups({ categories: [], data: {} }).length).assertEqual(0);
    });

    it('flattenChaptersAssignsDisplayOrderAcrossGroups', 0, () => {
      const groups: ChapterGroup[] = parseChapterGroups(asGroups(CHAPTER_GROUPS_DERIVED));
      const flat = flattenChapters(groups);
      expect(flat.length).assertEqual(3);
      expect(flat[0].order).assertEqual(1);
      expect(flat[2].order).assertEqual(3);
      expect(flat[0].groupId).assertEqual('a');
    });

    it('crossGroupSameChapterIdDoesNotCollideInRowKeys', 0, () => {
      const detail = parseBookDetailJson(BOOK_DETAIL_FULL_DERIVED, 'x');
      // 分组 5 与分组 6 都有章节 id=90010（真实响应是否允许未验证，这里验证客户端不冲突）
      expect(detail.chapters.length).assertEqual(4);
      let first: Chapter | null = null;
      let second: Chapter | null = null;
      for (let i = 0; i < detail.chapters.length; i++) {
        const ch: Chapter = detail.chapters[i];
        if (ch.id === '90010') {
          if (first === null) {
            first = ch;
          } else {
            second = ch;
          }
        }
      }
      expect(first !== null && second !== null).assertTrue();
      if (first !== null && second !== null) {
        const a: Chapter = first;
        const b: Chapter = second;
        expect(a.groupId === b.groupId).assertFalse();
        const rowA: ChapterRow = ChapterRow.item(a.groupId, a.groupName, a);
        const rowB: ChapterRow = ChapterRow.item(b.groupId, b.groupName, b);
        expect(rowA.key === rowB.key).assertFalse();
      }
      expect(ChapterRow.header('5', '第 1 卷', true, 3).key).assertEqual('g:5');
    });

    it('groupExpandCollapseAndCount', 0, () => {
      const group: ChapterGroup = new ChapterGroup('x', '分組 X', []);
      expect(group.isExpanded).assertTrue();
      expect(group.count).assertEqual(0);
      group.isExpanded = false;
      expect(group.isExpanded).assertFalse();
      const detail = parseBookDetailJson(BOOK_DETAIL_FULL_DERIVED, 'x');
      expect(detail.groups[0].count).assertEqual(3);
      expect(detail.groups[2].count).assertEqual(0);
    });

    // ==================== 章节图片 / 特殊章节 ====================

    it('normalCidImagePathRule', 0, () => {
      expect(buildChapterImageUrl('900', '12', 1))
        .assertEqual(`${NOY_IMG_ORIGIN}/900/12/1.webp`);
    });

    it('zeroCidImagePathHasNoChapterSegment', 0, () => {
      // 首方 ct(bid,0) = `${img}/${bid}` → 少一级目录
      expect(buildChapterImageUrl('900', '0', 1))
        .assertEqual(`${NOY_IMG_ORIGIN}/900/1.webp`);
      const images: string[] = parseChapterImages(
        asChapter(CHAPTER_IMAGES_ZERO_CID_DERIVED), '900', '0');
      expect(images.length).assertEqual(2); // 只取 chapter.this.count=2，不按 URL 推断
      expect(images[0]).assertEqual(`${NOY_IMG_ORIGIN}/900/1.webp`);
      expect(images[1]).assertEqual(`${NOY_IMG_ORIGIN}/900/2.webp`);
    });

    it('imageCountOnlyComesFromResponseCount', 0, () => {
      const envelope: RawChapterEnvelope = { data: { count: 3 } };
      const images: string[] = parseChapterImages(envelope, '1', '2');
      expect(images.length).assertEqual(3);
      expect(images[2]).assertEqual(`${NOY_IMG_ORIGIN}/1/2/3.webp`);
      // 没有 count → 空列表，不猜测页数
      expect(parseChapterImages({ chapter: {} }, '1', '2').length).assertEqual(0);
      expect(parseChapterImages({ data: { count: Number.NaN } }, '1', '2').length).assertEqual(0);
    });

    it('chapterImagesRejectMissingIds', 0, () => {
      const err: Error | null = catchError(() => {
        parseChapterImages({ data: { count: 1 } }, '', '2');
      });
      expect(err instanceof ProtocolError).assertTrue();
    });
  });
}
