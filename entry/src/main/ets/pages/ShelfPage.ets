/**
 * ShelfPage.ets —— 我的收藏独立路由页（用户 → 我的收藏）
 *
 * 即使在设置中隐藏了主导航「收藏」Tab，用户仍可从「用户 - 我的收藏」完整使用账号收藏与本地书架功能。
 */
import { HdsNavDestination } from '@kit.UIDesignKit';
import { ShelfComponent } from '../components/ShelfComponent';
import { StandardPageScaffold } from '../components/StandardPageScaffold';
import { ShelfViewModel } from '../viewmodel/ShelfViewModel';
import { LocalizationManager } from '../utils/LocalizationManager';

@ComponentV2
export struct ShelfPage {
  @Consumer('pageStack') pageStack: NavPathStack = new NavPathStack();
  @Local private vm: ShelfViewModel = new ShelfViewModel();
  @Local private lm: LocalizationManager = LocalizationManager.getInstance();

  aboutToAppear(): void {
    this.vm.initDefaultSource();
    this.vm.onTabSelected();
  }

  @Builder
  ShelfBody() {
    ShelfComponent({
      vm: this.vm,
      active: true,
      inSubPage: true
    })
  }

  build() {
    HdsNavDestination() {
      StandardPageScaffold({
        title: this.lm.getString($r('app.string.shelf_title'), '收藏'),
        showHeaderBottom: false,
        onBack: (): void => {
          this.pageStack.pop();
        },
        content: (): void => {
          this.ShelfBody();
        }
      })
    }
    .hideTitleBar(true)
  }
}

/** 系统路由表构建函数：与 route_map.json 的 "ShelfPageBuilder" 对应 */
@Builder
export function ShelfPageBuilder(name: string, param?: object) {
  ShelfPage()
}
