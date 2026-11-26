// A terminal's text to select and copy on a phone (Phone.tsx's Select text): the scrollback and
// the screen as lines. A row the terminal wrapped onto continues the row before it, so a long
// command or URL copies whole; the row before keeps its trailing blanks then (a space at the wrap
// is the text's), any other row loses them; but a wide character (CJK, emoji) that did not fit
// in the row's last cell wraps whole and leaves that cell empty, which is not text. Blank rows at
// the end are dropped.

export interface RowSource {
  length: number; // rows in the buffer (scrollback + screen)
  text(y: number, trimRight: boolean): string;
  wrapped(y: number): boolean; // row y continues row y - 1
  wideStart?(y: number): boolean; // row y's first cell holds a wide character
  lastEmpty?(y: number): boolean; // row y's last cell holds nothing (not even a space)
}

// At most the last `max` rows, from the first row of the line they start in.
export function bufferText(src: RowSource, max: number): string {
  let from = Math.max(0, src.length - max);
  while (from > 0 && src.wrapped(from)) from--;
  const lines: string[] = [];
  for (let y = from; y < src.length; y++) {
    const next = y + 1 < src.length && src.wrapped(y + 1);
    let t = src.text(y, !next);
    // the empty cell a wide character left when it wrapped
    if (next && src.wideStart?.(y + 1) && src.lastEmpty?.(y) && t.endsWith(" ")) t = t.slice(0, -1);
    if (src.wrapped(y) && lines.length) lines[lines.length - 1] += t;
    else lines.push(t);
  }
  while (lines.length && lines[lines.length - 1].trim() === "") lines.pop();
  return lines.join("\n");
}
