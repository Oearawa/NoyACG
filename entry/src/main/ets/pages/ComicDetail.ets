import { HdsNavDestination } from '@kit.UIDesignKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { curves, uiMaterial } from '@kit.ArkUI';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
/**
 * ComicDetail.ets —— 漫画详情页（Stage / 状态管理 V2 · StandardPageScaffold 统一骨架）
 *
 * 布局模式：
 * - < 600vp（竖屏单栏）：单个 List 依次承载 DetailHeader + 相关推荐 + ChapterSection + CommentSection。
 * - >= 600vp（横屏/平板双栏）：左侧固定可滚动 DetailHeader，右侧独立滚动 List 承载推荐/章节/评论。
 *
 * 数据真实性：所有展示字段均来自 ComicDetailViewModel 与首方详情分包，不编造不存在的评论提交等接口。
 * 收藏（I-000002）：进入/重进页面时以只读 /get 校准，toggle 写路径失败回滚。
 */
import { ComicDetailViewModel, DetailState } from '../viewmodel/ComicDetailViewModel';
import { ComicDetail as ComicDetailModel } from '../model/ComicDetail';
import { ComicReaderParam } from '../model/ReaderParam';
import { BookRecommend } from '../model/BookRecommend';
import { ViewportState } from '../utils/ViewportState';
import { ResponsiveLayoutMetrics, resolveLayoutPolicy } from '../responsive/LayoutPolicy';
import { Logger } from '../utils/Logger';
import { MangaImage } from '../components/MangaImage';
import { StandardPageScaffold } from '../components/StandardPageScaffold';
import { DetailHeader } from '../components/detail/DetailHeader';
import { ChapterSection } from '../components/detail/ChapterSection';
import { CommentSection } from '../components/detail/CommentSection';
import { ThemeColors, ThemeDims } from '../utils/Theme';
import { ThemeManager } from '../utils/ThemeManager';
import {
  SPATIAL_PRESS_SCALE,
  resolvePanelMaterialTokens,
  resolveSettingsPillBorderColor,
  resolveSettingsPillSurfaceColor
} from '../utils/MaterialPolicy';
import {
  buildPanelImmersiveMaterial,
  buildPillImmersiveMaterial
} from '../utils/ImmersiveMaterial';
import { spatialDialogTransition } from '../utils/ImmersiveMotion';
import {
  DETAIL_LEFT_PANE_WIDTH,
  DETAIL_RIGHT_PANE_WIDTH,
  RECOMMEND_CARD_WIDTH_VP,
  RECOMMEND_COVER_HEIGHT_VP,
  RECOMMEND_TITLE_GAP_VP,
  detailBottomInsetVp,
  detailUseTwoPane
} from '../utils/ComicDetailLayout';
import { ComicBadgeOverlay } from '../components/ComicBadgeOverlay';
import { parseTagList } from '../utils/BlockedTags';
import { RatingBridge } from '../utils/RatingBridge';
import { LocalizationManager } from '../utils/LocalizationManager';
import { cardPressOpacity, cardPressScale, cardSpringCurve } from '../utils/SpringMotion';

const TAG: string = 'ComicDetail';

@ComponentV2
export struct ComicDetail {
  /** 路由参数：漫画 id（由 ComicDetailBuilder 从 pushPathByName 的 param 转交） */
  @Require @Param comicId: string;
  /** 全局路由栈：返回 / 跳转阅读器 / 登录页 */
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  /** 视图模型 */
  @Local vm: ComicDetailViewModel = new ComicDetailViewModel();
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();
  /** 容器实测宽度（vp） */
  @Local containerWidth: number = 0;
  /** 统一响应式布局策略（主依据窗口宽度四档断点） */
  @Local layout: ResponsiveLayoutMetrics = ViewportState.getInstance().getLayoutPolicy();
  /** 是否真横屏双栏（仅 widthVp > heightVp && widthVp >= 600vp 时为 true） */
  @Local isTwoPane: boolean = detailUseTwoPane(
    ViewportState.getInstance().widthVp, ViewportState.getInstance().heightVp);
  /** 底部安全区高度（vp） */
  @Local bottomAvoidVp: number = ViewportState.getInstance().bottomVp;
  /** 顶栏按压反馈标记 */
  @Local private pressedTopAction: string = '';
  /** 相关推荐卡片按压反馈标记 */
  @Local private pressedRecBid: string = '';
  /** 分享弹窗显隐 */
  @Local showShareDialog: boolean = false;
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  private readonly pillMaterial: uiMaterial.Material | undefined = buildPillImmersiveMaterial();
  private readonly panelMaterial: uiMaterial.Material | undefined = buildPanelImmersiveMaterial();

  private readonly syncViewport = (): void => {
    const vp: ViewportState = ViewportState.getInstance();
    const targetW: number = this.containerWidth > 0 ? this.containerWidth : vp.widthVp;
    this.layout = resolveLayoutPolicy(targetW, vp.isLandscape());
    const winW: number = vp.widthVp > 0 ? vp.widthVp : this.containerWidth;
    const winH: number = vp.heightVp > 0 ? vp.heightVp : 844;
    const nextTwoPane: boolean = detailUseTwoPane(winW, winH);
    if (nextTwoPane !== this.isTwoPane) {
      this.isTwoPane = nextTwoPane;
    }
    if (Math.abs(vp.bottomVp - this.bottomAvoidVp) >= 0.01) {
      this.bottomAvoidVp = vp.bottomVp;
    }
  };

  /** 内容分级变化订阅（Phase 14-T）：用原 comicId 重取详情，相关推荐随详情一起更新 */
  private ratingBridge: RatingBridge = new RatingBridge((): void => {
    this.vm.refreshForRating();
  });

  aboutToAppear(): void {
    this.vm.activate();
    this.ratingBridge.start();
    ViewportState.getInstance().addListener(this.syncViewport);
    this.syncViewport();
  }

  aboutToDisappear(): void {
    ViewportState.getInstance().removeListener(this.syncViewport);
    this.ratingBridge.stop();
    this.vm.dispose();
  }

  build() {
    HdsNavDestination() {
      Stack() {
        StandardPageScaffold({
          title: this.vm.detail === null
            ? this.lm.getString($r('app.string.detail_title'), '漫画详情')
            : this.vm.detail.title,
          transparentHeader: true,
          isLoading: this.vm.state === DetailState.IDLE || this.vm.state === DetailState.LOADING,
          hasContent: this.vm.state === DetailState.SUCCESS || this.vm.state === DetailState.AUTH_REQUIRED,
          isEmpty: this.vm.state === DetailState.EMPTY,
          errorTitle: this.lm.getString($r('app.string.detail_load_failed'), '详情加载失败'),
          errorMessage: this.vm.state === DetailState.ERROR
            ? (this.vm.errorMessage === ''
              ? this.lm.getString($r('app.string.detail_check_network'), '请检查网络后重试')
              : this.vm.errorMessage)
            : '',
          emptyTitle: this.lm.getString($r('app.string.detail_no_chapters'), '暂无章节'),
          emptyMessage: this.lm.getString(
            $r('app.string.detail_no_chapters_msg'),
            '服务端未返回章节目录，且未标明为单本作品。请稍后重试。'
          ),
          maxContentWidth: this.isTwoPane ? 0 : ThemeDims.CONTENT_MAX_WIDTH,
          onWidthMeasured: (w: number): void => {
            this.containerWidth = w;
            this.syncViewport();
          },
          onBack: (): void => {
            this.pageStack.pop();
          },
          onRetry: (): void => {
            this.vm.retry();
          },
          rightAction: (): void => {
            this.DetailTopActions();
          },
          content: (): void => {
            this.DetailContent();
          }
        })

        if (this.showShareDialog) {
          this.ShareDialogOverlay()
        }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .withTheme({ enableThemeColorMode: true })
    .backgroundColor(ThemeColors.BG)
    .onBackPressed((): boolean => {
      if (this.showShareDialog) {
        this.showShareDialog = false;
        return true;
      }
      return false;
    })
    .onReady(() => {
      Logger.info(TAG, `onReady, comicId=${this.comicId}`);
      if (!this.vm.reloadIfRatingChanged()) {
        this.vm.loadDetail(this.comicId);
      }
    })
    .onShown(() => {
      this.ratingBridge.start();
      this.vm.activate();
      this.vm.reloadIfRatingChanged();
      this.vm.resyncFavoriteOnReentry();
      void this.vm.resyncProgressAndDownloadsOnReentry();
    })
    .onHidden(() => {
      this.ratingBridge.stop();
    })
  }

  @Builder
  DetailContent() {
    Column({ space: 0 }) {
      if (this.vm.state === DetailState.AUTH_REQUIRED) {
        this.AuthRequiredView()
      } else if (this.vm.detail !== null) {
        if (this.vm.downloadNotice !== '') {
          Text(this.vm.downloadNotice)
            .fontSize(12)
            .fontColor(ThemeColors.PRIMARY)
            .width('100%')
            .padding({ left: 16, right: 16, top: 6, bottom: 6 })
            .backgroundColor(ThemeColors.SURFACE_PRIMARY)
        }
        this.ResponsiveDetailBody(this.vm.detail)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 登录失效：独立状态，明确引导登录，不并入普通网络错误 */
  @Builder
  AuthRequiredView() {
    Column({ space: 12 }) {
      Text($r('app.string.detail_need_login'))
        .fontSize(16)
        .fontColor(ThemeColors.TEXT)
      Text(this.vm.errorMessage === ''
        ? this.lm.getString($r('app.string.detail_need_login_msg'), '会话已失效或未登录，登录后可查看详情与章节')
        : this.vm.errorMessage)
        .fontSize(12)
        .fontColor(ThemeColors.TEXT_SECONDARY)
        .textAlign(TextAlign.Center)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Row({ space: 10 }) {
        Button($r('app.string.common_go_login'))
          .backgroundColor(ThemeColors.PRIMARY)
          .fontColor(ThemeColors.BG)
          .onClick(() => {
            this.pageStack.pushPathByName('LoginPage', null);
          })
        Button($r('app.string.common_retry'))
          .backgroundColor(ThemeColors.SURFACE)
          .fontColor(ThemeColors.TEXT)
          .onClick(() => {
            this.vm.retry();
          })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 32, right: 32 })
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1800 });
    } catch (e) {
      Logger.warn(TAG, `Toast 展示失败: ${(e as Error).message}`);
    }
  }

  private copyToPasteboard(text: string): boolean {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setDataSync(data);
      return true;
    } catch (e) {
      Logger.warn(TAG, `剪贴板写入失败: ${(e as Error).message}`);
      return false;
    }
  }

  private handleTopDownload(): void {
    const detail: ComicDetailModel | null = this.vm.detail;
    if (detail === null) {
      return;
    }
    if (this.vm.isAllChaptersDownloaded()) {
      this.showToast(this.lm.getString($r('app.string.detail_all_offline'), '已全部离线下载'));
      return;
    }
    void this.vm.downloadAllMissingChapters();
    this.showToast(this.lm.getString($r('app.string.detail_added_offline'), '已加入离线下载'));
  }

  private async handleSystemShare(): Promise<void> {
    const detail: ComicDetailModel | null = this.vm.detail;
    const title: string = detail === null ? 'NoyAcg' : detail.title;
    const shareText: string = ComicDetailViewModel.buildShareText(title, this.comicId);
    this.showShareDialog = false;
    try {
      const shareData: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.PLAIN_TEXT,
        content: shareText,
        title: title
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(shareData);
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await controller.show(context, {
        previewMode: systemShare.SharePreviewMode.DEFAULT,
        selectionMode: systemShare.SelectionMode.SINGLE
      });
    } catch (e) {
      Logger.warn(TAG, `系统分享拉起失败，降级复制文本: ${(e as Error).message}`);
      this.copyToPasteboard(shareText);
      this.showToast(this.lm.getString($r('app.string.detail_copied_share'), '已复制分享内容'));
    }
  }

  @Builder
  DetailTopActions() {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.arrow_down_to_line'))
          .fontSize(19)
          .fontColor([this.vm.isAllChaptersDownloaded()
            ? ThemeColors.PRIMARY
            : ThemeColors.TEXT_STRONG])
      }
      .width(38)
      .height(38)
      .buttonStyle(ButtonStyleMode.NORMAL)
      .backgroundColor(resolveSettingsPillSurfaceColor(this.theme.isDark, this.pressedTopAction === 'download'))
      .border({
        width: 1,
        color: resolveSettingsPillBorderColor(this.theme.isDark)
      })
      .systemMaterial(this.pillMaterial)
      .scale({
        x: this.pressedTopAction === 'download' ? SPATIAL_PRESS_SCALE : 1.0,
        y: this.pressedTopAction === 'download' ? SPATIAL_PRESS_SCALE : 1.0
      })
      .animation({ curve: curves.springMotion(0.24, 0.82) })
      .accessibilityText(this.lm.getString($r('app.string.detail_action_download'), '下载'))
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressedTopAction = 'download';
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressedTopAction = '';
        }
      })
      .onClick(() => {
        this.handleTopDownload();
      })

      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.share'))
          .fontSize(19)
          .fontColor([ThemeColors.TEXT_STRONG])
      }
      .width(38)
      .height(38)
      .buttonStyle(ButtonStyleMode.NORMAL)
      .backgroundColor(resolveSettingsPillSurfaceColor(this.theme.isDark, this.pressedTopAction === 'share'))
      .border({
        width: 1,
        color: resolveSettingsPillBorderColor(this.theme.isDark)
      })
      .systemMaterial(this.pillMaterial)
      .scale({
        x: this.pressedTopAction === 'share' ? SPATIAL_PRESS_SCALE : 1.0,
        y: this.pressedTopAction === 'share' ? SPATIAL_PRESS_SCALE : 1.0
      })
      .animation({ curve: curves.springMotion(0.24, 0.82) })
      .accessibilityText(this.lm.getString($r('app.string.detail_action_share'), '分享'))
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressedTopAction = 'share';
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressedTopAction = '';
        }
      })
      .onClick(() => {
        this.showShareDialog = true;
      })
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  ShareDialogOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#73000000')
        .transition(TransitionEffect.OPACITY.animation({ duration: 180 }))
        .onClick(() => {
          this.showShareDialog = false;
        })

      Column({ space: 8 }) {
        Text('Share')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.TEXT_STRONG)
          .width('100%')
          .padding({ bottom: 4 })

        this.ShareOptionRow(
          this.lm.getString($r('app.string.detail_share_copy_link'), '复制 Link'),
          $r('sys.symbol.link'),
          (): void => {
            this.copyToPasteboard(ComicDetailViewModel.buildShareLink(this.comicId));
            this.showShareDialog = false;
            this.showToast(this.lm.getString($r('app.string.detail_copied_link'), '已复制链接'));
          }
        )

        this.ShareOptionRow(
          this.lm.getString($r('app.string.detail_share_copy_nid'), '复制 NID'),
          $r('sys.symbol.doc_plaintext'),
          (): void => {
            this.copyToPasteboard(this.comicId);
            this.showShareDialog = false;
            this.showToast(this.lm.getString($r('app.string.detail_copied_nid'), '已复制 NID'));
          }
        )

        this.ShareOptionRow(
          this.lm.getString($r('app.string.detail_share_more_apps'), '其他应用'),
          $r('sys.symbol.share'),
          (): void => {
            void this.handleSystemShare();
          }
        )

        Row() {
          Blank()
          Text($r('app.string.common_cancel'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.PRIMARY)
            .padding({ left: 14, right: 8, top: 8, bottom: 4 })
            .onClick(() => {
              this.showShareDialog = false;
            })
        }
        .width('100%')
      }
      .width(296)
      .padding({ left: 20, right: 20, top: 18, bottom: 14 })
      .borderRadius(20)
      .backgroundColor(this.theme.isDark ? '#1E2028' : '#FFFFFF')
      .border({
        width: 1,
        color: this.theme.isDark ? '#2E323D' : '#E2E8F0'
      })
      .shadow({
        radius: resolvePanelMaterialTokens(this.theme.isDark).shadowRadius,
        color: resolvePanelMaterialTokens(this.theme.isDark).shadowColor,
        offsetX: 0,
        offsetY: 12
      })
      .systemMaterial(this.panelMaterial)
      .clip(true)
      .transition(spatialDialogTransition())
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  ShareOptionRow(label: string, icon: Resource, action: () => void) {
    Row({ space: 12 }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([ThemeColors.TEXT_SECONDARY])
      Text(label)
        .fontSize(15)
        .fontColor(ThemeColors.TEXT_STRONG)
        .layoutWeight(1)
    }
    .width('100%')
    .height(44)
    .padding({ left: 10, right: 10 })
    .borderRadius(12)
    .backgroundColor(resolveSettingsPillSurfaceColor(this.theme.isDark, false))
    .border({
      width: 1,
      color: resolveSettingsPillBorderColor(this.theme.isDark)
    })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      action();
    })
  }

  @Builder
  RatingCard(detail: ComicDetailModel, embedded: boolean = false) {
    Column({ space: 8 }) {
      Text(this.vm.userRatingStars > 0
        ? ComicDetailViewModel.ratingLabelForStars(this.vm.userRatingStars, this.lm.effectiveLocale)
        : (detail.rating >= 8.5
          ? this.lm.getString($r('app.string.detail_rating_5'), '非常好')
          : this.lm.getString($r('app.string.detail_rating_tap'), '点击星星评分')))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.isDark ? '#F8FAFC' : '#1E2430')

      Row({ space: 10 }) {
        ForEach([1, 2, 3, 4, 5], (star: number) => {
          SymbolGlyph(this.isStarActive(detail, star) ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
            .fontSize(28)
            .fontColor([this.isStarActive(detail, star) ? ThemeColors.RATING : '#94A3B8'])
            .padding(4)
            .onClick(() => {
              this.vm.submitRating(star);
              if (this.vm.ratingNotice !== '') {
                this.showToast(this.vm.ratingNotice);
              }
            })
        }, (star: number) => `${star}`)
      }
      .alignItems(VerticalAlign.Center)

      Text(`${Math.max(detail.ratingCount, 0)} 人已评分`)
        .fontSize(12)
        .fontColor(this.theme.isDark ? '#94A3B8' : '#64748B')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 14, bottom: 14, left: 16, right: 16 })
    .borderRadius(embedded ? 0 : 14)
    .backgroundColor(embedded ? Color.Transparent : ThemeColors.CARD)
    .margin(embedded ? { top: 0, bottom: 0 } : { left: 16, right: 16, top: 8, bottom: 4 })
  }

  private isStarActive(detail: ComicDetailModel, star: number): boolean {
    const active: number = this.vm.userRatingStars > 0
      ? this.vm.userRatingStars
      : (detail.rating >= 0 ? Math.round(detail.rating / 2) : 0);
    return star <= active;
  }

  @Builder
  MainInfoCard(detail: ComicDetailModel) {
    Column({ space: 0 }) {
      DetailHeader({
        detail: detail,
        vm: this.vm,
        compactCover: false,
        inCard: true,
        onOpenReader: (param: ComicReaderParam | null): void => {
          this.openReader(param);
        }
      })
      Divider()
        .color(this.theme.isDark ? '#2E323D' : '#E2E8F0')
        .strokeWidth(1)
        .margin({ left: 16, right: 16 })
      this.RatingCard(detail, true)
    }
    .width('100%')
    .borderRadius(16)
    .backgroundColor(this.theme.isDark ? '#1C1E24' : '#FFFFFF')
    .border({ width: 1, color: this.theme.isDark ? '#2E323D' : '#E2E8F0' })
    .clip(true)
  }

  @Builder
  DetailSectionsColumn(detail: ComicDetailModel) {
    Column({ space: 12 }) {
      Column() {
        ChapterSection({
          detail: detail,
          vm: this.vm,
          onOpenReader: (param: ComicReaderParam | null): void => {
            this.openReader(param);
          }
        })
      }
      .width('100%')
      .padding({ top: 6, bottom: 10 })
      .borderRadius(16)
      .backgroundColor(this.theme.isDark ? '#1C1E24' : '#FFFFFF')
      .border({ width: 1, color: this.theme.isDark ? '#2E323D' : '#E2E8F0' })
      .clip(true)

      if (detail.recommend.length > 0) {
        Column() {
          this.RecommendSection(detail)
        }
        .width('100%')
        .padding({ bottom: 12 })
        .borderRadius(16)
        .backgroundColor(this.theme.isDark ? '#1C1E24' : '#FFFFFF')
        .border({ width: 1, color: this.theme.isDark ? '#2E323D' : '#E2E8F0' })
        .clip(true)
      }

      Column() {
        CommentSection({ detail: detail, vm: this.vm })
      }
      .width('100%')
      .padding({ bottom: 10 })
      .borderRadius(16)
      .backgroundColor(this.theme.isDark ? '#1C1E24' : '#FFFFFF')
      .border({ width: 1, color: this.theme.isDark ? '#2E323D' : '#E2E8F0' })
      .clip(true)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 统一响应式主体：仅真横屏宽屏（widthVp > heightVp && widthVp >= 600）启用 42% / 58% 双栏卡片，竖屏/折叠屏竖屏均采用单栏流式卡片 */
  @Builder
  ResponsiveDetailBody(detail: ComicDetailModel) {
    if (this.isTwoPane) {
      Row({ space: 0 }) {
        // 左栏（42%）：主信息与评分圆角卡片
        Scroll() {
          Column({ space: 0 }) {
            this.MainInfoCard(detail)

            Column()
              .width('100%')
              .height(detailBottomInsetVp(this.bottomAvoidVp))
          }
          .width('100%')
          .padding({ top: 12 })
          .alignItems(HorizontalAlign.Start)
        }
        .width(DETAIL_LEFT_PANE_WIDTH)
        .height('100%')
        .padding({ right: 6 })
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)

        // 右栏（58%）：单一完整 Scroll 包裹目录 / 推荐 / 评论三张卡片，滚动顺滑一体
        Scroll() {
          Column({ space: 0 }) {
            this.DetailSectionsColumn(detail)

            Column()
              .width('100%')
              .height(detailBottomInsetVp(this.bottomAvoidVp))
          }
          .width('100%')
          .padding({ top: 12 })
          .alignItems(HorizontalAlign.Start)
        }
        .width(DETAIL_RIGHT_PANE_WIDTH)
        .height('100%')
        .padding({ left: 6 })
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16 })
      .backgroundColor(this.theme.isDark ? '#121214' : '#F4F5F8')
      .alignItems(VerticalAlign.Top)
    } else {
      Scroll() {
        Column({ space: 12 }) {
          this.MainInfoCard(detail)
          this.DetailSectionsColumn(detail)

          Column()
            .width('100%')
            .height(detailBottomInsetVp(this.bottomAvoidVp))
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(this.theme.isDark ? '#121214' : '#F4F5F8')
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  /** 相关推荐：固定封面容器高度（coverFill=true），消除图文空白断层 */
  @Builder
  RecommendSection(detail: ComicDetailModel) {
    Column({ space: 0 }) {
      Text($r('app.string.detail_recommended'))
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemeColors.TEXT)
        .margin({ left: 16, right: 16, top: 12, bottom: 8 })
      Scroll() {
        Row({ space: 10 }) {
          ForEach(detail.recommend, (rec: BookRecommend) => {
            Column({ space: 0 }) {
              Stack({ alignContent: Alignment.TopStart }) {
                MangaImage({ imageUrl: rec.cover, coverFill: true })
                ComicBadgeOverlay({ isCompleted: null, tags: parseTagList(rec.tags) })
              }
              .width(RECOMMEND_CARD_WIDTH_VP)
              .height(RECOMMEND_COVER_HEIGHT_VP)
              .borderRadius(6)
              .clip(true)
              .backgroundColor(ThemeColors.SURFACE)

              Text(rec.title)
                .fontSize(12)
                .lineHeight(16)
                .fontColor(ThemeColors.TEXT)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width(RECOMMEND_CARD_WIDTH_VP)
                .margin({ top: RECOMMEND_TITLE_GAP_VP })
            }
            .width(RECOMMEND_CARD_WIDTH_VP)
            .alignItems(HorizontalAlign.Start)
            .scale({
              x: cardPressScale(this.pressedRecBid === rec.bid),
              y: cardPressScale(this.pressedRecBid === rec.bid)
            })
            .opacity(cardPressOpacity(this.pressedRecBid === rec.bid))
            .animation({ curve: cardSpringCurve() })
            .onTouch((event: TouchEvent): void => {
              if (event.type === TouchType.Down) {
                this.pressedRecBid = rec.bid;
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                if (this.pressedRecBid === rec.bid) {
                  this.pressedRecBid = '';
                }
              }
            })
            .onClick(() => {
              this.pageStack.pushPathByName('ComicDetail', rec.bid);
            })
          }, (rec: BookRecommend) => rec.bid)
        }
        .padding({ left: 16, right: 16 })
        .alignItems(VerticalAlign.Top)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 统一跳转阅读器：参数由 VM 生成，页面不自行拼装章节标识 */
  private openReader(param: ComicReaderParam | null): void {
    if (param === null) {
      Logger.warn(TAG, '阅读器参数无效，已忽略跳转');
      return;
    }
    this.pageStack.pushPathByName('ComicReader', param);
  }
}

/**
 * 系统路由表构建函数：与 route_map.json 中
 * "buildFunction": "ComicDetailBuilder" 一一对应。
 * 直接渲染页面组件（其根节点已是 NavDestination），不包外层。
 */
@Builder
export function ComicDetailBuilder(name: string, param?: object) {
  ComicDetail({ comicId: param === undefined ? '' : String(param) })
}
