/**
 * CommunityImageViewer.ets —— 社区图片大图预览遮罩（经 MangaImage 走防盗链 Referer）
 */
import { MangaImage } from './MangaImage';

@ComponentV2
export struct CommunityImageViewer {
  @Param imageUrl: string = '';
  @Event onClose: () => void = (): void => {};

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        MangaImage({
          imageUrl: this.imageUrl,
          fillPage: true,
          allowTapRetry: true,
          diagLabel: 'community-preview'
        })
          .width('100%')
          .height('100%')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .onClick((): void => {
        this.onClose();
      })

      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(20)
          .fontColor(['#FFFFFF'])
      }
      .width(40)
      .height(40)
      .borderRadius(20)
      .backgroundColor('#80000000')
      .margin({ top: 44, right: 16 })
      .onClick((): void => {
        this.onClose();
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#E6000000')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
