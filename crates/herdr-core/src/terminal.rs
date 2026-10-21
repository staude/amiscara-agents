//! Pane content as styled lines.
//!
//! `pane.read` with `format: "ansi"` returns a screen herdr has already
//! rendered: lines separated by `\r\n`, styled with SGR sequences
//! (`ESC[...m`) and nothing else. No cursor movement, no scroll regions.
//! A full terminal emulator would only replay that, so this module parses
//! SGR into runs of equally styled text, which maps directly onto
//! `AttributedString` in SwiftUI and spans in a web view. Any other escape
//! sequence is skipped, so a newer herdr cannot break the view.
//!
//! herdr drops the targets of OSC 8 hyperlinks from this format, so links
//! are web addresses found in the text (#186).

use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

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
    /// The web address this text belongs to; a wrapped address links all
    /// of its parts to the whole of it.
    pub link: Option<String>,
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
                link: None,
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
        let mut screen = Self { lines };
        screen.mark_links();
        screen
    }

    /// Finds web addresses and puts them on the spans as links.
    fn mark_links(&mut self) {
        if !self
            .lines
            .iter()
            .any(|line| line.spans.iter().any(|span| span.text.contains("://")))
        {
            return;
        }
        let rows: Vec<Vec<char>> = self
            .lines
            .iter()
            .map(|line| line.text().chars().collect())
            .collect();
        let found = find_links(&rows);
        if found.is_empty() {
            return;
        }
        let mut marks: Vec<Vec<Option<usize>>> =
            rows.iter().map(|row| vec![None; row.len()]).collect();
        for (index, link) in found.iter().enumerate() {
            for &(row, start, end) in &link.parts {
                marks[row][start..end].fill(Some(index));
            }
        }
        for (line, marks) in self.lines.iter_mut().zip(&marks) {
            if marks.iter().all(Option::is_none) {
                continue;
            }
            let cells: Vec<(char, Style)> = line
                .spans
                .iter()
                .flat_map(|span| span.text.chars().map(move |c| (c, span.style)))
                .collect();
            let mut spans: Vec<Span> = Vec::new();
            for ((c, style), mark) in cells.into_iter().zip(marks) {
                let link = mark.map(|index| &found[index].url);
                match spans.last_mut() {
                    Some(span) if span.style == style && span.link.as_ref() == link => {
                        span.text.push(c)
                    }
                    _ => spans.push(Span {
                        text: c.to_string(),
                        style,
                        link: link.cloned(),
                    }),
                }
            }
            line.spans = spans;
        }
    }

    /// The text without styles, one entry per line.
    pub fn text_lines(&self) -> Vec<String> {
        self.lines.iter().map(Line::text).collect()
    }

    /// The last `max_lines` lines with text, without styles, for a small
    /// screen such as the Watch (#156): trailing spaces trimmed, blank lines
    /// at the bottom dropped, runs of blank lines folded into one, and each
    /// line cut to [`EXCERPT_LINE_CHARS`] characters.
    pub fn excerpt(&self, max_lines: usize) -> String {
        let mut lines: Vec<String> = Vec::new();
        for line in self.text_lines().iter().rev() {
            if lines.len() == max_lines {
                break;
            }
            let text: String = line.trim_end().chars().take(EXCERPT_LINE_CHARS).collect();
            if text.is_empty() && lines.last().is_none_or(String::is_empty) {
                continue;
            }
            lines.push(text);
        }
        while lines.last().is_some_and(String::is_empty) {
            lines.pop();
        }
        lines.reverse();
        lines.join("\n")
    }
}

/// A web address and where it stands: `(row, start, end)` in characters,
/// more than one part when it wraps.
#[derive(Debug, PartialEq, Eq)]
struct FoundLink {
    url: String,
    parts: Vec<(usize, usize, usize)>,
}

/// A screen narrower than this has no full lines to wrap at.
const MIN_WRAP_WIDTH: usize = 40;

/// `http://` and `https://` addresses. One that reaches the right edge of a
/// full line goes on in the next line when that line is not indented (the
/// terminal wrapped it) or the address began its line (an agent such as
/// Claude Code wraps with an indent, but moves a word to the next line
/// first, so an address that only ends at the edge stands alone).
fn find_links(rows: &[Vec<char>]) -> Vec<FoundLink> {
    let trimmed = |row: &[char]| row.len() - row.iter().rev().take_while(|c| **c == ' ').count();
    let indent = |row: &[char]| row.iter().take_while(|c| **c == ' ').count();
    let width = |row: &[char]| {
        row[..trimmed(row)]
            .iter()
            .map(|c| c.width().unwrap_or(0))
            .sum::<usize>()
    };
    let full = rows.iter().map(|row| width(row)).max().unwrap_or(0);

    let mut found = Vec::new();
    let (mut row, mut col) = (0, 0);
    while row < rows.len() {
        let Some(start) = url_start(&rows[row], col) else {
            row += 1;
            col = 0;
            continue;
        };
        let end = url_end(&rows[row], start);
        let mut url: String = rows[row][start..end].iter().collect();
        let mut parts = vec![(row, start, end)];
        let (mut at, mut part_start, mut part_end) = (row, start, end);
        while full >= MIN_WRAP_WIDTH
            && part_end == trimmed(&rows[at])
            && width(&rows[at]) == full
            && at + 1 < rows.len()
            && (indent(&rows[at + 1]) == 0 || part_start == indent(&rows[at]))
        {
            let next = &rows[at + 1];
            let from = indent(next);
            let to = url_end(next, from);
            if to == from {
                break;
            }
            url.extend(&next[from..to]);
            parts.push((at + 1, from, to));
            (at, part_start, part_end) = (at + 1, from, to);
        }
        let cut = trailing_punctuation(&url);
        for _ in 0..cut {
            url.pop();
        }
        let mut left = cut;
        while left > 0 {
            let last = parts.last_mut().expect("an address has a part");
            let take = left.min(last.2 - last.1);
            last.2 -= take;
            left -= take;
            if last.1 == last.2 {
                parts.pop();
            }
        }
        (row, col) = (at, part_end);
        if url
            .split_once("://")
            .is_some_and(|(_, rest)| !rest.is_empty())
        {
            found.push(FoundLink { url, parts });
        }
    }
    found
}

/// The next `http://` or `https://` at or after `from` that does not stand
/// inside a word.
fn url_start(row: &[char], from: usize) -> Option<usize> {
    (from..row.len()).find(|&i| {
        (i == 0 || !row[i - 1].is_alphanumeric())
            && ["https://", "http://"].iter().any(|scheme| {
                row[i..]
                    .iter()
                    .copied()
                    .take(scheme.len())
                    .eq(scheme.chars())
            })
    })
}

fn url_end(row: &[char], from: usize) -> usize {
    from + row[from..].iter().take_while(|c| is_url_char(**c)).count()
}

/// Not whitespace, quotes or angle brackets, and no box drawing a TUI puts
/// around text.
fn is_url_char(c: char) -> bool {
    !(c.is_whitespace()
        || c.is_control()
        || matches!(c, '<' | '>' | '"' | '\'' | '`' | '\u{2500}'..='\u{259f}'))
}

/// Characters at the end that close the sentence rather than the address:
/// `.`, `,`, `:` and the like, and a `)` or `]` without its opening one.
fn trailing_punctuation(url: &str) -> usize {
    let mut chars: Vec<char> = url.chars().collect();
    let mut cut = 0;
    while let Some(&last) = chars.last() {
        let unbalanced = |open: char, close: char| {
            last == close
                && chars.iter().filter(|c| **c == open).count()
                    < chars.iter().filter(|c| **c == close).count()
        };
        if matches!(last, '.' | ',' | ';' | ':' | '!' | '?')
            || unbalanced('(', ')')
            || unbalanced('[', ']')
        {
            chars.pop();
            cut += 1;
        } else {
            break;
        }
    }
    cut
}

/// Longest line in [`Screen::excerpt`].
pub const EXCERPT_LINE_CHARS: usize = 200;

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
    fn excerpt_keeps_the_last_lines_with_text() {
        let screen = Screen::parse(
            "old\r\n\x1b[1mDo you want to proceed?\x1b[0m   \r\n\r\n\r\n\
             \u{276f} 1. Yes\r\n  2. No\r\n\r\n\r\n",
        );
        assert_eq!(
            screen.excerpt(4),
            "Do you want to proceed?\n\n\u{276f} 1. Yes\n  2. No"
        );
        assert_eq!(screen.excerpt(2), "\u{276f} 1. Yes\n  2. No");
        assert_eq!(Screen::parse("\r\n\r\n").excerpt(5), "");
    }

    #[test]
    fn excerpt_cuts_long_lines() {
        let screen = Screen::parse(&"\u{2500}".repeat(EXCERPT_LINE_CHARS + 10));
        assert_eq!(screen.excerpt(1).chars().count(), EXCERPT_LINE_CHARS);
    }

    fn links(screen: &Screen) -> Vec<(String, String)> {
        screen
            .lines
            .iter()
            .flat_map(|line| &line.spans)
            .filter_map(|span| Some((span.text.clone(), span.link.clone()?)))
            .collect()
    }

    fn link(text: &str, url: &str) -> (String, String) {
        (text.to_string(), url.to_string())
    }

    /// A full-width rule as Claude Code and shell prompts draw one.
    fn rule(width: usize) -> String {
        "\u{2500}".repeat(width)
    }

    #[test]
    fn web_addresses_become_links() {
        let screen = Screen::parse("  PR: https://github.com/o/r/pull/1 and http://x.y/a?b=1&c=2");
        assert_eq!(
            links(&screen),
            [
                link(
                    "https://github.com/o/r/pull/1",
                    "https://github.com/o/r/pull/1"
                ),
                link("http://x.y/a?b=1&c=2", "http://x.y/a?b=1&c=2"),
            ]
        );
        assert_eq!(
            screen.text_lines(),
            ["  PR: https://github.com/o/r/pull/1 and http://x.y/a?b=1&c=2"]
        );
    }

    #[test]
    fn link_keeps_the_styles_it_crosses() {
        let screen = Screen::parse("see \x1b[1mhttps://a.b/\x1b[0mc d");
        let bold = Style {
            bold: true,
            ..Style::default()
        };
        let spans: Vec<_> = screen.lines[0]
            .spans
            .iter()
            .map(|s| (s.text.as_str(), s.style, s.link.as_deref()))
            .collect();
        assert_eq!(
            spans,
            [
                ("see ", Style::default(), None),
                ("https://a.b/", bold, Some("https://a.b/c")),
                ("c", Style::default(), Some("https://a.b/c")),
                (" d", Style::default(), None),
            ]
        );
    }

    #[test]
    fn sentence_punctuation_is_not_part_of_the_link() {
        let screen = Screen::parse(
            "(siehe https://x.y/issues/3238). Oder https://x.y/wiki/A_(B), \"https://q.r\" <https://s.t>",
        );
        let urls: Vec<String> = links(&screen).into_iter().map(|(_, url)| url).collect();
        assert_eq!(
            urls,
            [
                "https://x.y/issues/3238",
                "https://x.y/wiki/A_(B)",
                "https://q.r",
                "https://s.t"
            ]
        );
    }

    #[test]
    fn no_link_without_host_or_inside_a_word() {
        let screen = Screen::parse("https:// and xhttps://a.b and ftp://c.d");
        assert!(links(&screen).is_empty());
    }

    #[test]
    fn box_drawing_ends_a_link() {
        let screen = Screen::parse("\u{2502} https://a.b/c\u{2502}");
        assert_eq!(links(&screen), [link("https://a.b/c", "https://a.b/c")]);
    }

    #[test]
    fn address_wrapped_by_the_terminal_links_both_parts() {
        let first = format!("$ open https://example.com/{}", "a".repeat(33));
        assert_eq!(first.len(), 60);
        let screen = Screen::parse(&format!("{}\r\n{first}\r\nbcd/e?f=1 rest\r\n$ ", rule(60)));
        let url = format!("https://example.com/{}bcd/e?f=1", "a".repeat(33));
        assert_eq!(
            links(&screen),
            [link(&first[7..], &url), link("bcd/e?f=1", &url)]
        );
    }

    #[test]
    fn indented_address_wrapped_by_an_agent_links_both_parts() {
        let first = format!("  https://example.com/{}", "a".repeat(38));
        let screen = Screen::parse(&format!("{}\r\n{first}\r\n  tail.\r\n  next", rule(60)));
        let url = format!("https://example.com/{}tail", "a".repeat(38));
        assert_eq!(
            links(&screen),
            [link(&first[2..], &url), link("tail", &url)]
        );
    }

    #[test]
    fn address_that_only_ends_at_the_edge_stays_alone() {
        // Claude Code moved the next word down; the address did not wrap.
        let first = format!("  Link: https://example.com/{}", "a".repeat(32));
        let screen = Screen::parse(&format!("{}\r\n{first}\r\n  bearbeiten", rule(60)));
        let url = format!("https://example.com/{}", "a".repeat(32));
        assert_eq!(links(&screen), [link(&url, &url)]);
    }

    #[test]
    fn short_line_does_not_wrap() {
        let screen = Screen::parse(&format!("{}\r\nhttps://a.b/c\r\nnext", rule(60)));
        assert_eq!(links(&screen), [link("https://a.b/c", "https://a.b/c")]);
    }

    #[test]
    fn unfinished_sequence_at_end_is_dropped() {
        assert_eq!(Screen::parse("ok\x1b[38;2;1").text_lines(), ["ok"]);
    }
}
