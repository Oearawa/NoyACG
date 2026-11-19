import { HdsNavDestination } from '@kit.UIDesignKit';
/**
 * ComicReader.ets —— 核心漫画阅读器（Stage / 状态管理 V2）
 *
 * 架构分层：
 * - ReaderSessionController：阅读模式（VERTICAL_STRIP / PAGE_LTR / PAGE_RTL）、HUD 显隐、
 *   点击热区、页码钳制与章节边界状态机；
 * - ReaderPreloadScheduler：滑动窗口预加载 [i-1, i+3] 与内存淘汰 [i-3, i+5]，防长章节 OOM；
 * - ReaderGestureMath：双击/双指缩放 [1.0, 3.5] 与放大态防越界拖拽；
 * - ReaderDeviceController：方向锁定、独立亮度调节与音量键翻页（退出/后台严格还原）；
 * - ReadingProgressStore：防抖（350ms）进度落盘 + 退出/切章立即刷盘 + 模式记忆；
 * - ReaderChapterDrawer：章节目录抽屉（SurfaceMaterialModifier 材质合规）。
 */
import { curves, display, uiMaterial, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ComicReaderParam } from '../model/ReaderParam';
import { ComicReaderViewModel } from '../viewmodel/ComicReaderViewModel';
import { MangaImage } from '../components/MangaImage';
import { SegmentSelector } from '../components/SegmentSelector';
import { ReaderChapterDrawer } from '../components/reader/ReaderChapterDrawer';
import { ReaderSessionController } from '../reader/ReaderSessionController';
import { ReadingProgressStore } from '../reader/ReadingProgressStore';
import { ReaderPreloadScheduler } from '../reader/ReaderPreloadWindow';
import {
  ReaderDeviceController,
  ArkUIWindowDeviceAdapter,
  MIN_READER_BRIGHTNESS,
  MAX_READER_BRIGHTNESS,
  VolumeKeyAction
} from '../reader/ReaderDeviceController';
import {
  DOUBLE_TAP_INTERVAL_MS,
  PanEdgeTurnDirection,
  TAP_MAX_MOVE_VP,
  clampPanOffset,
  clampZoomScale,
  computePinchDistanceVp,
  isDoubleTapMatch,
  isPanEnabledForScale,
  isSingleFingerTapCandidate,
  isWithinPinchCooldown,
  resetZoomTransform,
  resolvePinchEndTransform,
  resolveZoomedPanEdgeTurn,
  shouldDeferTapForDoubleZoom,
  shouldLockReaderScroll,
  toggleDoubleTapZoom,
  ZoomOffset,
  ZoomTransformState
} from '../reader/ReaderGestureMath';
import {
  HorizontalTurnControllerAction,
  READER_HUD_BACK_TARGET_VP,
  READER_PAGE_CACHED_COUNT,
  READER_PAGE_DISPLAY_COUNT,
  READER_PAGE_SWIPE_DURATION_MS,
  READER_STRIP_FRICTION,
  computeReaderContentWidthVp,
  computeReaderHudInsets,
  computeVerticalPageTurnStepVp,
  resolveHorizontalTurnControllerAction,
  resolvePageTurnAnimated,
  resolveReaderBackgroundColor,
  resolveReaderStatusBarContentColor,
  resolveReaderTapAction
} from '../reader/ReaderLayout';
import {
  ReaderChapterItem,
  ReaderMode,
  ReadingProgressSnapshot,
  TapZoneAction
} from '../reader/ReaderTypes';
import { OrientationLockMode, PreferenceManager, ReadDirection } from '../utils/PreferenceManager';
import { SafeAreaManager } from '../utils/SafeAreaManager';
import { ThemeColors, ThemeDims } from '../utils/Theme';
import { ThemeManager } from '../utils/ThemeManager';
import {
  buildBarImmersiveMaterial,
  buildPanelImmersiveMaterial,
  buildPillImmersiveMaterial
} from '../utils/ImmersiveMaterial';
import {
  ReaderSliderGlowState,
  resolvePanelMaterialTokens,
  resolveReaderSliderGlowState,
  resolveSettingsPillBorderColor,
  resolveSettingsPillSurfaceColor
} from '../utils/MaterialPolicy';
import {
  spatialHudTransition,
  spatialMenuTransition,
  spatialSheetTransition
} from '../utils/ImmersiveMotion';
import { Logger } from '../utils/Logger';
import { LocalizationManager } from '../utils/LocalizationManager';

const TAG: string = 'ComicReader';

@ComponentV2
export struct ComicReader {
  @Require @Param param: ComicReaderParam;
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local vm: ComicReaderViewModel = new ComicReaderViewModel();
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();
  @Local session: ReaderSessionController = new ReaderSessionController();
  private resumeIndex: number = 0;
  @Local viewportWidthVp: number = 0;
  @Local viewportHeightVp: number = 0;
  @Local topAvoidVp: number = 0;
  @Local bottomAvoidVp: number = 0;
  @Local activeChapterId: string = '';
  @Local activeChapterTitle: string = '';
  @Local zoomScale: number = 1.0;
  @Local zoomOffsetX: number = 0;
  @Local zoomOffsetY: number = 0;
  @Local activeTouchCount: number = 0;
  @Local isPinching: boolean = false;
  @Local hudVisible: boolean = false;
  @Local drawerVisible: boolean = false;
  @Local settingsVisible: boolean = false;
  @Local sliderPreviewPage: number = 0;
  @Local isDraggingPageSlider: boolean = false;
  @Local isDraggingBrightnessSlider: boolean = false;
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private settings: PreferenceManager = PreferenceManager.getInstance();
  private readonly barMaterial: uiMaterial.Material | undefined = buildBarImmersiveMaterial(false);
  private readonly pillMaterial: uiMaterial.Material | undefined = buildPillImmersiveMaterial();
  private readonly panelMaterial: uiMaterial.Material | undefined = buildPanelImmersiveMaterial();

  private pinchBaseScale: number = 1.0;
  private panBaseX: number = 0;
  private panBaseY: number = 0;
  private downTouchX: number = 0;
  private downTouchY: number = 0;
  private downTouchTimeMs: number = 0;
  private hasValidDownTouch: boolean = false;
  private tapMovedTooFar: boolean = false;
  private hadMultiTouchInSequence: boolean = false;
  private touchPinchStartDist: number = 0;
  private touchPanStartX: number = 0;
  private touchPanStartY: number = 0;
  private touchPanDragging: boolean = false;
  private lastPinchEndTimeMs: number = 0;
  private lastTapTimeMs: number = 0;
  private lastTapX: number = 0;
  private lastTapY: number = 0;
  private pendingSingleTapTimer: number = -1;
  private lastHudShownTimeMs: number = 0;

  private readonly listScroller: Scroller = new Scroller();
  private readonly pageSwiperController: SwiperController = new SwiperController();
  private readonly progressStore: ReadingProgressStore = new ReadingProgressStore();
  private readonly preloadScheduler: ReaderPreloadScheduler = new ReaderPreloadScheduler();
  private readonly deviceController: ReaderDeviceController = new ReaderDeviceController(
    new ArkUIWindowDeviceAdapter(() => this.getUIContext().getHostContext())
  );

  aboutToAppear(): void {
    this.initViewportFallback();
    this.activeChapterId = this.param.chapterId;
    this.activeChapterTitle = this.param.chapterTitle;
    this.resumeIndex = Math.max(this.param.startPage - 1, 0);
    this.session.setChapters(this.param.chapters, this.activeChapterId);
    this.vm.prepareChapter(this.param.startPage);
    this.syncSystemBarTheme();
    this.deviceController.setVolumeKeyTriggerListener((action: VolumeKeyAction): void => {
      this.handleVolumeKeyAction(action);
    });

    if (this.progressStore.hasSavedMode(this.param.comicId)) {
      this.session.setMode(this.progressStore.getMode(this.param.comicId));
    } else {
      this.session.setMode(this.settings.getReaderModeSync());
    }

    const hostCtx = this.getUIContext().getHostContext();
    SafeAreaManager.getStatusBarHeight(hostCtx)
      .then((h: number): void => {
        this.topAvoidVp = h;
      })
      .catch((): void => {});
    SafeAreaManager.getBottomSafeAreaHeight(hostCtx)
      .then((h: number): void => {
        this.bottomAvoidVp = h;
      })
      .catch((): void => {});
  }

  aboutToDisappear(): void {
    this.clearPendingSingleTapTimer();
    this.setSystemBarsVisible(true);
    this.preloadScheduler.dispose();
    this.progressStore.cancelPending();
    void this.flushCurrentProgress();
    void this.deviceController.exitReader();
  }

  private clearPendingSingleTapTimer(): void {
    if (this.pendingSingleTapTimer >= 0) {
      clearTimeout(this.pendingSingleTapTimer);
      this.pendingSingleTapTimer = -1;
    }
  }

  private syncHudState(): void {
    this.hudVisible = this.session.isHudVisible;
    this.drawerVisible = this.session.isDrawerVisible;
    this.settingsVisible = this.session.isSettingsVisible;
    if (this.hudVisible) {
      this.lastHudShownTimeMs = Date.now();
    }
  }

  @Builder
  ChapterSheetBuilder() {
    ReaderChapterDrawer({
      chapters: this.session.chapters,
      currentChapterId: this.activeChapterId,
      topSafeVp: this.topAvoidVp,
      bottomSafeVp: this.bottomAvoidVp,
      embeddedInSheet: true,
      onSelectChapter: (chapter: ReaderChapterItem): void => {
        this.session.closeDrawer();
        this.syncHudState();
        void this.switchChapter(chapter);
      },
      onClose: (): void => {
        this.session.closeDrawer();
        this.syncHudState();
      }
    })
  }

  build() {
    HdsNavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 底层：漫画内容 / 加载态 / 错误态（含缩放变换容器）
        this.ReaderContent()

        // 章节边界轻量提示
        if (this.session.boundaryNotice !== '') {
          this.BoundaryBanner()
        }

        // 顶部与底部沉浸式操作栏（打开目录或设置面板时互斥隐藏，防止按钮重叠）
        if (this.hudVisible && !this.drawerVisible && !this.settingsVisible) {
          this.TopHudBar()
          this.BottomHudBar()
        }

        // 阅读设置半屏浮层
        if (this.settingsVisible) {
          this.SettingsPanel()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(resolveReaderBackgroundColor(this.theme.isDark))
      .bindSheet(this.drawerVisible, this.ChapterSheetBuilder(), {
        height: SheetSize.LARGE,
        detents: [SheetSize.MEDIUM, SheetSize.LARGE],
        dragBar: true,
        showClose: true,
        title: {
          title: `${this.lm.getLocalizedString($r('app.string.reader_toc'), '目录', '目錄', 'Chapters')} (${this.session.chapters.length})`
        },
        backgroundColor: ThemeColors.CARD,
        onWillDismiss: (dismissAction: DismissSheetAction): void => {
          this.session.closeDrawer();
          this.syncHudState();
          dismissAction.dismiss();
        }
      })
      .focusable(true)
      .defaultFocus(true)
      .focusOnTouch(true)
      .onKeyEvent((event: KeyEvent): boolean => {
        if (event.type !== KeyType.Down ||
          this.drawerVisible ||
          this.settingsVisible) {
          return false;
        }
        const action: VolumeKeyAction = this.deviceController.handleKeyCode(event.keyCode);
        return this.handleVolumeKeyAction(action);
      })
      .onAreaChange((_oldVal: Area, newVal: Area) => {
        const w: number = Number(newVal.width);
        const h: number = Number(newVal.height);
        if (Number.isFinite(w) && w > 0) {
          this.viewportWidthVp = w;
        }
        if (Number.isFinite(h) && h > 0) {
          this.viewportHeightVp = h;
        }
      })
    }
    .hideTitleBar(true)
    .withTheme({ enableThemeColorMode: true })
    .backgroundColor(resolveReaderBackgroundColor(this.theme.isDark))
    .onBackPressed((): boolean => {
      if (this.settingsVisible) {
        this.session.closeSettings();
        this.syncHudState();
        return true;
      }
      if (this.drawerVisible) {
        this.session.closeDrawer();
        this.syncHudState();
        return true;
      }
      return false;
    })
    .onReady(() => {
      Logger.info(TAG, `onReady, comicId=${this.param.comicId}, chapterId=${this.activeChapterId}, ` +
        `startPage=${this.param.startPage}`);
      void this.loadActiveChapter(this.param.startPage, false);
    })
    .onShown(() => {
      this.setSystemBarsVisible(false);
      void this.deviceController.enterReader(
        this.settings.orientationLock,
        this.settings.volumeKeyPageTurn
      );
    })
    .onHidden(() => {
      this.clearPendingSingleTapTimer();
      this.session.hideHud();
      this.syncHudState();
      this.setSystemBarsVisible(true);
      void this.deviceController.onBackground();
      void this.flushCurrentProgress();
    })
    .onDisAppear(() => {
      this.clearPendingSingleTapTimer();
      this.setSystemBarsVisible(true);
      this.preloadScheduler.dispose();
      this.progressStore.cancelPending();
      void this.flushCurrentProgress();
      void this.deviceController.exitReader();
    })
  }

  private async loadActiveChapter(startPage: number, forceReload: boolean): Promise<void> {
    this.resetZoom();
    const targetChapterId: string = this.activeChapterId;
    await this.vm.loadChapter(this.param.comicId, targetChapterId, startPage, forceReload);
    if (targetChapterId !== this.activeChapterId) {
      return;
    }
    this.session.syncPages(this.vm.totalCount, this.vm.currentPage);
    this.resumeIndex = this.session.currentPageIndex;
    const urls: string[] = [];
    for (let i = 0; i < this.vm.totalCount; i++) {
      urls.push(this.vm.imageDataSource.getData(i) as string);
    }
    this.preloadScheduler.setChapterUrls(urls);
    if (urls.length > 0) {
      this.preloadScheduler.onPageChanged(this.session.currentPageIndex);
    }
  }

  private initViewportFallback(): void {
    try {
      const defDisplay: display.Display = display.getDefaultDisplaySync();
      const uiCtx = this.getUIContext();
      const wVp: number = uiCtx.px2vp(defDisplay.width);
      const hVp: number = uiCtx.px2vp(defDisplay.height);
      if (this.viewportWidthVp <= 0 && Number.isFinite(wVp) && wVp > 0) {
        this.viewportWidthVp = wVp;
      }
      if (this.viewportHeightVp <= 0 && Number.isFinite(hVp) && hVp > 0) {
        this.viewportHeightVp = hVp;
      }
    } catch (e) {
      Logger.debug(TAG, `获取屏幕默认宽高回退默认值: ${(e as Error).message}`);
    }
    if (this.viewportWidthVp <= 0) {
      this.viewportWidthVp = 360;
    }
    if (this.viewportHeightVp <= 0) {
      this.viewportHeightVp = 780;
    }
  }

  private resetZoom(): void {
    const reset: ZoomTransformState = resetZoomTransform();
    if (this.zoomScale !== reset.scale) {
      this.zoomScale = reset.scale;
    }
    if (this.zoomOffsetX !== reset.offsetX) {
      this.zoomOffsetX = reset.offsetX;
    }
    if (this.zoomOffsetY !== reset.offsetY) {
      this.zoomOffsetY = reset.offsetY;
    }
  }

  private resetZoomWithSpring(): void {
    if (this.zoomScale <= 1.001 && this.zoomOffsetX === 0 && this.zoomOffsetY === 0) {
      this.resetZoom();
      return;
    }
    try {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.32, 0.85) }, (): void => {
        this.resetZoom();
      });
    } catch (_e) {
      this.resetZoom();
    }
  }

  private buildProgressSnapshot(): ReadingProgressSnapshot {
    return new ReadingProgressSnapshot(
      this.param.comicId,
      this.activeChapterId,
      this.activeChapterTitle,
      this.session.currentPageNumber,
      this.vm.totalCount,
      this.session.mode,
      Date.now()
    );
  }

  private scheduleProgressSave(): void {
    if (this.vm.totalCount <= 0) {
      return;
    }
    this.progressStore.scheduleSave(this.buildProgressSnapshot());
  }

  private async flushCurrentProgress(): Promise<void> {
    if (this.vm.totalCount <= 0) {
      return;
    }
    if (this.progressStore.hasPendingSave()) {
      await this.progressStore.flushSave();
    } else {
      await this.progressStore.saveNow(this.buildProgressSnapshot());
    }
  }

  private async switchChapter(target: ReaderChapterItem): Promise<void> {
    if (target.id === '' || target.id === this.activeChapterId) {
      return;
    }
    const prevSnapshot: ReadingProgressSnapshot | null = this.vm.totalCount > 0
      ? this.buildProgressSnapshot() : null;
    this.preloadScheduler.dispose();
    this.resetZoom();
    this.activeChapterId = target.id;
    this.activeChapterTitle = target.title;
    this.session.updateCurrentChapterId(target.id);
    this.resumeIndex = 0;
    const sessionId: number = this.vm.prepareChapter(1);
    if (prevSnapshot !== null) {
      void this.progressStore.saveNow(prevSnapshot);
    }
    const savedPage: number = await this.progressStore.loadChapterPage(this.param.comicId, target.id, 1);
    if (sessionId !== this.vm.chapterSessionId || target.id !== this.activeChapterId) {
      return;
    }
    this.resumeIndex = Math.max(savedPage - 1, 0);
    await this.loadActiveChapter(savedPage, true);
  }

  private switchToPrevChapter(): void {
    const target: ReaderChapterItem | null = this.session.prevChapter();
    if (target !== null) {
      void this.switchChapter(target);
    }
  }

  private switchToNextChapter(): void {
    const target: ReaderChapterItem | null = this.session.nextChapter();
    if (target !== null) {
      void this.switchChapter(target);
    }
  }

  private scrollToCurrentPage(animated: boolean): void {
    const smooth: boolean = resolvePageTurnAnimated(animated);
    if (this.session.mode === ReaderMode.VERTICAL_STRIP) {
      this.listScroller.scrollToIndex(this.session.currentPageIndex, smooth, ScrollAlign.START);
    } else {
      this.pageSwiperController.changeIndex(this.session.currentPageIndex, smooth);
    }
  }

  private handleVolumeKeyAction(action: VolumeKeyAction): boolean {
    if (action === VolumeKeyAction.NONE ||
      this.session.isDrawerVisible ||
      this.session.isSettingsVisible) {
      return false;
    }
    const isNext: boolean = action === VolumeKeyAction.NEXT_PAGE;
    this.turnPageByDelta(isNext ? 1 : -1, this.settings.pageTurnAnimationEnabled);
    return true;
  }

  private turnPageByDelta(
    delta: number,
    animated: boolean = this.settings.pageTurnAnimationEnabled
  ): void {
    const smooth: boolean = resolvePageTurnAnimated(animated);
    if (this.session.mode !== ReaderMode.VERTICAL_STRIP) {
      const action: HorizontalTurnControllerAction = resolveHorizontalTurnControllerAction(
        this.session.currentPageIndex,
        this.session.totalPages,
        delta,
        smooth
      );
      if (action === 'none') {
        return;
      }
      this.resetZoom();
      if (action === 'show_next') {
        this.pageSwiperController.showNext();
        return;
      }
      if (action === 'show_prev') {
        this.pageSwiperController.showPrevious();
        return;
      }
      const movedHorizontal: boolean = delta < 0 ? this.session.prevPage() : this.session.nextPage();
      if (!movedHorizontal) {
        return;
      }
      this.resumeIndex = this.session.currentPageIndex;
      this.vm.updatePage(this.session.currentPageIndex);
      this.preloadScheduler.onPageChanged(this.session.currentPageIndex);
      this.scrollToCurrentPage(false);
      this.scheduleProgressSave();
      return;
    }

    const moved: boolean = delta < 0 ? this.session.prevPage() : this.session.nextPage();
    if (!moved) {
      if (this.viewportHeightVp > 0) {
        const stepVp: number = computeVerticalPageTurnStepVp(this.viewportHeightVp);
        this.listScroller.scrollBy(0, delta > 0 ? stepVp : -stepVp);
      }
      return;
    }
    this.resetZoom();
    this.resumeIndex = this.session.currentPageIndex;
    this.vm.updatePage(this.session.currentPageIndex);
    this.preloadScheduler.onPageChanged(this.session.currentPageIndex);
    this.scrollToCurrentPage(smooth);
    this.scheduleProgressSave();
  }

  private showReaderToast(message: string): void {
    if (message === '') {
      return;
    }
    try {
      this.getUIContext().getPromptAction().showToast({
        message: message,
        duration: 2200
      });
    } catch (e) {
      Logger.debug(TAG, `Toast 忽略: ${(e as Error).message}`);
    }
  }

  private handleReaderTap(xVp: number, yVp: number): void {
    const w: number = this.viewportWidthVp > 0 ? this.viewportWidthVp : 360;
    const h: number = this.viewportHeightVp > 0 ? this.viewportHeightVp : 780;
    const action: TapZoneAction = resolveReaderTapAction(
      xVp, yVp, w, h, this.session.mode, this.settings.doubleTapZoomEnabled
    );
    if (action === TapZoneAction.TOGGLE_HUD) {
      this.session.toggleHud();
      this.syncHudState();
      return;
    }
    this.turnPageByDelta(
      action === TapZoneAction.NEXT_PAGE ? 1 : -1,
      this.settings.pageTurnAnimationEnabled
    );
  }

  private jumpToPageNumber(pageNumber: number): void {
    this.resetZoom();
    const targetIndex: number = this.session.goToPageNumber(pageNumber);
    this.resumeIndex = targetIndex;
    this.vm.updatePage(targetIndex);
    this.preloadScheduler.onPageChanged(targetIndex);
    this.scrollToCurrentPage(false);
    this.scheduleProgressSave();
  }

  private applyMode(nextMode: ReaderMode): void {
    if (nextMode === this.session.mode) {
      return;
    }
    this.resetZoom();
    this.resumeIndex = this.session.currentPageIndex;
    this.session.setMode(nextMode);
    this.progressStore.setMode(this.param.comicId, nextMode);
    void this.settings.setReaderMode(nextMode);
  }

  private modeSegmentIndex(): number {
    if (this.session.mode === ReaderMode.PAGE_LTR) {
      return 1;
    }
    if (this.session.mode === ReaderMode.PAGE_RTL) {
      return 2;
    }
    return 0;
  }

  private orientationSegmentIndex(): number {
    if (this.deviceController.orientationLock === OrientationLockMode.PORTRAIT) {
      return 1;
    }
    if (this.deviceController.orientationLock === OrientationLockMode.LANDSCAPE) {
      return 2;
    }
    return 0;
  }

  private pageSliderGlow(): ReaderSliderGlowState {
    const activePage: number = this.sliderPreviewPage > 0
      ? this.sliderPreviewPage : this.session.currentPageNumber;
    return resolveReaderSliderGlowState(
      this.isDraggingPageSlider,
      activePage,
      Math.max(this.vm.totalCount, 1),
      this.theme.isDark
    );
  }

  private brightnessSliderGlow(): ReaderSliderGlowState {
    return resolveReaderSliderGlowState(
      this.isDraggingBrightnessSlider,
      this.deviceController.customBrightness,
      MAX_READER_BRIGHTNESS,
      this.theme.isDark
    );
  }

  private onListScrollIndex(firstIndex: number): void {
    const prevIndex: number = this.session.currentPageIndex;
    this.vm.updatePage(firstIndex);
    this.session.goToPage(firstIndex);
    this.resumeIndex = this.session.currentPageIndex;
    if (firstIndex !== prevIndex) {
      this.resetZoom();
    }
    this.preloadScheduler.onPageChanged(firstIndex);
    this.scheduleProgressSave();
  }

  private handleTouchEvent(event: TouchEvent): void {
    if (event.target && event.target.area) {
      const targetW: number = Number(event.target.area.width);
      const targetH: number = Number(event.target.area.height);
      if (Number.isFinite(targetW) && targetW > 0) {
        this.viewportWidthVp = targetW;
      }
      if (Number.isFinite(targetH) && targetH > 0) {
        this.viewportHeightVp = targetH;
      }
    }

    const touches: TouchObject[] = event.touches;
    const w: number = this.viewportWidthVp > 0 ? this.viewportWidthVp : 360;
    const h: number = this.viewportHeightVp > 0 ? this.viewportHeightVp : 780;

    if (event.type === TouchType.Cancel) {
      this.activeTouchCount = 0;
      this.clearPendingSingleTapTimer();
    } else if (event.type === TouchType.Up) {
      this.activeTouchCount = Math.max(0, touches.length - event.changedTouches.length);
    } else {
      this.activeTouchCount = touches.length;
    }

    if (event.type === TouchType.Down && touches.length === 1) {
      if (Number.isFinite(touches[0].x) && Number.isFinite(touches[0].y)) {
        this.downTouchX = touches[0].x;
        this.downTouchY = touches[0].y;
        this.hasValidDownTouch = true;
      }
      this.downTouchTimeMs = Date.now();
      this.tapMovedTooFar = false;
      this.hadMultiTouchInSequence = false;
      this.touchPinchStartDist = 0;
      if (isPanEnabledForScale(this.zoomScale)) {
        this.touchPanStartX = touches[0].x;
        this.touchPanStartY = touches[0].y;
        this.panBaseX = this.zoomOffsetX;
        this.panBaseY = this.zoomOffsetY;
        this.touchPanDragging = false;
      }
    }

    if (touches.length >= 2) {
      this.hadMultiTouchInSequence = true;
      this.clearPendingSingleTapTimer();
      this.lastTapTimeMs = 0;
      this.touchPanDragging = false;
      const dist: number = computePinchDistanceVp(
        touches[0].x, touches[0].y, touches[1].x, touches[1].y
      );
      if (!this.isPinching || this.touchPinchStartDist < 8) {
        if (dist >= 8) {
          this.isPinching = true;
          this.touchPinchStartDist = dist;
          this.pinchBaseScale = this.zoomScale;
        }
      } else if (event.type === TouchType.Move && dist > 0 && this.touchPinchStartDist >= 8) {
        this.zoomScale = clampZoomScale(this.pinchBaseScale * (dist / this.touchPinchStartDist));
        const clamped: ZoomOffset = clampPanOffset(
          this.zoomOffsetX, this.zoomOffsetY, this.zoomScale, w, h
        );
        this.zoomOffsetX = clamped.x;
        this.zoomOffsetY = clamped.y;
      }
    } else if (touches.length === 1 && event.type === TouchType.Move && !this.hadMultiTouchInSequence) {
      const moveDist: number = computePinchDistanceVp(
        this.downTouchX, this.downTouchY, touches[0].x, touches[0].y
      );
      if (moveDist > TAP_MAX_MOVE_VP) {
        this.tapMovedTooFar = true;
        this.clearPendingSingleTapTimer();
      }
      if (isPanEnabledForScale(this.zoomScale)) {
        const dx: number = touches[0].x - this.touchPanStartX;
        const dy: number = touches[0].y - this.touchPanStartY;
        if (this.touchPanDragging || Math.hypot(dx, dy) >= 8) {
          this.touchPanDragging = true;
          const clamped: ZoomOffset = clampPanOffset(
            this.panBaseX + dx,
            this.panBaseY + dy,
            this.zoomScale,
            w,
            h
          );
          this.zoomOffsetX = clamped.x;
          this.zoomOffsetY = clamped.y;
        }
      }
    }

    if (this.activeTouchCount < 2 && this.isPinching) {
      this.touchPinchStartDist = 0;
      this.onPinchFinish();
    }

    if (this.activeTouchCount === 0 && event.type === TouchType.Up) {
      if (this.touchPanDragging) {
        this.touchPanDragging = false;
        const released = event.changedTouches.length > 0 ? event.changedTouches[0] : undefined;
        if (released !== undefined) {
          this.triggerZoomedEdgeTurn(
            released.x - this.touchPanStartX,
            released.y - this.touchPanStartY
          );
        }
        return;
      }
      const durationMs: number = Date.now() - this.downTouchTimeMs;
      if (this.hasValidDownTouch && isSingleFingerTapCandidate(
        this.hadMultiTouchInSequence,
        this.isPinching,
        this.touchPanDragging,
        this.tapMovedTooFar,
        durationMs
      )) {
        const tapX: number = this.downTouchX;
        const tapY: number = this.downTouchY;
        const tapAction: TapZoneAction = resolveReaderTapAction(
          tapX, tapY, w, h, this.session.mode, this.settings.doubleTapZoomEnabled
        );
        if (!shouldDeferTapForDoubleZoom(tapAction, this.settings.doubleTapZoomEnabled)) {
          const nowMs: number = Date.now();
          if (this.settings.doubleTapZoomEnabled &&
            isDoubleTapMatch(this.lastTapTimeMs, this.lastTapX, this.lastTapY, nowMs, tapX, tapY)) {
            this.clearPendingSingleTapTimer();
            this.lastTapTimeMs = 0;
            this.handleDoubleTapGesture();
          } else {
            this.clearPendingSingleTapTimer();
            this.lastTapTimeMs = 0;
            this.handleReaderTap(tapX, tapY);
          }
        } else {
          const nowMs: number = Date.now();
          if (isDoubleTapMatch(this.lastTapTimeMs, this.lastTapX, this.lastTapY, nowMs, tapX, tapY)) {
            this.clearPendingSingleTapTimer();
            this.lastTapTimeMs = 0;
            this.handleDoubleTapGesture();
          } else {
            this.lastTapTimeMs = nowMs;
            this.lastTapX = tapX;
            this.lastTapY = tapY;
            this.clearPendingSingleTapTimer();
            this.pendingSingleTapTimer = setTimeout((): void => {
              this.pendingSingleTapTimer = -1;
              this.lastTapTimeMs = 0;
              this.handleReaderTap(tapX, tapY);
            }, DOUBLE_TAP_INTERVAL_MS);
          }
        }
      }
    }
  }

  private handleDoubleTapGesture(): void {
    if (!this.settings.doubleTapZoomEnabled) {
      return;
    }
    const w: number = this.viewportWidthVp > 0 ? this.viewportWidthVp : 360;
    const h: number = this.viewportHeightVp > 0 ? this.viewportHeightVp : 780;
    const next: ZoomTransformState = toggleDoubleTapZoom(
      this.zoomScale, w / 2, h / 2, w, h
    );
    try {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.32, 0.85) }, (): void => {
        this.zoomScale = next.scale;
        this.zoomOffsetX = next.offsetX;
        this.zoomOffsetY = next.offsetY;
      });
    } catch (_e) {
      this.zoomScale = next.scale;
      this.zoomOffsetX = next.offsetX;
      this.zoomOffsetY = next.offsetY;
    }
  }

  private onPinchFinish(): void {
    this.isPinching = false;
    this.touchPanDragging = false;
    this.lastPinchEndTimeMs = Date.now();
    const w: number = this.viewportWidthVp > 0 ? this.viewportWidthVp : 360;
    const h: number = this.viewportHeightVp > 0 ? this.viewportHeightVp : 780;
    const settled: ZoomTransformState = resolvePinchEndTransform(
      this.zoomScale, this.zoomOffsetX, this.zoomOffsetY, w, h
    );
    try {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.32, 0.85) }, (): void => {
        this.zoomScale = settled.scale;
        this.zoomOffsetX = settled.offsetX;
        this.zoomOffsetY = settled.offsetY;
      });
    } catch (_e) {
      this.zoomScale = settled.scale;
      this.zoomOffsetX = settled.offsetX;
      this.zoomOffsetY = settled.offsetY;
    }
  }

  private triggerZoomedEdgeTurn(deltaX: number, deltaY: number): void {
    if (isWithinPinchCooldown(this.lastPinchEndTimeMs, Date.now())) {
      return;
    }
    const w: number = this.viewportWidthVp > 0 ? this.viewportWidthVp : 360;
    const h: number = this.viewportHeightVp > 0 ? this.viewportHeightVp : 780;
    const turnDir: PanEdgeTurnDirection = resolveZoomedPanEdgeTurn(
      this.panBaseX,
      this.panBaseY,
      deltaX,
      deltaY,
      this.zoomScale,
      w,
      h,
      this.session.mode
    );
    if (turnDir === 'none') {
      return;
    }
    this.turnPageByDelta(turnDir === 'next' ? 1 : -1, this.settings.pageTurnAnimationEnabled);
  }

  @Builder
  ReaderContent() {
    if (this.vm.imageDataSource.isEmpty() && this.vm.errorMessage !== '') {
      Column({ space: 12 }) {
        Text(this.vm.incompleteMessage !== ''
          ? $r('app.string.reader_local_unavailable')
          : $r('app.string.reader_load_failed'))
          .fontSize(16)
          .fontColor(ThemeColors.TEXT)
        Text(this.vm.errorMessage)
          .fontSize(12)
          .fontColor(ThemeColors.TEXT_SECONDARY)
          .textAlign(TextAlign.Center)
        Row({ space: 10 }) {
          Button($r('app.string.common_retry'))
            .backgroundColor(ThemeColors.PRIMARY)
            .fontColor(ThemeColors.BG)
            .onClick(() => {
              void this.loadActiveChapter(this.param.startPage, true);
            })
          if (this.vm.needsLogin) {
            Button($r('app.string.common_go_login'))
              .backgroundColor(ThemeColors.SURFACE)
              .fontColor(ThemeColors.TEXT)
              .onClick(() => {
                this.pageStack.pushPathByName('LoginPage', null);
              })
          }
          if (this.vm.incompleteMessage !== '') {
            Button($r('app.string.reader_download_manage'))
              .backgroundColor(ThemeColors.SURFACE)
              .fontColor(ThemeColors.TEXT)
              .onClick(() => {
                this.pageStack.pushPathByName('DownloadPage', null);
              })
          }
        }
        .margin({ top: 8 })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ left: 32, right: 32 })
    } else if (this.vm.imageDataSource.isEmpty() && this.vm.isLoading) {
      Column({ space: 12 }) {
        LoadingProgress()
          .width(36)
          .height(36)
          .color(ThemeColors.PRIMARY)
        Text($r('app.string.reader_loading_chapter'))
          .fontSize(13)
          .fontColor(ThemeColors.TEXT_SECONDARY)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    } else if (this.vm.imageDataSource.isEmpty()) {
      Column({ space: 12 }) {
        Text($r('app.string.reader_no_pages'))
          .fontSize(16)
          .fontColor(ThemeColors.TEXT)
        Text($r('app.string.reader_no_pages_msg'))
          .fontSize(12)
          .fontColor(ThemeColors.TEXT_SECONDARY)
        Button($r('app.string.common_retry'))
          .backgroundColor(ThemeColors.PRIMARY)
          .fontColor(ThemeColors.BG)
          .onClick(() => {
            void this.loadActiveChapter(this.param.startPage, true);
          })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ left: 32, right: 32 })
    } else {
      Stack() {
        Column() {
          if (this.session.mode === ReaderMode.VERTICAL_STRIP) {
            this.VerticalStripReader()
          } else {
            this.PagedReader()
          }
        }
        .width('100%')
        .height('100%')
        .scale({ x: this.zoomScale, y: this.zoomScale })
        .translate({ x: this.zoomOffsetX, y: this.zoomOffsetY })
      }
      .width('100%')
      .height('100%')
      .clip(true)
      .zIndex(1)
      .onAreaChange((_oldVal: Area, newVal: Area): void => {
        const w: number = Number(newVal.width);
        const h: number = Number(newVal.height);
        if (Number.isFinite(w) && w > 0) {
          this.viewportWidthVp = w;
        }
        if (Number.isFinite(h) && h > 0) {
          this.viewportHeightVp = h;
        }
      })
      .onTouch((event: TouchEvent): void => {
        this.handleTouchEvent(event);
      })
    }
  }

  /** 连续上下条漫模式：宽屏（>= 600vp）限宽居中（<= 760vp） */
  @Builder
  VerticalStripReader() {
    Column() {
      List({
        space: 0,
        initialIndex: this.resumeIndex,
        scroller: this.listScroller
      }) {
        LazyForEach(this.vm.imageDataSource, (url: string, index: number) => {
          ListItem() {
            MangaImage({ imageUrl: url })
          }
        }, (url: string, index: number) => `${this.vm.chapterStableKey()}_${index}_${url}`)
      }
      .width(this.viewportWidthVp > 0
        ? computeReaderContentWidthVp(this.viewportWidthVp, this.session.mode) : '100%')
      .height('100%')
      .cachedCount(ThemeDims.LIST_CACHED_COUNT)
      .friction(READER_STRIP_FRICTION)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .enableScrollInteraction(!shouldLockReaderScroll(this.activeTouchCount, this.isPinching, this.zoomScale))
      .onScrollStart(() => {
        if (this.session.isHudVisible && this.tapMovedTooFar && Date.now() - this.lastHudShownTimeMs > 350) {
          this.session.hideHud();
          this.syncHudState();
        }
      })
      .onScrollIndex((firstIndex: number) => {
        this.onListScrollIndex(firstIndex);
      })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /** 单页翻页模式：Swiper 锁定单次最多翻 1 页，放大态/双指态优先消费缩放与拖拽 */
  @Builder
  PagedReader() {
    Swiper(this.pageSwiperController) {
      LazyForEach(this.vm.imageDataSource, (url: string, index: number) => {
        MangaImage({ imageUrl: url, fillPage: true })
          .width('100%')
          .height('100%')
      }, (url: string, index: number) => `${this.vm.chapterStableKey()}_${index}_${url}`)
    }
    .index(this.resumeIndex)
    .width('100%')
    .height('100%')
    .loop(false)
    .indicator(false)
    .duration(READER_PAGE_SWIPE_DURATION_MS)
    .curve(Curve.FastOutSlowIn)
    .cachedCount(READER_PAGE_CACHED_COUNT)
    .displayCount(READER_PAGE_DISPLAY_COUNT)
    .disableSwipe(shouldLockReaderScroll(this.activeTouchCount, this.isPinching, this.zoomScale))
    .direction(this.session.mode === ReaderMode.PAGE_RTL ? Direction.Rtl : Direction.Ltr)
    .onChange((index: number) => {
      this.onListScrollIndex(index);
    })
  }

  @Builder
  BoundaryBanner() {
    Row() {
      Text(this.session.boundaryNotice)
        .fontSize(12)
        .fontColor(ThemeColors.TEXT_STRONG)
        .padding({ left: 14, right: 14, top: 6, bottom: 6 })
        .backgroundColor('#CC1E1E1E')
        .borderRadius(16)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .margin({ top: computeReaderHudInsets(this.topAvoidVp, this.bottomAvoidVp).topVp + 60 })
    .zIndex(15)
  }

  /** 顶部沉浸式操作栏（官方沉浸光感材质 + 1vp 高光边线 + 空间唤出动效） */
  @Builder
  TopHudBar() {
    Row({ space: 8 }) {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(20)
          .fontColor([ThemeColors.TEXT_STRONG])
      }
      .width(READER_HUD_BACK_TARGET_VP)
      .height(READER_HUD_BACK_TARGET_VP)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        void this.flushCurrentProgress();
        this.pageStack.pop();
      })

      Column({ space: 1 }) {
        Text(this.activeChapterTitle === ''
          ? this.lm.getString($r('app.string.reader_reading'), '阅读中')
          : this.activeChapterTitle)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.TEXT_STRONG)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.vm.isOffline) {
          Text($r('app.string.reader_offline_chapter'))
            .fontSize(10)
            .fontColor(ThemeColors.PRIMARY)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({
      left: 8,
      right: 12,
      top: computeReaderHudInsets(this.topAvoidVp, this.bottomAvoidVp).topVp + 6,
      bottom: 8
    })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.theme.isDark ? '#181A20' : '#FFFFFF')
    .border({
      width: { bottom: 1 },
      color: this.theme.isDark ? '#2E323D' : '#E2E8F0'
    })
    .systemMaterial(this.barMaterial)
    .position({ x: 0, y: 0 })
    .zIndex(10)
    .transition(spatialHudTransition(true))
  }

  /** 底部沉浸式操作栏（光感进度滑块 + 官方沉浸光感材质 + 悬浮矢量按钮） */
  @Builder
  BottomHudBar() {
    Column({ space: 10 }) {
      if (this.isDraggingPageSlider) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.book_pages'))
            .fontSize(13)
            .fontColor([ThemeColors.PRIMARY])
          Text(`${this.sliderPreviewPage > 0
            ? this.sliderPreviewPage
            : this.session.currentPageNumber} / ${Math.max(this.vm.totalCount, 1)}`)
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.TEXT_STRONG)
        }
        .padding({ left: 14, right: 14, top: 6, bottom: 6 })
        .borderRadius(16)
        .backgroundColor(this.theme.isDark ? '#1E2028' : '#FFFFFF')
        .border({
          width: 1,
          color: this.pageSliderGlow().pillBorderColor
        })
        .shadow({
          radius: this.pageSliderGlow().glowShadowRadius,
          color: this.pageSliderGlow().glowShadowColor,
          offsetX: 0,
          offsetY: 2
        })
        .systemMaterial(this.pillMaterial)
        .transition(spatialMenuTransition())
      }

      Row({ space: 10 }) {
        Text(`${this.sliderPreviewPage > 0 ? this.sliderPreviewPage : this.session.currentPageNumber}`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.TEXT_STRONG)
          .width(30)
          .textAlign(TextAlign.Center)

        Slider({
          value: this.sliderPreviewPage > 0 ? this.sliderPreviewPage : this.session.currentPageNumber,
          min: 1,
          max: Math.max(this.vm.totalCount, 1),
          step: 1
        })
          .selectedColor(ThemeColors.PRIMARY)
          .trackColor(this.theme.isDark ? '#33FFFFFF' : '#33000000')
          .trackThickness(this.isDraggingPageSlider ? 6 : 4)
          .blockSize({
            width: this.isDraggingPageSlider ? 20 : 16,
            height: this.isDraggingPageSlider ? 20 : 16
          })
          .blockBorderWidth(this.isDraggingPageSlider ? 3 : 0)
          .blockBorderColor(this.pageSliderGlow().glowShadowColor)
          .scale({ x: 1.0, y: this.pageSliderGlow().trackScaleY })
          .animation({ curve: curves.springMotion(0.24, 0.80) })
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            const target: number = Math.round(value);
            if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
              this.isDraggingPageSlider = true;
              this.sliderPreviewPage = target;
            } else if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.isDraggingPageSlider = false;
              this.sliderPreviewPage = 0;
              this.jumpToPageNumber(target);
            }
          })

        Text(`${Math.max(this.vm.totalCount, 1)}`)
          .fontSize(12)
          .fontColor(ThemeColors.TEXT_SECONDARY)
          .width(30)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 8 }) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(16)
            .fontColor([ThemeColors.TEXT_STRONG])
          Text($r('app.string.reader_prev_chapter'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.TEXT_STRONG)
        }
        .height(38)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(resolveSettingsPillSurfaceColor(this.theme.isDark, false))
        .border({
          width: 1,
          color: resolveSettingsPillBorderColor(this.theme.isDark)
        })
        .borderRadius(19)
        .opacity(this.session.hasPrevChapter() ? 1 : 0.4)
        .enabled(this.session.hasPrevChapter())
        .onClick(() => {
          this.switchToPrevChapter();
        })

        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.list_bullet'))
            .fontSize(16)
            .fontColor([ThemeColors.TEXT_STRONG])
          Text($r('app.string.reader_toc'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.TEXT_STRONG)
        }
        .height(38)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(resolveSettingsPillSurfaceColor(this.theme.isDark, false))
        .border({
          width: 1,
          color: resolveSettingsPillBorderColor(this.theme.isDark)
        })
        .borderRadius(19)
        .onClick(() => {
          this.isDraggingPageSlider = false;
          this.session.openDrawer();
          this.syncHudState();
        })

        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.gearshape'))
            .fontSize(16)
            .fontColor([ThemeColors.TEXT_STRONG])
          Text($r('app.string.reader_settings'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.TEXT_STRONG)
        }
        .height(38)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(resolveSettingsPillSurfaceColor(this.theme.isDark, false))
        .border({
          width: 1,
          color: resolveSettingsPillBorderColor(this.theme.isDark)
        })
        .borderRadius(19)
        .onClick(() => {
          this.isDraggingPageSlider = false;
          this.session.openSettings();
          this.syncHudState();
        })

        Row({ space: 4 }) {
          Text($r('app.string.reader_next_chapter'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.TEXT_STRONG)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([ThemeColors.TEXT_STRONG])
        }
        .height(38)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(resolveSettingsPillSurfaceColor(this.theme.isDark, false))
        .border({
          width: 1,
          color: resolveSettingsPillBorderColor(this.theme.isDark)
        })
        .borderRadius(19)
        .opacity(this.session.hasNextChapter() ? 1 : 0.4)
        .enabled(this.session.hasNextChapter())
        .onClick(() => {
          this.switchToNextChapter();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({
      left: 14,
      right: 14,
      top: 10,
      bottom: computeReaderHudInsets(this.topAvoidVp, this.bottomAvoidVp).bottomVp + 10
    })
    .backgroundColor(this.theme.isDark ? '#181A20' : '#FFFFFF')
    .border({
      width: { top: 1 },
      color: this.theme.isDark ? '#2E323D' : '#E2E8F0'
    })
    .systemMaterial(this.barMaterial)
    .position({ x: 0, y: '100%' })
    .translate({ y: '-100%' })
    .zIndex(10)
    .transition(spatialHudTransition(false))
  }

  /** 阅读设置半屏浮层：官方沉浸光感材质 + 1vp 边缘高光描边 + 空间弹性展开转场 */
  @Builder
  SettingsPanel() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#73000000')
        .transition(TransitionEffect.OPACITY.animation({ duration: 180 }))
        .onClick(() => {
          this.isDraggingBrightnessSlider = false;
          this.session.closeSettings();
          this.syncHudState();
        })

      Column({ space: 12 }) {
        Row() {
          Text($r('app.string.reader_settings_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.TEXT_STRONG)
          Blank()
          Row() {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(16)
              .fontColor([ThemeColors.TEXT_STRONG])
          }
          .width(32)
          .height(32)
          .borderRadius(16)
          .backgroundColor(resolveSettingsPillSurfaceColor(this.theme.isDark, false))
          .border({
            width: 1,
            color: resolveSettingsPillBorderColor(this.theme.isDark)
          })
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .responseRegion({ x: -6, y: -6, width: READER_HUD_BACK_TARGET_VP, height: READER_HUD_BACK_TARGET_VP })
          .onClick(() => {
            this.isDraggingBrightnessSlider = false;
            this.session.closeSettings();
            this.syncHudState();
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text($r('app.string.reader_mode_label'))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.TEXT_SECONDARY)
          .width('100%')

        SegmentSelector({
          labels: [
            this.lm.getString($r('app.string.reader_mode_webtoon'), '垂直滚动'),
            this.lm.getString($r('app.string.reader_mode_ltr'), '由左至右'),
            this.lm.getString($r('app.string.reader_mode_rtl'), '由右至左')
          ],
          selectedIndex: this.modeSegmentIndex(),
          onSelect: (index: number) => {
            const target: ReaderMode = index === 1
              ? ReaderMode.PAGE_LTR
              : (index === 2 ? ReaderMode.PAGE_RTL : ReaderMode.VERTICAL_STRIP);
            this.applyMode(target);
          }
        })

        Text($r('app.string.reader_orientation_label'))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.TEXT_SECONDARY)
          .width('100%')

        SegmentSelector({
          labels: [
            this.lm.getString($r('app.string.reader_orientation_system'), '跟随系统'),
            this.lm.getString($r('app.string.reader_orientation_portrait'), '锁定竖屏'),
            this.lm.getString($r('app.string.reader_orientation_landscape'), '锁定横屏')
          ],
          selectedIndex: this.orientationSegmentIndex(),
          onSelect: (index: number) => {
            const mode: OrientationLockMode = index === 1
              ? OrientationLockMode.PORTRAIT
              : (index === 2 ? OrientationLockMode.LANDSCAPE : OrientationLockMode.SYSTEM);
            void this.settings.setOrientationLock(mode);
            void this.deviceController.setOrientationLock(mode);
          }
        })

        Row() {
          Text($r('app.string.reader_system_brightness'))
            .fontSize(14)
            .fontColor(ThemeColors.TEXT_STRONG)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.deviceController.followSystemBrightness })
            .selectedColor(ThemeColors.PRIMARY)
            .onChange((isOn: boolean) => {
              this.isDraggingBrightnessSlider = false;
              void this.deviceController.setFollowSystemBrightness(isOn);
            })
        }
        .width('100%')
        .constraintSize({ minHeight: READER_HUD_BACK_TARGET_VP })
        .alignItems(VerticalAlign.Center)

        if (!this.deviceController.followSystemBrightness) {
          Row({ space: 10 }) {
            Text($r('app.string.reader_brightness'))
              .fontSize(12)
              .fontColor(ThemeColors.TEXT_SECONDARY)
            Slider({
              value: this.deviceController.customBrightness,
              min: MIN_READER_BRIGHTNESS,
              max: MAX_READER_BRIGHTNESS,
              step: 0.05
            })
              .selectedColor(ThemeColors.PRIMARY)
              .trackColor(this.theme.isDark ? '#33FFFFFF' : '#33000000')
              .trackThickness(this.isDraggingBrightnessSlider ? 6 : 4)
              .blockSize({
                width: this.isDraggingBrightnessSlider ? 20 : 16,
                height: this.isDraggingBrightnessSlider ? 20 : 16
              })
              .blockBorderWidth(this.isDraggingBrightnessSlider ? 3 : 0)
              .blockBorderColor(this.brightnessSliderGlow().glowShadowColor)
              .scale({ x: 1.0, y: this.brightnessSliderGlow().trackScaleY })
              .animation({ curve: curves.springMotion(0.24, 0.80) })
              .layoutWeight(1)
              .onChange((value: number, mode: SliderChangeMode) => {
                if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
                  this.isDraggingBrightnessSlider = true;
                } else if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.isDraggingBrightnessSlider = false;
                }
                void this.deviceController.setCustomBrightness(value);
              })
            Text(`${Math.round(this.deviceController.customBrightness * 100)}%`)
              .fontSize(12)
              .fontWeight(this.isDraggingBrightnessSlider ? FontWeight.Bold : FontWeight.Medium)
              .fontColor(this.isDraggingBrightnessSlider
                ? ThemeColors.PRIMARY
                : ThemeColors.TEXT_SECONDARY)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .borderRadius(10)
              .backgroundColor(this.isDraggingBrightnessSlider
                ? resolveSettingsPillSurfaceColor(this.theme.isDark, false)
                : Color.Transparent)
              .border({
                width: this.isDraggingBrightnessSlider ? 1 : 0,
                color: this.brightnessSliderGlow().pillBorderColor
              })
              .constraintSize({ minWidth: 44 })
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .constraintSize({ minHeight: READER_HUD_BACK_TARGET_VP })
          .alignItems(VerticalAlign.Center)
        }

        Row() {
          Text($r('app.string.reader_volume_paging'))
            .fontSize(14)
            .fontColor(ThemeColors.TEXT_STRONG)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.deviceController.volumeKeyPageTurn })
            .selectedColor(ThemeColors.PRIMARY)
            .onChange((isOn: boolean) => {
              this.deviceController.setVolumeKeyPageTurn(isOn);
              void this.settings.setVolumeKeyPageTurn(isOn);
            })
        }
        .width('100%')
        .constraintSize({ minHeight: READER_HUD_BACK_TARGET_VP })
        .alignItems(VerticalAlign.Center)

        Row() {
          Text(this.lm.getLocalizedString(
            $r('app.string.reader_double_tap_zoom'),
            '双击缩放',
            '雙擊縮放',
            'Double-Tap to Zoom'
          ))
            .fontSize(14)
            .fontColor(ThemeColors.TEXT_STRONG)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.settings.doubleTapZoomEnabled })
            .selectedColor(ThemeColors.PRIMARY)
            .onChange((isOn: boolean) => {
              const prev: boolean = this.settings.doubleTapZoomEnabled;
              if (isOn === prev) {
                return;
              }
              void this.settings.setDoubleTapZoomEnabled(isOn);
              if (isOn) {
                this.showReaderToast(
                  this.lm.getLocalizedString(
                    $r('app.string.reader_double_tap_zoom_delay_hint'),
                    '已开启双击缩放，呼出菜单可能会有轻微延迟',
                    '已開啟雙擊縮放，呼出選單可能會有輕微延遲',
                    'Double-tap zoom enabled; opening the menu may have a slight delay'
                  )
                );
              }
            })
        }
        .width('100%')
        .constraintSize({ minHeight: READER_HUD_BACK_TARGET_VP })
        .alignItems(VerticalAlign.Center)

        Row() {
          Text(this.lm.getLocalizedString(
            $r('app.string.reader_page_turn_animation'),
            '翻页动画',
            '翻頁動畫',
            'Page-Turn Animation'
          ))
            .fontSize(14)
            .fontColor(ThemeColors.TEXT_STRONG)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.settings.pageTurnAnimationEnabled })
            .selectedColor(ThemeColors.PRIMARY)
            .onChange((isOn: boolean) => {
              if (isOn === this.settings.pageTurnAnimationEnabled) {
                return;
              }
              void this.settings.setPageTurnAnimationEnabled(isOn);
            })
        }
        .width('100%')
        .constraintSize({ minHeight: READER_HUD_BACK_TARGET_VP })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({
        left: 18,
        right: 18,
        top: 14,
        bottom: computeReaderHudInsets(this.topAvoidVp, this.bottomAvoidVp).bottomVp + 18
      })
      .backgroundColor(this.theme.isDark ? '#1E2028' : '#FFFFFF')
      .border({
        width: { top: 1 },
        color: this.theme.isDark ? '#2E323D' : '#E2E8F0'
      })
      .borderRadius({ topLeft: 22, topRight: 22 })
      .systemMaterial(this.panelMaterial)
      .clip(true)
      .transition(spatialSheetTransition(TransitionEdge.BOTTOM))
    }
    .width('100%')
    .height('100%')
    .zIndex(20)
  }

  @Monitor('theme.isDark')
  onThemeModeChanged(): void {
    this.syncSystemBarTheme();
  }

  private syncSystemBarTheme(): void {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    const dark: boolean = this.theme.isDark;
    window.getLastWindow(context)
      .then((win: window.Window) => {
        const barProps: window.SystemBarProperties = {
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          statusBarContentColor: resolveReaderStatusBarContentColor(dark),
          isStatusBarLightIcon: dark,
          isNavigationBarLightIcon: dark
        };
        return win.setWindowSystemBarProperties(barProps);
      })
      .catch((_err: BusinessError) => {
        // ignore
      });
  }

  private setSystemBarsVisible(visible: boolean): void {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      Logger.error(TAG, '获取 UI 上下文失败，无法控制系统栏');
      return;
    }
    const dark: boolean = this.theme.isDark;
    window.getLastWindow(context)
      .then((win: window.Window) => {
        const barProps: window.SystemBarProperties = {
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          statusBarContentColor: resolveReaderStatusBarContentColor(dark),
          isStatusBarLightIcon: dark,
          isNavigationBarLightIcon: dark
        };
        void win.setWindowSystemBarProperties(barProps);
        if (visible) {
          return win.setWindowSystemBarEnable(['status', 'navigation']);
        }
        return win.setWindowSystemBarEnable([]);
      })
      .then(() => {
        Logger.debug(TAG, visible ? '系统栏已恢复' : '系统栏已隐藏（沉浸阅读）');
      })
      .catch((err: BusinessError) => {
        Logger.error(TAG, `系统栏控制失败: ${err.code} - ${err.message}`);
      });
  }
}

@Builder
export function ComicReaderBuilder(name: string, param?: object) {
  if (param instanceof ComicReaderParam) {
    ComicReader({ param: param })
  } else if (param !== undefined) {
    ComicReader({ param: new ComicReaderParam('', String(param), '') })
  }
}
