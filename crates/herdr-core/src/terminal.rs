//! Pane content as styled lines.
//!
//! `pane.read` with `format: "ansi"` returns a screen herdr has already
//! rendered: lines separated by `\r\n`, styled with SGR sequences
//! (`ESC[...m`) and nothing else. No cursor movement, no scroll regions.
//! A full terminal emulator would only replay that, so this module parses
//! SGR into runs of equally styled text, which maps directly onto
//! `AttributedString` in SwiftUI and spans in a web view. Any other escape
//! sequence is skipped, so a newer herdr cannot break the view.

use unicode_width::UnicodeWidthStr;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub enum Color {
    #[default]
    Default,
    /// Palette index: 0-7 normal, 8-15 bright, 16-255 the xterm cube and greys.
    Indexed(u8),
    Rgb(u8, u8, u8),
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct Style {
    pub fg: Color,
    pub bg: Color,
    pub bold: bool,
    pub dim: bool,
    pub italic: bool,
    pub underline: bool,
    pub inverse: bool,
    pub hidden: bool,
    pub strikethrough: bool,
}

/// A run of text in one style.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Span {
    pub text: String,
    pub style: Style,
}

impl Span {
    /// Terminal columns, counting wide characters (CJK, most emoji) as two.
    pub fn width(&self) -> usize {
        self.text.width()
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Line {
    pub spans: Vec<Span>,
}

impl Line {
    pub fn width(&self) -> usize {
        self.spans.iter().map(Span::width).sum()
    }

    pub fn text(&self) -> String {
        self.spans.iter().map(|span| span.text.as_str()).collect()
    }

    fn push(&mut self, ch: char, style: Style) {
        match self.spans.last_mut() {
            Some(span) if span.style == style => span.text.push(ch),
            _ => self.spans.push(Span {
                text: ch.to_string(),
                style,
            }),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Screen {
    pub lines: Vec<Line>,
}

const TAB_WIDTH: usize = 8;

impl Screen {
    /// Parses `pane.read` output in `ansi` format. Plain `text` output works
    /// too and yields unstyled lines.
    pub fn parse(input: &str) -> Self {
        let mut lines = Vec::new();
        let mut line = Line::default();
        let mut style = Style::default();
        let mut chars = input.chars().peekable();

        while let Some(ch) = chars.next() {
            match ch {
                '\x1b' => match chars.next() {
                    Some('[') => {
                        let mut body = String::new();
                        let mut final_byte = None;
                        for c in chars.by_ref() {
                            if ('\x40'..='\x7e').contains(&c) {
                                final_byte = Some(c);
                                break;
                            }
                            body.push(c);
                        }
                        if final_byte == Some('m') && is_plain_params(&body) {
                            apply_sgr(&mut style, &body);
                        }
                    }
                    // OSC (e.g. OSC 8 hyperlinks) and other strings run to BEL or ST.
                    Some(']' | 'P' | 'X' | '^' | '_') => {
                        while let Some(c) = chars.next() {
                            if c == '\x07' {
                                break;
                            }
                            if c == '\x1b' {
                                if chars.peek() == Some(&'\\') {
                                    chars.next();
                                }
                                break;
                            }
                        }
                    }
                    // Two-byte escapes (ESC 7, ESC =, ...) carry no text.
                    _ => {}
                },
                '\n' => lines.push(std::mem::take(&mut line)),
                '\r' => {}
                '\t' => {
                    let pad = TAB_WIDTH - line.width() % TAB_WIDTH;
                    for _ in 0..pad {
                        line.push(' ', style);
                    }
                }
                c if c.is_control() => {}
                c => line.push(c, style),
            }
        }
        // A trailing newline ends the last line rather than opening a new one.
        if !input.ends_with('\n') {
            lines.push(line);
        }
        Self { lines }
    }

    /// The text without styles, one entry per line.
    pub fn text_lines(&self) -> Vec<String> {
        self.lines.iter().map(Line::text).collect()
    }
}

/// SGR parameters are digits, `;` and `:` only. A private marker such as
/// `?` or `>` makes it a different sequence (e.g. `CSI > 4 m`).
fn is_plain_params(body: &str) -> bool {
    body.chars()
        .all(|c| c.is_ascii_digit() || c == ';' || c == ':')
}

fn apply_sgr(style: &mut Style, body: &str) {
    // `ESC[m` is a reset.
    if body.is_empty() {
        *style = Style::default();
        return;
    }
    let groups: Vec<Vec<Option<u16>>> = body
        .split(';')
        .map(|group| group.split(':').map(|n| n.parse().ok()).collect())
        .collect();
    let mut i = 0;
    while i < groups.len() {
        let group = &groups[i];
        let code = group.first().copied().flatten().unwrap_or(0);
        match code {
            0 => *style = Style::default(),
            1 => style.bold = true,
            2 => style.dim = true,
            3 => style.italic = true,
            // `4:0` turns underline off, other sub-styles (curly, dotted) count as on.
            4 => style.underline = group.get(1).copied().flatten() != Some(0),
            7 => style.inverse = true,
            8 => style.hidden = true,
            9 => style.strikethrough = true,
            21 => style.underline = true,
            22 => {
                style.bold = false;
                style.dim = false;
            }
            23 => style.italic = false,
            24 => style.underline = false,
            27 => style.inverse = false,
            28 => style.hidden = false,
            29 => style.strikethrough = false,
            30..=37 => style.fg = Color::Indexed((code - 30) as u8),
            39 => style.fg = Color::Default,
            40..=47 => style.bg = Color::Indexed((code - 40) as u8),
            49 => style.bg = Color::Default,
            90..=97 => style.fg = Color::Indexed((code - 90 + 8) as u8),
            100..=107 => style.bg = Color::Indexed((code - 100 + 8) as u8),
            38 | 48 | 58 => {
                let (color, used) = extended_color(&groups, i);
                i += used;
                match (code, color) {
                    (38, Some(color)) => style.fg = color,
                    (48, Some(color)) => style.bg = color,
                    // 58 is the underline color; consumed, not shown.
                    _ => {}
                }
            }
            _ => {}
        }
        i += 1;
    }
}

/// Reads `38;5;n`, `38;2;r;g;b` or the colon forms `38:5:n`, `38:2::r:g:b`
/// and `38:2:r:g:b`. Returns the color and how many extra `;` groups it used.
fn extended_color(groups: &[Vec<Option<u16>>], i: usize) -> (Option<Color>, usize) {
    let group = &groups[i];
    if group.len() > 1 {
        let color = match group.get(1).copied().flatten() {
            Some(5) => group
                .get(2)
                .copied()
                .flatten()
                .map(|n| Color::Indexed(byte(n))),
            Some(2) => {
                let rgb = if group.len() >= 6 {
                    &group[3..6]
                } else {
                    &group[2..]
                };
                rgb_color(rgb)
            }
            _ => None,
        };
        return (color, 0);
    }
    let arg = |k: usize| groups.get(i + k).and_then(|g| g.first().copied().flatten());
    match arg(1) {
        Some(5) => (arg(2).map(|n| Color::Indexed(byte(n))), 2),
        Some(2) => {
            let rgb = [arg(2), arg(3), arg(4)];
            (rgb_color(&rgb), 4)
        }
        _ => (None, 1),
    }
}

fn rgb_color(parts: &[Option<u16>]) -> Option<Color> {
    match parts {
        [Some(r), Some(g), Some(b), ..] => Some(Color::Rgb(byte(*r), byte(*g), byte(*b))),
        _ => None,
    }
}

fn byte(n: u16) -> u8 {
    u8::try_from(n).unwrap_or(u8::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spans(line: &Line) -> Vec<(&str, Style)> {
        line.spans
            .iter()
            .map(|s| (s.text.as_str(), s.style))
            .collect()
    }

    #[test]
    fn plain_lines_with_crlf() {
        let screen = Screen::parse("one\r\ntwo\r\n\r\nfour");
        assert_eq!(screen.text_lines(), ["one", "two", "", "four"]);
    }

    #[test]
    fn trailing_newline_does_not_add_a_line() {
        assert_eq!(Screen::parse("a\r\nb\r\n").text_lines(), ["a", "b"]);
        assert_eq!(Screen::parse("").text_lines(), [""]);
    }

    #[test]
    fn truecolor_and_reset_from_real_output() {
        let screen = Screen::parse("verwirf mit \x1b[0m\x1b[38;2;177;185;249mgit -C \x1b[0m\r\n");
        let line = &screen.lines[0];
        assert_eq!(
            spans(line),
            [
                ("verwirf mit ", Style::default()),
                (
                    "git -C ",
                    Style {
                        fg: Color::Rgb(177, 185, 249),
                        ..Style::default()
                    }
                ),
            ]
        );
    }

    #[test]
    fn style_carries_across_lines_until_reset() {
        let screen = Screen::parse("\x1b[1;3mbold\r\nstill\x1b[0m plain");
        let bold_italic = Style {
            bold: true,
            italic: true,
            ..Style::default()
        };
        assert_eq!(spans(&screen.lines[0]), [("bold", bold_italic)]);
        assert_eq!(
            spans(&screen.lines[1]),
            [("still", bold_italic), (" plain", Style::default())]
        );
    }

    #[test]
    fn attributes_switch_off_individually() {
        let mut style = Style::default();
        apply_sgr(&mut style, "1;2;4;7;9");
        assert!(style.bold && style.dim && style.underline && style.inverse && style.strikethrough);
        apply_sgr(&mut style, "22;24;27;29");
        assert_eq!(style, Style::default());
        apply_sgr(&mut style, "4:3");
        assert!(style.underline, "curly underline counts");
        apply_sgr(&mut style, "4:0");
        assert!(!style.underline);
    }

    #[test]
    fn palette_colors() {
        let mut style = Style::default();
        apply_sgr(&mut style, "31;102");
        assert_eq!(
            (style.fg, style.bg),
            (Color::Indexed(1), Color::Indexed(10))
        );
        apply_sgr(&mut style, "90;40");
        assert_eq!((style.fg, style.bg), (Color::Indexed(8), Color::Indexed(0)));
        apply_sgr(&mut style, "38;5;208;48;5;236");
        assert_eq!(
            (style.fg, style.bg),
            (Color::Indexed(208), Color::Indexed(236))
        );
        apply_sgr(&mut style, "39;49");
        assert_eq!((style.fg, style.bg), (Color::Default, Color::Default));
    }

    #[test]
    fn colon_color_forms() {
        let mut style = Style::default();
        apply_sgr(&mut style, "38:2::10:20:30");
        assert_eq!(style.fg, Color::Rgb(10, 20, 30));
        apply_sgr(&mut style, "48:2:1:2:3");
        assert_eq!(style.bg, Color::Rgb(1, 2, 3));
        apply_sgr(&mut style, "38:5:42");
        assert_eq!(style.fg, Color::Indexed(42));
    }

    #[test]
    fn underline_color_is_consumed_not_applied() {
        let mut style = Style::default();
        apply_sgr(&mut style, "58;2;1;2;3;1");
        assert_eq!(
            style,
            Style {
                bold: true,
                ..Style::default()
            }
        );
    }

    #[test]
    fn other_sequences_are_skipped() {
        let input =
            "a\x1b[2Jb\x1b[?25lc\x1b]8;;https://x.y\x07link\x1b]8;;\x1b\\d\x1b[>4;1me\x1b=f";
        assert_eq!(Screen::parse(input).text_lines(), ["abclinkdef"]);
    }

    #[test]
    fn tabs_expand_and_wide_chars_count_double() {
        let screen = Screen::parse("ab\tc\r\n日本🙂x");
        assert_eq!(screen.text_lines()[0], "ab      c");
        assert_eq!(screen.lines[1].width(), 7);
    }

    #[test]
    fn unfinished_sequence_at_end_is_dropped() {
        assert_eq!(Screen::parse("ok\x1b[38;2;1").text_lines(), ["ok"]);
    }
}
