/**
 * CommunityRichText.ets —— 社区正文/评论富文本渲染组件
 *
 * 支持：
 * - [pack:name] 表情包内联渲染（ImageSpan）
 * - NID<数字> 书籍引用高亮可点击跳转（ComicDetail）
 * - 列表摘要模式下支持 maxLines + Ellipsis
 */
import { ThemeColors } from '../utils/Theme';
import { parseRichText, resolveStickerUrl, RichKind, RichSeg } from '../utils/RichText';

@ComponentV2
export struct CommunityRichText {
  @Param content: string = '';
  @Param fontSizeFp: number = 14;
  @Param textColor: ResourceColor = ThemeColors.TEXT_SECONDARY;
  @Param maxLinesCount: number = 0;
  @Event onOpenBook: (bid: number) => void = (_bid: number): void => {};

  build() {
    if (this.maxLinesCount > 0) {
      Text() {
        ForEach(parseRichText(this.content), (seg: RichSeg, idx: number) => {
          if (seg.kind === RichKind.Book) {
            Span(` ${seg.text} `)
              .fontSize(this.fontSizeFp)
              .fontColor(ThemeColors.PRIMARY)
              .fontWeight(FontWeight.Medium)
              .onClick((): void => {
                if (seg.bid > 0) {
                  this.onOpenBook(seg.bid);
                }
              })
          } else if (seg.kind === RichKind.Sticker) {
            ImageSpan(resolveStickerUrl(seg.pack, seg.name))
              .width(this.fontSizeFp + 6)
              .height(this.fontSizeFp + 6)
              .objectFit(ImageFit.Contain)
              .verticalAlign(ImageSpanAlignment.CENTER)
          } else {
            Span(seg.text)
              .fontSize(this.fontSizeFp)
              .fontColor(this.textColor)
          }
        }, (seg: RichSeg, idx: number): string => `${idx}_${seg.kind}_${seg.text}`)
      }
      .fontSize(this.fontSizeFp)
      .lineHeight(this.fontSizeFp + 6)
      .maxLines(this.maxLinesCount)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
    } else {
      Text() {
        ForEach(parseRichText(this.content), (seg: RichSeg, idx: number) => {
          if (seg.kind === RichKind.Book) {
            Span(` ${seg.text} `)
              .fontSize(this.fontSizeFp)
              .fontColor(ThemeColors.PRIMARY)
              .fontWeight(FontWeight.Medium)
              .onClick((): void => {
                if (seg.bid > 0) {
                  this.onOpenBook(seg.bid);
                }
              })
          } else if (seg.kind === RichKind.Sticker) {
            ImageSpan(resolveStickerUrl(seg.pack, seg.name))
              .width(this.fontSizeFp + 8)
              .height(this.fontSizeFp + 8)
              .objectFit(ImageFit.Contain)
              .verticalAlign(ImageSpanAlignment.CENTER)
          } else {
            Span(seg.text)
              .fontSize(this.fontSizeFp)
              .fontColor(this.textColor)
          }
        }, (seg: RichSeg, idx: number): string => `${idx}_${seg.kind}_${seg.text}`)
      }
      .fontSize(this.fontSizeFp)
      .lineHeight(this.fontSizeFp + 7)
      .width('100%')
    }
  }
}
