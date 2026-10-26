# Handoff from other AI tools

Plan a task in Claude, ChatGPT or another tool, then hand the result to an
agent on a host without retyping it. The text reaches the agent as a
Markdown file in its composer, together with a short prompt; nothing is
sent until you press send there. Available in the Mac, iPhone and iPad
apps (not on the Apple TV, Watch, Android or desktop app).

## Three ways in

- **Share sheet** (Mac, iPhone, iPad): share the text or a Markdown file to
  "Amiscara Agents", pick the agent. The switch "Als Übergabe-Datei" is on
  for text of 2000 characters or more and for `.md` files; with it off,
  short text goes into the composer as the prompt itself, as before. On
  iPhone and iPad a notification opens the agent; the Mac app opens at
  once.
- **Clipboard:** copy the text, then in the Mac app "Gehe zu" › "Übergabe
  aus Zwischenablage …" (⌥⌘V), on iPhone and iPad the clipboard button in
  the sidebar's toolbar.
- **Link:** `amiscara-agents://prompt?text=<text>` with optional
  `host=<name or id>` and `pane=<herdr pane id>` to preselect the agent.
  The text is percent-encoded and at most 1,000,000 characters. A host or
  pane that does not match leaves the choice to you; it is no error.

  ```sh
  open "amiscara-agents://prompt?text=Hello&host=work"
  ```

The clipboard and the link open a sheet with the agents of all connected
hosts, a preview of the text and the prompt. "Weiter" opens that agent.

## What the agent gets

The composer holds the prompt and the attachment `handoff-<date>-<time>.md`.
On sending, the file is uploaded to `~/.amiscara-agents/uploads/` on the
host as `file-<unix seconds>-<nanoseconds>-handoff-<date>-<time>.md` (the
core puts its own prefix before every uploaded name), and its path follows
the prompt on its own line:

```text
Lies die Übergabe in dieser Datei und setze sie um:
/home/me/.amiscara-agents/uploads/file-1792999920-123456789-handoff-2026-10-26-0912.md
```

The prompt is editable in the share sheet and the handoff sheet; the last
one is kept for next time, an empty one goes back to the default.

Uploads must be on for the host ("Bilder hochladen (SFTP)" in the host
editor). With uploads off the text itself goes into the composer, with a
note below it. An agent waiting at a dialog rejects the prompt, as herdr
does for any `agent.prompt`; the error shows under the composer and the
text and file stay.

## Handing over from Claude

At the end of the conversation, ask Claude to write a handoff message,
then share or copy only that one message (Claude app: long-press the
message, Share; Mac: the message's copy button). Do not use the share link
of the whole conversation: it is a public link and not meant for a handoff.

## Template

Ask the tool to write the handoff along these lines, so the agent finds
what it needs:

```markdown
# Handoff: <short title>

## Goal
What should exist or work when the agent is done, in two or three sentences.

## Decisions
- What was decided and why, including options that were ruled out.

## Open questions
- What is still unclear; what the agent should ask about rather than guess.

## Files
- The files or areas that are likely affected, with a word on each.

## How to check
- Commands, tests or manual steps that show the result works.
```
