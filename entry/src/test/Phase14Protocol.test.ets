/**
 * Phase14Protocol.test.ets —— Phase 14-I 首页聚合 / 广告 / 推荐 / 评论 解析测试
 *
 * 全部样例都是 `*.derived.json` 派生的**非抓包**数据（auth-required 镜像已证实的未登录形态），
 * 见 fixtures/README.md。本套件验证「拿到响应体之后」的映射、安全校验与异常分支，
 * 不联网、不依赖设备，也不声称验证了登录后的真实接口响应。
 *
 * 覆盖：
 * - 首页聚合（bulletin / favDay / readDay / fs / proportion / stream / tags）与 stream 缺失降级；
 * - 广告 img/url 的 http/https 白名单校验与空数据；
 * - 评论分页 over/cid/官方置顶(uid=0)/楼中楼 replies；
 * - 详情推荐 book.recommend（缺 bid 丢弃）、comment、points、F 收藏标记；
 * - Status 0/1 → 连载/完结 的整数语义映射。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  NOY_IMG_ORIGIN,
  NOY_STREAM_ORIGIN,
  mapCompletionStatus,
  parseAds,
  parseAdsJson,
  parseBookDetailJson,
  parseCommentPage,
  parseCommentPageJson,
  parseHomeFeed,
  parseHomeFeedJson
} from '../main/ets/source/NoyAcgProtocol';
import { HomeFeed } from '../main/ets/model/HomeFeed';
import { AdItem } from '../main/ets/model/AdItem';
import { CommentPage } from '../main/ets/model/BookComment';
import { ComicDetail } from '../main/ets/model/ComicDetail';
import { AuthRequiredError, ProtocolError } from '../main/ets/api/ApiErrors';
import {
  ADS_EMPTY_DERIVED,
  ADS_SUCCESS_DERIVED,
  BOOK_COMMENTS_AUTH_REQUIRED,
  BOOK_COMMENTS_SUCCESS_DERIVED,
  BOOK_DETAIL_FULL_DERIVED,
  HOME_NO_STREAM_DERIVED,
  HOME_SUCCESS_DERIVED,
  HOME_WITH_STREAM_DERIVED
} from './fixtures/FixtureData';

function catchError(fn: () => void): Error | null {
  try {
    fn();
    return null;
  } catch (e) {
    return e as Error;
  }
}

export default function phase14ProtocolTest() {
  describe('Phase14Protocol', () => {
    // ==================== 首页聚合（POST /api/home） ====================

    it('homeFeedMapsBulletinRanksAndTags', 0, () => {
      const feed: HomeFeed = parseHomeFeedJson(HOME_SUCCESS_DERIVED);
      // 公告
      expect(feed.bulletin.text).assertEqual('系統維護公告（範例，非真實資料）');
      expect(feed.bulletin.show).assertTrue();
      // 日收藏榜：帕斯卡字段 + Ptag 空格分隔
      expect(feed.favDay.length).assertEqual(2);
      expect(feed.favDay[0].id).assertEqual('900401');
      expect(feed.favDay[0].title).assertEqual('日收藏範例 A');
      expect(feed.favDay[0].author).assertEqual('範例作者 A');
      expect(feed.favDay[0].categories).assertEqual('標籤甲 標籤乙 其他標籤');
      expect(feed.favDay[0].ratingSum).assertEqual(86);
      expect(feed.favDay[0].views).assertEqual(100);
      expect(feed.favDay[0].favorites).assertEqual(50);
      expect(feed.favDay[0].publishYear).assertEqual('2023');
      expect(feed.favDay[0].pageCount).assertEqual(20);
      expect(feed.favDay[0].description).assertEqual('用於首頁聚合解析測試的範例條目（非真實資料）');
      // Status=1 → 已完结
      expect(feed.favDay[0].isCompleted === true).assertTrue();
      // 第二个条目缺字段：保持默认值，不伪造
      expect(feed.favDay[1].id).assertEqual('900406');
      expect(feed.favDay[1].isCompleted === null).assertTrue();
      // 日阅读榜 / 推荐位 / 高质推荐
      expect(feed.readDay.length).assertEqual(1);
      expect(feed.readDay[0].id).assertEqual('900402');
      expect(feed.fs.length).assertEqual(1);
      expect(feed.fs[0].id).assertEqual('900403');
      // Status=0 → 连载中
      expect(feed.fs[0].isCompleted === false).assertTrue();
      expect(feed.proportion.length).assertEqual(2);
      expect(feed.proportion[1].id).assertEqual('900405');
      // 无 stream → 空数组
      expect(feed.stream.length).assertEqual(0);
      // tags：空格分隔字符串 → 数组
      expect(feed.tags.length).assertEqual(3);
      expect(feed.tags[0]).assertEqual('冒險');
      expect(feed.tags[2]).assertEqual('戀愛');
    });

    it('homeFeedMapsStreamItemsWithLowercaseFields', 0, () => {
      const feed: HomeFeed = parseHomeFeedJson(HOME_WITH_STREAM_DERIVED);
      expect(feed.stream.length).assertEqual(2);
      const first = feed.stream[0];
      expect(first.id).assertEqual('501');
      expect(first.title).assertEqual('動畫範例 A');
      expect(first.description).assertEqual('動畫劇情簡介（範例，非真實資料）');
      expect(first.tags).assertEqual('動作,冒險');
      expect(first.cover).assertEqual(`${NOY_STREAM_ORIGIN}/501/cover.webp`);
      expect(first.views).assertEqual(999);
      expect(first.favorites).assertEqual(88);
      expect(first.count).assertEqual(12);
      expect(first.favorited).assertTrue();
      expect(first.updatedAt).assertEqual('2025-01-01');
      // 最小字段条目
      const second = feed.stream[1];
      expect(second.id).assertEqual('502');
      expect(second.title).assertEqual('動畫範例 B');
      expect(second.views).assertEqual(0);
      expect(second.favorited).assertFalse();
      expect(second.updatedAt).assertEqual('');
      // tags 数组形态
      expect(feed.tags.length).assertEqual(2);
      expect(feed.tags[1]).assertEqual('熱血');
    });

    it('homeFeedMissingAllSectionsDegradesToEmpty', 0, () => {
      const feed: HomeFeed = parseHomeFeedJson(HOME_NO_STREAM_DERIVED);
      expect(feed.bulletin.text).assertEqual('');
      expect(feed.bulletin.show).assertFalse();
      expect(feed.favDay.length).assertEqual(0);
      expect(feed.readDay.length).assertEqual(0);
      expect(feed.fs.length).assertEqual(0);
      expect(feed.proportion.length).assertEqual(0);
      expect(feed.stream.length).assertEqual(0);
      expect(feed.tags.length).assertEqual(0);
    });

    it('homeFeedAuthRequiredIsDetected', 0, () => {
      const err: Error | null = catchError(() => {
        parseHomeFeedJson('{"status":"login"}');
      });
      expect(err instanceof AuthRequiredError).assertTrue();
    });

    it('homeFeedBusinessErrorRejected', 0, () => {
      const err: Error | null = catchError(() => {
        parseHomeFeedJson('{"status":"error"}');
      });
      expect(err instanceof ProtocolError).assertTrue();
      expect(err instanceof AuthRequiredError).assertFalse();
    });

    it('homeFeedNonJsonRejected', 0, () => {
      const err: Error | null = catchError(() => {
        parseHomeFeedJson('<html>gateway</html>');
      });
      expect(err instanceof ProtocolError).assertTrue();
    });

    it('homeFeedEmptyEnvelopeRejected', 0, () => {
      const err: Error | null = catchError(() => {
        parseHomeFeed(undefined);
      });
      expect(err instanceof ProtocolError).assertTrue();
    });

    // ==================== 首页广告（POST /api/v3/ads） ====================

    it('adsKeepOnlyHttpAndHttps', 0, () => {
      const ads: AdItem[] = parseAdsJson(ADS_SUCCESS_DERIVED);
      // 4 条原始数据：https 全字段保留、javascript: 被置空、ftp 全无效被丢弃、空 img 保留 url
      expect(ads.length).assertEqual(3);
      expect(ads[0].image).assertEqual('https://img.noymanga.com/ads/1.webp');
      expect(ads[0].url).assertEqual('https://example.com/promo/1');
      expect(ads[1].image).assertEqual('http://cdn.example.com/ads/2.webp');
      expect(ads[1].url).assertEqual('');
      expect(ads[2].image).assertEqual('');
      expect(ads[2].url).assertEqual('https://example.com/noimg');
    });

    it('adsEmptyDataReturnsEmptyList', 0, () => {
      expect(parseAdsJson(ADS_EMPTY_DERIVED).length).assertEqual(0);
      // data 字段整体缺失 → 空列表（支持空数据，不 Mock）
      expect(parseAds({ status: 'ok' }).length).assertEqual(0);
    });

    it('adsAuthRequiredIsDetected', 0, () => {
      const err: Error | null = catchError(() => {
        parseAdsJson('{"status":"login"}');
      });
      expect(err instanceof AuthRequiredError).assertTrue();
    });

    it('adsDataNotArrayRejected', 0, () => {
      const err: Error | null = catchError(() => {
        parseAdsJson('{"status":"ok","data":{"a":1}}');
      });
      expect(err instanceof ProtocolError).assertTrue();
    });

    // ==================== 书籍评论分页 ====================

    it('commentPageMapsCidOfficialPinnedAndReplies', 0, () => {
      const page: CommentPage = parseCommentPageJson(BOOK_COMMENTS_SUCCESS_DERIVED, 1);
      expect(page.page).assertEqual(1);
      expect(page.over).assertFalse();
      expect(page.hasMore).assertTrue();
      expect(page.comments.length).assertEqual(2);
      // 官方置顶：uid=0
      const pinned = page.comments[0];
      expect(pinned.cid).assertEqual('1001');
      expect(pinned.isOfficial).assertTrue();
      expect(pinned.area).assertEqual('官方公告');
      expect(pinned.time).assertEqual('2025-01-01');
      // 用户评论 + 楼中楼
      const user = page.comments[1];
      expect(user.cid).assertEqual('1002');
      expect(user.uid).assertEqual('900007');
      expect(user.isOfficial).assertFalse();
      expect(user.replyCount).assertEqual(2);
      expect(user.hasMoreReplies).assertTrue();
      expect(user.replies.length).assertEqual(1);
      expect(user.replies[0].cid).assertEqual('2001');
      expect(user.replies[0].username).assertEqual('讀者乙');
    });

    it('commentPageOverIsOnlyHasMoreSignal', 0, () => {
      // over=true → hasMore=false；不按条数推断
      const page: CommentPage = parseCommentPage(
        { status: 'ok', data: { comments: [], page: 3, over: true } }, 3);
      expect(page.over).assertTrue();
      expect(page.hasMore).assertFalse();
    });

    it('commentPageAuthRequiredIsDetected', 0, () => {
      const err: Error | null = catchError(() => {
        parseCommentPageJson(BOOK_COMMENTS_AUTH_REQUIRED, 1);
      });
      expect(err instanceof AuthRequiredError).assertTrue();
    });

    it('commentPageMissingCommentsRejected', 0, () => {
      const err: Error | null = catchError(() => {
        parseCommentPage({ status: 'ok', data: {} }, 1);
      });
      expect(err instanceof ProtocolError).assertTrue();
    });

    // ==================== 详情：推荐 / 评论 / 积分 / 收藏标记 ====================

    it('detailMapsRecommendCommentPointsAndFavorited', 0, () => {
      const detail: ComicDetail = parseBookDetailJson(BOOK_DETAIL_FULL_DERIVED, 'fallback');
      // 相关推荐：缺 bid 的条目被丢弃
      expect(detail.recommend.length).assertEqual(2);
      expect(detail.recommend[0].bid).assertEqual('900501');
      expect(detail.recommend[0].title).assertEqual('推薦範例 A');
      expect(detail.recommend[0].author).assertEqual('推薦作者 A');
      expect(detail.recommend[0].tags).assertEqual('熱血 冒險');
      expect(detail.recommend[0].cover).assertEqual(`${NOY_IMG_ORIGIN}/900501/m1.webp`);
      expect(detail.recommend[0].views).assertEqual(120);
      expect(detail.recommend[0].favorites).assertEqual(30);
      expect(detail.recommend[1].bid).assertEqual('900502');
      expect(detail.recommend[1].views).assertEqual(0);
      // 首屏评论：count 不含官方置顶，但 data 包含官方置顶
      expect(detail.commentCount).assertEqual(2);
      expect(detail.comments.length).assertEqual(2);
      expect(detail.comments[0].isOfficial).assertTrue();
      expect(detail.comments[0].cid).assertEqual('3001');
      expect(detail.comments[1].cid).assertEqual('3002');
      expect(detail.comments[1].replies.length).assertEqual(1);
      expect(detail.comments[1].replies[0].cid).assertEqual('3101');
      // 积分
      expect(detail.bookPrice).assertEqual('0');
      expect(detail.userBalance).assertEqual('100.5');
      // F=false → 未收藏
      expect(detail.favorited === false).assertTrue();
    });

    it('detailWithoutRecommendCommentPointsDegradesToEmpty', 0, () => {
      const detail: ComicDetail = parseBookDetailJson('{"book":{"info":{"Bid":7,"Bookname":"无章节"}}}', '7');
      expect(detail.recommend.length).assertEqual(0);
      expect(detail.comments.length).assertEqual(0);
      expect(detail.commentCount).assertEqual(0);
      expect(detail.bookPrice).assertEqual('');
      expect(detail.userBalance).assertEqual('');
      expect(detail.favorited === null).assertTrue();
    });

    // ==================== 字段语义修正 ====================

    it('mapCompletionStatusIntegerSemantics', 0, () => {
      expect(mapCompletionStatus(0) === false).assertTrue();
      expect(mapCompletionStatus(1) === true).assertTrue();
      expect(mapCompletionStatus('0') === false).assertTrue();
      expect(mapCompletionStatus('1') === true).assertTrue();
      expect(mapCompletionStatus(false) === false).assertTrue();
      expect(mapCompletionStatus(true) === true).assertTrue();
      // 未知值 → null（不编造连载/完结）
      expect(mapCompletionStatus(2) === null).assertTrue();
      expect(mapCompletionStatus('ongoing') === null).assertTrue();
      expect(mapCompletionStatus('finished') === null).assertTrue();
      expect(mapCompletionStatus(undefined) === null).assertTrue();
    });
  });
}
