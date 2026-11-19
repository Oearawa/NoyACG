import { HdsNavDestination } from '@kit.UIDesignKit';
import { hdsTitleBarStyle } from '../utils/HdsMaterialPolicy';
/**
 * CacheSettingsPage.ets —— 高级缓存配置（Phase 14-R）
 *
 * 与「存储管理」的关系：
 * - 存储管理只展示真实占用并提供「清理」按钮（既有能力）；
 * - 本页负责**策略**：容量上限（500MB / 1GB / 无限制）+ 按最近访问时间的 LRU 自动清理。
 *
 * 边界：只作用于 `<cacheDir>` 下的图片缓存文件；`<filesDir>/Downloads` 的离线章节
 * 完全不在清理范围内（CacheCleaner 的删除红线本来就只认图片缓存文件名）。
 */
import { CachePolicyViewModel } from '../viewmodel/CachePolicyViewModel';
import { CapsuleSelect } from '../components/CapsuleSelect';
import { HdsLightButton } from '../components/HdsLightButton';
import { CacheViewModel } from '../viewmodel/CacheViewModel';
import { CacheClearResult } from '../utils/CacheCleaner';
import { ImageCacheManager } from '../utils/ImageCacheManager';
import { SafeAreaManager } from '../utils/SafeAreaManager';
import { LocalizationManager } from '../utils/LocalizationManager';
import { ThemeColors, ThemeDims, ThemeFonts } from '../utils/Theme';
import { Logger } from '../utils/Logger';
import { LIST_ROW_LAYOUT, SETTINGS_LAYOUT, SETTINGS_TEXT_LAYOUT } from '../utils/ProfileLayout';

const TAG: string = 'CacheSettingsPage';
const LIMIT_OPTIONS: number[] = [524288000, 1073741824, -1];

@ComponentV2
export struct CacheSettingsPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local vm: CachePolicyViewModel = new CachePolicyViewModel();
  @Local clearing: boolean = false;
  private lm: LocalizationManager = LocalizationManager.getInstance();

  aboutToAppear(): void {
    this.vm.load();
  }

  private text(res: Resource, fallback: string): string {
    return this.lm.getString(res, fallback);
  }

  private limitIndex(): number {
    return Math.max(0, LIMIT_OPTIONS.indexOf(this.vm.limitBytes));
  }

  private limitLabelRes(index: number): Resource {
    if (index === 0) {
      return $r('app.string.cache_limit_mb500');
    }
    if (index === 1) {
      return $r('app.string.cache_limit_gb1');
    }
    return $r('app.string.cache_limit_unlimited');
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (e) {
      Logger.warn(TAG, `Toast 展示失败: ${(e as Error).message}`);
    }
  }

  private async selectLimit(index: number): Promise<void> {
    await this.vm.selectLimit(LIMIT_OPTIONS[index]);
    if (this.vm.errorMessage === 'not_persisted') {
      this.toast(this.text($r('app.string.cache_limit_save_failed'), '容量上限未能保存到本地'));
      return;
    }
    if (this.vm.hasEvictionResult) {
      this.toast(this.lm.getString($r('app.string.cache_clean_result'),
        '已清理 %d 个文件，释放 %s', this.vm.lastDeletedCount,
        CacheViewModel.formatBytes(this.vm.lastFreedBytes)));
    }
  }

  /** 清理按钮：与「存储管理」同一语义（只清图片缓存），因此同样二次确认 */
  private confirmClear(): void {
    if (this.clearing) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: this.text($r('app.string.dialog_clear_cache_title'), '清理图片缓存'),
      message: this.text($r('app.string.dialog_clear_cache_body_short'),
        '只删除图片缓存，离线章节、收藏与阅读进度不受影响。'),
      autoCancel: true,
      primaryButton: {
        value: this.text($r('app.string.common_cancel'), '取消'),
        action: () => {
        }
      },
      secondaryButton: {
        value: this.text($r('app.string.dialog_clear_confirm'), '清理'),
        fontColor: ThemeColors.ERROR,
        action: () => {
          this.doClear();
        }
      }
    });
  }

  private async doClear(): Promise<void> {
    this.clearing = true;
    try {
      const result: CacheClearResult = await ImageCacheManager.getInstance().clearImageCache();
      if (!result.success) {
        this.toast(this.text($r('app.string.toast_cache_failed'), '清理失败，请稍后重试'));
      } else if (result.deletedCount === 0) {
        this.toast(this.text($r('app.string.toast_cache_empty'), '缓存已经是空的'));
      } else {
        this.toast(this.lm.getString($r('app.string.toast_cache_freed'), '已清理 %s',
          CacheViewModel.formatBytes(result.freedBytes)));
      }
      await this.vm.refreshUsage();
    } finally {
      this.clearing = false;
    }
  }

  private lastCleanText(): string {
    if (!this.vm.hasEvictionResult) {
      return this.text($r('app.string.cache_clean_never'), '当前缓存未达上限，暂无需自动清理');
    }
    if (this.vm.lastDeletedCount <= 0) {
      return this.text($r('app.string.cache_auto_cleaned_some'), '已自动清理部分旧缓存');
    }
    return this.lm.getString($r('app.string.cache_clean_result'),
      '已清理 %d 个文件，释放 %s', this.vm.lastDeletedCount,
      CacheViewModel.formatBytes(this.vm.lastFreedBytes));
  }

  build() {
    HdsNavDestination() {
      Column() {
        Scroll() {
          Row() {
            Column({ space: SETTINGS_LAYOUT.groupSpacing }) {
              // 真实占用 + 上限
              Column({ space: 6 }) {
                Row() {
                  Text($r('app.string.cache_usage_title'))
                    .fontSize(ThemeFonts.BODY)
                    .fontColor(ThemeColors.TEXT)
                  Blank()
                  if (this.vm.isBusy) {
                    LoadingProgress().width(13).height(13).color(ThemeColors.PRIMARY)
                  } else {
                    Text(this.vm.usageText())
                      .fontSize(ThemeFonts.BODY_SMALL + 1)
                      .fontColor(this.vm.isOverLimit() ? ThemeColors.ERROR : ThemeColors.TEXT_SECONDARY)
                  }
                }
                .width('100%')
                .height(22)
                .alignItems(LIST_ROW_LAYOUT.verticalAlign)

                Text($r('app.string.cache_limit_desc'))
                  .fontSize(ThemeFonts.CAPTION + 1)
                  .fontColor(ThemeColors.TEXT_MUTED)
                  .width(SETTINGS_TEXT_LAYOUT.hintWidth)
                  .textAlign(SETTINGS_TEXT_LAYOUT.hintTextAlign)

                Row({ space: ThemeDims.SPACE_M }) {
                  Text($r('app.string.cache_limit_title'))
                    .fontSize(ThemeFonts.BODY_SMALL)
                    .fontColor(ThemeColors.TEXT_SECONDARY)
                    .layoutWeight(LIST_ROW_LAYOUT.textColumnWeight)
                  CapsuleSelect({
                    label: this.limitLabelRes(this.limitIndex()),
                    options: [
                      $r('app.string.cache_limit_mb500'),
                      $r('app.string.cache_limit_gb1'),
                      $r('app.string.cache_limit_unlimited')
                    ],
                    selectedIndex: this.limitIndex(),
                    isEnabled: true,
                    onSelect: (index: number): void => {
                      this.selectLimit(index);
                    }
                  })
                }
                .width('100%')
                .alignItems(LIST_ROW_LAYOUT.verticalAlign)

                if (this.vm.isOverLimit()) {
                  Text($r('app.string.cache_over_limit'))
                    .fontSize(ThemeFonts.CAPTION + 1)
                    .fontColor(ThemeColors.ERROR)
                    .width(SETTINGS_TEXT_LAYOUT.hintWidth)
                    .textAlign(SETTINGS_TEXT_LAYOUT.hintTextAlign)
                }
              }
              .width('100%')
              .padding({
                left: SETTINGS_LAYOUT.paddingHorizontal,
                right: SETTINGS_LAYOUT.paddingHorizontal,
                top: SETTINGS_LAYOUT.paddingVertical,
                bottom: SETTINGS_LAYOUT.paddingVertical
              })
              .backgroundColor(ThemeColors.CARD)
              .borderRadius(SETTINGS_LAYOUT.cardRadius)
              .alignItems(SETTINGS_TEXT_LAYOUT.containerAlign)

              // LRU 说明 + 最近清理 + 手动检查
              Column({ space: 8 }) {
                Text($r('app.string.cache_lru_note'))
                  .fontSize(ThemeFonts.CAPTION + 1)
                  .fontColor(ThemeColors.TEXT_MUTED)
                  .width(SETTINGS_TEXT_LAYOUT.hintWidth)
                  .textAlign(SETTINGS_TEXT_LAYOUT.hintTextAlign)
                Text($r('app.string.cache_offline_isolated'))
                  .fontSize(ThemeFonts.CAPTION + 1)
                  .fontColor(ThemeColors.TEXT_MUTED)
                  .width(SETTINGS_TEXT_LAYOUT.hintWidth)
                  .textAlign(SETTINGS_TEXT_LAYOUT.hintTextAlign)
                Text(this.lastCleanText())
                  .fontSize(ThemeFonts.CAPTION + 1)
                  .fontColor(ThemeColors.TEXT_SECONDARY)
                  .width(SETTINGS_TEXT_LAYOUT.hintWidth)
                  .textAlign(SETTINGS_TEXT_LAYOUT.hintTextAlign)

                Row({ space: 8 }) {
                  HdsLightButton({
                    label: $r('app.string.cache_clean_now'),
                    variant: 'neutral',
                    isEnabled: !this.vm.isBusy,
                    onAction: () => {
                      this.vm.enforceNow();
                    }
                  })
                  HdsLightButton({
                    label: $r('app.string.storage_cache_clear'),
                    variant: 'neutral',
                    isEnabled: !this.clearing,
                    onAction: () => {
                      this.confirmClear();
                    }
                  })
                }
                .width('100%')
                .alignItems(LIST_ROW_LAYOUT.verticalAlign)
              }
              .width('100%')
              .padding({
                left: SETTINGS_LAYOUT.paddingHorizontal,
                right: SETTINGS_LAYOUT.paddingHorizontal,
                top: SETTINGS_LAYOUT.paddingVertical,
                bottom: SETTINGS_LAYOUT.paddingVertical
              })
              .backgroundColor(ThemeColors.CARD)
              .borderRadius(SETTINGS_LAYOUT.cardRadius)
              .alignItems(SETTINGS_TEXT_LAYOUT.containerAlign)

              Column().width('100%').height(ThemeDims.SPACE_L)
            }
            .width('100%')
            .constraintSize({ maxWidth: ThemeDims.CONTENT_MAX_WIDTH })
            .padding({
              left: ThemeDims.PAGE_PADDING,
              right: ThemeDims.PAGE_PADDING,
              top: 8,
              bottom: 20
            })
            .alignItems(SETTINGS_TEXT_LAYOUT.containerAlign)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }
        .layoutWeight(LIST_ROW_LAYOUT.textColumnWeight)
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemeColors.BG)
    }
    .withTheme({ enableThemeColorMode: true })
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      content: { title: { mainTitle: $r('app.string.adv_cache') } },
      style: hdsTitleBarStyle()
    })
    .backgroundColor(ThemeColors.BG)
  }
}

/** 系统路由表构建函数：与 route_map.json 的 "CacheSettingsPageBuilder" 对应 */
@Builder
export function CacheSettingsPageBuilder(name: string, param?: object) {
  CacheSettingsPage()
}
