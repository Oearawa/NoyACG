/**
 * check-i18n.mjs —— 语言资源完整性 + 硬编码文案审查（Phase 14-L）
 *
 * 三件事：
 * 1. 三个资源目录（base / zh_CN / zh_TW）的 key 集合必须完全一致，无重复、无空值；
 * 2. 列出「代码里引用了但资源里没有」的 key（编译期不会报，运行时会显示成 id）；
 * 3. 扫描 .ets 里剩余的中文字面量，按文件统计，供交付报告如实记录迁移进度。
 *
 * 用法：node scripts/check-i18n.mjs   （有缺失时退出码 1）
 */
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

const RES = join('entry', 'src', 'main', 'resources');
const LANGS = ['base', 'zh_CN', 'zh_TW'];

function load(lang) {
  const path = join(RES, lang, 'element', 'string.json');
  const json = JSON.parse(readFileSync(path, 'utf8'));
  return json.string || [];
}

const tables = {};
for (const lang of LANGS) {
  tables[lang] = load(lang);
}

let failed = false;
const baseKeys = tables.base.map((s) => s.name);

// 1) key 一致性 / 重复 / 空值
for (const lang of LANGS) {
  const keys = tables[lang].map((s) => s.name);
  const dup = keys.filter((k, i) => keys.indexOf(k) !== i);
  if (dup.length) {
    console.error(`[FAIL] ${lang} 存在重复 key: ${dup.join(', ')}`);
    failed = true;
  }
  const missing = baseKeys.filter((k) => !keys.includes(k));
  if (missing.length) {
    console.error(`[FAIL] ${lang} 缺少 key: ${missing.join(', ')}`);
    failed = true;
  }
  const empty = tables[lang].filter((s) => !s.value || String(s.value).trim() === '');
  if (empty.length) {
    console.error(`[FAIL] ${lang} 存在空值: ${empty.map((s) => s.name).join(', ')}`);
    failed = true;
  }
}

// 2) 代码引用 vs 资源定义
const etsFiles = [];
function walk(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p);
    else if (name.endsWith('.ets')) etsFiles.push(p);
  }
}
walk(join('entry', 'src', 'main', 'ets'));

const used = new Set();
for (const f of etsFiles) {
  // 先去掉注释，避免把注释里的示例 key 当成真实引用
  const src = readFileSync(f, 'utf8')
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\/\/[^\n]*/g, '');
  for (const m of src.matchAll(/\$r\('app\.string\.([A-Za-z0-9_]+)'\)/g)) used.add(m[1]);
}
const undefinedKeys = [...used].filter((k) => !baseKeys.includes(k));
if (undefinedKeys.length) {
  console.error(`[FAIL] 代码引用了未定义的 key: ${undefinedKeys.join(', ')}`);
  failed = true;
}

// 3) 剩余中文硬编码（用于报告，不判失败：业务动态数据/注释/日志属合理保留）
const rows = [];
for (const f of etsFiles) {
  let src = readFileSync(f, 'utf8');
  src = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
  const hits = [...src.matchAll(/'[^'\n]*[\u4e00-\u9fa5][^'\n]*'/g)].map((m) => m[0]);
  if (hits.length) rows.push({ file: f.replace(/\\/g, '/'), count: hits.length });
}
rows.sort((a, b) => b.count - a.count);

console.log(`\n[INFO] 资源 key 总数: ${baseKeys.length}（三种语言各一份）`);
console.log(`[INFO] 代码引用 key 数: ${used.size}，未定义: ${undefinedKeys.length}`);
console.log(`[INFO] 仍有中文硬编码字面量的文件: ${rows.length} 个，合计 ${rows.reduce((n, r) => n + r.count, 0)} 处`);
for (const r of rows.slice(0, 20)) console.log(`        ${r.count.toString().padStart(3)}  ${r.file}`);

if (failed) {
  console.error('\n[RESULT] FAIL');
  process.exit(1);
}
console.log('\n[RESULT] PASS —— key 集合一致、无重复、无空值、无未定义引用');
