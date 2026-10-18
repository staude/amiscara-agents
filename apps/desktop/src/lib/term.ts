// Terminal colors for styled spans, xterm palette.

import type { StyledSpan, TermColor } from "./types";

const BASE = [
  "#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5",
  "#666666", "#f14c4c", "#23d18b", "#f5f543", "#3b8eea", "#d670d6", "#29b8db", "#ffffff",
];

function indexed(index: number): string {
  if (index < 16) return BASE[index];
  if (index < 232) {
    const n = index - 16;
    const step = (v: number) => (v === 0 ? 0 : 55 + v * 40);
    return `rgb(${step(Math.floor(n / 36))}, ${step(Math.floor(n / 6) % 6)}, ${step(n % 6)})`;
  }
  const grey = 8 + (index - 232) * 10;
  return `rgb(${grey}, ${grey}, ${grey})`;
}

function color(c: TermColor): string | null {
  switch (c.kind) {
    case "default":
      return null;
    case "indexed":
      return indexed(c.index);
    case "rgb":
      return `rgb(${c.r}, ${c.g}, ${c.b})`;
  }
}

/** Inline style of a span; default colors come from the stylesheet. */
export function spanStyle(span: StyledSpan): string {
  let fg = color(span.fg);
  let bg = color(span.bg);
  if (span.inverse) {
    [fg, bg] = [bg ?? "var(--term-bg)", fg ?? "var(--term-fg)"];
  }
  const parts: string[] = [];
  if (fg) parts.push(`color: ${fg}`);
  if (bg) parts.push(`background: ${bg}`);
  if (span.bold) parts.push("font-weight: 700");
  if (span.dim) parts.push("opacity: 0.55");
  if (span.italic) parts.push("font-style: italic");
  const lines = [span.underline && "underline", span.strikethrough && "line-through"].filter(Boolean);
  if (lines.length) parts.push(`text-decoration: ${lines.join(" ")}`);
  if (span.hidden) parts.push("color: transparent");
  return parts.join("; ");
}
