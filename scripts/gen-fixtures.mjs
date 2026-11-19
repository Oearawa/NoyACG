/**
 * gen-fixtures.mjs —— 把 fixtures/*.json 编译成测试可直接引用的 ArkTS 常量模块。
 *
 * 为什么需要：
 * 本地单元测试运行在 PC 侧 ArkTS 运行时，系统 Kit 为桩实现（fs.readTextSync 不存在），
 * 测试进程无法读取磁盘文件；因此把 fixture 原文内联成字符串常量。
 * 单一事实来源仍是 fixtures/*.json —— 每次改动 fixture 后执行：
 *     node scripts/gen-fixtures.mjs
 */
import fs from 'node:fs';
import path from 'node:path';

const FIXTURE_DIR = 'fixtures';
const OUT_FILE = 'entry/src/test/fixtures/FixtureData.ets';

const files = fs.readdirSync(FIXTURE_DIR).filter((f) => f.endsWith('.json')).sort();
const constName = (file) => file.replace(/\.json$/, '').replace(/[^a-zA-Z0-9]+/g, '_').toUpperCase();

const parts = [];
parts.push('/**');
parts.push(' * FixtureData.ets —— fixtures/*.json 的内联副本（自动生成，请勿手改）');
parts.push(' *');
parts.push(' * 生成命令：node scripts/gen-fixtures.mjs');
parts.push(' * 来源目录：fixtures/（真实抓包 + 依据首方前端字段用法派生的样例，见 fixtures/README.md）');
parts.push(' */');
parts.push('');

for (const file of files) {
  const raw = fs.readFileSync(path.join(FIXTURE_DIR, file), 'utf8').replace(/\r\n/g, '\n');
  const name = constName(file);
  parts.push(`/** 对应 fixtures/${file} */`);
  parts.push(`export const ${name}: string = ${JSON.stringify(raw)};`);
  parts.push('');
}

fs.mkdirSync(path.dirname(OUT_FILE), { recursive: true });
fs.writeFileSync(OUT_FILE, parts.join('\n'), 'utf8');
console.log(`generated ${OUT_FILE} from ${files.length} fixture(s): ${files.join(', ')}`);
