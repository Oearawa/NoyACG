import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

// Assertions over layouts captured from the physical API 26 device by HDC.
// These do not measure animation frame rate or replace screenshot inspection.
function layout(name) {
  const json = JSON.parse(readFileSync(new URL(`../logs/${name}.json`, import.meta.url), 'utf8'));
  const nodes = [];
  function visit(node) {
    if (node.attributes) nodes.push(node.attributes);
    for (const child of node.children ?? []) visit(child);
  }
  visit(json);
  return nodes;
}
function box(node, original = false) {
  assert.ok(node, 'Expected a device layout node');
  const [left, top, right, bottom] = (original ? node.origBounds : node.bounds).match(/-?\d+/g).map(Number);
  return { left, top, right, bottom, width: right - left, height: bottom - top };
}
const find = (nodes, type) => nodes.find(node => node.type === type);
const entryRow = nodes => nodes.find(node => node.id === 'homeNavigationEntries');
const homeDark = layout('r61-device04-dark-home');
const hidden = layout('r61-device04-hidden');
const restored = layout('r61-device04-restored');
const horizontal = layout('r61-device04-horizontal');
const light = layout('r61-device04-light-home');
const expanded = layout('r61-device03-expanded');

function checkRow(nodes) {
  const row = entryRow(nodes);
  assert.ok(row);
  const buttons = nodes.filter(node => node.type === 'Button' &&
    node.hierarchy.startsWith(`${row.hierarchy},`));
  assert.equal(buttons.length, 4);
  const bounds = buttons.map(button => box(button));
  assert.ok(bounds.every(button => button.top === bounds[0].top && button.bottom === bounds[0].bottom));
  for (let index = 1; index < bounds.length; index++) {
    assert.ok(bounds[index - 1].right <= bounds[index].left);
  }
  assert.equal(bounds[3].width, bounds[3].height, 'Search hit target must remain circular');
  assert.ok(bounds[3].right <= box(row).right);
}
test('physical outer and inner screens keep all four home actions on one row', () => {
  checkRow(homeDark);
  checkRow(light);
  checkRow(expanded);
});
test('physical native home title stays below the system status area', () => {
  for (const nodes of [homeDark, light, expanded]) {
    const title = nodes.find(node => node.type === 'Text' && node.text === 'NoyAcg');
    assert.ok(box(title, true).top >= box(find(nodes, 'Navigation')).top);
  }
});
test('physical outer-screen native bar contains every navigation item', () => {
  const bar = box(find(homeDark, 'TabBar'));
  assert.ok(bar.width <= 344 * 2.75 + 2);
  for (const label of ['主页', '最新', '收藏', '用户']) {
    const item = homeDark.find(node => node.type === 'Column' && node.text === label);
    const bounds = box(item);
    assert.ok(bounds.left >= bar.left && bounds.right <= bar.right);
    assert.ok(bounds.top >= bar.top && bounds.bottom <= bar.bottom);
  }
});
test('physical upward gesture hides the entire native title without a fixed content gap', () => {
  assert.ok(box(find(hidden, 'TitleBar')).height <= 2);
  assert.equal(entryRow(hidden), undefined);
  assert.equal(box(find(hidden, 'Scroll')).top, box(find(hidden, 'Navigation')).top);
});
test('physical reverse gesture restores the title and entry row', () => {
  assert.ok(box(find(restored, 'TitleBar')).height > 200);
  checkRow(restored);
});
test('physical bottom navigation remains fixed throughout title collapse and restoration', () => {
  assert.deepEqual(box(find(homeDark, 'TabBar')), box(find(hidden, 'TabBar')));
  assert.deepEqual(box(find(hidden, 'TabBar')), box(find(restored, 'TabBar')));
});
test('physical horizontal ranking gesture leaves the native title expanded', () => {
  assert.deepEqual(box(find(restored, 'TitleBar')), box(find(horizontal, 'TitleBar')));
  checkRow(horizontal);
});
test('physical expanded screen replaces the bottom bar with the existing side rail', () => {
  assert.equal(find(expanded, 'TabBar'), undefined);
  const content = box(expanded.find(node => node.id === 'hdsTabs'));
  assert.ok(content.left > 0);
  assert.ok(expanded.some(node => node.type === 'Text' && node.text === '主页' &&
    box(node).right < content.left));
  assert.equal(homeDark.filter(node => node.type === 'TabBar').length, 1);
});
test('physical search is hosted by one native destination and title', () => {
  const nodes = layout('r61-device04-search');
  assert.equal(nodes.filter(node => node.type === 'NavDestination').length, 1);
  const title = box(find(nodes, 'TitleBar'));
  const search = box(find(nodes, 'Search'));
  assert.ok(search.top >= title.top && search.bottom <= title.bottom);
});
test('physical native back button pops search to the existing home', () => {
  const nodes = layout('r61-device03-pop');
  assert.equal(find(nodes, 'NavDestination'), undefined);
  assert.ok(entryRow(nodes));
  assert.ok(nodes.some(node => node.id === 'hdsTabs'));
});
test('physical pre-fix snapshot reproduces the status overlap and full-width bar regression', () => {
  const before = layout('r61-device-before');
  const title = before.find(node => node.type === 'Text' && node.text === 'NoyAcg');
  assert.ok(box(title, true).top < box(find(before, 'Navigation')).top);
  assert.ok(box(find(before, 'TabBar')).width > 344 * 2.75 + 2);
});
