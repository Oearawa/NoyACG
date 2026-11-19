import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

// These are source contracts, not evidence of rendered material or gesture behavior.
const root = fileURLToPath(new URL('../', import.meta.url));
const etsRoot = resolve(root, 'entry/src/main/ets');
function files(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap(item => {
    const path = resolve(dir, item.name);
    return item.isDirectory() ? files(path) : path.endsWith('.ets') ? [path] : [];
  });
}
function source(path) {
  return readFileSync(resolve(etsRoot, path), 'utf8')
    .replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
}
const index = source('pages/Index.ets');
const home = source('components/HomeComponent.ets');
const entries = source('components/HomeNavigationEntries.ets');
const policy = source('utils/HdsMaterialPolicy.ets');
const all = files(etsRoot).map(path => [relative(etsRoot, path), source(path)]);
const routes = JSON.parse(readFileSync(resolve(root,
  'entry/src/main/resources/base/profile/route_map.json'), 'utf8')).routerMap;
const count = (text, pattern) => [...text.matchAll(pattern)].length;
function nativeOnly(text) {
  assert.doesNotMatch(text,
    /\b(?:backgroundEffect|backgroundBlurStyle|backdropBlur|backdropFilter|GlassRole|glassSpec)\b/);
}
function oneTabs(text) {
  assert.equal(count(text, /\bHdsTabs\(/g), 1);
  assert.doesNotMatch(text, /\bTabs\(|\bBottomBar\(/);
}

test('production tree contains no retired custom material implementation', () => {
  for (const [path, text] of all) assert.doesNotThrow(() => nativeOnly(text), path);
});
test('one HdsTabs owns all four persistent TabContent instances', () => {
  oneTabs(index);
  assert.equal(count(index, /\bTabContent\(/g), 4);
  for (const name of ['HomeComponent', 'LatestComponent', 'ShelfComponent', 'ProfileBody']) {
    assert.equal(count(index, new RegExp(`\\b${name}\\(`, 'g')), 1);
  }
});
test('one provider and one HDS navigation use the existing shared stack', () => {
  assert.equal(count(index, /@Provider\('pageStack'\)/g), 1);
  assert.match(index, /HdsNavigation\(this\.pageStack\)/);
  assert.doesNotMatch(all.map(([,text]) => text).join('\n'), /\bNavigation\(/);
});
test('side rail and native bottom bar derive from the same viewport mode', () => {
  assert.match(index, /if \(!this\.isBottomNav\(\)\)\s*\{\s*this\.SideRail\(\)/);
  assert.match(index, /\.barHeight\(this\.isBottomNav\(\) \? ThemeDims\.BOTTOM_BAR_HEIGHT : 0\)/);
  assert.match(index, /\.barFloatingStyle\(this\.isBottomNav\(\) \? this\.floatingBarStyle\(\) : undefined\)/);
  assert.match(index, /this\.navModeValue = vp\.navMode/);
});
test('floating HDS bar uses the official material option and geometry types', () => {
  assert.match(index, /systemMaterialEffect: HDS_SYSTEM_MATERIAL/);
  for (const pattern of [/\.vertical\(false\)/, /\.barPosition\(BarPosition\.End\)/,
    /\.barOverlap\(this\.isBottomNav\(\)\)/, /smallWidth:/, /mediumWidth:/, /largeWidth:/]) {
    assert.match(index, pattern);
  }
  assert.doesNotMatch(index, /systemMaterial:|maskColor:|gradientMask:|barBackgroundColor\(/);
});
test('themes and capability fallback remain owned by the shared adaptive policy', () => {
  assert.match(policy, /materialType: hdsMaterial\.MaterialType\.ADAPTIVE/);
  assert.match(policy, /materialLevel: hdsMaterial\.MaterialLevel\.ADAPTIVE/);
  assert.match(policy, /getSystemMaterialTypes\(\)/);
  assert.doesNotMatch(policy, /#[\da-f]{6}|isDark|materialColor|radius:/i);
});
test('home title and entry row are hosted by the native material title bar', () => {
  assert.match(index, /\.titleBar\(\{[\s\S]*?bottomBuilder:.*this\.HomeEntries\(\)/);
  assert.match(index, /style: hdsTitleBarStyle\(\)/);
  assert.match(index, /HomeEntries\(\)\s*\{\s*HomeNavigationEntries\(\)/);
  assert.doesNotMatch(home, /HomeHeader\(|DiscoveryEntries\(|GlassCapsule\(/);
});
test('native HDS titles inherit the existing app theme without replacing material policy', () => {
  assert.match(index, /WithTheme\(\{ colorMode: this\.theme\.isDark \? ThemeColorMode\.DARK : ThemeColorMode\.LIGHT \}\)/);
  assert.match(index, /\.withTheme\(\{ enableThemeColorMode: true \}\)/);
  for (const route of routes) {
    assert.match(source(route.pageSourceFile.replace('src/main/ets/', '')),
      /\.withTheme\(\{ enableThemeColorMode: true \}\)/, route.name);
  }
});
test('only the primary home Scroller controls SCROLL_UP visibility', () => {
  assert.match(index, /\.bindToScrollable\(this\.currentTabIndex === 0 \? \[this\.homeScroller\] : \[\]\)/);
  assert.match(home, /Scroll\(this\.homeScroller\)/);
  assert.equal(count(home, /Scroll\(this\.homeScroller\)/g), 1);
  assert.match(index, /hideTitleArea: true,\s*hideBottomBuilder: true,\s*hideStatusBar: false,\s*mode: HideMode\.SCROLL_UP/);
  assert.doesNotMatch(home, /\.onScroll\(|\.onScrollFrameBegin\(|hideTitleBar|dynamicHideTitleBar/);
});
test('horizontal rankings and secondary pages have no home scroll binding', () => {
  assert.match(home, /\.listDirection\(Axis\.Horizontal\)/);
  for (const [path, text] of all) {
    if (path.replaceAll('\\', '/') === 'pages/Index.ets') continue;
    assert.doesNotMatch(text, /\.bindToScrollable\(|\.dynamicHideTitleBar\(/, path);
  }
});
test('three discovery routes and circular search share a single nonwrapping row', () => {
  for (const route of ['ROUTE_RANK', 'ROUTE_CATEGORY', 'ROUTE_PERSONALIZED']) {
    assert.match(entries, new RegExp(`this\\.Entry\\([^\\n]*${route}`));
  }
  assert.equal(count(entries, /this\.Entry\(/g), 3);
  assert.match(entries, /Button\(\{ type: ButtonType\.Circle \}\)/);
  assert.match(entries, /\.width\(40\)\s*\.height\(40\)/);
  assert.match(entries, /accessibilityText\('打开搜索页'\)/);
  assert.match(entries, /pushPathByName\('SearchPage', null\)/);
  assert.doesNotMatch(entries, /FlexWrap|Search\(|GlassCapsule|width\(120\)/);
});
test('entry pills use native touch controls and cached official material', () => {
  assert.match(entries, /Button\(\{ type: ButtonType\.Capsule \}\)/);
  assert.match(entries, /\.layoutWeight\(weight\)/);
  assert.match(entries, /\.minFontSize\(9\)/);
  assert.match(entries, /private readonly material = buildImmersiveMaterial\(\)/);
  assert.equal(count(entries, /\.systemMaterial\(this\.material\)/g), 2);
  assert.equal(count(entries, /\.buttonStyle\(ButtonStyleMode\.NORMAL\)/g), 2);
  assert.doesNotMatch(entries, /\.backgroundColor\(|\.border\(|\.shadow\(/);
});
test('every registered destination delegates its back button to a native HDS title', () => {
  assert.equal(routes.length, 18);
  for (const route of routes) {
    const text = source(route.pageSourceFile.replace('src/main/ets/', ''));
    assert.match(text, /HdsNavDestination\(\)/, route.name);
    assert.match(text, /\.titleBar\(/, route.name);
    assert.match(text, /style: hdsTitleBarStyle\(\)/, route.name);
    assert.doesNotMatch(text, /UnifiedBackButton|SettingsSubHeader|Text\('←'\)|chevron_left|\.hideBackButton\(true\)/);
    assert.match(text, /@Consumer\('pageStack'\)/);
  }
});
test('search retains its ViewModel input, history writes and existing lifecycle', () => {
  const text = source('pages/SearchPage.ets');
  for (const pattern of [/Search\(\{ value: this\.vm\.keyword!!/, /this\.vm\.onKeywordInput\(value\)/,
    /this\.settings\.addSearchHistory\(text\)/, /this\.vm\.activate\(\)/, /\.onSubmit\(/]) {
    assert.match(text, pattern);
  }
});
test('home state and responsive navigation subscriptions survive shell migration', () => {
  assert.match(home, /@Local vm: HomeViewModel = new HomeViewModel\(\)/);
  assert.doesNotMatch(home, /this\.vm\.dispose\(\)/);
  assert.match(index, /viewportSource\.addListener\(this\.syncGeometry\)/);
  assert.match(index, /viewportSource\.removeListener\(this\.syncGeometry\)/);
  assert.match(index, /index: this\.currentTabIndex/);
  assert.match(index, /shouldRefreshShelfOnPop\(isPop, toIsNavBar\)/);
});
test('reader keeps system-bar and progress lifecycle with native menu visibility', () => {
  const text = source('pages/ComicReader.ets');
  assert.match(text, /\.hideTitleBar\(!this\.isMenuVisible\)/);
  assert.match(text, /this\.setSystemBarsVisible\(false\)/);
  assert.match(text, /this\.setSystemBarsVisible\(true\)/);
  assert.match(text, /this\.saveProgress\(\)/);
});
test('native bottom items and material share the same fixed bar width', () => {
  assert.equal(count(index, /\.tabBar\(this\.BottomItem\(/g), 4);
  assert.match(index, /new BottomTabBarStyle\(/);
  assert.match(index, /\.barWidth\(this\.isBottomNav\(\) \? ThemeDims\.BOTTOM_BAR_WIDTH : 0\)/);
  assert.doesNotMatch(index, /\.barWidth\(this\.isBottomNav\(\) \? '100%'/);
});
test('native titles explicitly avoid the system status area', () => {
  assert.match(index, /avoidLayoutSafeArea: true/);
  for (const route of routes) {
    assert.match(source(route.pageSourceFile.replace('src/main/ets/', '')),
      /avoidLayoutSafeArea: true/, route.name);
  }
});
test('home title inset scrolls with content rather than leaving a component safe-area gap', () => {
  assert.match(index, /enableComponentSafeArea: false/);
  assert.match(home, /Blank\(\)\.height\(this\.homeTopInset\)/);
  assert.match(index, /homeTopInset: this\.topVpValue \+ ThemeDims\.TOP_BAR_HEIGHT \+ 48/);
});
test('both native scroll title styles use the live app text colors', () => {
  assert.match(policy, /mainTitleColor: ThemeColors\.TEXT_STRONG/);
  assert.match(policy, /subTitleColor: ThemeColors\.TEXT_SECONDARY/);
  assert.match(policy, /originalStyle: titleStyle/);
  assert.match(policy, /scrollEffectStyle: titleStyle/);
});
test('material foregrounds use official tab resources and explicit search text contrast', () => {
  assert.match(index, /sys\.color\.ohos_id_color_bottom_tab_icon_off/);
  const search = source('pages/SearchPage.ets');
  assert.match(search, /\.fontColor\(ThemeColors\.TEXT\)/);
  assert.match(search, /\.searchIcon\(\{ color: ThemeColors\.TEXT_SECONDARY \}\)/);
});
test('native resource color mode follows the saved app mode with a duplicate guard', () => {
  assert.match(index, /@Monitor\('theme\.mode'\)/);
  assert.match(index, /this\.nativeThemeMode === this\.theme\.mode/);
  assert.match(index, /getApplicationContext\(\)\.setColorMode\(mode\)/);
  assert.match(index, /ConfigurationConstant\.ColorMode\.COLOR_MODE_NOT_SET/);
  assert.match(index, /ConfigurationConstant\.ColorMode\.COLOR_MODE_DARK/);
  assert.match(index, /ConfigurationConstant\.ColorMode\.COLOR_MODE_LIGHT/);
});
test('negative controls detect forbidden material and duplicate tab rendering', () => {
  assert.throws(() => nativeOnly(index + '\n.backgroundEffect({ radius: 20 })'));
  assert.throws(() => oneTabs(index + '\nTabs() {}'));
  assert.throws(() => oneTabs(index + '\nHdsTabs() {}'));
});
