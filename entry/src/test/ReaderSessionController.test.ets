/**
 * ReaderSessionController.test.ets —— 阅读器状态机、点击热区、宽屏限宽、章节边界与防抖进度回归测试
 */
import { describe, it, expect, beforeEach } from '@ohos/hypium';
import {
  READER_HUD_BACK_TARGET_VP,
  READER_STRIP_MAX_WIDTH_VP,
  READER_WIDE_BREAKPOINT_VP,
  clampPageIndex,
  clampPageNumber,
  computeReaderHudInsets,
  computeReaderStripWidthVp,
  pageIndexToSliderValue,
  resolveReaderTapAction,
  resolveTapZoneAction,
  sliderValueToPageIndex
} from '../main/ets/reader/ReaderLayout';
import { ComicReaderViewModel } from '../main/ets/viewmodel/ComicReaderViewModel';
import { AuthRequiredError } from '../main/ets/api/ApiErrors';
import { HttpError } from '../main/ets/api/HttpManager';
import { StubDetailSource } from './DetailStubs';
import { ReaderSessionController } from '../main/ets/reader/ReaderSessionController';
import { ReadingProgressStore } from '../main/ets/reader/ReadingProgressStore';
import {
  ReaderChapterItem,
  ReaderHudInsets,
  ReaderMode,
  ReadingProgressSnapshot,
  TapZoneAction
} from '../main/ets/reader/ReaderTypes';
import { InMemoryReadingStore, delay } from './DetailStubs';

export default function readerSessionControllerTest() {
  describe('ReaderLayoutPureFunctions', () => {
    it('tapZoneMapsCorrectlyAcrossAllThreeModes', 0, () => {
      // PAGE_LTR: left=prev, center=hud, right=next
      expect(resolveTapZoneAction(0.15, 0.5, ReaderMode.PAGE_LTR)).assertEqual(TapZoneAction.PREV_PAGE);
      expect(resolveTapZoneAction(0.50, 0.5, ReaderMode.PAGE_LTR)).assertEqual(TapZoneAction.TOGGLE_HUD);
      expect(resolveTapZoneAction(0.85, 0.5, ReaderMode.PAGE_LTR)).assertEqual(TapZoneAction.NEXT_PAGE);

      // PAGE_RTL: left=next, center=hud, right=prev
      expect(resolveTapZoneAction(0.15, 0.5, ReaderMode.PAGE_RTL)).assertEqual(TapZoneAction.NEXT_PAGE);
      expect(resolveTapZoneAction(0.50, 0.5, ReaderMode.PAGE_RTL)).assertEqual(TapZoneAction.TOGGLE_HUD);
      expect(resolveTapZoneAction(0.85, 0.5, ReaderMode.PAGE_RTL)).assertEqual(TapZoneAction.PREV_PAGE);

      // VERTICAL_STRIP: top edge=prev, middle=hud, bottom edge=next
      expect(resolveTapZoneAction(0.5, 0.10, ReaderMode.VERTICAL_STRIP)).assertEqual(TapZoneAction.PREV_PAGE);
      expect(resolveTapZoneAction(0.5, 0.50, ReaderMode.VERTICAL_STRIP)).assertEqual(TapZoneAction.TOGGLE_HUD);
      expect(resolveTapZoneAction(0.5, 0.90, ReaderMode.VERTICAL_STRIP)).assertEqual(TapZoneAction.NEXT_PAGE);
    });

    it('adaptiveTapZonesRespectDoubleTapSetting', 0, () => {
      // doubleTapZoomEnabled = true: VERTICAL_STRIP center band y in [0.30H, 0.70H], x in [0, W]
      expect(resolveReaderTapAction(18, 270, 360, 1000, ReaderMode.VERTICAL_STRIP, true))
        .assertEqual(TapZoneAction.PREV_PAGE);
      expect(resolveReaderTapAction(20, 500, 360, 1000, ReaderMode.VERTICAL_STRIP, true))
        .assertEqual(TapZoneAction.TOGGLE_HUD);
      expect(resolveReaderTapAction(180, 500, 360, 1000, ReaderMode.VERTICAL_STRIP, true))
        .assertEqual(TapZoneAction.TOGGLE_HUD);
      expect(resolveReaderTapAction(340, 500, 360, 1000, ReaderMode.VERTICAL_STRIP, true))
        .assertEqual(TapZoneAction.TOGGLE_HUD);
      expect(resolveReaderTapAction(18, 320, 360, 1000, ReaderMode.VERTICAL_STRIP, true))
        .assertEqual(TapZoneAction.TOGGLE_HUD);
      expect(resolveReaderTapAction(342, 680, 360, 1000, ReaderMode.VERTICAL_STRIP, true))
        .assertEqual(TapZoneAction.TOGGLE_HUD);
      expect(resolveReaderTapAction(180, 720, 360, 1000, ReaderMode.VERTICAL_STRIP, true))
        .assertEqual(TapZoneAction.NEXT_PAGE);

      // doubleTapZoomEnabled = false: VERTICAL_STRIP legacy [0.25H, 0.75H] band
      expect(resolveReaderTapAction(18, 270, 360, 1000, ReaderMode.VERTICAL_STRIP, false))
        .assertEqual(TapZoneAction.TOGGLE_HUD);
      expect(resolveReaderTapAction(18, 230, 360, 1000, ReaderMode.VERTICAL_STRIP, false))
        .assertEqual(TapZoneAction.PREV_PAGE);
      expect(resolveReaderTapAction(180, 760, 360, 1000, ReaderMode.VERTICAL_STRIP, false))
        .assertEqual(TapZoneAction.NEXT_PAGE);

      // Horizontal modes: center full-height band x in [0.30W, 0.70W], y in [0, H]
      expect(resolveReaderTapAction(180, 50, 400, 1000, ReaderMode.PAGE_LTR, true))
        .assertEqual(TapZoneAction.TOGGLE_HUD);
      expect(resolveReaderTapAction(180, 950, 400, 1000, ReaderMode.PAGE_LTR, true))
        .assertEqual(TapZoneAction.TOGGLE_HUD);
      expect(resolveReaderTapAction(80, 500, 400, 1000, ReaderMode.PAGE_LTR, true))
        .assertEqual(TapZoneAction.PREV_PAGE);
      expect(resolveReaderTapAction(320, 500, 400, 1000, ReaderMode.PAGE_LTR, true))
        .assertEqual(TapZoneAction.NEXT_PAGE);
      expect(resolveReaderTapAction(80, 500, 400, 1000, ReaderMode.PAGE_RTL, true))
        .assertEqual(TapZoneAction.NEXT_PAGE);
      expect(resolveReaderTapAction(320, 500, 400, 1000, ReaderMode.PAGE_RTL, true))
        .assertEqual(TapZoneAction.PREV_PAGE);
    });

    it('pageClampingAndWideStripWidthAndHudInsets', 0, () => {
      expect(READER_WIDE_BREAKPOINT_VP).assertEqual(600);
      expect(READER_STRIP_MAX_WIDTH_VP).assertEqual(760);
      expect(READER_HUD_BACK_TARGET_VP).assertEqual(44);

      expect(clampPageIndex(-3, 10)).assertEqual(0);
      expect(clampPageIndex(0, 10)).assertEqual(0);
      expect(clampPageIndex(9, 10)).assertEqual(9);
      expect(clampPageIndex(25, 10)).assertEqual(9);
      expect(clampPageIndex(3, 0)).assertEqual(0);
      expect(clampPageNumber(0, 10)).assertEqual(1);
      expect(clampPageNumber(15, 10)).assertEqual(10);

      expect(computeReaderStripWidthVp(360)).assertEqual(360);
      expect(computeReaderStripWidthVp(599)).assertEqual(599);
      expect(computeReaderStripWidthVp(600)).assertEqual(600);
      expect(computeReaderStripWidthVp(760)).assertEqual(760);
      expect(computeReaderStripWidthVp(1280)).assertEqual(760);
      expect(computeReaderStripWidthVp(0)).assertEqual(0);

      const insets: ReaderHudInsets = computeReaderHudInsets(36, 28);
      expect(insets.topVp).assertEqual(36);
      expect(insets.bottomVp).assertEqual(28);
      const safeNegative: ReaderHudInsets = computeReaderHudInsets(-10, Number.NaN);
      expect(safeNegative.topVp).assertEqual(0);
      expect(safeNegative.bottomVp).assertEqual(0);

      // Slider 双向映射（totalPages = 0 / 1 / N）
      expect(sliderValueToPageIndex(5, 0)).assertEqual(0);
      expect(sliderValueToPageIndex(3, 1)).assertEqual(0);
      expect(sliderValueToPageIndex(1, 20)).assertEqual(0);
      expect(sliderValueToPageIndex(20, 20)).assertEqual(19);
      expect(sliderValueToPageIndex(99, 20)).assertEqual(19);
      expect(pageIndexToSliderValue(0, 0)).assertEqual(1);
      expect(pageIndexToSliderValue(0, 1)).assertEqual(1);
      expect(pageIndexToSliderValue(19, 20)).assertEqual(20);
      expect(pageIndexToSliderValue(99, 20)).assertEqual(20);
    });
  });

  describe('ReaderSessionControllerState', () => {
    let session: ReaderSessionController = new ReaderSessionController();

    beforeEach(() => {
      session = new ReaderSessionController();
      session.setChapters([
        new ReaderChapterItem('c1', '第 1 话', 1),
        new ReaderChapterItem('c2', '第 2 话', 2),
        new ReaderChapterItem('c3', '第 3 话', 3)
      ], 'c2');
      session.syncPages(12, 3);
    });

    it('modeCycleAndTapActionsUpdateState', 0, () => {
      expect(session.mode).assertEqual(ReaderMode.PAGE_LTR);
      expect(session.cycleMode()).assertEqual(ReaderMode.PAGE_RTL);
      expect(session.cycleMode()).assertEqual(ReaderMode.VERTICAL_STRIP);
      expect(session.cycleMode()).assertEqual(ReaderMode.PAGE_LTR);

      session.setMode(ReaderMode.PAGE_RTL);
      expect(session.currentPageIndex).assertEqual(2);
      expect(session.handleTap(0.5, 0.5)).assertEqual(TapZoneAction.TOGGLE_HUD);
      expect(session.isHudVisible).assertTrue();
      expect(session.handleTap(0.1, 0.5)).assertEqual(TapZoneAction.NEXT_PAGE);
      expect(session.currentPageIndex).assertEqual(3);
      expect(session.handleTap(0.9, 0.5)).assertEqual(TapZoneAction.PREV_PAGE);
      expect(session.currentPageIndex).assertEqual(2);
    });

    it('sliderJumpAndChapterBoundaries', 0, () => {
      expect(session.goToPageNumber(999)).assertEqual(11);
      expect(session.currentPageNumber).assertEqual(12);
      expect(session.nextPage()).assertFalse();

      expect(session.goToPage(0)).assertEqual(0);
      expect(session.prevPage()).assertFalse();

      expect(session.hasPrevChapter()).assertTrue();
      expect(session.hasNextChapter()).assertTrue();

      const prevCh: ReaderChapterItem | null = session.prevChapter();
      expect(prevCh !== null && prevCh.id === 'c1').assertTrue();
      expect(session.hasPrevChapter()).assertFalse();
      expect(session.prevChapter() === null).assertTrue();
      expect(session.boundaryNotice).assertEqual('已是第一章');

      const lastCh: ReaderChapterItem | null = session.selectChapter('c3');
      expect(lastCh !== null && lastCh.id === 'c3').assertTrue();
      expect(session.hasNextChapter()).assertFalse();
      expect(session.nextChapter() === null).assertTrue();
      expect(session.boundaryNotice).assertEqual('已是最后一章');
    });
  });

  describe('ReadingProgressStorePersistence', () => {
    it('debouncedSaveFlushAndRestoreOnReentry', 0, async () => {
      const memStore: InMemoryReadingStore = new InMemoryReadingStore();
      const progressStore: ReadingProgressStore = new ReadingProgressStore(memStore, 30);
      expect(progressStore.hasSavedMode('new_comic')).assertFalse();
      expect(progressStore.getMode('new_comic')).assertEqual(ReaderMode.PAGE_LTR);

      progressStore.scheduleSave(
        new ReadingProgressSnapshot('b1', 'c1', '第 1 话', 4, 20, ReaderMode.PAGE_RTL, 1000)
      );
      progressStore.scheduleSave(
        new ReadingProgressSnapshot('b1', 'c1', '第 1 话', 7, 20, ReaderMode.PAGE_RTL, 1010)
      );
      expect(memStore.saveCalls).assertEqual(0);
      expect(progressStore.hasPendingSave()).assertTrue();

      await delay(60);
      expect(memStore.saveCalls).assertEqual(1);
      expect(progressStore.hasPendingSave()).assertFalse();
      expect(progressStore.getMode('b1')).assertEqual(ReaderMode.PAGE_RTL);

      const restored: number = await progressStore.loadChapterPage('b1', 'c1', 1);
      expect(restored).assertEqual(7);

      // Immediate flush before exit
      progressStore.scheduleSave(
        new ReadingProgressSnapshot('b1', 'c2', '第 2 话', 11, 25, ReaderMode.VERTICAL_STRIP, 2000)
      );
      const flushed: boolean = await progressStore.flushSave();
      expect(flushed).assertTrue();
      expect(memStore.saveCalls).assertEqual(2);
      expect(await progressStore.loadChapterPage('b1', 'c2', 1)).assertEqual(11);
    });

    it('readerViewModelHandlesSingleBookEmptyErrorAndRetry', 0, async () => {
      class StubReaderSource extends StubDetailSource {
        images: string[] = [];
        imgError: HttpError | null = null;

        async getChapterImages(_bookId: string, _chapterId: string): Promise<string[]> {
          if (this.imgError !== null) {
            throw this.imgError;
          }
          return this.images;
        }
      }

      const src: StubReaderSource = new StubReaderSource();
      const store: InMemoryReadingStore = new InMemoryReadingStore();
      const vm: ComicReaderViewModel = new ComicReaderViewModel(src, store);

      // AUTH_REQUIRED
      src.imgError = new AuthRequiredError('need login');
      await vm.loadChapter('900302', '0', 1, true);
      expect(vm.needsLogin).assertTrue();
      expect(vm.totalCount).assertEqual(0);

      // ERROR -> retry -> EMPTY -> retry -> SUCCESS (cid='0' 单本)
      src.imgError = new HttpError(503, 'network error');
      await vm.loadChapter('900302', '0', 1, true);
      expect(vm.needsLogin).assertFalse();
      expect(vm.errorMessage !== '').assertTrue();

      src.imgError = null;
      src.images = [];
      await vm.loadChapter('900302', '0', 1, true);
      expect(vm.errorMessage).assertEqual('');
      expect(vm.totalCount).assertEqual(0);

      src.images = ['https://img.example/1.webp', 'https://img.example/2.webp'];
      await vm.loadChapter('900302', '0', 2, true);
      expect(vm.totalCount).assertEqual(2);
      expect(vm.currentPage).assertEqual(2);
    });
  });
}
