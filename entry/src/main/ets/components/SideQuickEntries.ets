/**
 * SideQuickEntries.ets —— 横屏侧栏上部快捷入口组（p7-landscape-side-rail Task 1）
 *
 * 契约（plan Task 1 / brief）：
 *   - 纵向胶囊组：N 个快捷入口（默认 DiscoveryRoutes：排行榜/分类/精选）+ 搜索文字胶囊（w49 统一同构）；
 *   - 路由决策：组件内部 @Consumer('pageStack') 接入 Index 的全局 NavPathStack（同 HomeNavigationEntries
 *     模式，最小侵入，不向 Index 注入回调）；onSearch 仅作未来扩展点保留；
 *   - 材质：Button Capsule + systemMaterial(buildImmersiveMaterial())（MaterialPolicy 唯一决策源，
 *     systemMaterial 接管 bg/border/shadow，不 co-set；禁用过滤类特效 API）；
 *   - 尺寸全部引用 ThemeDims（NAV_RAIL_* / SPACE_* / ICON_SIZE）；搜索入口与快捷胶囊同构（w49）。
 */
import { ThemeColors, ThemeDims } from '../utils/Theme';
import { SIDE_QUICK_ROUTES, SIDE_SEARCH_ROUTE } from '../viewport/SideRailModel';

/** 快捷入口数据描述（label/icon/route；route 与 route_map.json 的 name 一一对应） */
export interface QuickEntry {
  /** 入口文案（资源引用，如 $r('app.string.discovery_rank')） */
  label: Resource;
  /** 入口图标（系统符号资源，如 $r('sys.symbol.doc_plaintext')） */
  icon: Resource;
  /** 路由名（NavPathStack.pushPathByName 第一参） */
  route: string;
}

/**
 * 默认快捷入口：与 SIDE_QUICK_ROUTES（SideRailModel）同源，只在渲染时构造
 * （$r() 资源引用不放到模块顶层，保持组件文件可被纯数据测试安全 import）。
 */
export function defaultQuickEntries(): QuickEntry[] {
  const labels: Resource[] = [
    $r('app.string.discovery_rank'),
    $r('app.string.discovery_category'),
    $r('app.string.discovery_personalized')
  ];
  const icons: Resource[] = [
    $r('sys.symbol.doc_plaintext'),
    $r('sys.symbol.square_grid_2x2'),
    $r('sys.symbol.star')
  ];
  const list: QuickEntry[] = [];
  for (let i = 0; i < SIDE_QUICK_ROUTES.length; i++) {
    list.push({ label: labels[i], icon: icons[i], route: SIDE_QUICK_ROUTES[i] });
  }
  return list;
}

@ComponentV2
export struct SideQuickEntries {
  /** 快捷入口列表（默认 SIDE_QUICK_ROUTES 三项）；调用方可不传 */
  @Param entries: QuickEntry[] = [];
  /** 响应式密度参数（由 SideGroupLayout 驱动） */
  @Param capsuleH: number = ThemeDims.NAV_RAIL_ITEM_HEIGHT - ThemeDims.SPACE_M;
  @Param itemGap: number = ThemeDims.SPACE_M;
  @Param iconSize: number = ThemeDims.ICON_SIZE;
  @Param labelSize: number = 12;
  /** 可选搜索扩展点（未来带参搜索）；当前版本搜索按钮固定推 ROUTE_SEARCH */
  @Event onSearch: () => void = () => {
  };

  /** 全局路由栈：与 HomeNavigationEntries 相同模式，Index 的 @Provider('pageStack') 注入 */
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();

  /**
   * 实际入口列表：缺省时用默认快捷入口。
   * ArkTS 限制 build() 内不允许局部变量声明，故抽为私有方法（每次 build 求值，key 稳定复用）。
   */
  private effectiveEntries(): QuickEntry[] {
    return this.entries.length > 0 ? this.entries : defaultQuickEntries();
  }

  @Builder
  QuickCapsule(entry: QuickEntry) {
    Column({ space: this.capsuleH <= 36 ? 1 : 3 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(entry.icon)
          .fontSize(this.capsuleH <= 36 ? this.iconSize : 20)
          .fontColor([ThemeColors.IS_DARK ? '#CBD5E1' : '#333A48'])
      }
      .width(48)
      .height(this.capsuleH <= 36 ? 22 : 28)
      .borderRadius(14)

      Text(entry.label)
        .fontSize(this.capsuleH <= 36 ? this.labelSize : 11)
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .fontColor(ThemeColors.IS_DARK ? '#94A3B8' : '#5A6270')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height(this.capsuleH <= 36 ? this.capsuleH + 6 : ThemeDims.NAV_RAIL_ITEM_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(Color.Transparent)
    .accessibilityText(entry.label)
    .onClick(() => this.pageStack.pushPathByName(entry.route, null))
  }

  build() {
    Column({ space: this.itemGap }) {
      // 快捷入口胶囊组（排行榜/分类/精选）
      ForEach(this.effectiveEntries(), (entry: QuickEntry) => {
        this.QuickCapsule(entry)
      }, (entry: QuickEntry) => entry.route)

      // 搜索：统一文字胶囊（图标 + 搜索 文字，路由不变）
      this.QuickCapsule({ label: $r('app.string.discovery_search'), icon: $r('sys.symbol.magnifyingglass'), route: SIDE_SEARCH_ROUTE })
    }
    .id('sideQuickEntries')
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
