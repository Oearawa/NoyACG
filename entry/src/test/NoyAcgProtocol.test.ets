/**
 * NoyAcgProtocol.test.ets —— 协议层解析测试（真实 Fixture + 派生 Fixture）
 *
 * Fixture 说明（详见 fixtures/README.md）：
 * - `*auth-required` / `login.invalid-credentials` 是**真实抓包**（匿名 HTTP 200 响应）；
 * - `*.derived` 是依据 NoyAcg 首方前端字段用法构造的样例，**不是**真实抓包，
 *   用于验证解析器对已证实字段、缺失字段、脏数据的处理。
 *
 * 本套件不联网、不依赖设备，验证的是「拿到真实响应体之后」的全部映射与异常分支。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  NOY_IMG_ORIGIN,
  NOY_STREAM_ORIGIN,
  RawChapterEnvelope,
  buildBookListForm,
  buildCoverUrl,
  parseBookDetailJson,
  parseBookListJson,
  parseChapterImages,
  parseSearchJson,
  BOOKLIST_SORT_VIEWS,
  BOOKLIST_SORT_RATING,
  BOOKLIST_FINISHED_COMPLETED,
  BOOKLIST_FINISHED_ONGOING
} from '../main/ets/source/NoyAcgProtocol';
import { Comic } from '../main/ets/model/Comic';
import { PageInfo } from '../main/ets/model/PageInfo';
import { ComicDetail } from '../main/ets/model/ComicDetail';
import { AuthRequiredError, ProtocolError } from '../main/ets/api/ApiErrors';
import {
  BOOK_DETAIL_AUTH_REQUIRED,
  BOOK_DETAIL_DERIVED,
  BOOKLIST_SUCCESS_DERIVED,
  CHAPTER_IMAGES_DERIVED,
  LOGIN_INVALID_CREDENTIALS,
  SEARCH_AUTH_REQUIRED,
  SEARCH_EMPTY_DERIVED,
  SEARCH_SUCCESS_DERIVED
} from './fixtures/FixtureData';

/** 捕获解析异常，返回异常对象（null = 未抛异常） */
function catchError(fn: () => void): Error | null {
  try {
    fn();
    return null;
  } catch (e) {
    return e as Error;
  }
}

/** 把章节 fixture 文本解析为协议层入参（测试内自行保证 JSON 合法） */
function chapterEnvelope(text: string): RawChapterEnvelope {
  try {
    return JSON.parse(text) as RawChapterEnvelope;
  } catch (e) {
    throw new ProtocolError(`章节 fixture 不是合法 JSON: ${(e as Error).message}`);
  }
}

export default function noyAcgProtocolTest() {
  describe('NoyAcgProtocol', () => {

    // ==================== 搜索成功 ====================

    it('searchParsesSuccessPayload', 0, () => {
      const page: PageInfo<Comic> = parseSearchJson(SEARCH_SUCCESS_DERIVED, 1);
      expect(page.list.length).assertEqual(3);
      expect(page.page).assertEqual(1);
      // count=42，页大小 20 → 3 页
      expect(page.totalPages).assertEqual(3);
      expect(page.hasMore).assertTrue();

      const first: Comic = page.list[0];
      expect(first.id).assertEqual('900101');
      expect(first.title).assertEqual('範例作品 A');
      expect(first.author).assertEqual('範例作者 A');
      // 封面规则：默认走图片 CDN /{id}/m1.webp
      expect(first.cover).assertEqual(`${NOY_IMG_ORIGIN}/900101/m1.webp`);
      // 标签：tags + otag，空格分隔
      expect(first.categories).assertEqual('標籤甲 標籤乙 其他標籤');
    });

    it('searchHandlesStreamItemCover', 0, () => {
      const page: PageInfo<Comic> = parseSearchJson(SEARCH_SUCCESS_DERIVED, 1);
      const stream: Comic = page.list[1];
      // source=stream → 走 stream CDN，且路径使用 id 的相反数
      expect(stream.id).assertEqual('900102');
      expect(stream.cover).assertEqual(`${NOY_STREAM_ORIGIN}/-900102/cover.webp`);
    });

    it('searchToleratesMissingOptionalFields', 0, () => {
      const page: PageInfo<Comic> = parseSearchJson(SEARCH_SUCCESS_DERIVED, 1);
      const minimal: Comic = page.list[2];
      expect(minimal.id).assertEqual('900103');
      expect(minimal.title).assertEqual('最小欄位作品');
      expect(minimal.author).assertEqual('');
      expect(minimal.categories).assertEqual('');
      expect(minimal.cover).assertEqual(`${NOY_IMG_ORIGIN}/900103/m1.webp`);
    });

    it('searchEmptyResult', 0, () => {
      const page: PageInfo<Comic> = parseSearchJson(SEARCH_EMPTY_DERIVED, 1);
      expect(page.list.length).assertEqual(0);
      expect(page.totalPages).assertEqual(0);
      expect(page.hasMore).assertFalse();
    });

    it('searchLastPageHasNoMore', 0, () => {
      // count=42，第 3 页 → 不应再判为有下一页（避免无限翻页）
      const page: PageInfo<Comic> = parseSearchJson(SEARCH_SUCCESS_DERIVED, 3);
      expect(page.totalPages).assertEqual(3);
      expect(page.hasMore).assertFalse();
    });

    it('searchUnknownCountUsesPageSizeHeuristic', 0, () => {
      // 无 count 字段：本页 3 条 < 20 → 判定没有下一页
      const text: string = '{"data":[{"id":1,"name":"A"}]}';
      const page: PageInfo<Comic> = parseSearchJson(text, 1);
      expect(page.totalPages).assertEqual(-1);
      expect(page.hasMore).assertFalse();
    });

    // ==================== 搜索异常 ====================

    it('searchAuthRequiredIsDetected', 0, () => {
      // 真实抓包：HTTP 200 + {"status":"login"}
      const err: Error | null = catchError(() => {
        parseSearchJson(SEARCH_AUTH_REQUIRED, 1);
      });
      expect(err !== null).assertTrue();
      expect(err instanceof AuthRequiredError).assertTrue();
      expect((err as AuthRequiredError).message.indexOf('登录') >= 0).assertTrue();
    });

    it('searchNonJsonRejected', 0, () => {
      const err: Error | null = catchError(() => {
        parseSearchJson('<html><body>gateway error</body></html>', 1);
      });
      expect(err instanceof ProtocolError).assertTrue();
      expect((err as Error).message.indexOf('不是合法 JSON') >= 0).assertTrue();
    });

    it('searchMissingDataRejected', 0, () => {
      const err: Error | null = catchError(() => {
        parseSearchJson('{"count":0}', 1);
      });
      expect(err instanceof ProtocolError).assertTrue();
      expect((err as Error).message.indexOf('data') >= 0).assertTrue();
    });

    it('searchDataNotArrayRejected', 0, () => {
      const err: Error | null = catchError(() => {
        parseSearchJson('{"data":{"a":1},"count":1}', 1);
      });
      expect(err instanceof ProtocolError).assertTrue();
    });

    it('searchAllItemsWithoutIdRejected', 0, () => {
      // 全是没有 id 的脏数据：无法作为列表 key，必须报协议错误而不是渲染空列表
      const err: Error | null = catchError(() => {
        parseSearchJson('{"data":[{"name":"无 id"}],"count":1}', 1);
      });
      expect(err instanceof ProtocolError).assertTrue();
      expect((err as Error).message.indexOf('id') >= 0).assertTrue();
    });

    it('loginErrorStatusIsNotAuthSuccess', 0, () => {
      // 真实抓包：错误凭据返回 {"status":"error"}；它不是列表响应，必须按协议错误处理
      const err: Error | null = catchError(() => {
        parseSearchJson(LOGIN_INVALID_CREDENTIALS, 1);
      });
      expect(err instanceof ProtocolError).assertTrue();
      expect(err instanceof AuthRequiredError).assertFalse();
    });

    // ==================== 书单（首页/最新） ====================

    it('bookListParsesPascalCasePayload', 0, () => {
      const page: PageInfo<Comic> = parseBookListJson(BOOKLIST_SUCCESS_DERIVED, 1);
      expect(page.list.length).assertEqual(2);
      // len=21 → 2 页
      expect(page.totalPages).assertEqual(2);
      expect(page.hasMore).assertTrue();
      const first: Comic = page.list[0];
      expect(first.id).assertEqual('900201');
      expect(first.title).assertEqual('範例作品 C');
      expect(first.author).assertEqual('範例作者 C');
      expect(first.cover).assertEqual(`${NOY_IMG_ORIGIN}/900201/m1.webp`);
      expect(first.categories).assertEqual('標籤丙 其他標籤');
      // Phase 14-B：卡片信息字段映射（评分/浏览量/收藏/年份/页数）
      expect(first.ratingSum).assertEqual(88);
      expect(first.views).assertEqual(100);
      expect(first.favorites).assertEqual(9);
      expect(first.publishYear).assertEqual('2023');
      expect(first.pageCount).assertEqual(32);
      // Phase 14-H：简介字段映射（来自书单响应 Description）
      expect(first.description).assertEqual('用於書單解析測試的範例條目（非真實資料）');
      // 第二个条目缺字段，应保持默认值（不把缺失字段伪装成真实数据）
      const second: Comic = page.list[1];
      expect(second.ratingSum).assertEqual(0);
      expect(second.views).assertEqual(0);
      expect(second.publishYear).assertEqual('');
      expect(second.pageCount).assertEqual(0);
      expect(second.description).assertEqual('');
      // 第二页数据（第 2 页）不再有下一页
      const lastPage: PageInfo<Comic> = parseBookListJson(BOOKLIST_SUCCESS_DERIVED, 2);
      expect(lastPage.hasMore).assertFalse();
    });

    it('bookListAuthRequiredIsDetected', 0, () => {
      const err: Error | null = catchError(() => {
        parseBookListJson(SEARCH_AUTH_REQUIRED, 1);
      });
      expect(err instanceof AuthRequiredError).assertTrue();
    });

    it('buildBookListForm_mapsSortAndFinished', 0, () => {
      // 默认：sort=new、finished=''
      const d: Record<string, string> = buildBookListForm(1);
      expect(d['page']).assertEqual('1');
      expect(d['sort']).assertEqual('new');
      expect(d['finished']).assertEqual('');
      // 排序 + 筛选映射
      const v: Record<string, string> = buildBookListForm(3, BOOKLIST_SORT_VIEWS, BOOKLIST_FINISHED_COMPLETED);
      expect(v['page']).assertEqual('3');
      expect(v['sort']).assertEqual('views');
      expect(v['finished']).assertEqual('true');
      // 非法 sort/finished 回退默认值（不把未验证值发给服务端）
      const bad: Record<string, string> = buildBookListForm(1, 'uploaded', 'nonsense');
      expect(bad['sort']).assertEqual('new');
      expect(bad['finished']).assertEqual('');
      // 最高评分 / 连载筛选
      const r: Record<string, string> = buildBookListForm(2, BOOKLIST_SORT_RATING, BOOKLIST_FINISHED_ONGOING);
      expect(r['sort']).assertEqual('rating');
      expect(r['finished']).assertEqual('false');
    });

    // ==================== 详情（Phase 10 预备） ====================

    it('bookDetailParsesChaptersInCategoryOrder', 0, () => {
      const detail: ComicDetail = parseBookDetailJson(BOOK_DETAIL_DERIVED, 'fallback');
      expect(detail.id).assertEqual('900201');
      expect(detail.title).assertEqual('範例作品 C');
      expect(detail.author).assertEqual('範例作者 C');
      expect(detail.description.indexOf('範例簡介') >= 0).assertTrue();
      expect(detail.chapters.length).assertEqual(3);
      // 分类顺序优先，组内按 sort 升序：90010(sort1) → 90011(sort2) → 90012(sort3)
      expect(detail.chapters[0].id).assertEqual('90010');
      expect(detail.chapters[1].id).assertEqual('90011');
      expect(detail.chapters[2].id).assertEqual('90012');
      expect(detail.chapters[0].order).assertEqual(1);
      expect(detail.chapters[2].order).assertEqual(3);
    });

    it('bookDetailAuthRequiredIsDetected', 0, () => {
      const err: Error | null = catchError(() => {
        parseBookDetailJson(BOOK_DETAIL_AUTH_REQUIRED, '900201');
      });
      expect(err instanceof AuthRequiredError).assertTrue();
    });

    it('bookDetailWithoutChaptersDegradesToEmpty', 0, () => {
      const text: string = '{"book":{"info":{"Bid":7,"Bookname":"无章节"}}}';
      const detail: ComicDetail = parseBookDetailJson(text, '7');
      expect(detail.chapters.length).assertEqual(0);
      expect(detail.title).assertEqual('无章节');
    });

    it('bookDetailMissingInfoRejected', 0, () => {
      const err: Error | null = catchError(() => {
        parseBookDetailJson('{"book":{}}', '1');
      });
      expect(err instanceof ProtocolError).assertTrue();
    });

    // ==================== 封面规则 ====================

    it('coverUrlRules', 0, () => {
      expect(buildCoverUrl('123')).assertEqual(`${NOY_IMG_ORIGIN}/123/m1.webp`);
      expect(buildCoverUrl('123', 'http://cdn.example/a.webp'))
        .assertEqual('http://cdn.example/a.webp');
      expect(buildCoverUrl('', 'book')).assertEqual('');
      expect(buildCoverUrl('77', 'stream')).assertEqual(`${NOY_STREAM_ORIGIN}/-77/cover.webp`);
    });

    // ==================== 章节图片（Phase 10） ====================

    it('chapterImagesUsesThisCountNotDataCount', 0, () => {
      // 派生 fixture：chapter.this.count=3，data.count=9 → 只应生成 3 张
      const images: string[] = parseChapterImages(chapterEnvelope(CHAPTER_IMAGES_DERIVED), '900', '12');
      expect(images.length).assertEqual(3);
      expect(images[0]).assertEqual(`${NOY_IMG_ORIGIN}/900/12/1.webp`);
      expect(images[2]).assertEqual(`${NOY_IMG_ORIGIN}/900/12/3.webp`);
    });

    it('chapterImagesFallsBackToDataCount', 0, () => {
      const images: string[] = parseChapterImages(
        { chapter: {}, data: { count: 2 } }, '900', '12');
      expect(images.length).assertEqual(2);
      expect(images[1]).assertEqual(`${NOY_IMG_ORIGIN}/900/12/2.webp`);
    });

    it('chapterImagesZeroCountReturnsEmpty', 0, () => {
      expect(parseChapterImages({ data: { count: 0 } }, '1', '2').length).assertEqual(0);
      expect(parseChapterImages({}, '1', '2').length).assertEqual(0);
    });

    it('chapterImagesRejectsMissingIds', 0, () => {
      const err: Error | null = catchError(() => {
        parseChapterImages({ data: { count: 1 } }, '  ', '2');
      });
      expect(err instanceof ProtocolError).assertTrue();
    });

    it('chapterImagesRejectsEmptyEnvelope', 0, () => {
      const err: Error | null = catchError(() => {
        parseChapterImages(undefined, '1', '2');
      });
      expect(err instanceof ProtocolError).assertTrue();
    });

    it('chapterImagesAuthRequiredIsDetected', 0, () => {
      const err: Error | null = catchError(() => {
        parseChapterImages({ status: 'login' }, '1', '2');
      });
      expect(err instanceof AuthRequiredError).assertTrue();
    });

    it('chapterImagesTrimsIdsAndHandlesBadCount', 0, () => {
      const images: string[] = parseChapterImages(
        { data: { count: Number.NaN } }, ' 900 ', ' 12 ');
      expect(images.length).assertEqual(0); // 非有限页数按 0 处理，不生成脏 URL
    });
  });
}
