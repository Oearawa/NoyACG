/**
 * Phase14L.test.ets —— 应用语言（i18n）逻辑回归测试
 *
 * 覆盖 14-L 中「应用侧可验证」的那一半：
 *   1. 平台返回值归一化（zh-Hans-CN / zh-Hant-TW / en-US / default 等）；
 *   2. 选项下标 ↔ 语言 ID 双射与越界回退；
 *   3. 设置链路：成功 / 抛错 / 「调用没报错但平台没生效」三种结局都必须如实反映，
 *      不允许出现「界面显示已切换、系统实际没生效」。
 *
 * 边界说明（不冒充设备验收）：
 * - 系统 API 被 `LanguagePort` 桩替换，因此本测试只证明应用侧的映射与错误处理正确；
 * - 资源是否真的按 zh_TW 解析、冷启动后界面是否变繁体，属于运行时行为，
 *   宿主环境无法验证，报告中标记 RUNTIME_UNVERIFIED。
 */
import { describe, it, expect, beforeEach, afterEach } from '@ohos/hypium';
import {
  AUTONYM_EN_US,
  AUTONYM_ZH_CN,
  AUTONYM_ZH_TW,
  LANG_EN_US,
  LANG_SYSTEM,
  LANG_ZH_CN,
  LANG_ZH_TW,
  LANGUAGE_IDS,
  LanguagePort,
  LocalizationManager,
  bcp47CandidatesForLanguage,
  indexToLanguage,
  languageButtonLabel,
  languageOptionLabels,
  languageToIndex,
  normalizeLanguageId
} from '../main/ets/utils/LocalizationManager';
import { themeAccentName, themeAccentNames, themeAccentResources } from '../main/ets/utils/ThemeAccent';
import { communitySortOptions, formatCommunityTime } from '../main/ets/utils/CommunityFeedHelper';
import { latestFinishedLabels, latestSortLabels } from '../main/ets/components/LatestComponent';
import { ComicDetailViewModel } from '../main/ets/viewmodel/ComicDetailViewModel';
import { HOME_FEED_SECTION_ORDER } from '../main/ets/components/HomeComponent';
import { formatDeviceModelOnly } from '../main/ets/pages/ProfilePage';
import {
  APP_VERSION_CODE,
  APP_VERSION_NAME,
  GITHUB_LATEST_RELEASE_API,
  GITHUB_RELEASES_URL,
  GITHUB_REPO_URL,
  compareSemver,
  evaluateReleaseUpdate,
  stripVersionPrefix
} from '../main/ets/utils/AppUpdateChecker';

/** 读取即失败的端口（模拟系统 API 读取异常） */
class BrokenReadPort implements LanguagePort {
  getPreferred(): string {
    throw new Error('read failed');
  }

  setPreferred(languageId: string): void {
    // 读取失败场景不需要设置
  }
}

/** 可控语言端口：模拟成功 / 抛错 / 静默不生效 */
class FakeLanguagePort implements LanguagePort {
  /** 平台当前语言（模拟系统状态） */
  current: string = 'default';
  /** 设置时是否抛错 */
  failOnSet: boolean = false;
  /** 设置时是否「不报错但也不生效」 */
  ignoreSet: boolean = false;
  /** 调用记录 */
  setCalls: string[] = [];

  getPreferred(): string {
    return this.current;
  }

  setPreferred(languageId: string): void {
    this.setCalls.push(languageId);
    if (this.failOnSet) {
      throw new Error('setAppPreferredLanguage failed');
    }
    if (!this.ignoreSet) {
      this.current = languageId;
    }
  }
}

export default function phase14lTest() {
  describe('Phase14L_LanguageMapping', () => {
    it('optionsAreFourAndOrdered', 0, () => {
      // 跟随系统 / 简体 / 繁体 / English，顺序即设置页 Select 顺序
      expect(LANGUAGE_IDS.length).assertEqual(4);
      expect(LANGUAGE_IDS[0]).assertEqual(LANG_SYSTEM);
      expect(LANGUAGE_IDS[1]).assertEqual(LANG_ZH_CN);
      expect(LANGUAGE_IDS[2]).assertEqual(LANG_ZH_TW);
      expect(LANGUAGE_IDS[3]).assertEqual(LANG_EN_US);
    });

    it('normalizeSystemAndEmpty', 0, () => {
      expect(normalizeLanguageId('default')).assertEqual(LANG_SYSTEM);
      expect(normalizeLanguageId('')).assertEqual(LANG_SYSTEM);
      expect(normalizeLanguageId('   ')).assertEqual(LANG_SYSTEM);
    });

    it('normalizeSimplifiedVariants', 0, () => {
      // 平台可能返回带脚本标记 / 地区的 BCP-47 形式
      expect(normalizeLanguageId('zh-CN')).assertEqual(LANG_ZH_CN);
      expect(normalizeLanguageId('zh-Hans-CN')).assertEqual(LANG_ZH_CN);
      expect(normalizeLanguageId('zh-SG')).assertEqual(LANG_ZH_CN);
      expect(normalizeLanguageId('zh')).assertEqual(LANG_ZH_CN);
    });

    it('normalizeTraditionalVariants', 0, () => {
      expect(normalizeLanguageId('zh-TW')).assertEqual(LANG_ZH_TW);
      expect(normalizeLanguageId('zh-Hant-TW')).assertEqual(LANG_ZH_TW);
      expect(normalizeLanguageId('zh-HK')).assertEqual(LANG_ZH_TW);
      expect(normalizeLanguageId('zh-MO')).assertEqual(LANG_ZH_TW);
    });

    it('unknownLanguageFallsBackToSystem', 0, () => {
      expect(normalizeLanguageId('en-US')).assertEqual(LANG_EN_US);
      expect(normalizeLanguageId('en')).assertEqual(LANG_EN_US);
      expect(normalizeLanguageId('ja-JP')).assertEqual(LANG_SYSTEM);
    });

    it('autonymsStayFixedAcrossLocales', 0, () => {
      const scOpts: string[] = languageOptionLabels('跟随系统');
      const twOpts: string[] = languageOptionLabels('跟隨系統');
      const enOpts: string[] = languageOptionLabels('Follow System');
      expect(scOpts.length).assertEqual(4);
      expect(scOpts[1]).assertEqual(AUTONYM_ZH_CN);
      expect(twOpts[1]).assertEqual('简体中文');
      expect(enOpts[1]).assertEqual('简体中文');
      expect(scOpts[2]).assertEqual(AUTONYM_ZH_TW);
      expect(twOpts[2]).assertEqual('繁體中文');
      expect(enOpts[2]).assertEqual('繁體中文');
      expect(scOpts[3]).assertEqual(AUTONYM_EN_US);
      expect(twOpts[3]).assertEqual('English');
      expect(enOpts[3]).assertEqual('English');
      expect(languageButtonLabel(1, 'Follow System')).assertEqual('简体中文');
      expect(languageButtonLabel(2, 'Follow System')).assertEqual('繁體中文');
      expect(languageButtonLabel(3, 'Follow System')).assertEqual('English');
      expect(languageButtonLabel(0, 'Follow System')).assertEqual('Follow System');
      expect(bcp47CandidatesForLanguage(LANG_ZH_CN)[0]).assertEqual('zh-Hans');
      expect(bcp47CandidatesForLanguage(LANG_ZH_TW)[0]).assertEqual('zh-Hant');
      expect(bcp47CandidatesForLanguage(LANG_EN_US)[0]).assertEqual('en-US');
    });

    it('indexAndLanguageRoundTrip', 0, () => {
      for (let i = 0; i < LANGUAGE_IDS.length; i++) {
        expect(indexToLanguage(languageToIndex(LANGUAGE_IDS[i]))).assertEqual(LANGUAGE_IDS[i]);
      }
      // 越界 / 未知值安全回退
      expect(indexToLanguage(9)).assertEqual(LANG_SYSTEM);
      expect(indexToLanguage(-1)).assertEqual(LANG_SYSTEM);
      expect(languageToIndex('ja-JP')).assertEqual(0);
    });
  });

  describe('Phase14L_ApplyLanguage', () => {
    let port: FakeLanguagePort = new FakeLanguagePort();
    let lm: LocalizationManager = LocalizationManager.getInstance();

    beforeEach(() => {
      port = new FakeLanguagePort();
      lm.setPortForTest(port);
    });

    afterEach(() => {
      // 恢复系统端口，避免污染其它用例
      lm.resetPort();
    });

    it('readsPlatformStateAsTruth', 0, () => {
      port.current = 'zh-TW';
      expect(lm.currentLanguageId()).assertEqual(LANG_ZH_TW);
      expect(lm.currentIndex()).assertEqual(2);
    });

    it('applySimplifiedSucceeds', 0, () => {
      const ok: boolean = lm.applyIndex(1);
      expect(ok).assertTrue();
      expect(port.setCalls[0]).assertEqual(LANG_ZH_CN);
      expect(lm.currentIndex()).assertEqual(1);
      expect(lm.errorMessage).assertEqual('');
    });

    it('applyTraditionalSucceeds', 0, () => {
      const ok: boolean = lm.applyIndex(2);
      expect(ok).assertTrue();
      expect(port.setCalls[0]).assertEqual(LANG_ZH_TW);
      expect(lm.currentIndex()).assertEqual(2);
    });

    it('applyEnglishSucceeds', 0, () => {
      const ok: boolean = lm.applyIndex(3);
      expect(ok).assertTrue();
      expect(port.setCalls[0]).assertEqual(LANG_EN_US);
      expect(lm.currentIndex()).assertEqual(3);
    });

    it('applyFollowSystemSucceeds', 0, () => {
      port.current = 'zh-CN';
      const ok: boolean = lm.applyIndex(0);
      expect(ok).assertTrue();
      expect(port.setCalls[0]).assertEqual(LANG_SYSTEM);
      expect(lm.currentIndex()).assertEqual(0);
    });

    it('apiFailureKeepsOldSettingAndReports', 0, () => {
      port.current = 'zh-CN';
      port.failOnSet = true;
      const ok: boolean = lm.applyIndex(2);
      // 不得伪装成功；平台状态未变 → 选项仍停留在简体
      expect(ok).assertFalse();
      expect(lm.errorMessage !== '').assertTrue();
      expect(lm.currentIndex()).assertEqual(1);
    });

    it('silentlyIgnoredSetIsDetected', 0, () => {
      // 平台没抛错但也没生效（极端情况）：以回读结果为准，必须判定失败
      port.current = 'zh-CN';
      port.ignoreSet = true;
      const ok: boolean = lm.applyIndex(2);
      expect(ok).assertFalse();
      expect(lm.errorMessage.indexOf('未生效') >= 0).assertTrue();
      expect(lm.currentIndex()).assertEqual(1);
    });

    it('readFailureFallsBackToSystem', 0, () => {
      // 读取异常时按「跟随系统」降级，并记录错误，不崩溃
      const broken: BrokenReadPort = new BrokenReadPort();
      lm.setPortForTest(broken);
      expect(lm.currentIndex()).assertEqual(0);
      expect(lm.errorMessage !== '').assertTrue();
    });

    it('savedEnglishOverridesStalePlatformChinese', 0, () => {
      // 核心回归：平台返回系统默认 zh-Hans-CN 时，持久化 en-US 仍必须选中第 3 项（English）
      expect(normalizeLanguageId('en')).assertEqual(LANG_EN_US);
      expect(normalizeLanguageId('en-US')).assertEqual(LANG_EN_US);
      expect(normalizeLanguageId('en-Latn-US')).assertEqual(LANG_EN_US);
      expect(normalizeLanguageId('en-GB')).assertEqual(LANG_EN_US);
      expect(languageToIndex('en-Latn-US')).assertEqual(3);
      expect(languageButtonLabel(3, 'Follow System')).assertEqual('English');
      port.current = 'zh-Hans-CN';
      expect(lm.resolveSelectedLanguageIndex('en-US')).assertEqual(3);
      expect(lm.syncEffectiveLocale('en-US')).assertEqual('en-US');
      expect(lm.effectiveLocale).assertEqual('en-US');
    });

    it('effectiveLocaleResolvesAllThreeLocales', 0, () => {
      port.current = 'zh-Hans-CN';
      expect(lm.resolveSelectedLanguageIndex('default')).assertEqual(0);
      expect(lm.syncEffectiveLocale('default')).assertEqual('zh-CN');
      port.current = 'zh-Hant-TW';
      expect(lm.resolveSelectedLanguageIndex('default')).assertEqual(0);
      expect(lm.syncEffectiveLocale('default')).assertEqual('zh-TW');
      port.current = 'en-US';
      expect(lm.resolveSelectedLanguageIndex('default')).assertEqual(0);
      expect(lm.syncEffectiveLocale('default')).assertEqual('en-US');
      port.current = 'default';
      expect(lm.syncEffectiveLocale('zh-TW')).assertEqual('zh-TW');
      expect(lm.syncEffectiveLocale('zh-CN')).assertEqual('zh-CN');
      expect(lm.syncEffectiveLocale('en-US')).assertEqual('en-US');
    });

    it('localizedThemeAccentNames', 0, () => {
      expect(themeAccentName('mist_iris', 'en-US')).assertEqual('Mist Iris');
      expect(themeAccentName('celadon_sage', 'zh-TW')).assertEqual('青瓷綠');
      expect(themeAccentNames('en-US').length).assertEqual(6);
      expect(themeAccentNames('en-US')[5]).assertEqual('Graphite');
      expect(themeAccentResources().length).assertEqual(6);
    });

    it('localizedCommunityAndLatestHelpers', 0, () => {
      const now: number = 1700000000000;
      expect(formatCommunityTime(now - 10 * 1000, now, 'en-US')).assertEqual('Just now');
      expect(formatCommunityTime(now - 5 * 60 * 1000, now, 'en-US')).assertEqual('5m ago');
      expect(formatCommunityTime(now - 2 * 3600 * 1000, now, 'zh-TW')).assertEqual('2 小時前');
      expect(communitySortOptions('en-US')[0].label).assertEqual('Newest');
      const enSort: string[] = latestSortLabels('en-US');
      expect(enSort.length).assertEqual(4);
      expect(enSort[0]).assertEqual('Newest');
      expect(enSort[1]).assertEqual('Viewed');
      expect(enSort[2]).assertEqual('Liked');
      expect(enSort[3]).assertEqual('Rated');
      for (let i = 0; i < enSort.length; i++) {
        expect(enSort[i].length <= 8).assertTrue();
      }
      expect(latestFinishedLabels('en-US')[0]).assertEqual('All');
      expect(ComicDetailViewModel.ratingLabelForStars(5, 'en-US')).assertEqual('5★ Excellent');
      expect(ComicDetailViewModel.ratingLabelForStars(4, 'zh-TW')).assertEqual('4星 推薦');
    });

    it('homeOrderAndDeviceModelOnly', 0, () => {
      const qualityIdx: number = HOME_FEED_SECTION_ORDER.indexOf('quality');
      const recommendIdx: number = HOME_FEED_SECTION_ORDER.indexOf('recommend');
      expect(qualityIdx >= 0).assertTrue();
      expect(recommendIdx > qualityIdx).assertTrue();
      expect(formatDeviceModelOnly('HOP-AL00', 'HUAWEI Pura 70')).assertEqual('HOP-AL00');
      expect(formatDeviceModelOnly('', 'HUAWEI Pura 70')).assertEqual('HUAWEI Pura 70');
      expect(formatDeviceModelOnly('', '')).assertEqual('—');
    });

    it('appUpdateCheckerSemverAnd404', 0, () => {
      expect(APP_VERSION_NAME).assertEqual('1.0.1');
      expect(APP_VERSION_CODE).assertEqual(1000001);
      expect(GITHUB_REPO_URL).assertEqual('https://github.com/Oearawa/NoyACG');
      expect(GITHUB_RELEASES_URL).assertEqual('https://github.com/Oearawa/NoyACG/releases');
      expect(GITHUB_LATEST_RELEASE_API)
        .assertEqual('https://api.github.com/repos/Oearawa/NoyACG/releases/latest');

      expect(stripVersionPrefix('v1.0.1-beta.1')).assertEqual('1.0.1');
      expect(compareSemver('1.0.0', 'v1.0.1')).assertEqual(-1);
      expect(compareSemver(APP_VERSION_NAME, 'v1.0.1')).assertEqual(0);
      expect(compareSemver('1.2.0', '1.10.0')).assertEqual(-1);
      expect(compareSemver('2.0.0', '1.9.9')).assertEqual(1);

      const notReleased = evaluateReleaseUpdate(APP_VERSION_NAME, 404, '{"message":"Not Found"}');
      expect(notReleased.status).assertEqual('up_to_date');
      expect(notReleased.hasUpdate).assertFalse();

      const serverErr = evaluateReleaseUpdate(APP_VERSION_NAME, 502, '');
      expect(serverErr.status).assertEqual('error');
      expect(serverErr.hasUpdate).assertFalse();

      const currentReleaseJson = '{"tag_name":"v1.0.1","name":"NoyAcg v1.0.1","body":"Current release","html_url":"https://github.com/Oearawa/NoyACG/releases/tag/v1.0.1"}';
      const alreadyCurrent = evaluateReleaseUpdate(APP_VERSION_NAME, 200, currentReleaseJson);
      expect(alreadyCurrent.status).assertEqual('up_to_date');
      expect(alreadyCurrent.hasUpdate).assertFalse();

      const newReleaseJson = '{"tag_name":"v1.0.2","name":"v1.0.2","body":"Bug fixes","html_url":"https://github.com/Oearawa/NoyACG/releases/tag/v1.0.2"}';
      const hasNew = evaluateReleaseUpdate(APP_VERSION_NAME, 200, newReleaseJson);
      expect(hasNew.status).assertEqual('update_available');
      expect(hasNew.hasUpdate).assertTrue();
      expect(hasNew.release !== null).assertTrue();
      expect(hasNew.release?.version).assertEqual('1.0.2');
      expect(hasNew.release?.htmlUrl).assertEqual('https://github.com/Oearawa/NoyACG/releases/tag/v1.0.2');
    });
  });
}
