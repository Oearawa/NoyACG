/**
 * Phase14K.test.ets —— Phase 14-K 主题统一回归测试
 *
 * 为什么用「对比度」做断言：
 * 本阶段的缺陷是「个人中心在浅色系统主题下变成白色页面」，根因是页面用了
 * `$r('sys.color.*')` 系统色。修复后所有业务页面只允许引用 ThemeColors。
 * 静态审查无法阻止以后有人再把浅色写回去，所以这里对 ThemeColors 做
 * **可量化的深色主题契约**校验：
 *   1. 背景令牌必须是深色（相对亮度很低）；
 *   2. 文本令牌必须是浅色；
 *   3. 文本 / 背景、按钮字 / 按钮底、错误色 / 卡片底 的 WCAG 对比度必须达标；
 *   4. 封面遮罩终点必须足够不透明（保证封面上的白字可读）。
 * 断言基于 ThemeColors 的真实取值，颜色被改浅或对比度被改坏都会直接失败。
 */
import { describe, it, expect } from '@ohos/hypium';
import { ThemeColors, ThemeDims, ThemeFonts } from '../main/ets/utils/Theme';

/** 解析 #RRGGBB / #AARRGGBB（返回 0..1 的 RGB + alpha） */
class Rgba {
  r: number = 0;
  g: number = 0;
  b: number = 0;
  a: number = 1;
}

function parseColor(hex: string): Rgba {
  const s: string = hex.charAt(0) === '#' ? hex.substring(1) : hex;
  const out: Rgba = new Rgba();
  if (s.length === 8) {
    out.a = parseInt(s.substring(0, 2), 16) / 255;
    out.r = parseInt(s.substring(2, 4), 16) / 255;
    out.g = parseInt(s.substring(4, 6), 16) / 255;
    out.b = parseInt(s.substring(6, 8), 16) / 255;
  } else {
    out.r = parseInt(s.substring(0, 2), 16) / 255;
    out.g = parseInt(s.substring(2, 4), 16) / 255;
    out.b = parseInt(s.substring(4, 6), 16) / 255;
  }
  return out;
}

/** sRGB 通道 → 线性亮度分量 */
function linearize(channel: number): number {
  return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4);
}

/** WCAG 相对亮度（忽略 alpha：用于判断底色深浅） */
function luminance(hex: string): number {
  const c: Rgba = parseColor(hex);
  return 0.2126 * linearize(c.r) + 0.7152 * linearize(c.g) + 0.0722 * linearize(c.b);
}

/** WCAG 对比度（1..21） */
function contrast(a: string, b: string): number {
  const la: number = luminance(a);
  const lb: number = luminance(b);
  const hi: number = Math.max(la, lb);
  const lo: number = Math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/** 颜色字面量格式校验：仅接受 #RGB? 本项目统一 #RRGGBB / #AARRGGBB */
function isHexColor(value: string): boolean {
  if (value.charAt(0) !== '#') {
    return false;
  }
  return value.length === 7 || value.length === 9;
}

export default function phase14kTest() {
  describe('Phase14K_DarkThemeContract', () => {
    it('backgroundTokensAreDark', 0, () => {
      // 页面底色 / 卡片底色都必须是深色：相对亮度 < 0.05（#121212 约 0.006）
      expect(luminance(ThemeColors.BG) < 0.05).assertTrue();
      expect(luminance(ThemeColors.BG_DEEP) < 0.05).assertTrue();
      expect(luminance(ThemeColors.CARD) < 0.05).assertTrue();
      expect(luminance(ThemeColors.TOP_BAR) < 0.05).assertTrue();
      // 卡片必须比页面底色更亮一点（层次可见），但不能亮到变成浅色面
      expect(luminance(ThemeColors.CARD) > luminance(ThemeColors.BG)).assertTrue();
      expect(luminance(ThemeColors.CARD) < 0.06).assertTrue();
    });

    it('textTokensAreLight', 0, () => {
      expect(luminance(ThemeColors.TEXT_STRONG) > 0.8).assertTrue();
      expect(luminance(ThemeColors.TEXT) > 0.7).assertTrue();
      expect(luminance(ThemeColors.TEXT_SECONDARY) > 0.3).assertTrue();
      expect(luminance(ThemeColors.TEXT_TERTIARY) > 0.5).assertTrue();
      expect(luminance(ThemeColors.TEXT_MUTED) > 0.25).assertTrue();
    });

    it('primaryTextContrastOnBackground', 0, () => {
      // 正文 / 标题：WCAG AAA（>= 7:1）
      expect(contrast(ThemeColors.BG, ThemeColors.TEXT_STRONG) >= 7).assertTrue();
      expect(contrast(ThemeColors.BG, ThemeColors.TEXT) >= 7).assertTrue();
      // 次级 / 最弱文本：至少 AA（>= 4.5:1），否则深色底上会「糊」
      expect(contrast(ThemeColors.BG, ThemeColors.TEXT_SECONDARY) >= 4.5).assertTrue();
      expect(contrast(ThemeColors.BG, ThemeColors.TEXT_MUTED) >= 4.5).assertTrue();
    });

    it('cardTextContrast', 0, () => {
      // 卡片内文字同样要达标（个人中心所有信息都写在 CARD 上）
      expect(contrast(ThemeColors.CARD, ThemeColors.TEXT) >= 7).assertTrue();
      expect(contrast(ThemeColors.CARD, ThemeColors.TEXT_SECONDARY) >= 4.5).assertTrue();
      expect(contrast(ThemeColors.CARD, ThemeColors.TEXT_MUTED) >= 4.5).assertTrue();
    });

    it('accentContrast', 0, () => {
      // 主色按钮：紫底 + 近黑字，必须 >= 4.5:1（截图里登录/退出等按钮都走这个组合）
      expect(contrast(ThemeColors.PRIMARY, ThemeColors.ON_PRIMARY) >= 4.5).assertTrue();
      // 主色作为深色底上的文字（链接/当前选项）也要可读
      expect(contrast(ThemeColors.BG, ThemeColors.PRIMARY) >= 4.5).assertTrue();
      // 错误/危险操作文字（清理缓存、退出登录）
      expect(contrast(ThemeColors.CARD, ThemeColors.ERROR) >= 4.5).assertTrue();
      // 状态色（连载中/已完结徽标上的白字）
      expect(contrast(ThemeColors.STATUS_ONGOING, ThemeColors.ON_COVER) >= 3).assertTrue();
      expect(contrast(ThemeColors.STATUS_COMPLETED, ThemeColors.ON_COVER) >= 3).assertTrue();
    });

    it('coverScrimKeepsWhiteTextReadable', 0, () => {
      // 封面白字必须纯白
      expect(ThemeColors.ON_COVER).assertEqual('#FFFFFF');
      // 遮罩终点 alpha 至少 0.75，否则白字压在亮封面上会看不清
      const scrim: Rgba = parseColor(ThemeColors.SCRIM_TO);
      expect(scrim.a >= 0.75).assertTrue();
      expect(luminance(ThemeColors.SCRIM_TO) < 0.05).assertTrue();
      // 遮罩起点必须完全透明（不能整块压暗封面）
      expect(parseColor(ThemeColors.SCRIM_FROM).a < 0.01).assertTrue();
    });

    it('allCoreTokensAreValidHexColors', 0, () => {
      const tokens: string[] = [
        ThemeColors.BG, ThemeColors.BG_DEEP, ThemeColors.TOP_BAR, ThemeColors.CARD,
        ThemeColors.SURFACE, ThemeColors.SURFACE_PRIMARY, ThemeColors.CARD_ALT,
        ThemeColors.TEXT, ThemeColors.TEXT_STRONG, ThemeColors.TEXT_SECONDARY,
        ThemeColors.TEXT_TERTIARY, ThemeColors.TEXT_MUTED, ThemeColors.PRIMARY,
        ThemeColors.ON_PRIMARY, ThemeColors.ON_COVER, ThemeColors.ON_COVER_SUB,
        ThemeColors.RATING, ThemeColors.ERROR, ThemeColors.SUCCESS, ThemeColors.INFO,
        ThemeColors.STATUS_ONGOING, ThemeColors.STATUS_COMPLETED,
        ThemeColors.DIVIDER, ThemeColors.PLACEHOLDER, ThemeColors.OVERLAY,
        ThemeColors.SCRIM_FROM, ThemeColors.SCRIM_TO
      ];
      for (let i = 0; i < tokens.length; i++) {
        expect(isHexColor(tokens[i])).assertTrue();
      }
    });

    it('cardHierarchyIsSeparatedButSubtle', 0, () => {
      // 层级：BG < CARD_ALT < CARD < SURFACE，亮度单调递增，但差异保持克制（< 2.5:1）
      expect(luminance(ThemeColors.CARD_ALT) > luminance(ThemeColors.BG)).assertTrue();
      expect(luminance(ThemeColors.CARD) > luminance(ThemeColors.CARD_ALT)).assertTrue();
      expect(luminance(ThemeColors.SURFACE) > luminance(ThemeColors.CARD)).assertTrue();
      expect(contrast(ThemeColors.BG, ThemeColors.CARD) < 2.5).assertTrue();
      expect(contrast(ThemeColors.CARD, ThemeColors.SURFACE) < 3).assertTrue();
    });
  });

  describe('Phase14K_TypographyScale', () => {
    it('fontScaleIsMonotonic', 0, () => {
      // 字号层级必须严格递增：卡片标题 < 区块标题 < 页面标题
      expect(ThemeFonts.CAPTION < ThemeFonts.BODY_SMALL).assertTrue();
      expect(ThemeFonts.BODY_SMALL < ThemeFonts.TITLE_CARD).assertTrue();
      expect(ThemeFonts.TITLE_CARD < ThemeFonts.BODY).assertTrue();
      expect(ThemeFonts.BODY < ThemeFonts.TITLE_SECTION).assertTrue();
      expect(ThemeFonts.TITLE_SECTION < ThemeFonts.TITLE_PAGE).assertTrue();
    });

    it('compactProfileSpacing', 0, () => {
      // 个人中心「紧凑」的量化约束：卡片间距小于页面左右边距，卡片最大宽度受控
      expect(ThemeDims.SPACE_M < ThemeDims.PAGE_PADDING).assertTrue();
      expect(ThemeDims.CONTENT_MAX_WIDTH > 0).assertTrue();
      expect(ThemeDims.CONTENT_MAX_WIDTH <= 720).assertTrue();
    });
  });
}
