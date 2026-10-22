// Terminal colors for styled spans, xterm palette.

import type { StyledSpan, TermColor } from "./types";

type RGB = [number, number, number];

/** Light or dark terminal: as the app (default) or fixed. */
export type TerminalAppearance = "app" | "light" | "dark";
/** Same schemes as the Apple apps (`TerminalTheme.swift`). */
export type TerminalScheme = "standard" | "solarized" | "apple";

/** The resolved colors a pane is drawn with. */
export interface TerminalTheme {
  background: RGB;
  foreground: RGB;
  base: RGB[];
  dark: boolean;
  minContrast: boolean;
}

const hex = (value: number): RGB => [(value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff];

const STANDARD = [
  0x000000, 0xcc3d3d, 0x5cb85c, 0xccad3d, 0x4275d6, 0xb05cc7, 0x3dadbd, 0xcccccc,
  0x757575, 0xf56666, 0x85e085, 0xf5db66, 0x75a3fa, 0xdb85f5, 0x6bdbeb, 0xffffff,
].map(hex);

const SOLARIZED = [
  0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
  0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3,
].map(hex);

const APPLE = [
  0x000000, 0x990000, 0x00a600, 0x999900, 0x0000b2, 0xb200b2, 0x00a6b2, 0xbfbfbf,
  0x666666, 0xe50000, 0x00d900, 0xe5e500, 0x0000ff, 0xe500e5, 0x00e5e5, 0xe5e5e5,
].map(hex);

const SCHEMES: Record<TerminalScheme, { light: [number, number]; dark: [number, number]; base: RGB[] }> = {
  standard: { light: [0xffffff, 0x1b1f20], dark: [0x1c1c1f, 0xe0e0e0], base: STANDARD },
  solarized: { light: [0xfdf6e3, 0x657b83], dark: [0x002b36, 0x839496], base: SOLARIZED },
  apple: { light: [0xffffff, 0x000000], dark: [0x1e1e1e, 0xf2f2f2], base: APPLE },
};

export function terminalTheme(scheme: TerminalScheme, dark: boolean, minContrast: boolean): TerminalTheme {
  const s = SCHEMES[scheme] ?? SCHEMES.standard;
  const [background, foreground] = dark ? s.dark : s.light;
  return { background: hex(background), foreground: hex(foreground), base: s.base, dark, minContrast };
}

export const css = ([r, g, b]: RGB) => `rgb(${Math.round(r)}, ${Math.round(g)}, ${Math.round(b)})`;

function indexed(index: number, theme: TerminalTheme): RGB {
  if (index < 16) return theme.base[index];
  if (index < 232) {
    const n = index - 16;
    const step = (v: number) => (v === 0 ? 0 : 55 + v * 40);
    return [step(Math.floor(n / 36)), step(Math.floor(n / 6) % 6), step(n % 6)];
  }
  const grey = 8 + (index - 232) * 10;
  return [grey, grey, grey];
}

function color(c: TermColor, theme: TerminalTheme): RGB | null {
  switch (c.kind) {
    case "default":
      return null;
    case "indexed":
      return indexed(c.index, theme);
    case "rgb":
      return [c.r, c.g, c.b];
  }
}

/** Relative luminance after WCAG 2. */
function luminance([r, g, b]: RGB): number {
  const channel = (v: number) => {
    const c = v / 255;
    return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

function contrast(a: RGB, b: RGB): number {
  const [la, lb] = [luminance(a), luminance(b)];
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

const mix = (a: RGB, b: RGB, t: number): RGB => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];

/** Contrast ratio text gets at least with `minContrast` (WCAG AA); colors
 * move only as far as needed, so they stay recognizable. */
const CONTRAST_TARGET = 4.5;

/** `fg` on `bg`, lightened or darkened until it is readable. */
function readable(fg: RGB, bg: RGB): RGB {
  if (contrast(fg, bg) >= CONTRAST_TARGET) return fg;
  const white: RGB = [255, 255, 255];
  const black: RGB = [0, 0, 0];
  const target = contrast(white, bg) >= contrast(black, bg) ? white : black;
  // The least change that reaches the target.
  let [low, high] = [0, 1];
  for (let i = 0; i < 12; i++) {
    const mid = (low + high) / 2;
    if (contrast(mix(fg, target, mid), bg) < CONTRAST_TARGET) low = mid;
    else high = mid;
  }
  return mix(fg, target, high);
}

/** Inline style of a span; default colors come from the stylesheet. */
/**
 * A row drawn only with box-drawing and block characters, such as a frame
 * or a rule of a full-screen program: wrapping would break it apart, so a
 * wrapping view clips it instead (#191).
 */
export function isRule(spans: StyledSpan[]): boolean {
  const text = spans.map((span) => span.text).join("");
  return /^[\s\u2500-\u259f]*$/.test(text) && /[\u2500-\u259f]/.test(text);
}

export function spanStyle(span: StyledSpan, theme: TerminalTheme): string {
  let fg = color(span.fg, theme);
  let bg = color(span.bg, theme);
  if (span.inverse) {
    [fg, bg] = [bg ?? theme.background, fg ?? theme.foreground];
  }
  if (theme.minContrast && (fg || bg)) fg = readable(fg ?? theme.foreground, bg ?? theme.background);
  const parts: string[] = [];
  if (fg) parts.push(`color: ${css(fg)}`);
  if (bg) parts.push(`background: ${css(bg)}`);
  if (span.bold) parts.push("font-weight: 700");
  if (span.dim) parts.push("opacity: 0.55");
  if (span.italic) parts.push("font-style: italic");
  const lines = [span.underline && "underline", span.strikethrough && "line-through"].filter(Boolean);
  if (lines.length) parts.push(`text-decoration: ${lines.join(" ")}`);
  if (span.hidden) parts.push("color: transparent");
  return parts.join("; ");
}
