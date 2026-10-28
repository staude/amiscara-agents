//! Choice questions on a pane's screen (#272): Claude Code's permission
//! prompt and AskUserQuestion list numbered options, one marked `❯`, and
//! take the digit as the answer. Found on the visible screen, not in the
//! conversation history, which holds no options for permission prompts.
//!
//! The search runs from the bottom: below the dialog stand only a hint
//! such as `Esc to cancel` and lines of box characters, above its last
//! option the others follow without gaps up to `1.`. Anything else, such as
//! a numbered list in the agent's output without a marker, is no question.

use crate::terminal::Screen;

/// One option of a choice question; `number` is the digit that selects it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Choice {
    pub number: u8,
    pub label: String,
}

/// Lines with text below the last option, other than box characters: the
/// hint, a status line of more than one row, the unnumbered `Chat about
/// this` and `Notes` of a question with previews.
const MAX_TAIL_LINES: usize = 5;

/// Options that need more than a key press: free text or a chat.
const SKIPPED_LABELS: [&str; 3] = ["Type something.", "Type something", "Chat about this"];

/// Labels of a question with several answers, which needs more than one
/// step.
const CHECKBOXES: [&str; 5] = ["[ ]", "[✔]", "[x]", "☐", "☒"];

/// The options of the choice question at the bottom of the screen, `None`
/// when there is none or it is answered by more than a digit.
pub fn detect(screen: &Screen) -> Option<Vec<Choice>> {
    detect_lines(&screen.text_lines())
}

fn detect_lines(lines: &[String]) -> Option<Vec<Choice>> {
    let mut rows = lines.iter().rev();
    let mut tail = 0;
    let last = loop {
        let line = rows.next()?;
        if let Some(option) = Row::option(line) {
            break option;
        }
        // The agent's own input line: its dialog is not open, so options
        // above are a prompt the user sent, as Claude Code echoes it.
        if line.trim_start().starts_with('❯') {
            return None;
        }
        if !Row::is_blank_or_frame(line) {
            tail += 1;
            if tail > MAX_TAIL_LINES {
                return None;
            }
        }
    };

    // More than nine options take more than one key; no question then.
    if last.number > 9 {
        return None;
    }
    let indent = last.indent;
    let mut found = vec![last];
    while found.last()?.number > 1 {
        let line = rows.next()?;
        // A description may start with a number such as `10. Mai`.
        if let Some(option) = Row::option(line).filter(|option| option.number <= 9) {
            let expected = found.last()?.number - 1;
            if option.number != expected || option.indent != indent {
                return None;
            }
            found.push(option);
        } else if !Row::is_blank_or_frame(line) && Row::indent(line) <= indent {
            return None;
        }
    }
    found.reverse();
    // Options right under a rule are a numbered prompt typed into the
    // agent's input box, not sent yet; a dialog has its question above.
    if rows.next().is_some_and(|line| Row::is_rule(line)) {
        return None;
    }

    if found.len() < 2
        || found.iter().filter(|option| option.selected).count() != 1
        || found
            .iter()
            .any(|option| CHECKBOXES.iter().any(|mark| option.label.starts_with(mark)))
    {
        return None;
    }
    let choices: Vec<Choice> = found
        .into_iter()
        .filter(|option| !SKIPPED_LABELS.contains(&option.label.as_str()))
        .map(|option| Choice {
            number: option.number,
            label: option.label,
        })
        .collect();
    (!choices.is_empty()).then_some(choices)
}

/// A line read as an option: `❯ 2. Label`, optionally in a `│` frame.
#[derive(Debug)]
struct Row {
    number: u8,
    label: String,
    selected: bool,
    /// Column of the digit; the options of one question line up.
    indent: usize,
}

impl Row {
    fn option(line: &str) -> Option<Self> {
        let line = line.trim_end().trim_end_matches('│').trim_end();
        let start = line.trim_start_matches(|c: char| c.is_whitespace() || c == '│');
        let (selected, rest) = match start.strip_prefix('❯') {
            Some(rest) => (true, rest.trim_start()),
            None => (false, start),
        };
        let indent = line.chars().count() - rest.chars().count();
        let digits = rest.chars().take_while(char::is_ascii_digit).count();
        let after = rest[digits..].strip_prefix(". ")?;
        let number: u8 = rest[..digits].parse().ok().filter(|n| *n > 0)?;
        let label = after
            .split('│')
            .next()
            .unwrap_or_default()
            .split("   ")
            .next()
            .unwrap_or_default()
            .trim();
        if label.is_empty() {
            return None;
        }
        Some(Self {
            number,
            label: label.to_owned(),
            selected,
            indent,
        })
    }

    /// Empty, or drawn in box characters: a rule (`─`, `╌`), the bottom of
    /// a frame or a preview box, a framed line of description.
    fn is_blank_or_frame(line: &str) -> bool {
        line.trim()
            .chars()
            .next()
            .is_none_or(|c| ('\u{2500}'..='\u{257f}').contains(&c))
    }

    fn is_rule(line: &str) -> bool {
        line.trim().starts_with('─')
    }

    fn indent(line: &str) -> usize {
        line.chars().take_while(|c| c.is_whitespace()).count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn detect_text(text: &str) -> Option<Vec<(u8, String)>> {
        let lines: Vec<String> = text.lines().map(str::to_owned).collect();
        detect_lines(&lines).map(|choices| {
            choices
                .into_iter()
                .map(|choice| (choice.number, choice.label))
                .collect()
        })
    }

    fn labels(text: &str) -> Vec<String> {
        detect_text(text)
            .expect("a question")
            .into_iter()
            .map(|(_, label)| label)
            .collect()
    }

    /// Claude Code 2.1 asking for a shell command, as `herdr pane read`
    /// returned it.
    const PERMISSION: &str = "\
⏺ Fetching example.com and printing HTTP status code
  ⎿  $ curl -s https://example.com -o /dev/null -w '%{http_code}'

────────────────────────────────────────────────────────────────────────
 Bash command
 Tip: auto mode handles these prompts for you — choose \"switch to auto mode\" below
 Fetch example.com and print HTTP status code
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 curl -s https://example.com -o /dev/null -w '%{http_code}'
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 This command requires approval

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don’t ask again for: curl *
   3. Yes, and switch to auto mode · auto mode handles these prompts for you
   4. No

 Esc to cancel · Tab to amend
";

    /// AskUserQuestion with descriptions, the free text option and the chat
    /// below a rule, live from Claude Code 2.1.
    const ASK: &str = "\
⏺ Which color do you prefer?
────────────────────────────────────────────────────────────────────────
 ☐ Color

Which color do you prefer?

❯ 1. Red
     A warm, bold color.
  2. Green
     A natural, calm color.
  3. Blue
     A cool, steady color.
  4. Type something.
────────────────────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
";

    #[test]
    fn permission_prompt() {
        assert_eq!(
            detect_text(PERMISSION),
            Some(vec![
                (1, "Yes".to_owned()),
                (2, "Yes, and don’t ask again for: curl *".to_owned()),
                (
                    3,
                    "Yes, and switch to auto mode · auto mode handles these prompts for you"
                        .to_owned()
                ),
                (4, "No".to_owned()),
            ])
        );
    }

    #[test]
    fn ask_user_question_without_free_text_and_chat() {
        assert_eq!(
            detect_text(ASK),
            Some(vec![
                (1, "Red".to_owned()),
                (2, "Green".to_owned()),
                (3, "Blue".to_owned()),
            ])
        );
    }

    #[test]
    fn ask_user_question_with_framed_text_and_status_line() {
        let text = "\
 ☐ Messdaten

│ Woher kommen die Messdaten für den Bericht?
│ Bitte eine Quelle wählen.

❯ 1. Zähler
     Monatliche Ablesung am Zähler.
  2. Abrechnung
     Werte aus der Jahresabrechnung.
  3. Type something.
────────────────────────────────────────────────────────────────────────
  4. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
──── 📋 #272 · feature/272-pane-render-agent ─────────────────────────────
";
        assert_eq!(labels(text), ["Zähler", "Abrechnung"]);
    }

    #[test]
    fn framed_dialog() {
        let text = "\
╭──────────────────────────────────────────────╮
│ Do you want to make this edit to main.rs?    │
│ ❯ 1. Yes                                     │
│   2. Yes, allow all edits during this session │
│   3. No                                      │
╰──────────────────────────────────────────────╯
";
        assert_eq!(
            labels(text),
            ["Yes", "Yes, allow all edits during this session", "No"]
        );
    }

    #[test]
    fn preview_column_is_cut_off() {
        let text = "\
 ☐ Layout

Which layout do you want?

❯ 1. Grid                         ┌──────────────────────────────┐
  2. List                         │ [ A ] [ B ] [ C ]            │
                                  │ [ D ] [ E ] [ F ]            │
                                  │ [ G ] [ H ] [ I ]            │
                                  └──────────────────────────────┘

                                  Notes: press n to add notes

────────────────────────────────────────────────────────────────────────
  Chat about this

Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel
";
        assert_eq!(labels(text), ["Grid", "List"]);
    }

    #[test]
    fn numbered_list_without_marker_is_no_question() {
        let text = "\
⏺ Next steps:
  1. Build the crate
  2. Run the tests
  3. Open a pull request

❯
";
        assert_eq!(detect_text(text), None);
    }

    #[test]
    fn numbered_input_line_is_no_question() {
        let text = "\
⏺ Done.

────────────────────────────────────────────────────────────────────────
❯ 1. foo
────────────────────────────────────────────────────────────────────────
  ⏸ manual mode on
";
        assert_eq!(detect_text(text), None);
    }

    #[test]
    fn queued_message_stands_above_the_dialog() {
        // Live: a message sent while the agent works waits above its dialog,
        // the dialog keeps the bottom.
        let text = PERMISSION.replacen("\n────", "\n❯ queued follow-up note\n\n────", 1);
        assert_eq!(detect_text(&text).map(|choices| choices.len()), Some(4));
    }

    #[test]
    fn numbered_prompt_echo_is_no_question() {
        let text = "\
❯ Reply with just OK:
  1. Build
  2. Test

· Kneading…

────────────────────────────────────────────────────────────────────────
❯ 1. Build
  2. Test
────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────
  Fable 5.1 · CTX ███░░░░░░░ 51k/200k
  ⏸ manual mode on
";
        assert_eq!(detect_text(text), None);
    }

    #[test]
    fn numbered_prompt_in_the_input_box_is_no_question() {
        let text = "\
⏺ Done.

────────────────────────────────────────────────────────────────────────
❯ 1. Build
  2. Test
────────────────────────────────────────────────────────────────────────
  ⏸ manual mode on
";
        assert_eq!(detect_text(text), None);
    }

    #[test]
    fn description_starting_with_a_number() {
        let text = "\
Which day?

❯ 1. Monday
     10. Mai, the first slot.
  2. Tuesday

Enter to select · Esc to cancel
";
        assert_eq!(labels(text), ["Monday", "Tuesday"]);
    }

    #[test]
    fn more_than_nine_options_are_no_question() {
        let mut text = String::from("❯ 1. Option 1\n");
        for number in 2..=10 {
            text.push_str(&format!("  {number}. Option {number}\n"));
        }
        assert_eq!(detect_text(&text), None);
    }

    #[test]
    fn several_answers_are_no_question() {
        let text = "\
←  ☐ Fruits  ✔ Submit  →

Which fruits do you like?

❯ 1. [ ] Apple
         Crisp and sweet or tart.
  2. [ ] Pear
         Soft, juicy and mild.
  3. [ ] Type something
     Submit
────────────────────────────────────────────────────────────────────────
  4. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
";
        assert_eq!(detect_text(text), None);
    }

    #[test]
    fn gaps_and_text_between_options_are_no_question() {
        assert_eq!(detect_text("❯ 1. Yes\n  3. No\n"), None);
        assert_eq!(detect_text("❯ 1. Yes\nsome text\n  2. No\n"), None);
        assert_eq!(detect_text("  1. Yes\n  2. No\n"), None);
        assert_eq!(detect_text("❯ 1. Yes\n❯ 2. No\n"), None);
        assert_eq!(detect_text("  2. Yes\n❯ 3. No\n"), None);
    }

    #[test]
    fn question_far_above_the_bottom_is_no_question() {
        let mut text = String::from("❯ 1. Yes\n  2. No\n");
        for line in 0..=MAX_TAIL_LINES {
            text.push_str(&format!("output {line}\n"));
        }
        assert_eq!(detect_text(&text), None);
    }

    #[test]
    fn only_chat_left_is_no_question() {
        assert_eq!(
            detect_text("❯ 1. Type something.\n  2. Chat about this\n"),
            None
        );
    }

    #[test]
    fn reads_a_parsed_screen() {
        let screen = Screen::parse(&ASK.replace('\n', "\r\n"));
        let choices = detect(&screen).expect("a question");
        assert_eq!(choices.len(), 3);
        assert_eq!(choices[0].label, "Red");
    }
}
