/**
 * ComicDetailLayout.test.ets —— ComicDetail 响应式双栏布局、正倒序目录、状态机与评论分页回归测试
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import {
  DETAIL_CHAPTER_TOUCH_TARGET_VP,
  DETAIL_LEFT_PANE_WIDTH,
  DETAIL_RIGHT_PANE_WIDTH,
  DETAIL_WIDE_BREAKPOINT_VP,
  DETAIL_WIDE_COVER_HEIGHT_VP,
  DETAIL_WIDE_COVER_WIDTH_VP,
  RECOMMEND_CARD_WIDTH_VP,
  RECOMMEND_COVER_HEIGHT_VP,
  RECOMMEND_TITLE_GAP_VP,
  detailBottomInsetVp,
  detailChapterColumns,
  detailUseTwoPane,
  recommendCoverHeightVp,
  resolveDetailScaffoldMode
} from '../main/ets/utils/ComicDetailLayout';
import { ComicDetailViewModel, DetailState } from '../main/ets/viewmodel/ComicDetailViewModel';
import { ChapterRow, ChapterRowKind } from '../main/ets/model/ChapterRow';
import { BookComment, CommentPage } from '../main/ets/model/BookComment';
import { parseBookDetailJson } from '../main/ets/source/NoyAcgProtocol';
import { AuthRequiredError, ProtocolError } from '../main/ets/api/ApiErrors';
import { HttpError } from '../main/ets/api/HttpManager';
import { BOOK_DETAIL_FULL_DERIVED, BOOK_DETAIL_MINIMAL_DERIVED,
  BOOK_DETAIL_SINGLE_DERIVED } from './fixtures/FixtureData';
import { InMemoryReadingStore, StubAccountFavPort, StubDetailSource } from './DetailStubs';

function collectChapterIdsFromRows(vm: ComicDetailViewModel): string[] {
  const ids: string[] = [];
  const total: number = vm.chapterRows.totalCount();
  for (let i = 0; i < total; i++) {
    const row: ChapterRow = vm.chapterRows.getData(i) as ChapterRow;
    if (row.kind === ChapterRowKind.CHAPTER && row.chapter !== null) {
      ids.push(row.chapter.id);
    }
  }
  return ids;
}

function makeBookComment(cid: string, uid: string, username: string, content: string): BookComment {
  const c: BookComment = new BookComment();
  c.cid = cid;
  c.uid = uid;
  c.username = username;
  c.content = content;
  c.area = 'JP';
  c.time = '2026-01-01';
  c.isOfficial = false;
  return c;
}

class PaginatedCommentStubSource extends StubDetailSource {
  commentsPage: CommentPage = new CommentPage([], 1, true);
  commentsError: HttpError | null = null;

  override async getBookComments(_bookId: string, _page: number): Promise<CommentPage> {
    if (this.commentsError !== null) {
      throw this.commentsError;
    }
    return this.commentsPage;
  }
}

export default function comicDetailLayoutTest() {
  describe('ComicDetailLayout', () => {
    it('detailUseTwoPaneRespects600vpBreakpointAndInvalidInputs', 0, () => {
      expect(DETAIL_WIDE_BREAKPOINT_VP).assertEqual(600);
      expect(DETAIL_CHAPTER_TOUCH_TARGET_VP).assertEqual(44);
      expect(detailUseTwoPane(0)).assertFalse();
      expect(detailUseTwoPane(-120)).assertFalse();
      expect(detailUseTwoPane(Number.NaN)).assertFalse();
      expect(detailUseTwoPane(599)).assertFalse();
      expect(detailUseTwoPane(600)).assertTrue();
      expect(detailUseTwoPane(840)).assertTrue();
      expect(detailUseTwoPane(1280)).assertTrue();
    });

    it('detailUseTwoPaneRequiresTrueLandscapeAspectRatioAndWidth', 0, () => {
      // 竖屏宽屏（如折叠屏展开竖屏 700x900 / 平板竖屏 800x1024）或方形窗口一律单栏
      expect(detailUseTwoPane(700, 900)).assertFalse();
      expect(detailUseTwoPane(800, 1024)).assertFalse();
      expect(detailUseTwoPane(700, 700)).assertFalse();
      // 窄屏横屏（width < 600）一律单栏
      expect(detailUseTwoPane(560, 360)).assertFalse();
      // 真横屏宽屏（width > height && width >= 600）启用双栏（42% / 58%）
      expect(detailUseTwoPane(960, 600)).assertTrue();
      expect(detailUseTwoPane(844, 390)).assertTrue();
      expect(detailUseTwoPane(1280, 800)).assertTrue();
      expect(detailUseTwoPane(960, 0)).assertFalse();
      expect(detailUseTwoPane(960, Number.NaN)).assertFalse();
      expect(DETAIL_LEFT_PANE_WIDTH).assertEqual('42%');
      expect(DETAIL_RIGHT_PANE_WIDTH).assertEqual('58%');
    });

    it('detailChapterColumnsAndBottomInset', 0, () => {
      expect(detailChapterColumns(360)).assertEqual(1);
      expect(detailChapterColumns(479)).assertEqual(1);
      expect(detailChapterColumns(480)).assertEqual(2);
      expect(detailChapterColumns(720)).assertEqual(2);
      expect(detailBottomInsetVp(0)).assertEqual(16);
      expect(detailBottomInsetVp(-10)).assertEqual(16);
      expect(detailBottomInsetVp(28)).assertEqual(44);
    });

    it('resolveDetailScaffoldModeMapsAllStates', 0, () => {
      expect(resolveDetailScaffoldMode('idle')).assertEqual('loading');
      expect(resolveDetailScaffoldMode('loading')).assertEqual('loading');
      expect(resolveDetailScaffoldMode('auth_required')).assertEqual('auth_required');
      expect(resolveDetailScaffoldMode('error')).assertEqual('error');
      expect(resolveDetailScaffoldMode('empty')).assertEqual('empty');
      expect(resolveDetailScaffoldMode('success')).assertEqual('ready');
    });

    it('recommendCardAndWideHeaderCoverDimensionsStayBounded', 0, () => {
      expect(RECOMMEND_CARD_WIDTH_VP).assertEqual(108);
      expect(RECOMMEND_COVER_HEIGHT_VP).assertEqual(154);
      expect(RECOMMEND_TITLE_GAP_VP).assertEqual(5);
      expect(recommendCoverHeightVp(108, 0.7)).assertEqual(154);
      expect(recommendCoverHeightVp(0, 0.7)).assertEqual(RECOMMEND_COVER_HEIGHT_VP);
      expect(DETAIL_WIDE_COVER_WIDTH_VP).assertEqual(168);
      expect(DETAIL_WIDE_COVER_HEIGHT_VP >= 220 && DETAIL_WIDE_COVER_HEIGHT_VP <= 260).assertTrue();
    });
  });

  describe('ComicDetailViewModelModular', () => {
    let source: PaginatedCommentStubSource = new PaginatedCommentStubSource();
    let store: InMemoryReadingStore = new InMemoryReadingStore();
    let favPort: StubAccountFavPort = new StubAccountFavPort();
    let vm: ComicDetailViewModel = new ComicDetailViewModel(source, store);

    beforeEach(() => {
      source = new PaginatedCommentStubSource();
      store = new InMemoryReadingStore();
      favPort = new StubAccountFavPort();
      vm = new ComicDetailViewModel(source, store, undefined, favPort);
      source.detail = parseBookDetailJson(BOOK_DETAIL_FULL_DERIVED, '900201');
    });

    it('toggleChapterOrderReversesRowsWithoutMutatingModel', 0, async () => {
      await vm.loadDetail('900201');
      expect(vm.state).assertEqual(DetailState.SUCCESS);
      expect(vm.isChapterReversed).assertFalse();

      const originalModelIds: string[] = [];
      if (vm.detail !== null) {
        for (let i = 0; i < vm.detail.chapters.length; i++) {
          originalModelIds.push(vm.detail.chapters[i].id);
        }
      }
      if (vm.detail !== null && vm.detail.groups.length > 0) {
        vm.toggleGroup(vm.detail.groups[0].id);
      }
      const ascRowIds: string[] = collectChapterIdsFromRows(vm);
      expect(ascRowIds.length > 1).assertTrue();
      const firstGroupCount: number = vm.detail !== null && vm.detail.groups.length > 0
        ? vm.detail.groups[0].chapters.length : ascRowIds.length;
      expect(firstGroupCount > 1).assertTrue();

      vm.toggleChapterOrder();
      expect(vm.isChapterReversed).assertTrue();
      const descRowIds: string[] = collectChapterIdsFromRows(vm);
      expect(descRowIds.length).assertEqual(ascRowIds.length);
      expect(descRowIds[0]).assertEqual(ascRowIds[firstGroupCount - 1]);
      expect(descRowIds[firstGroupCount - 1]).assertEqual(ascRowIds[0]);

      if (vm.detail !== null) {
        for (let i = 0; i < vm.detail.chapters.length; i++) {
          expect(vm.detail.chapters[i].id).assertEqual(originalModelIds[i]);
        }
      }

      vm.toggleChapterOrder();
      expect(vm.isChapterReversed).assertFalse();
      const restoredIds: string[] = collectChapterIdsFromRows(vm);
      expect(restoredIds[0]).assertEqual(ascRowIds[0]);
    });

    it('stateTransitionsAndFavoriteToggleSync', 0, async () => {
      source.error = new AuthRequiredError('need login');
      await vm.loadDetail('900201');
      expect(vm.state).assertEqual(DetailState.AUTH_REQUIRED);

      source.error = new HttpError(503, 'network down');
      await vm.retry();
      expect(vm.state).assertEqual(DetailState.ERROR);

      source.error = null;
      source.detail = parseBookDetailJson(BOOK_DETAIL_MINIMAL_DERIVED, '900201');
      await vm.retry();
      expect(vm.state).assertEqual(DetailState.EMPTY);

      source.detail = parseBookDetailJson(BOOK_DETAIL_FULL_DERIVED, '900201');
      await vm.loadDetail('900201-fresh');
      expect(vm.state).assertEqual(DetailState.SUCCESS);

      const beforeFav: boolean = vm.isFavorite;
      if (!beforeFav) {
        favPort.favoriteIds.push('900201');
      }
      await vm.toggleFavorite();
      expect(vm.isFavorite).assertEqual(!beforeFav);

      favPort.toggleError = new ProtocolError('toggle failed');
      await vm.toggleFavorite();
      expect(vm.isFavorite).assertEqual(!beforeFav);
    });

    it('commentPaginationAppendsAndHandlesLoadMoreError', 0, async () => {
      await vm.loadDetail('900201');
      source.commentsPage = new CommentPage([
        makeBookComment('1', '101', 'readerA', 'nice')
      ], 1, false);
      await vm.loadComments(false);
      expect(vm.comments.length).assertEqual(1);
      expect(vm.commentHasMore).assertTrue();

      source.commentsError = new HttpError(504, 'timeout');
      await vm.loadComments(true);
      expect(vm.comments.length).assertEqual(1);
      expect(vm.commentError !== '').assertTrue();

      source.commentsError = null;
      source.commentsPage = new CommentPage([
        makeBookComment('2', '102', 'readerB', 'great')
      ], 2, true);
      await vm.loadComments(true);
      expect(vm.comments.length).assertEqual(2);
      expect(vm.commentHasMore).assertFalse();
    });

    it('singleBookNormalizesDisplayChapterCountToOneInsteadOfZero', 0, async () => {
      source.detail = parseBookDetailJson(BOOK_DETAIL_SINGLE_DERIVED, '900302');
      await vm.loadDetail('900302');
      expect(vm.state).assertEqual(DetailState.SUCCESS);
      expect(vm.displayChapterCount).assertEqual(1);
      expect(vm.displayGroupCount).assertEqual(1);
      expect(vm.chapterRows.totalCount()).assertEqual(2);
      const itemRow: ChapterRow = vm.chapterRows.getData(1) as ChapterRow;
      expect(itemRow.kind).assertEqual(ChapterRowKind.CHAPTER);
      expect(itemRow.chapter !== null && itemRow.chapter.id === '0').assertTrue();
    });
  });
}
