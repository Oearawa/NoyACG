/**
 * SearchPage.ets —— 全局搜索页（响应式重构版）
 *
 * - 横屏/宽屏（isInlineHeader）：单行顶栏（< 搜索 | 自适应搜索胶囊 minWidth 180vp | 紧凑筛选胶囊）
 * - 竖屏（!isInlineHeader）：< 搜索 + 三层光感搜索胶囊行 + 筛选胶囊栏（含重置）
 * - 搜索发现态：搜索历史（清空确认 + 单条删除）+ 热门搜索/推荐标签（前 3 序号角标）
 * - 结果态：统计提示栏 + 横向图文信息卡（ComicListItem + .lanes() 多列）+ 悬浮 PaginationBar
 */
import { HdsNavDestination } from '@kit.UIDesignKit';
import { uiMaterial } from '@kit.ArkUI';
import { Comic } from '../model/Comic';
import { SearchParam, SEARCH_MODE_DEFAULT } from '../model/NavParams';
import {
  SEARCH_SORT_DEFAULT,
  SEARCH_SORT_VIEWS,
  SEARCH_SORT_FAVORITES,
  SEARCH_SORT_RATING,
  SEARCH_TYPE_DEFAULT,
  SEARCH_TYPE_BOOK,
  SEARCH_TYPE_STREAM,
  SEARCH_FINISHED_ALL,
  SEARCH_FINISHED_COMPLETED,
  SEARCH_FINISHED_ONGOING
} from '../source/NoyAcgSource';
import { SearchViewModel } from '../viewmodel/SearchViewModel';
import { ComicListItem } from '../components/ComicListItem';
import { CapsuleSelect } from '../components/CapsuleSelect';
import { PaginationBar } from '../components/PaginationBar';
import { StandardPageScaffold } from '../components/StandardPageScaffold';
import { shouldScrollFilterBar } from '../utils/StandardScaffoldLayout';
import { ThemeManager } from '../utils/ThemeManager';
import { LocalizationManager } from '../utils/LocalizationManager';
import { buildPillImmersiveMaterial } from '../utils/ImmersiveMaterial';
import {
  resolveGlassCapsuleBorderColor,
  resolveGlassCapsuleShadowColor,
  resolveGlassCapsuleTintColor,
  resolveSettingsPillBorderColor,
  resolveSettingsPillSurfaceColor
} from '../utils/MaterialPolicy';
import { ViewportState } from '../utils/ViewportState';
import { ResponsiveLayoutMetrics, resolveLayoutPolicy } from '../responsive/LayoutPolicy';
import { ThemeColors, ThemeDims } from '../utils/Theme';
import { PreferenceManager } from '../utils/PreferenceManager';
import { Logger } from '../utils/Logger';
import { WindowSizeClass, classifyWidth } from '../utils/WindowClass';
import { prefetchComicsAround, cancelPrefetch } from '../utils/ImagePrefetch';
import { RatingBridge } from '../utils/RatingBridge';
import {
  formatSearchResultSummary,
  hasActiveSearchFilters,
  isSearchInlineHeader,
  mergeHotSearchTags,
  searchResultBottomInsetVp,
  shouldShowInlineSearchFilters,
  shouldShowStackedSearchFilters
} from '../utils/SearchLayoutHelper';

const TAG: string = 'SearchPage';

@ComponentV2
export struct SearchPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Param initialKeyword: string = '';
  @Param initialMode: string = SEARCH_MODE_DEFAULT;

  @Local vm: SearchViewModel = new SearchViewModel();
  @Local sortFilter: string = SEARCH_SORT_DEFAULT;
  @Local typeFilter: string = SEARCH_TYPE_DEFAULT;
  @Local finishedFilter: string = SEARCH_FINISHED_ALL;
  @Local layout: ResponsiveLayoutMetrics = ViewportState.getInstance().getLayoutPolicy();
  @Local columns: number = ViewportState.getInstance().getLayoutPolicy().listLanes;
  @Local containerWidth: number = ViewportState.getInstance().widthVp;
  @Local viewportHeightVp: number = ViewportState.getInstance().heightVp;
  @Local isExpanded: boolean = false;
  @Local private theme: ThemeManager = ThemeManager.getInstance();
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();

  private readonly pillMaterial: uiMaterial.Material | undefined = buildPillImmersiveMaterial();
  private settings: PreferenceManager = PreferenceManager.getInstance();

  private readonly syncViewport = (): void => {
    const vp: ViewportState = ViewportState.getInstance();
    const targetW: number = this.containerWidth > 0 ? this.containerWidth : vp.widthVp;
    const metrics: ResponsiveLayoutMetrics = resolveLayoutPolicy(targetW, vp.isLandscape());
    this.layout = metrics;
    if (metrics.listLanes !== this.columns) {
      this.columns = metrics.listLanes;
    }
    if (vp.heightVp > 0 && Math.abs(vp.heightVp - this.viewportHeightVp) >= 0.5) {
      this.viewportHeightVp = vp.heightVp;
    }
  };

  private effectiveWidth(): number {
    return this.containerWidth > 0 ? this.containerWidth : ViewportState.getInstance().widthVp;
  }

  private isInlineHeader(): boolean {
    return isSearchInlineHeader(this.effectiveWidth(), this.viewportHeightVp);
  }

  private hasSearchState(): boolean {
    return this.vm.hasSearched || this.vm.isSearching || this.vm.hasError || this.hasActiveFilters();
  }

  private hasActiveFilters(): boolean {
    return hasActiveSearchFilters(this.sortFilter, this.typeFilter, this.finishedFilter);
  }

  private ratingBridge: RatingBridge = new RatingBridge((): void => {
    this.vm.refreshForRating();
  });

  aboutToAppear(): void {
    this.syncViewport();
    ViewportState.getInstance().addListener(this.syncViewport);
    this.vm.activate();
    this.ratingBridge.start();
    const keyword: string = this.initialKeyword.trim();
    if (keyword !== '') {
      this.vm.applyInitialQuery(keyword, this.initialMode);
      this.settings.addSearchHistory(keyword).catch((e: Error) => {
        Logger.warn(TAG, `搜索历史写入失败: ${e.message}`);
      });
    } else {
      this.vm.reloadIfRatingChanged();
    }
  }

  aboutToDisappear(): void {
    ViewportState.getInstance().removeListener(this.syncViewport);
    this.ratingBridge.stop();
    cancelPrefetch('search');
    this.vm.dispose();
  }

  private dismissKeyboard(): void {
    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (_e) {
      // 忽略无焦点状态
    }
  }

  private handleClearInput(): void {
    this.vm.clearKeyword();
    this.sortFilter = SEARCH_SORT_DEFAULT;
    this.typeFilter = SEARCH_TYPE_DEFAULT;
    this.finishedFilter = SEARCH_FINISHED_ALL;
  }

  private handleResetFilters(): void {
    this.sortFilter = SEARCH_SORT_DEFAULT;
    this.typeFilter = SEARCH_TYPE_DEFAULT;
    this.finishedFilter = SEARCH_FINISHED_ALL;
    this.vm.resetFilters();
  }

  private confirmClearHistory(): void {
    this.getUIContext().showAlertDialog({
      title: this.lm.getString($r('app.string.search_clear_title'), '清空搜索历史'),
      message: this.lm.getString($r('app.string.search_clear_msg'), '确定清空全部历史搜索记录吗？'),
      autoCancel: true,
      primaryButton: {
        value: this.lm.getString($r('app.string.common_cancel'), '取消'),
        action: (): void => {}
      },
      secondaryButton: {
        value: this.lm.getString($r('app.string.common_clear'), '清空'),
        fontColor: ThemeColors.ERROR,
        action: (): void => {
          this.settings.clearSearchHistory().catch((e: Error) => {
            Logger.warn(TAG, `清空搜索历史失败: ${e.message}`);
          });
        }
      }
    });
  }

  private doSubmit(value: string): void {
    const text: string = value.trim();
    this.dismissKeyboard();
    this.vm.submit();
    if (text === '') {
      return;
    }
    this.settings.addSearchHistory(text).catch((e: Error) => {
      Logger.warn(TAG, `搜索历史写入失败: ${e.message}`);
    });
  }

  private searchTag(tag: string): void {
    const clean: string = tag.trim();
    if (clean === '') {
      return;
    }
    this.vm.keyword = clean;
    this.doSubmit(clean);
  }

  private bottomListInset(): number {
    return searchResultBottomInsetVp(this.vm.totalPages, ViewportState.getInstance().bottomVp);
  }

  build() {
    HdsNavDestination() {
      StandardPageScaffold({
        title: this.initialMode === 'tag' && this.initialKeyword.trim() !== ''
          ? this.initialKeyword.trim()
          : this.lm.getString($r('app.string.search_title'), '搜索'),
        inlineHeaderCenter: this.isInlineHeader(),
        showHeaderBottom: !this.isInlineHeader(),
        isLoading: this.vm.isSearching && this.vm.isEmpty,
        hasContent: !this.vm.hasSearched || !this.vm.isEmpty,
        isEmpty: this.vm.hasSearched && this.vm.isEmpty,
        errorMessage: this.vm.hasError
          ? (this.vm.errorMessage === '' ? '请检查网络后重试' : this.vm.errorMessage)
          : '',
        errorTitle: this.vm.needsLogin
          ? this.lm.getString($r('app.string.search_need_login'), '需要登录 NoyAcg')
          : this.lm.getString($r('app.string.search_failed'), '搜索失败'),
        emptyIcon: $r('sys.symbol.magnifyingglass'),
        emptyTitle: this.lm.getString($r('app.string.search_empty'), '没有找到相关漫画'),
        emptyMessage: `${this.vm.keyword.trim()}`,
        showSecondaryAction: this.vm.needsLogin || this.hasActiveFilters(),
        secondaryActionText: this.vm.needsLogin
          ? this.lm.getString($r('app.string.common_go_login'), '去登录')
          : this.lm.getString($r('app.string.search_reset_filter'), '重置筛选'),
        onRetry: (): void => {
          this.vm.retry();
        },
        onSecondaryAction: (): void => {
          if (this.vm.needsLogin) {
            this.pageStack.pushPathByName('LoginPage', null);
          } else {
            this.handleResetFilters();
          }
        },
        onWidthMeasured: (w: number): void => {
          this.isExpanded = classifyWidth(w) === WindowSizeClass.EXPANDED;
          this.containerWidth = w;
          this.syncViewport();
        },
        headerCenter: () => {
          if (this.isInlineHeader()) {
            this.InlineSearchHeader()
          }
        },
        rightAction: () => {
          if (shouldShowInlineSearchFilters(
            this.effectiveWidth(),
            this.viewportHeightVp,
            this.hasSearchState()
          )) {
            this.FilterBarSelects(true)
          }
        },
        headerBottom: () => {
          if (!this.isInlineHeader()) {
            this.SearchHeader()
          }
        },
        content: () => {
          this.SearchBody()
        }
      })
    }
    .withTheme({ enableThemeColorMode: true })
    .hideTitleBar(true)
    .onShown(() => {
      this.ratingBridge.start();
      if (!this.vm.reloadIfRatingChanged()) {
        this.vm.activate();
      }
    })
    .onHidden(() => {
      this.ratingBridge.stop();
    })
    .backgroundColor(ThemeColors.BG)
  }

  @Builder
  InlineSearchHeader() {
    Row() {
      this.SearchInputCapsule(true)
    }
    .width('100%')
    .constraintSize({ minWidth: 180 })
  }

  /** 三层沉浸光感搜索胶囊（支持横屏紧凑与竖屏完整双态） */
  @Builder
  SearchInputCapsule(compact: boolean) {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(compact ? 16 : 18)
        .fontColor([ThemeColors.TEXT_SECONDARY])

      TextInput({ placeholder: this.lm.getString($r('app.string.search_placeholder'), '搜索漫画标题 / 作者 / 标签'), text: this.vm.keyword })
        .layoutWeight(1)
        .height(compact ? 32 : 36)
        .fontSize(compact ? 13 : 14)
        .fontColor(ThemeColors.TEXT)
        .placeholderColor(ThemeColors.TEXT_MUTED)
        .backgroundColor(Color.Transparent)
        .padding({ left: 0, right: 0 })
        .enterKeyType(EnterKeyType.Search)
        .onChange((value: string) => {
          this.vm.onKeywordInput(value);
        })
        .onSubmit((_enterKey: EnterKeyType): void => {
          this.doSubmit(this.vm.keyword);
        })

      if (this.vm.keyword.length > 0) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
            .fontSize(17)
            .fontColor([ThemeColors.TEXT_MUTED])
        }
        .width(28)
        .height(28)
        .onClick((): void => {
          this.handleClearInput();
        })
      }

      if (!compact) {
        Text($r('app.string.common_search'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.ON_PRIMARY)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(14)
          .backgroundColor(ThemeColors.PRIMARY)
          .onClick((): void => {
            this.doSubmit(this.vm.keyword);
          })
      }
    }
    .width('100%')
    .height(compact ? 36 : 42)
    .padding({ left: 12, right: compact ? 8 : 6 })
    .borderRadius(compact ? 18 : 21)
    .backgroundColor(resolveGlassCapsuleTintColor(this.theme.isDark))
    .border({
      width: 1,
      color: resolveGlassCapsuleBorderColor(this.theme.isDark)
    })
    .shadow({
      radius: 12,
      color: resolveGlassCapsuleShadowColor(this.theme.isDark),
      offsetX: 0,
      offsetY: 3
    })
    .systemMaterial(this.pillMaterial)
  }

  @Builder
  SearchHeader() {
    Column({ space: 6 }) {
      this.SearchInputCapsule(false)
    }
    .width('100%')
    .constraintSize({ maxWidth: this.isExpanded ? ThemeDims.CONTENT_MAX_WIDTH : undefined })
    .alignSelf(ItemAlign.Center)
    .padding({ left: 16, right: 16, top: 2, bottom: 8 })
  }

  @Builder
  SearchBody() {
    if (!this.vm.hasSearched && !this.vm.isSearching && !this.vm.hasError) {
      this.DiscoveryView()
    } else {
      Column() {
        if (shouldShowStackedSearchFilters(
          this.effectiveWidth(),
          this.viewportHeightVp,
          this.hasSearchState()
        )) {
          this.FilterBar()
        }
        this.ResultView()
      }
      .width('100%')
      .layoutWeight(1)
    }
  }

  /** 搜索发现态：搜索历史 + 热门搜索标签 */
  @Builder
  DiscoveryView() {
    Scroll() {
      Column({ space: 20 }) {
        // 1. 搜索历史
        Column({ space: 10 }) {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.clock'))
              .fontSize(16)
              .fontColor([ThemeColors.TEXT_SECONDARY])
            Text($r('app.string.search_history'))
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(ThemeColors.TEXT)
            Blank()
            if (this.settings.searchHistory.length > 0) {
              Text($r('app.string.common_clear'))
                .fontSize(12)
                .fontColor(ThemeColors.TEXT_MUTED)
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(12)
                .backgroundColor(ThemeColors.SURFACE)
                .onClick((): void => {
                  this.confirmClearHistory();
                })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (this.settings.searchHistory.length === 0) {
            Text($r('app.string.search_history_empty'))
              .fontSize(12)
              .fontColor(ThemeColors.TEXT_MUTED)
              .padding({ top: 2, bottom: 4 })
          } else {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.settings.searchHistory, (item: string) => {
                Row({ space: 5 }) {
                  Text(item)
                    .fontSize(13)
                    .fontColor(ThemeColors.TEXT)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .constraintSize({ maxWidth: 200 })
                  SymbolGlyph($r('sys.symbol.xmark'))
                    .fontSize(11)
                    .fontColor([ThemeColors.TEXT_MUTED])
                    .padding(2)
                    .onClick((): void => {
                      this.settings.removeSearchHistory(item).catch((e: Error) => {
                        Logger.warn(TAG, `删除历史失败: ${e.message}`);
                      });
                    })
                }
                .padding({ left: 12, right: 8, top: 7, bottom: 7 })
                .backgroundColor(ThemeColors.CARD)
                .border({
                  width: 1,
                  color: resolveSettingsPillBorderColor(this.theme.isDark)
                })
                .borderRadius(16)
                .margin({ right: 8, bottom: 8 })
                .onClick((): void => {
                  this.searchTag(item);
                })
              }, (item: string): string => item)
            }
            .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // 2. 热门搜索 / 推荐标签
        Column({ space: 10 }) {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.flame'))
              .fontSize(16)
              .fontColor([ThemeColors.PRIMARY])
            Text($r('app.string.search_hot'))
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(ThemeColors.TEXT)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(mergeHotSearchTags([]), (tag: string, idx: number) => {
              Row({ space: 6 }) {
                if (idx < 3) {
                  Text(`${idx + 1}`)
                    .fontSize(11)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(ThemeColors.ON_PRIMARY)
                    .width(18)
                    .height(18)
                    .textAlign(TextAlign.Center)
                    .borderRadius(9)
                    .backgroundColor(ThemeColors.PRIMARY)
                }
                Text(tag)
                  .fontSize(13)
                  .fontWeight(idx < 3 ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(ThemeColors.TEXT)
              }
              .padding({ left: idx < 3 ? 8 : 12, right: 12, top: 7, bottom: 7 })
              .backgroundColor(resolveSettingsPillSurfaceColor(this.theme.isDark, false))
              .border({
                width: 1,
                color: resolveSettingsPillBorderColor(this.theme.isDark)
              })
              .borderRadius(16)
              .margin({ right: 8, bottom: 8 })
              .onClick((): void => {
                this.searchTag(tag);
              })
            }, (tag: string): string => `hot_${tag}`)
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ maxWidth: this.isExpanded ? ThemeDims.CONTENT_MAX_WIDTH : undefined })
      .padding({ left: 16, right: 16, top: 14, bottom: 24 })
    }
    .width('100%')
    .layoutWeight(1)
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .onScrollStart((): void => {
      this.dismissKeyboard();
    })
    .onTouch((e: TouchEvent): void => {
      if (e.type === TouchType.Down) {
        this.dismissKeyboard();
      }
    })
  }

  /** 结果区：统计栏 + 响应式横向图文信息卡列表 + 悬浮 PaginationBar */
  @Builder
  ResultView() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        // 轻量级结果统计栏
        Row({ space: 8 }) {
          Text(formatSearchResultSummary(
            this.vm.totalCount,
            this.vm.loadedCount,
            this.sortLabel(),
            this.typeLabel(),
            this.finishedLabel(),
            this.hasActiveFilters()
          ))
            .fontSize(12)
            .fontColor(ThemeColors.TEXT_MUTED)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          if (this.hasActiveFilters()) {
            Text($r('app.string.search_reset_filter'))
              .fontSize(12)
              .fontColor(ThemeColors.PRIMARY)
              .onClick((): void => {
                this.handleResetFilters();
              })
          }
        }
        .width('100%')
        .padding({ left: this.layout.pagePaddingVp, right: this.layout.pagePaddingVp, top: 6, bottom: 4 })

        List({ space: ThemeDims.SPACE_S }) {
          LazyForEach(this.vm.searchDataSource, (item: Comic, index: number) => {
            ListItem() {
              ComicListItem({ comic: item, coverWidth: ThemeDims.LIST_COVER_WIDTH })
            }
            .onAppear(() => {
              prefetchComicsAround(this.vm.searchDataSource.getDataArray(), index, 'search');
            })
          }, (item: Comic) => item.id)

          if (this.vm.totalPages <= 1) {
            ListItem() {
              this.FooterBar()
            }
          }
        }
        .lanes(this.layout.listLanes, this.layout.listGutterVp)
        .padding({ left: this.layout.pagePaddingVp, right: this.layout.pagePaddingVp, top: 4 })
        .width('100%')
        .layoutWeight(1)
        .contentEndOffset(this.bottomListInset())
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(ThemeDims.LIST_CACHED_COUNT)
        .onScrollStart((): void => {
          this.dismissKeyboard();
        })
        .onTouch((e: TouchEvent): void => {
          if (e.type === TouchType.Down) {
            this.dismissKeyboard();
          }
        })
        .onReachEnd(() => {
          if (this.vm.totalPages <= 1) {
            this.vm.loadMore();
          }
        })
      }
      .width('100%')
      .height('100%')

      if (this.vm.totalPages > 1) {
        PaginationBar({
          currentPage: this.vm.currentPage,
          totalPages: this.vm.totalPages,
          totalCount: this.vm.totalCount,
          countMode: this.vm.countMode,
          loading: this.vm.isSearching,
          compact: this.layout.listLanes >= 2 || this.effectiveWidth() >= 600,
          bottomSafeInset: ViewportState.getInstance().bottomVp,
          useMaterialSurface: true,
          onPageChange: (page: number): void => {
            this.vm.goToPage(page);
          }
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  FilterBarSelects(compact: boolean) {
    Row({ space: compact ? 6 : 8 }) {
      CapsuleSelect({
        label: this.sortLabel(),
        options: [
          this.lm.getString($r('app.string.search_sort_default'), '默认排序'),
          this.lm.getString($r('app.string.latest_sort_views'), '最多浏览'),
          this.lm.getString($r('app.string.latest_sort_favorites'), '最多收藏'),
          this.lm.getString($r('app.string.latest_sort_rating'), '最高评分')
        ],
        selectedIndex: this.sortIndex(),
        compact: compact,
        onSelect: (index: number): void => {
          this.applySort(index);
        }
      })
      CapsuleSelect({
        label: this.typeLabel(),
        options: [
          this.lm.getString($r('app.string.search_type_all'), '全部类型'),
          this.lm.getString($r('app.string.search_type_comic'), '漫画'),
          this.lm.getString($r('app.string.search_type_anime'), '动画')
        ],
        selectedIndex: this.typeIndex(),
        compact: compact,
        onSelect: (index: number): void => {
          this.applyType(index);
        }
      })
      CapsuleSelect({
        label: this.finishedLabel(),
        options: [
          this.lm.getString($r('app.string.search_progress_all'), '全部进度'),
          this.lm.getString($r('app.string.latest_filter_completed'), '已完结'),
          this.lm.getString($r('app.string.latest_filter_ongoing'), '连载中')
        ],
        selectedIndex: this.finishedIndex(),
        compact: compact,
        onSelect: (index: number): void => {
          this.applyFinished(index);
        }
      })
      if (!compact && this.hasActiveFilters()) {
        Text($r('app.string.common_reset'))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.PRIMARY)
          .padding({ left: 10, right: 10, top: 7, bottom: 7 })
          .borderRadius(15)
          .backgroundColor(ThemeColors.SURFACE)
          .onClick((): void => {
            this.handleResetFilters();
          })
      }
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  FilterBar() {
    Column() {
      if (shouldScrollFilterBar(this.effectiveWidth())) {
        Scroll() {
          this.FilterBarSelects(false)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .align(Alignment.Start)
      } else {
        Row() {
          this.FilterBarSelects(false)
          Blank()
        }
        .width('100%')
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: this.isExpanded ? ThemeDims.CONTENT_MAX_WIDTH : undefined })
    .alignSelf(ItemAlign.Center)
    .padding({ left: 16, right: 16, top: 8, bottom: 4 })
  }

  private applySort(index: number): void {
    const value: string = [SEARCH_SORT_DEFAULT, SEARCH_SORT_VIEWS, SEARCH_SORT_FAVORITES,
      SEARCH_SORT_RATING][index] ?? SEARCH_SORT_DEFAULT;
    this.sortFilter = value;
    this.vm.onFilterChanged('sort', value);
  }

  private applyType(index: number): void {
    const value: string = [SEARCH_TYPE_DEFAULT, SEARCH_TYPE_BOOK, SEARCH_TYPE_STREAM][index]
      ?? SEARCH_TYPE_DEFAULT;
    this.typeFilter = value;
    this.vm.onFilterChanged('type', value);
  }

  private applyFinished(index: number): void {
    const value: string = [SEARCH_FINISHED_ALL, SEARCH_FINISHED_COMPLETED,
      SEARCH_FINISHED_ONGOING][index] ?? SEARCH_FINISHED_ALL;
    this.finishedFilter = value;
    this.vm.onFilterChanged('finished', value);
  }

  private sortIndex(): number {
    return [SEARCH_SORT_DEFAULT, SEARCH_SORT_VIEWS, SEARCH_SORT_FAVORITES,
      SEARCH_SORT_RATING].indexOf(this.sortFilter);
  }

  private typeIndex(): number {
    return [SEARCH_TYPE_DEFAULT, SEARCH_TYPE_BOOK, SEARCH_TYPE_STREAM].indexOf(this.typeFilter);
  }

  private finishedIndex(): number {
    return [SEARCH_FINISHED_ALL, SEARCH_FINISHED_COMPLETED, SEARCH_FINISHED_ONGOING]
      .indexOf(this.finishedFilter);
  }

  private sortLabel(): string {
    const opts: string[] = [
      this.lm.getString($r('app.string.search_sort_default'), '默认排序'),
      this.lm.getString($r('app.string.latest_sort_views'), '最多浏览'),
      this.lm.getString($r('app.string.latest_sort_favorites'), '最多收藏'),
      this.lm.getString($r('app.string.latest_sort_rating'), '最高评分')
    ];
    return opts[this.sortIndex()] ?? opts[0];
  }

  private typeLabel(): string {
    const opts: string[] = [
      this.lm.getString($r('app.string.search_type_all'), '全部类型'),
      this.lm.getString($r('app.string.search_type_comic'), '漫画'),
      this.lm.getString($r('app.string.search_type_anime'), '动画')
    ];
    return opts[this.typeIndex()] ?? opts[0];
  }

  private finishedLabel(): string {
    const opts: string[] = [
      this.lm.getString($r('app.string.search_progress_all'), '全部进度'),
      this.lm.getString($r('app.string.latest_filter_completed'), '已完结'),
      this.lm.getString($r('app.string.latest_filter_ongoing'), '连载中')
    ];
    return opts[this.finishedIndex()] ?? opts[0];
  }

  @Builder
  FooterBar() {
    Column() {
      if (this.vm.isLoadMore) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(ThemeColors.PRIMARY)
          Text($r('app.string.search_load_more'))
            .fontSize(12)
            .fontColor(ThemeColors.TEXT_MUTED)
        }
        .justifyContent(FlexAlign.Center)
      } else if (this.vm.loadMoreError) {
        Row({ space: 6 }) {
          Text($r('app.string.search_load_more_failed'))
            .fontSize(12)
            .fontColor(ThemeColors.ERROR)
          Text($r('app.string.common_retry'))
            .fontSize(12)
            .fontColor(ThemeColors.PRIMARY)
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
            .onClick(() => {
              this.vm.retry();
            })
        }
        .justifyContent(FlexAlign.Center)
      } else if (!this.vm.hasMore) {
        Text($r('app.string.search_end'))
          .fontSize(11)
          .fontColor(ThemeColors.PLACEHOLDER)
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .height(40)
    .justifyContent(FlexAlign.Center)
  }
}

@Builder
export function SearchPageBuilder(name: string, param?: object) {
  SearchPage({
    initialKeyword: searchKeywordOf(param),
    initialMode: searchModeOf(param)
  })
}

function searchKeywordOf(param?: object): string {
  if (param !== undefined && param !== null && param instanceof SearchParam) {
    return param.keyword;
  }
  return '';
}

function searchModeOf(param?: object): string {
  if (param !== undefined && param !== null && param instanceof SearchParam) {
    return param.mode;
  }
  return SEARCH_MODE_DEFAULT;
}
