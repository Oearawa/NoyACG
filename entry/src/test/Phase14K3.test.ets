/**
 * Phase14K3.test.ets —— 双层个人中心结构 + 新增「时间格式化」设置回归测试
 *
 * 本阶段的核心约束是**分层职责**，不是某个控件长什么样。因此断言落在可验证的三处：
 *   1. 第一层入口表：日常功能恰好三项、文案为产品指定文案、设置入口唯一且指向 SettingsPage；
 *   2. 时间格式化：本阶段唯一新增的真实设置 —— 纯函数格式化 + 偏好归一化 + 持久化降级；
 *   3. 能力边界：未实现项不得以「可用控件」的形式出现（本文件只断言模型层没有伪入口）。
 *
 * 页面内部是否出现「常用功能」字样、是否残留清理按钮，属于源码结构约束，
 * 由交付报告中的 grep 证据负责（单元测试无法读取页面源码）。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  DAILY_ACTIONS,
  SETTINGS_ENTRY,
  ProfileMenuEntry,
  ROUTE_DOWNLOAD,
  ROUTE_HISTORY,
  ROUTE_MESSAGE,
  ROUTE_SETTINGS,
  allProfileEntries,
  findDailyAction,
  routeOfDailyAction
} from '../main/ets/model/ProfileMenu';
import {
  TIME_FORMAT_ABSOLUTE,
  TIME_FORMAT_RELATIVE,
  absoluteDate,
  absoluteDateTime,
  formatDownloadTime,
  formatHistoryTime,
  normalizeTimeFormat,
  relativeText,
  timeFormatLabel,
  TimeTexts
} from '../main/ets/utils/TimeFormat';
import { PreferenceManager } from '../main/ets/utils/PreferenceManager';

const MINUTE: number = 60 * 1000;
const HOUR: number = 60 * MINUTE;
const DAY: number = 24 * HOUR;

/** 固定时间基准（2026-11-08 15:04 本地时区），避免依赖真实当前时间 */
const BASE_MS: number = new Date(2026, 10, 8, 15, 4, 0, 0).getTime();

/** 固定简体文案（与资源 base 一致；用于验证格式化逻辑而非资源加载） */
const TEST_TEXTS: TimeTexts = {
  justNow: '刚刚',
  minutesAgo: (n: number): string => `${n} 分钟前`,
  hoursAgo: (n: number): string => `${n} 小时前`,
  daysAgo: (n: number): string => `${n} 天前`
};

/** 统计某路由在日常入口中出现次数 */
function countRoute(route: string): number {
  let n: number = 0;
  for (let i = 0; i < DAILY_ACTIONS.length; i++) {
    if (DAILY_ACTIONS[i].route === route) {
      n++;
    }
  }
  return n;
}

export default function phase14k3Test() {
  describe('Phase14K3_LayerStructure', () => {
    it('dailyActionsAreExactlyThree', 0, () => {
      // 第一层只有三项日常功能：消息 / 历史 / 下载
      expect(DAILY_ACTIONS.length).assertEqual(3);
      expect(DAILY_ACTIONS[0].route).assertEqual(ROUTE_MESSAGE);
      expect(DAILY_ACTIONS[1].route).assertEqual(ROUTE_HISTORY);
      expect(DAILY_ACTIONS[2].route).assertEqual(ROUTE_DOWNLOAD);
      expect(allProfileEntries().length).assertEqual(3);
    });

    it('dailyActionsUseMandatedSubtitles', 0, () => {
      // 产品指定文案，不得随意改写（用户可见的说明文字）
      expect(DAILY_ACTIONS[0].subtitle).assertEqual('评论回复 / 社区回复 / 系统消息');
      expect(DAILY_ACTIONS[1].subtitle).assertEqual('接着上次的进度继续阅读');
      expect(DAILY_ACTIONS[2].subtitle).assertEqual('离线章节、下载任务与文件清理');
    });

    it('settingsEntryIsTheSingleSecondLayerDoor', 0, () => {
      // 设置入口唯一：且不在「日常功能」表里（它单独渲染，避免被当成第四个日常入口）
      expect(SETTINGS_ENTRY.route).assertEqual(ROUTE_SETTINGS);
      expect(SETTINGS_ENTRY.title).assertEqual('设置');
      expect(countRoute(ROUTE_SETTINGS)).assertEqual(0);
    });

    it('noDuplicateRoutesAcrossLayers', 0, () => {
      const routes: string[] = [SETTINGS_ENTRY.route];
      for (let i = 0; i < DAILY_ACTIONS.length; i++) {
        const route: string = DAILY_ACTIONS[i].route;
        expect(routes.indexOf(route) < 0).assertTrue();
        routes.push(route);
      }
    });

    it('downloadIsSingleEntryAndReachable', 0, () => {
      expect(countRoute(ROUTE_DOWNLOAD)).assertEqual(1);
      const entry: ProfileMenuEntry | null = findDailyAction('downloads');
      expect(entry !== null).assertTrue();
      expect(routeOfDailyAction('downloads')).assertEqual(ROUTE_DOWNLOAD);
    });

    it('noUnsupportedEntriesInLayerOne', 0, () => {
      // 登出属于资料卡动作；邀请码/积分从未实现；不得混入日常入口
      const forbidden: string[] = ['logout', 'invite', 'points', 'drawer', 'theme', 'language'];
      for (let i = 0; i < DAILY_ACTIONS.length; i++) {
        expect(forbidden.indexOf(DAILY_ACTIONS[i].key) < 0).assertTrue();
      }
      expect(findDailyAction('not_exists') === null).assertTrue();
      expect(routeOfDailyAction('not_exists')).assertEqual('');
    });
  });

  describe('Phase14K3_TimeFormat', () => {
    it('absoluteFormatsKeepLegacyOutput', 0, () => {
      // 默认（绝对）格式必须与改造前两页的输出完全一致，避免视觉回归
      expect(absoluteDateTime(BASE_MS)).assertEqual('11-08 15:04');
      expect(absoluteDate(BASE_MS)).assertEqual('2026-11-08');
      // 非法时间戳
      expect(absoluteDateTime(0)).assertEqual('');
      expect(absoluteDate(-1)).assertEqual('');
    });

    it('relativeTextCoversAllBuckets', 0, () => {
      expect(relativeText(BASE_MS - 30 * 1000, BASE_MS, TEST_TEXTS)).assertEqual('刚刚');
      expect(relativeText(BASE_MS - 5 * MINUTE, BASE_MS, TEST_TEXTS)).assertEqual('5 分钟前');
      expect(relativeText(BASE_MS - 3 * HOUR, BASE_MS, TEST_TEXTS)).assertEqual('3 小时前');
      expect(relativeText(BASE_MS - 2 * DAY, BASE_MS, TEST_TEXTS)).assertEqual('2 天前');
    });

    it('relativeTextFallsBackBeyondSevenDays', 0, () => {
      // 超过 7 天返回空串 → 调用方回退绝对时间（避免「123 天前」这种无意义文案）
      expect(relativeText(BASE_MS - 10 * DAY, BASE_MS, TEST_TEXTS)).assertEqual('');
      // 未来时间（时钟漂移）也不编造相对文案
      expect(relativeText(BASE_MS + HOUR, BASE_MS, TEST_TEXTS)).assertEqual('');
    });

    it('historyAndDownloadFormattingSwitchByMode', 0, () => {
      const threeHoursAgo: number = BASE_MS - 3 * HOUR;
      // 绝对模式
      expect(formatHistoryTime(threeHoursAgo, TIME_FORMAT_ABSOLUTE, TEST_TEXTS, BASE_MS)).assertEqual('11-08 12:04');
      expect(formatDownloadTime(threeHoursAgo, TIME_FORMAT_ABSOLUTE, TEST_TEXTS, BASE_MS)).assertEqual('2026-11-08');
      // 相对模式
      expect(formatHistoryTime(threeHoursAgo, TIME_FORMAT_RELATIVE, TEST_TEXTS, BASE_MS)).assertEqual('3 小时前');
      expect(formatDownloadTime(threeHoursAgo, TIME_FORMAT_RELATIVE, TEST_TEXTS, BASE_MS)).assertEqual('3 小时前');
      // 超期回退绝对
      expect(formatHistoryTime(BASE_MS - 30 * DAY, TIME_FORMAT_RELATIVE, TEST_TEXTS, BASE_MS)).assertEqual('10-09 15:04');
      // 无时间戳：历史空串、下载占位符（与改造前一致）
      expect(formatHistoryTime(0, TIME_FORMAT_RELATIVE, TEST_TEXTS, BASE_MS)).assertEqual('');
      expect(formatDownloadTime(0, TIME_FORMAT_RELATIVE, TEST_TEXTS, BASE_MS)).assertEqual('-');
    });

    it('normalizeAndLabelAreSafe', 0, () => {
      expect(normalizeTimeFormat('')).assertEqual(TIME_FORMAT_ABSOLUTE);
      expect(normalizeTimeFormat('junk')).assertEqual(TIME_FORMAT_ABSOLUTE);
      expect(normalizeTimeFormat(TIME_FORMAT_RELATIVE)).assertEqual(TIME_FORMAT_RELATIVE);
      expect(timeFormatLabel(TIME_FORMAT_ABSOLUTE)).assertEqual('绝对时间');
      expect(timeFormatLabel(TIME_FORMAT_RELATIVE)).assertEqual('相对时间');
      expect(timeFormatLabel('junk')).assertEqual('绝对时间');
    });

    it('preferenceKeepsSingleSourceOfTruth', 0, () => {
      // 同一份偏好：写入后读回一致（无 Preferences 实例时降级为内存生效，返回值 false）
      const prefs: PreferenceManager = PreferenceManager.getInstance();
      prefs.setTimeFormat(TIME_FORMAT_RELATIVE);
      expect(normalizeTimeFormat(prefs.getTimeFormatSync())).assertEqual(TIME_FORMAT_RELATIVE);
      prefs.setTimeFormat('junk');
      expect(prefs.getTimeFormatSync()).assertEqual(TIME_FORMAT_ABSOLUTE);
      // 复位，避免影响其它用例
      prefs.setTimeFormat(TIME_FORMAT_ABSOLUTE);
      expect(prefs.getTimeFormatSync()).assertEqual(TIME_FORMAT_ABSOLUTE);
    });
  });
}
