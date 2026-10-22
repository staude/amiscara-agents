#!/usr/bin/env python3
"""Draws a fixed agent screen or command output for the screenshot demo (#199).

    fake-agent.py <scene>        an agent screen; stays until killed
    fake-agent.py --run <name>   output of a command; exits

Everything is fictional and the same on every run, so the screenshots
show the same text each time. seed.py reports the agent states to herdr,
since herdr cannot detect an agent in this script.
"""

import os
import signal
import sys

ESC = "\x1b["
RESET = ESC + "0m"
BOLD = ESC + "1m"
DIM = ESC + "2m"
ORANGE = ESC + "38;5;209m"
GREY = ESC + "38;5;246m"
GREEN = ESC + "32m"
RED = ESC + "31m"
BLUE = ESC + "38;5;111m"
YELLOW = ESC + "33m"
CYAN = ESC + "36m"
WIDTH = 72


def box(lines, color=GREY, width=WIDTH):
    """A rounded frame like Claude Code draws, `lines` padded to `width`."""
    out = [color + "╭" + "─" * (width - 2) + "╮" + RESET]
    for line in lines:
        visible = len(strip(line))
        out.append(color + "│" + RESET + " " + line + " " * max(0, width - 3 - visible) + color + "│" + RESET)
    out.append(color + "╰" + "─" * (width - 2) + "╯" + RESET)
    return out


def strip(text):
    """`text` without escape sequences, to measure it."""
    result, i = "", 0
    while i < len(text):
        if text[i] == "\x1b":
            i = text.index("m", i) + 1
        else:
            result += text[i]
            i += 1
    return result


def welcome(cwd):
    return box([
        ORANGE + "✻" + RESET + " Welcome to " + BOLD + "Claude Code" + RESET + "!",
        "",
        GREY + "  /help for help, /status for your current setup" + RESET,
        "",
        GREY + "  cwd: " + cwd + RESET,
    ], ORANGE) + [""]


def prompt_box(hint="? for shortcuts"):
    return box([">"]) + [GREY + "  " + hint + RESET]


def tool(name, arg, result):
    return [GREEN + "⏺" + RESET + " " + BOLD + name + RESET + "(" + arg + ")",
            GREY + "  ⎿  " + result + RESET, ""]


def say(text):
    return ["⏺ " + text, ""]


def user(text):
    return [GREY + "> " + text + RESET, ""]


def working_checkout(cwd):
    return (welcome(cwd)
            + user("Validate the address fields of the checkout form when they lose focus.")
            + say("I'll read the form component first.")
            + tool("Read", "src/checkout.ts", "Read 42 lines")
            + tool("Update", "src/checkout.ts", "Updated src/checkout.ts with 12 additions and 3 removals")
            + tool("Bash", "npm test -- checkout", "Tests  14 passed (14)")
            + [ORANGE + "✻" + RESET + " Adding error messages… " + GREY + "(42s · ↑ 1.8k tokens · esc to interrupt)" + RESET, ""]
            + prompt_box())


def blocked_tests(cwd):
    return (welcome(cwd)
            + user("Add rate limits to the public order endpoints and run the tests.")
            + say("The limiter is in place. Now the test suite.")
            + tool("Update", "src/orders.rs", "Updated src/orders.rs with 24 additions")
            + box([
                BOLD + "Bash command" + RESET,
                "",
                "  cargo test --all",
                GREY + "  Run the whole test suite" + RESET,
                "",
                "Do you want to proceed?",
                BLUE + "❯ 1. Yes" + RESET,
                "  2. Yes, and don't ask again for cargo test commands",
                "  3. No, and tell Claude what to do differently " + GREY + "(esc)" + RESET,
            ], BLUE))


def done_dashboard(cwd):
    return (welcome(cwd)
            + user("Add a daily chart for temperature and humidity to the dashboard.")
            + tool("Read", "dashboard/app.js", "Read 120 lines")
            + tool("Write", "dashboard/charts.js", "Wrote 64 lines to dashboard/charts.js")
            + tool("Bash", "npm run build", "Built in 1.2s")
            + say("The dashboard now shows a daily chart with temperature and humidity,\n"
                  "  one point per reading and the day's minimum and maximum marked.")
            + prompt_box())


def idle(cwd):
    return welcome(cwd) + prompt_box("Try \"write a post about the new dark mode\"")


def done_refunds(cwd):
    return ([BOLD + ">_ OpenAI Codex" + RESET + GREY + "  (research preview)" + RESET, "",
             GREY + "  directory: " + cwd + RESET, "",
             CYAN + "user" + RESET, "Add refunds for cancelled orders.", "",
             CYAN + "codex" + RESET,
             "• Added " + BOLD + "POST /orders/{id}/refund" + RESET + " with a check that the order is cancelled.",
             "• Stored refunds in a new table and wrote three tests.", "",
             GREEN + "✓" + RESET + " cargo test  " + GREY + "18 passed" + RESET, "",
             GREY + "▌ Ask Codex to do anything" + RESET])


SCENES = {
    "working-checkout": working_checkout,
    "blocked-tests": blocked_tests,
    "done-dashboard": done_dashboard,
    "idle": idle,
    "done-refunds": done_refunds,
}

RUNS = {
    "dev-server": [
        GREEN + "  VITE v6.3.5" + RESET + "  ready in 412 ms", "",
        "  ➜  " + BOLD + "Local" + RESET + ":   " + CYAN + "http://localhost:5173/" + RESET,
        GREY + "  ➜  Network: use --host to expose" + RESET, "",
        GREY + "10:42:07" + RESET + " " + CYAN + "[vite]" + RESET + " page reload src/checkout.ts",
        GREY + "10:42:31" + RESET + " " + CYAN + "[vite]" + RESET + " hmr update /src/CheckoutForm.svelte",
    ],
    "tests": [
        " " + GREEN + "✓" + RESET + " src/cart.test.ts " + GREY + "(8 tests) 12ms" + RESET,
        " " + GREEN + "✓" + RESET + " src/checkout.test.ts " + GREY + "(14 tests) 31ms" + RESET,
        " " + GREEN + "✓" + RESET + " src/products.test.ts " + GREY + "(6 tests) 9ms" + RESET, "",
        GREY + " Test Files  " + RESET + GREEN + "3 passed" + RESET + GREY + " (3)" + RESET,
        GREY + "      Tests  " + RESET + GREEN + "28 passed" + RESET + GREY + " (28)" + RESET,
    ],
    "cargo-test": [
        GREEN + "   Compiling" + RESET + " csvtool v0.3.0 (/tmp/amiscara-demo/csvtool)",
        GREEN + "    Finished" + RESET + " `test` profile [unoptimized + debuginfo] target(s) in 2.14s",
        GREEN + "     Running" + RESET + " unittests src/main.rs", "",
        "running 9 tests",
        "test parse::quoted_fields ... " + GREEN + "ok" + RESET,
        "test parse::empty_lines ... " + GREEN + "ok" + RESET,
        "test select::by_name ... " + GREEN + "ok" + RESET,
        "test table::wide_columns ... " + GREEN + "ok" + RESET, "",
        "test result: " + GREEN + "ok" + RESET + ". 9 passed; 0 failed",
    ],
}


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--run":
        print("\n".join(RUNS[sys.argv[2]]))
        return
    scene = SCENES[sys.argv[1]]
    cwd = os.environ.get("PWD", os.getcwd())
    title = {"working-checkout": "✳ Checkout validation", "blocked-tests": "✳ Rate limits",
             "done-dashboard": "✳ Daily charts", "idle": "✳ Claude Code",
             "done-refunds": "Codex"}[sys.argv[1]]
    sys.stdout.write("\x1b]0;" + title + "\x07" + ESC + "2J" + ESC + "H" + ESC + "?25l")
    sys.stdout.write("\r\n".join(line.replace("\n", "\r\n") for line in scene(cwd)))
    sys.stdout.flush()
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    while True:
        signal.pause()


if __name__ == "__main__":
    main()
