/**
 * Phase14O.test.ets —— 图片与文本加载闪跳专项回归（Phase 14-O）
 *
 * 覆盖：固定几何约束、图片状态幂等、稳定 key 增量更新、LRU 缓存、
 * 有界预取选择、缓存计数与原有搜索/区块列表回归。
 * ArkUI 组件实际布局/动画仍需真机验证，本文件不把纯逻辑断言冒充 UI 测量。
 */
import { describe, it, expect } from '@ohos/hypium';
import { Comic } from '../main/ets/model/Comic';
import { BasicDataSource } from '../main/ets/utils/BasicDataSource';
import { LruStringCache } from '../main/ets/utils/LruStringCache';
import { ImageCacheManager } from '../main/ets/utils/ImageCacheManager';
import { selectPrefetchUrls } from '../main/ets/utils/ImagePrefetch';
import {
  CARD_TEXT_LAYOUT,
  STABLE_COVER_FALLBACK_HEIGHT,
  STABLE_LIST_INFO_HEIGHT,
  isStableKey,
  shouldReloadImage,
  stableImageGeometry,
  comicDisplayFingerprint,
  planStableListUpdate
} from '../main/ets/utils/StableLayout';
import { ThemeDims } from '../main/ets/utils/Theme';
import {
  SectionListParam,
  SEARCH_MODE_TAG,
  buildTagSearchParam
} from '../main/ets/model/NavParams';

class CountingListener implements DataChangeListener {
  reloads: number = 0;
  adds: number[] = [];
  deletes: number[] = [];
  changes: number[] = [];
  datasetChanges: number = 0;

  onDataReloaded(): void {
    this.reloads++;
  }
  onDataAdded(index: number): void {
  }
  onDataAdd(index: number): void {
    this.adds.push(index);
  }
  onDataMoved(from: number, to: number): void {
  }
  onDataMove(from: number, to: number): void {
  }
  onDataDeleted(index: number): void {
  }
  onDataDelete(index: number): void {
    this.deletes.push(index);
  }
  onDataChanged(index: number): void {
  }
  onDataChange(index: number): void {
    this.changes.push(index);
  }
  onDatasetChange(dataOperations: DataOperation[]): void {
    this.datasetChanges += dataOperations.length;
  }
}

function makeComic(id: string, title: string, cover: string, favorites: number = 0): Comic {
  const comic: Comic = new Comic(id, title, cover, '', '');
  comic.favorites = favorites;
  return comic;
}

function comicKey(comic: Comic): string {
  return comic.id;
}

function comicFingerprint(comic: Comic): string {
  return comicDisplayFingerprint(comic);
}

export default function phase14oTest() {
  describe('Phase14O_StableGeometryAndText', () => {
    it('usesNonZeroFirstFrameCoverFallback', 0, () => {
      expect(STABLE_COVER_FALLBACK_HEIGHT > 0).assertTrue();
      expect(STABLE_LIST_INFO_HEIGHT > 0).assertTrue();
      expect(ThemeDims.LIST_CACHED_COUNT > 0).assertTrue();
      expect(ThemeDims.PREFETCH_RADIUS).assertEqual(2);
      expect(ThemeDims.PREFETCH_MAX_CONCURRENCY <= 2).assertTrue();
    });

    it('keepsCardTextLayoutConcrete', 0, () => {
      expect(CARD_TEXT_LAYOUT.titleMaxLines).assertEqual(2);
      expect(CARD_TEXT_LAYOUT.titleLineHeight > 0).assertTrue();
      expect(CARD_TEXT_LAYOUT.metaLineHeight > 0).assertTrue();
      expect(CARD_TEXT_LAYOUT.descLineHeight > 0).assertTrue();
      expect(CARD_TEXT_LAYOUT.overflow).assertEqual(TextOverflow.Ellipsis);
    });

    it('returnsSameGeometryForCoverPageAndStreamModes', 0, () => {
      const cover = stableImageGeometry(ThemeDims.COVER_RATIO, false, 0);
      expect(cover.mode).assertEqual('cover');
      expect(cover.aspectRatio).assertEqual(ThemeDims.COVER_RATIO);
      expect(cover.minHeight).assertEqual(0);
      const page = stableImageGeometry(0, true, 0);
      expect(page.mode).assertEqual('page');
      expect(page.height).assertEqual('100%');
      const stream = stableImageGeometry(0, false, 0);
      expect(stream.mode).assertEqual('stream');
      expect(stream.minHeight).assertEqual(180);
      expect(stream.aspectRatio).assertEqual(0);
      const knownStream = stableImageGeometry(0, false, 0.5);
      expect(knownStream.aspectRatio).assertEqual(0.5);
    });
  });

  describe('Phase14O_ImageStateIdempotency', () => {
    it('doesNotReloadSameSuccessfulImageOnTextStateChange', 0, () => {
      expect(shouldReloadImage('u', 'u', 'u', false)).assertFalse();
      expect(shouldReloadImage('u', 'u', '', false)).assertTrue();
      expect(shouldReloadImage('u', 'v', 'u', false)).assertTrue();
      expect(shouldReloadImage('u', 'u', 'u', true)).assertTrue();
      expect(shouldReloadImage('', '', '', false)).assertTrue();
    });

    it('rejectsUnstableKeys', 0, () => {
      expect(isStableKey('comic_1')).assertTrue();
      expect(isStableKey('')).assertFalse();
      expect(isStableKey('undefined')).assertFalse();
      expect(isStableKey('null')).assertFalse();
    });

    it('changesFingerprintOnTextButKeepsCoverReference', 0, () => {
      const comic: Comic = makeComic('c1', 'title-a', 'cover-a', 10);
      const before: string = comicDisplayFingerprint(comic);
      comic.title = 'title-b';
      comic.favorites = 11;
      const after: string = comicDisplayFingerprint(comic);
      expect(before !== after).assertTrue();
      expect(comic.cover).assertEqual('cover-a');
      expect(shouldReloadImage('cover-a', 'cover-a', 'cover-a', false)).assertFalse();
    });
  });

  describe('Phase14O_StableListUpdatePlan', () => {
    it('updatesOnlyChangedFingerprintWhenKeysAndOrderAreStable', 0, () => {
      const oldList: Comic[] = [makeComic('c1', 'a', 'u1'), makeComic('c2', 'b', 'u2')];
      const newList: Comic[] = [makeComic('c1', 'a', 'u1'), makeComic('c2', 'b2', 'u2')];
      const plan = planStableListUpdate(oldList, newList, comicKey, comicFingerprint);
      expect(plan.fullReload).assertFalse();
      expect(plan.changed.length).assertEqual(1);
      expect(plan.changed[0]).assertEqual(1);
      expect(plan.added.length).assertEqual(0);
      expect(plan.removed.length).assertEqual(0);
    });

    it('appendsAndRemovesTailItemsIncrementally', 0, () => {
      const oldList: Comic[] = [makeComic('c1', 'a', 'u1'), makeComic('c2', 'b', 'u2')];
      const appended: Comic[] = [
        makeComic('c1', 'a', 'u1'),
        makeComic('c2', 'b', 'u2'),
        makeComic('c3', 'c', 'u3')
      ];
      const addPlan = planStableListUpdate(oldList, appended, comicKey, comicFingerprint);
      expect(addPlan.fullReload).assertFalse();
      expect(addPlan.added.length).assertEqual(1);
      expect(addPlan.added[0]).assertEqual(2);
      const removePlan = planStableListUpdate(appended, oldList, comicKey, comicFingerprint);
      expect(removePlan.fullReload).assertFalse();
      expect(removePlan.removed.length).assertEqual(1);
      expect(removePlan.removed[0]).assertEqual(2);
    });

    it('fallsBackToFullReloadOnReorderOrDuplicateKeys', 0, () => {
      const oldList: Comic[] = [makeComic('c1', 'a', 'u1'), makeComic('c2', 'b', 'u2')];
      const reordered: Comic[] = [makeComic('c2', 'b', 'u2'), makeComic('c1', 'a', 'u1')];
      const duplicates: Comic[] = [makeComic('c1', 'a', 'u1'), makeComic('c1', 'a', 'u1')];
      expect(planStableListUpdate(oldList, reordered, comicKey, comicFingerprint).fullReload).assertTrue();
      expect(planStableListUpdate(oldList, duplicates, comicKey, comicFingerprint).fullReload).assertTrue();
    });
  });

  describe('Phase14O_BasicDataSourceIncrementalNotifications', () => {
    it('usesAddChangeDeleteInsteadOfReloadForStableUpdates', 0, () => {
      const ds: BasicDataSource<Comic> = new BasicDataSource<Comic>();
      const listener: CountingListener = new CountingListener();
      ds.registerDataChangeListener(listener);
      const c1: Comic = makeComic('c1', 'a', 'u1');
      const c2: Comic = makeComic('c2', 'b', 'u2');
      const c3: Comic = makeComic('c3', 'c', 'u3');
      ds.setDataStable([c1, c2, c3], comicKey, comicFingerprint);
      expect(ds.totalCount()).assertEqual(3);
      expect(listener.reloads).assertEqual(0);
      expect(listener.adds.length).assertEqual(3);

      const same: Comic[] = [
        makeComic('c1', 'a', 'u1'),
        makeComic('c2', 'b', 'u2'),
        makeComic('c3', 'c', 'u3')
      ];
      ds.setDataStable(same, comicKey, comicFingerprint);
      expect(listener.reloads).assertEqual(0);
      expect(listener.changes.length).assertEqual(0);
      expect(listener.adds.length).assertEqual(3);

      const changed: Comic[] = [same[0], makeComic('c2', 'b2', 'u2'), same[2]];
      ds.setDataStable(changed, comicKey, comicFingerprint);
      expect(listener.reloads).assertEqual(0);
      expect(listener.changes.length).assertEqual(1);
      expect(listener.changes[0]).assertEqual(1);

      ds.pushDataList([makeComic('c4', 'd', 'u4'), makeComic('c5', 'e', 'u5')]);
      expect(listener.reloads).assertEqual(0);
      expect(listener.adds.length).assertEqual(5);
      expect(ds.totalCount()).assertEqual(5);

      ds.pushDataList([]);
      expect(listener.adds.length).assertEqual(5);

      const trimmed: Comic[] = [changed[0], changed[1], changed[2], makeComic('c4', 'd', 'u4')];
      ds.setDataStable(trimmed, comicKey, comicFingerprint);
      expect(listener.reloads).assertEqual(0);
      expect(listener.deletes.length).assertEqual(1);
      expect(ds.totalCount()).assertEqual(4);

      const reordered: Comic[] = [trimmed[1], trimmed[0], trimmed[2], trimmed[3]];
      ds.setDataStable(reordered, comicKey, comicFingerprint);
      expect(listener.reloads).assertEqual(1);
    });
  });

  describe('Phase14O_LruAndPrefetch', () => {
    it('evictsLeastRecentlyUsedStringCacheEntry', 0, () => {
      const cache: LruStringCache = new LruStringCache(3);
      cache.set('a', '1');
      cache.set('b', '2');
      cache.set('c', '3');
      expect(cache.get('a')).assertEqual('1');
      cache.set('d', '4');
      expect(cache.get('b') === undefined).assertTrue();
      expect(cache.keys().join(',')).assertEqual('c,a,d');
    });

    it('selectsOnlyNearbyRemotePrefetchUrls', 0, () => {
      const urls: string[] = ['a', 'b', 'c', 'd', 'e', 'file://local', ''];
      expect(selectPrefetchUrls(urls, 2, 2).join(',')).assertEqual('a,b,c,d,e');
      expect(selectPrefetchUrls(urls, 5, 2).join(',')).assertEqual('d,e');
      expect(selectPrefetchUrls(urls, 2, 0).join(',')).assertEqual('c');
      expect(selectPrefetchUrls(urls, -1, 2).length).assertEqual(0);
    });

    it('reusesCachedImageWithoutNetworkOrPrefetchQueue', 0, async () => {
      const manager: ImageCacheManager = ImageCacheManager.getInstance();
      manager.clearMemoryForTest();
      manager.resetCountersForTest();
      const url: string = 'https://img.noymanga.com/phase14o/cached.webp';
      manager.setMemoryCacheForTest(url, 'file://cached.webp');
      const result: string = await manager.getImage(url);
      expect(result).assertEqual('file://cached.webp');
      const counters = manager.getCounters();
      expect(counters.memoryHitCount).assertEqual(1);
      expect(counters.networkRequestCount).assertEqual(0);
      expect(manager.getDebugSnapshot().memoryKeys.indexOf(url) >= 0).assertTrue();
      manager.prefetch([url], 'phase14o_test', 2);
      expect(manager.getCounters().prefetchQueuedCount).assertEqual(0);
      manager.cancelPrefetch('phase14o_test');
      manager.resetCountersForTest();
      expect(manager.getCounters().memoryHitCount).assertEqual(0);
      manager.clearMemoryForTest();
      expect(manager.getMemoryKeysForTest().length).assertEqual(0);
    });

    it('shortCircuitsLocalFileUriWithoutCacheLookup', 0, async () => {
      const manager: ImageCacheManager = ImageCacheManager.getInstance();
      manager.clearMemoryForTest();
      manager.resetCountersForTest();
      const result: string = await manager.getImage('file://local/1.webp');
      expect(result).assertEqual('file://local/1.webp');
      expect(manager.getCounters().memoryHitCount).assertEqual(0);
      expect(manager.getCounters().networkRequestCount).assertEqual(0);
    });
  });

  describe('Phase14O_Regression', () => {
    it('keepsTagSearchParamContract', 0, () => {
      const param = buildTagSearchParam('奇幻');
      expect(param.keyword).assertEqual('奇幻');
      expect(param.mode).assertEqual(SEARCH_MODE_TAG);
    });

    it('keepsSectionListServerOrder', 0, () => {
      const comics: Comic[] = [makeComic('a', 'a', 'a'), makeComic('b', 'b', 'b')];
      const param: SectionListParam = new SectionListParam('title', comics);
      expect(param.comics[1].id).assertEqual('b');
    });
  });
}
