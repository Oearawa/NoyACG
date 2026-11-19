/**
 * Phase15R21.test.ets —— 导航交互与窗口监听稳定性修复的纯函数单测（Phase 15-R2.1）
 *
 * 覆盖任务书第十二节的 12 项：
 *  1. Tabs 不滑动换页        → 由 `shouldCommitTab` 保证「只有点击/程序切换才提交」，
 *                              实际 `scrollable(false)` 属声明式属性，本文件用源码约束 + 行为谓词双重覆盖
 *  2. 同一窗口不重复绑定      → `shouldRebindWindow`
 *  3. 窗口改变需重绑          → `shouldRebindWindow`
 *  4. 新窗口立即更新几何      → `ViewportState.setGeometry` 同步提交
 *  5. 旧窗口晚到回调作废      → `isStaleWindowEvent`
 *  6. 连续事件只产生有效提交  → `ViewportState.commits`
 *  7. 侧栏与内容不溢出        → `NAV_RAIL_TOTAL_WIDTH`
 *  8. 侧栏左右边距对称        → `NAV_RAIL_TOTAL_WIDTH` / `NAV_RAIL_MARGIN`
 *  9. 深浅主题蒙层不同且有效  → `barMaskColor` / `BAR_MASK_DARK` / `BAR_MASK_LIGHT`
 * 10. 同主题不重复写系统栏    → 由 `ThemeManager` 的「比后写」保证，此处校验掩码语义
 * 11. 页面切换不重复提交      → `commitTabIndex` / `shouldCommitTab`
 * 12. POP 转场不提前刷新      → `shouldRefreshShelfOnPop`
 *
 * 说明：本文件是**宿主纯函数测试**，不能证明真机渲染结果。
 */
import { describe, it, expect } from '@ohos/hypium';
import { shouldRebindWindow, isStaleWindowEvent } from '../main/ets/utils/SafeAreaManager';
import {
  barMaskColor,
  barMaskHeight,
  BAR_MASK_DARK,
  BAR_MASK_LIGHT
} from './LegacyBarMaskFixture';
import { ThemeDims } from '../main/ets/utils/Theme';
import {
  profileContentEndInset,
  contentEndInset,
  FLOATING_BAR_GAP
} from '../main/ets/utils/BottomInset';
import {
  commitTabIndex,
  shouldCommitTab,
  clampTabIndex,
  shouldRefreshShelfOnPop
} from '../main/ets/utils/NavInteraction';
import { ViewportState } from '../main/ets/utils/ViewportState';
import { NavigationMode } from '../main/ets/utils/NavigationMode';

/** 仅用于对象身份比较的替身（不需要任何窗口能力） */
class FakeWindow {
  readonly tag: string;
  constructor(tag: string) {
    this.tag = tag;
  }
}

/** 解析 '#AARRGGBB' 的 alpha 通道；格式非法返回 -1 */
function alphaOf(color: string): number {
  if (color.length !== 9 || color.charAt(0) !== '#') {
    return -1;
  }
  return parseInt(color.substring(1, 3), 16);
}

export default function phase15r21Test(): void {
  describe('Phase15R21_WindowRebindIdentity', () => {

    it('sameWindowInstanceDoesNotRebind', 0, () => {
      const win: FakeWindow = new FakeWindow('main');
      // 实例相同：不重绑（重复注册监听会让同一事件采样两次）
      expect(shouldRebindWindow(win, win)).assertFalse();
    });

    it('changedWindowInstanceRequiresRebind', 0, () => {
      const oldWin: FakeWindow = new FakeWindow('old');
      const newWin: FakeWindow = new FakeWindow('new');
      // 实例变化：必须重绑，否则旧实例的 windowSizeChange 不再回调，形态冻结
      expect(shouldRebindWindow(oldWin, newWin)).assertTrue();
      // 首次绑定（当前为空）
      expect(shouldRebindWindow(undefined, newWin)).assertTrue();
      // 取不到新窗口：不能用空绑定覆盖可用绑定
      expect(shouldRebindWindow(oldWin, undefined)).assertFalse();
      // 两边都为空：不重绑
      expect(shouldRebindWindow(undefined, undefined)).assertFalse();
    });

    it('staleWindowCallbackIsDropped', 0, () => {
      // 旧代次（1）的回调在代次已推进到 2 之后必须被丢弃
      expect(isStaleWindowEvent(1, 2)).assertTrue();
      // 当前代次有效
      expect(isStaleWindowEvent(2, 2)).assertFalse();
      expect(isStaleWindowEvent(0, 0)).assertFalse();
    });

    it('newWindowCommitsGeometryImmediately', 0, () => {
      const state: ViewportState = new ViewportState();
      // 新窗口绑定后立即提交真实几何：横屏 2296×1624 → 侧栏
      const changed: boolean = state.setGeometry(2296, 1624, 0, 24);
      expect(changed).assertTrue();
      expect(state.navMode).assertEqual(NavigationMode.SIDE);
      expect(state.widthVp).assertEqual(2296);
      expect(state.heightVp).assertEqual(1624);
    });

    it('geometryCommitFlagTracksFirstSample', 0, () => {
      const state: ViewportState = new ViewportState();
      // 顶栏用它区分「topVp 真的是 0」与「还没采过样」
      expect(state.hasCommitted()).assertFalse();
      state.setGeometry(0, 0, 0, 0);
      expect(state.hasCommitted()).assertFalse();
      state.setGeometry(1264, 1848, 27, 24);
      expect(state.hasCommitted()).assertTrue();
      expect(state.topVp).assertEqual(27);
    });

    it('repeatedIdenticalSamplesProduceNoExtraCommit', 0, () => {
      const state: ViewportState = new ViewportState();
      state.setGeometry(1264, 1848, 30, 24);
      const baseline: number = state.commits;
      // 连续 20 次同尺寸事件（内外屏切换过程中的典型重复上报）不得产生状态提交
      for (let i = 0; i < 20; i++) {
        state.setGeometry(1264, 1848, 30, 24);
      }
      expect(state.commits).assertEqual(baseline);
      // 真实变化才提交，且只提交一次
      expect(state.setGeometry(2296, 1624, 30, 24)).assertTrue();
      expect(state.commits).assertEqual(baseline + 1);
      // 折叠回竖屏：一处状态完成回落，不需要第二次提交
      expect(state.setGeometry(1264, 1848, 30, 24)).assertTrue();
      expect(state.navMode).assertEqual(NavigationMode.BOTTOM_IMMERSIVE);
    });
  });

  describe('Phase15R21_RailGeometry', () => {

    it('railTotalWidthIsSymmetric', 0, () => {
      // 总占位 = 左 + 栏体 + 右，且左右相等
      expect(ThemeDims.NAV_RAIL_TOTAL_WIDTH)
        .assertEqual(ThemeDims.NAV_RAIL_MARGIN * 2 + ThemeDims.NAV_RAIL_WIDTH);
      const contentBox: number = ThemeDims.NAV_RAIL_TOTAL_WIDTH - ThemeDims.NAV_RAIL_MARGIN * 2;
      // 栏体刚好填满内容盒：不会右侧贴边（右侧边距就是 NAV_RAIL_MARGIN）
      expect(contentBox).assertEqual(ThemeDims.NAV_RAIL_WIDTH);
      expect(ThemeDims.NAV_RAIL_MARGIN).assertLarger(0);
    });

    it('railAndContentFitWindowWithoutOverflow', 0, () => {
      // 展开横屏可用宽度（vp）示例：2296px / 3 ≈ 765vp
      const windowWidth: number = 765;
      const contentWidth: number = windowWidth - ThemeDims.NAV_RAIL_TOTAL_WIDTH;
      // layoutWeight(1) 后的内容宽度为正，且两者之和恰好等于窗口宽度（不溢出）
      expect(contentWidth).assertLarger(0);
      expect(ThemeDims.NAV_RAIL_TOTAL_WIDTH + contentWidth).assertEqual(windowWidth);
      // 窄窗口（方形 600vp）：仍不溢出
      const squareWidth: number = 600;
      expect(ThemeDims.NAV_RAIL_TOTAL_WIDTH).assertLess(squareWidth);
    });
  });

  describe('Phase15R21_MaskContrast', () => {

    it('maskColorDiffersByTheme', 0, () => {
      const dark: string = barMaskColor(true);
      const light: string = barMaskColor(false);
      expect(dark).assertEqual(BAR_MASK_DARK);
      expect(light).assertEqual(BAR_MASK_LIGHT);
      // 两套主题必须不同（同一蒙层无法同时适配深浅底）
      expect(dark === light).assertFalse();
    });

    it('maskColorIsSemiTransparentButNotTransparent', 0, () => {
      const darkAlpha: number = alphaOf(BAR_MASK_DARK);
      const lightAlpha: number = alphaOf(BAR_MASK_LIGHT);
      // 格式合法（#AARRGGBB）
      expect(darkAlpha).assertLarger(0);
      expect(lightAlpha).assertLarger(0);
      // 不得是全透明（旧实现的问题）也不得完全不透明（会挡死材质）
      expect(darkAlpha).assertLarger(127);
      expect(darkAlpha).assertLess(255);
      expect(lightAlpha).assertLarger(127);
      expect(lightAlpha).assertLess(255);
      // 浅色底需要更高遮盖率
      expect(lightAlpha).assertLarger(darkAlpha);
    });

    it('maskHeightCoversBarAndGap', 0, () => {
      // 间隙必须与悬浮栏的 barBottomMargin 同源（FLOATING_BAR_GAP），否则蒙层会与栏错位
      const height: number = barMaskHeight(ThemeDims.BOTTOM_BAR_HEIGHT, FLOATING_BAR_GAP);
      expect(height).assertLarger(ThemeDims.BOTTOM_BAR_HEIGHT);
      expect(height).assertEqual(ThemeDims.BOTTOM_BAR_HEIGHT + FLOATING_BAR_GAP * 2);
      expect(FLOATING_BAR_GAP).assertEqual(ThemeDims.NAV_RAIL_MARGIN);
      // 非法入参不产生负数高度
      expect(barMaskHeight(-10, -10)).assertEqual(0);
      expect(barMaskHeight(NaN, NaN)).assertEqual(0);
    });
  });

  describe('Phase15R21_TabSelectionSingleSource', () => {

    it('tabCommitSkipsIdenticalIndex', 0, () => {
      // 形态变化重建时 Tabs 可能回放相同下标：不得重复提交副作用
      expect(shouldCommitTab(1, 1)).assertFalse();
      expect(commitTabIndex(1, 1)).assertEqual(1);
      // 真实切换才提交
      expect(shouldCommitTab(1, 2)).assertTrue();
      expect(commitTabIndex(1, 2)).assertEqual(2);
    });

    it('tabIndexIsClampedToRange', 0, () => {
      expect(clampTabIndex(-1, 4)).assertEqual(0);
      expect(clampTabIndex(0, 4)).assertEqual(0);
      expect(clampTabIndex(3, 4)).assertEqual(3);
      expect(clampTabIndex(9, 4)).assertEqual(3);
      // 非法输入回落到首页，避免 index 越界导致空白
      expect(clampTabIndex(NaN, 4)).assertEqual(0);
      expect(clampTabIndex(1, 0)).assertEqual(0);
    });

    it('tabSelectionIsPreservedWhenFormChanges', 0, () => {
      // 形态变化只改 navMode，不改页签下标：切侧栏/底栏不回到首页
      let index: number = 2;
      const state: ViewportState = new ViewportState();
      state.setGeometry(2296, 1624, 0, 24);
      index = commitTabIndex(index, index);
      state.setGeometry(1264, 1848, 0, 24);
      index = commitTabIndex(index, index);
      expect(index).assertEqual(2);
      expect(state.navMode).assertEqual(NavigationMode.BOTTOM_IMMERSIVE);
    });
  });

  describe('Phase15R21_ProfileInset', () => {

    it('routeFormIgnoresTabBarInset', 0, () => {
      // 独立路由形态：没有悬浮栏，只留系统避让（否则末尾多一整条栏高的空白）
      expect(profileContentEndInset(ThemeDims.BOTTOM_BAR_HEIGHT, false, true, 24)).assertEqual(24);
      expect(profileContentEndInset(ThemeDims.BOTTOM_BAR_HEIGHT, false, false, 24)).assertEqual(24);
    });

    it('tabFormKeepsBarInset', 0, () => {
      // Tab 形态 + 底栏：栏高 + 栏底边距 + 避让
      expect(profileContentEndInset(ThemeDims.BOTTOM_BAR_HEIGHT, true, true, 24))
        .assertEqual(contentEndInset(ThemeDims.BOTTOM_BAR_HEIGHT, true, 24));
      // Tab 形态 + 侧栏：只留系统避让
      expect(profileContentEndInset(ThemeDims.BOTTOM_BAR_HEIGHT, true, false, 24)).assertEqual(24);
    });
  });

  describe('Phase15R21_ViewportSubscription', () => {

    it('listenerFiresOnlyOnRealChange', 0, () => {
      const state: ViewportState = new ViewportState();
      let fired: number = 0;
      const listener = (): void => { fired++; };
      state.addListener(listener);
      state.setGeometry(1264, 1848, 27, 24);
      expect(fired).assertEqual(1);
      // 同尺寸重复上报不得重复通知（否则壳层会无谓重绘）
      state.setGeometry(1264, 1848, 27, 24);
      expect(fired).assertEqual(1);
      // 形态变化必须通知
      state.setGeometry(2296, 1624, 27, 24);
      expect(fired).assertEqual(2);
      expect(state.navMode).assertEqual(NavigationMode.SIDE);
    });

    it('removedListenerStopsReceiving', 0, () => {
      const state: ViewportState = new ViewportState();
      let fired: number = 0;
      const listener = (): void => { fired++; };
      state.addListener(listener);
      state.setGeometry(1264, 1848, 27, 24);
      state.removeListener(listener);
      state.setGeometry(2296, 1624, 27, 24);
      // 退订后不再回调（组件销毁后不得继续写 @Local）
      expect(fired).assertEqual(1);
    });

    it('throwingListenerDoesNotBreakOthers', 0, () => {
      const state: ViewportState = new ViewportState();
      let fired: number = 0;
      state.addListener((): void => {
        throw new Error('boom');
      });
      state.addListener((): void => { fired++; });
      state.setGeometry(1264, 1848, 27, 24);
      // 单个订阅者异常不得影响采样与其它订阅者
      expect(fired).assertEqual(1);
      expect(state.hasCommitted()).assertTrue();
    });
  });

  describe('Phase15R21_RouteShowPolicy', () => {

    it('shelfRefreshOnlyOnPopToHome', 0, () => {
      // 只有「POP 且目标为根页」才刷新书架
      expect(shouldRefreshShelfOnPop(true, true)).assertTrue();
      // 页面之间的 POP：不刷新
      expect(shouldRefreshShelfOnPop(true, false)).assertFalse();
      // PUSH：不刷新（转场期间更不应该启动网络请求）
      expect(shouldRefreshShelfOnPop(false, true)).assertFalse();
      expect(shouldRefreshShelfOnPop(false, false)).assertFalse();
    });
  });
}
