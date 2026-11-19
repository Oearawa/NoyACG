import { describe, expect, it } from '@ohos/hypium';
import { BackInterceptStack } from '../main/ets/utils/BackInterceptRegistry';
import {
  COMMUNITY_SPOILER_BLUR_RADIUS,
  resolveSpoilerBlurRadius,
  shouldOpenImageOnTap
} from '../main/ets/utils/CommunityFeedHelper';
import { CommunityViewerController } from '../main/ets/utils/CommunityViewerController';

export default function backInterceptAndSpoilerTest(): void {
  describe('BackInterceptAndSpoilerTest', () => {
    it('backInterceptStackDispatchesLifoAndFallsThroughWhenEmpty', 0, () => {
      const stack = new BackInterceptStack();
      const closed: string[] = [];

      let searchOpen: boolean = true;
      let composerOpen: boolean = true;
      let viewerOpen: boolean = true;

      stack.register('search', (): boolean => {
        if (searchOpen) {
          searchOpen = false;
          closed.push('search');
          return true;
        }
        return false;
      });
      stack.register('composer', (): boolean => {
        if (composerOpen) {
          composerOpen = false;
          closed.push('composer');
          return true;
        }
        return false;
      });
      stack.register('viewer', (): boolean => {
        if (viewerOpen) {
          viewerOpen = false;
          closed.push('viewer');
          return true;
        }
        return false;
      });

      expect(stack.size()).assertEqual(3);
      expect(stack.dispatchBack()).assertTrue();
      expect(stack.dispatchBack()).assertTrue();
      expect(stack.dispatchBack()).assertTrue();
      expect(stack.dispatchBack()).assertFalse();

      expect(closed.length).assertEqual(3);
      expect(closed[0]).assertEqual('viewer');
      expect(closed[1]).assertEqual('composer');
      expect(closed[2]).assertEqual('search');

      stack.unregister('composer');
      expect(stack.size()).assertEqual(2);
      stack.clear();
      expect(stack.hasHandlers()).assertFalse();
    });

    it('communityViewerControllerConsumesBackWhenOpen', 0, () => {
      const ctrl = new CommunityViewerController();
      expect(ctrl.isOpen()).assertFalse();
      expect(ctrl.closeIfOpen()).assertFalse();

      ctrl.open('https://bucket.noymanga.com/image/demo.webp');
      expect(ctrl.isOpen()).assertTrue();
      expect(ctrl.closeIfOpen()).assertTrue();
      expect(ctrl.isOpen()).assertFalse();
      expect(ctrl.closeIfOpen()).assertFalse();
    });

    it('spoilerBlurRadiusAndTwoTapUnlockRules', 0, () => {
      expect(COMMUNITY_SPOILER_BLUR_RADIUS).assertEqual(28);
      // 未解锁剧透图：内容模糊 28，首次点击只解锁不进大图
      expect(resolveSpoilerBlurRadius(true, false)).assertEqual(28);
      expect(shouldOpenImageOnTap(true, false)).assertFalse();

      // 已解锁剧透图：内容模糊归 0，二次点击进大图
      expect(resolveSpoilerBlurRadius(true, true)).assertEqual(0);
      expect(shouldOpenImageOnTap(true, true)).assertTrue();

      // 非剧透图：始终不模糊，直接进大图
      expect(resolveSpoilerBlurRadius(false, false)).assertEqual(0);
      expect(shouldOpenImageOnTap(false, false)).assertTrue();
    });
  });
}
