/**
 * RichText.ets —— 社区帖子 / 评论正文解析。
 *
 * 站点把正文当纯文本存储，由前端渲染两种特殊标记：
 *   [pack:name]   表情包代码，例如 [noygirl:yeah]（大小写敏感）
 *   NID<数字>     书籍引用，例如 NID123
 */
import { NOY_STICKER_ORIGIN } from '../models/NoyModels';

export enum RichKind {
  Text = 0,
  Sticker = 1,
  Book = 2
}

export class RichSeg {
  kind: RichKind;
  text: string;
  pack: string = '';
  name: string = '';
  bid: number = 0;

  constructor(kind: RichKind, text: string) {
    this.kind = kind;
    this.text = text;
  }
}

class SegBuilder {
  out: RichSeg[] = [];
  buf: string = '';

  flush(): void {
    if (this.buf.length > 0) {
      this.out.push(new RichSeg(RichKind.Text, this.buf));
      this.buf = '';
    }
  }
}

function isDigit(c: string): boolean {
  const code: number = c.charCodeAt(0);
  return code >= 48 && code <= 57;
}

function isAsciiAlnum(c: string): boolean {
  const code: number = c.charCodeAt(0);
  return (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

function isIdent(s: string): boolean {
  if (s.length === 0) {
    return false;
  }
  for (let k = 0; k < s.length; k++) {
    const c: string = s.charAt(k);
    if (!(isAsciiAlnum(c) || c === '_' || c === '-')) {
      return false;
    }
  }
  return true;
}

export function resolveStickerUrl(pack: string, name: string): string {
  if (pack === '' || name === '') {
    return '';
  }
  return `${NOY_STICKER_ORIGIN}/${pack}/${name}.webp`;
}

export function parseRichText(input: string): RichSeg[] {
  const b: SegBuilder = new SegBuilder();
  const n: number = input.length;
  let i: number = 0;

  while (i < n) {
    const ch: string = input.charAt(i);

    if (ch === '[') {
      const end: number = input.indexOf(']', i + 1);
      if (end > i + 1 && end - i <= 48) {
        const inner: string = input.substring(i + 1, end);
        const colon: number = inner.indexOf(':');
        if (colon > 0 && colon < inner.length - 1) {
          const pack: string = inner.substring(0, colon);
          const name: string = inner.substring(colon + 1);
          if (isIdent(pack) && isIdent(name)) {
            b.flush();
            const seg: RichSeg = new RichSeg(RichKind.Sticker, input.substring(i, end + 1));
            seg.pack = pack;
            seg.name = name;
            b.out.push(seg);
            i = end + 1;
            continue;
          }
        }
      }
    } else if (ch === 'N' && input.startsWith('NID', i)) {
      const prevOk: boolean = i === 0 || !isAsciiAlnum(input.charAt(i - 1));
      if (prevOk) {
        let j: number = i + 3;
        while (j < n && isDigit(input.charAt(j))) {
          j++;
        }
        const digits: number = j - (i + 3);
        if (digits > 0 && digits <= 10) {
          b.flush();
          const seg: RichSeg = new RichSeg(RichKind.Book, input.substring(i, j));
          seg.bid = parseInt(input.substring(i + 3, j), 10);
          b.out.push(seg);
          i = j;
          continue;
        }
      }
    }

    b.buf += ch;
    i++;
  }

  b.flush();
  return b.out;
}
