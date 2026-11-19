/**
 * HomeNavigationEntries.ets —— 竖屏单行首页顶部导航栏（随内容自然滚动 + 响应式放大比例）
 *
 * 布局：`NoyAcg  [排行榜] [分类] [精选] [搜索]`
 * - 挂载于 HomeComponent 滚动流最顶部第一项，随下方内容自然向上滚出屏幕（无吸顶、无折叠动画）；
 * - 路由与文案与横屏 SideRailModel（SIDE_QUICK_ROUTES / SIDE_SEARCH_ROUTE）及三语言资源同源；
 * - 常规/宽幅竖屏（>= 380vp）：54vp 内容高、20fp 品牌、36vp 胶囊、13fp 文字、15vp 图标；
 * - 360vp 紧凑竖屏：按 resolveCompactTopBarSpec 微调比例确保单行不截断；< 340vp 水平滚动兜底；
 * - 通过 responseRegion 保持实际可点击热区 >= 44vp；
 * - 背景材质严格经 MaterialPolicy / ImmersiveMaterial 决策，不混设硬编码 backgroundColor。
 */
import { ThemeColors } from '../utils/Theme';
import { ThemeManager } from '../utils/ThemeManager';
import { HdsLightButton } from './HdsLightButton';
import { ROUTE_CATEGORY } from '../model/DiscoveryRoutes';
import { SIDE_SEARCH_ROUTE } from '../viewport/SideRailModel';
import {
  CompactTopBarSpec,
  compactTopBarTotalHeightVp,
  normalizeSafeAreaVp,
  resolveCompactTopBarSpec
} from '../utils/TopBarViewport';

export interface CompactTopEntry {
  label: Resource;
  icon: Resource;
  route: string;
}

export function compactTopEntries(): CompactTopEntry[] {
  return [
    {
      label: $r('app.string.discovery_category'),
      icon: $r('sys.symbol.square_grid_2x2'),
      route: ROUTE_CATEGORY
    },
    {
      label: $r('app.string.discovery_search'),
      icon: $r('sys.symbol.magnifyingglass'),
      route: SIDE_SEARCH_ROUTE
    }
  ];
}

@ComponentV2
export struct HomeNavigationEntries {
  @Param topSafeInset: number = 0;
  @Param containerWidth: number = 380;
  @Param leadingPaddingVp: number = 12;
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local private theme: ThemeManager = ThemeManager.getInstance();

  private spec(): CompactTopBarSpec {
    return resolveCompactTopBarSpec(this.containerWidth);
  }

  @Builder
  CompactCapsule(entry: CompactTopEntry, spec: CompactTopBarSpec) {
    HdsLightButton({
      label: entry.label,
      leadingIcon: entry.icon,
      variant: 'accentSoft',
      minWidthVp: 0,
      heightVp: spec.capsuleHeightVp,
      radiusVp: spec.capsuleHeightVp / 2,
      hPaddingVp: spec.capsuleHPaddingVp,
      fontSizeFp: spec.capsuleFontSizeFp,
      iconSizeVp: spec.capsuleIconSizeVp,
      touchTargetHeightVp: spec.touchTargetVp,
      onAction: () => {
        this.pageStack.pushPathByName(entry.route, null);
      }
    })
  }

  @Builder
  CapsulesRow(spec: CompactTopBarSpec) {
    Row({ space: spec.capsuleGapVp }) {
      ForEach(compactTopEntries(), (entry: CompactTopEntry) => {
        this.CompactCapsule(entry, spec)
      }, (entry: CompactTopEntry) => entry.route)
    }
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.End)
  }

  build() {
    Row({ space: 8 }) {
      Text('NoyAcg')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme.accent)
        .maxLines(1)

      if (this.spec().scrollCapsules) {
        Scroll() {
          this.CapsulesRow(this.spec())
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .align(Alignment.End)
      } else {
        Row() {
          this.CapsulesRow(this.spec())
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.End)
      }
    }
    .id('homeNavigationEntries')
    .width('100%')
    .height(compactTopBarTotalHeightVp(this.topSafeInset))
    .padding({
      top: normalizeSafeAreaVp(this.topSafeInset),
      left: 16,
      right: 16
    })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Color.Transparent)
  }
}
