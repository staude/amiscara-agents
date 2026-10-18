// Find in the lines of a pane, history included; case and accents ignored.

import type { PaneContent } from "./types";

export interface SearchMatch {
  line: number;
  start: number;
  length: number;
}

/** Lowercase without accents, one char per char of the input. */
function fold(text: string): string {
  return Array.from(text)
    .map((ch) => {
      const base = ch.normalize("NFD").replace(/\p{M}/gu, "");
      return (base.length === 1 ? base : ch).toLowerCase();
    })
    .join("");
}

export function lineText(line: PaneContent["lines"][number]): string {
  return line.spans.map((s) => s.text).join("");
}

export function findMatches(query: string, content: PaneContent | null): SearchMatch[] {
  if (!query || !content) return [];
  const needle = fold(query);
  const out: SearchMatch[] = [];
  content.lines.forEach((line, index) => {
    const hay = fold(lineText(line));
    let from = 0;
    for (;;) {
      const at = hay.indexOf(needle, from);
      if (at < 0) break;
      out.push({ line: index, start: at, length: needle.length });
      from = at + Math.max(needle.length, 1);
    }
  });
  return out;
}
