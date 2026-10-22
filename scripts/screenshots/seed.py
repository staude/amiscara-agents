#!/usr/bin/env python3
"""Builds the screenshot demo (#199) in its own herdr session.

    seed.py            tear down, then build the session from demo.json
    seed.py --stop     stop the session and remove the demo repositories

Never touches the default herdr session: everything runs in the session
named in demo.json, with throwaway git repositories under its `root`.
The repositories get fixed authors, dates and contents, so commit hashes
and screens are the same on every run. Writes the ids of what it created
to `<root>/ids.json` for screenshots.sh.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEMO = json.loads((HERE / "demo.json").read_text())
SESSION = DEMO["session"]
ROOT = Path(DEMO["root"])
SOCKET = Path.home() / ".config/herdr/sessions" / SESSION / "herdr.sock"
FAKE = HERE / "fake-agent.py"
SOURCE = "amiscara-demo"

# Shell lines for the panes that run a command; the rest is fake output.
COMMANDS = {
    "git-log": "git log --oneline --graph --decorate",
    "git-status": "git status",
    "ls": "ls -1",
}


class Herdr:
    """A minimal client for herdr's socket API: one JSON line per connection."""

    def __init__(self, path):
        self.path = str(path)
        self.next_id = 0
        self.call("ping")

    def call(self, method, **params):
        self.next_id += 1
        request = {"id": f"seed-{self.next_id}", "method": method, "params": params}
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.connect(self.path)
            sock.sendall(json.dumps(request).encode() + b"\n")
            reply = json.loads(sock.makefile("rb").readline())
        if "error" in reply:
            raise RuntimeError(f"{method}: {reply['error']}")
        return reply.get("result", {})


def stop():
    subprocess.run(["herdr", "session", "stop", SESSION], capture_output=True)
    for _ in range(50):
        if not SOCKET.exists():
            break
        time.sleep(0.1)
    # Only ever the demo directory, never a path from elsewhere.
    if ROOT.name == "amiscara-demo" and ROOT.exists():
        shutil.rmtree(ROOT)


def git(repo, *args, when=None):
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "Demo Developer",
        "GIT_AUTHOR_EMAIL": "dev@example.com",
        "GIT_COMMITTER_NAME": "Demo Developer",
        "GIT_COMMITTER_EMAIL": "dev@example.com",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
    }
    if when:
        env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = when
    subprocess.run(["git", "-C", str(repo), *args], env=env, check=True, capture_output=True)


def build_repos():
    day = 0
    for name, spec in DEMO["repos"].items():
        repo = ROOT / name
        repo.mkdir(parents=True)
        git(repo, "init", "-q", "-b", "main")
        for path, text in spec["files"].items():
            (repo / path).parent.mkdir(parents=True, exist_ok=True)
            (repo / path).write_text(text)
        for number, message in enumerate(spec["commits"]):
            with (repo / "CHANGES.md").open("a") as changes:
                changes.write(f"- {message}\n")
            git(repo, "add", "-A")
            day += 1
            git(repo, "commit", "-q", "-m", message, when=f"2026-03-{day:02d}T10:{number:02d}:00+01:00")
        for path, branch in spec.get("worktrees", {}).items():
            git(repo, "worktree", "add", "-q", "-b", branch, str(ROOT / path))


def write_conversations():
    """Claude Code session files for the conversation view, under the demo
    home (`<root>/home`) that screenshots.sh gives the apps, never ~/.claude."""
    titles = {"shop-api": "Rate limits", "shop-web": "Checkout validation", "weather-station": "Daily charts"}
    for repo, entries in DEMO["conversations"].items():
        cwd = os.path.realpath(ROOT / repo)
        folder = ROOT / "home/.claude/projects" / "".join(c if c.isascii() and c.isalnum() else "-" for c in cwd)
        folder.mkdir(parents=True, exist_ok=True)
        lines = []
        for number, entry in enumerate(entries):
            stamp = f"2026-03-20T10:{number:02d}:00.000Z"
            if entry[0] == "user":
                message = {"role": "user", "content": entry[1]}
            elif entry[0] == "assistant":
                message = {"role": "assistant", "content": [{"type": "text", "text": entry[1]}]}
            else:
                message = {"role": "assistant", "content": [{"type": "tool_use", "name": entry[1], "input": entry[2]}]}
            kind = "user" if entry[0] == "user" else "assistant"
            lines.append({"type": kind, "message": message, "timestamp": stamp, "cwd": cwd})
        lines.append({"type": "ai-title", "aiTitle": titles[repo]})
        (folder / f"demo-{repo}.jsonl").write_text("".join(json.dumps(line) + "\n" for line in lines))


def shell_env():
    """A neutral prompt instead of the user's own (name, host, theme)."""
    zdot = ROOT / ".zsh"
    zdot.mkdir(parents=True)
    (zdot / ".zshrc").write_text(
        "PROMPT='%F{blue}%1~%f %F{green}❯%f '\nRPROMPT=''\nunsetopt beep\nHISTFILE=/dev/null\n"
    )
    return {"ZDOTDIR": str(zdot), "PS1": "\\W $ ", "GIT_PAGER": "cat", "PAGER": "cat", "GIT_CONFIG_GLOBAL": "/dev/null"}


def start_server():
    log = open(ROOT / "server.log", "w")
    subprocess.Popen(
        ["herdr", "--session", SESSION, "server"],
        stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True,
    )
    for _ in range(100):
        if SOCKET.exists():
            try:
                return Herdr(SOCKET)
            except OSError:
                pass
        time.sleep(0.1)
    sys.exit(f"seed: no socket at {SOCKET}, see {ROOT / 'server.log'}")


def fill(herdr, pane_id, spec, cwd):
    if "agent" in spec:
        line = f"exec python3 {FAKE} {spec['scene']}"
    elif spec["run"] in COMMANDS:
        line = "clear; " + COMMANDS[spec["run"]]
    else:
        line = f"clear; python3 {FAKE} --run {spec['run']}"
    herdr.call("pane.send_text", pane_id=pane_id, text=line)
    herdr.call("pane.send_keys", pane_id=pane_id, keys=["enter"])


def report(herdr, pane_id, spec):
    if "agent" not in spec:
        return
    state = spec["state"]
    # "done" is a finished turn nobody has looked at yet: working, then idle.
    steps = ["working", "idle"] if state == "done" else [state]
    for step in steps:
        herdr.call("pane.report_agent", pane_id=pane_id, source=SOURCE, agent=spec["agent"], state=step)
        time.sleep(0.3)


def build_spaces(herdr, env):
    ids = {"socket": str(SOCKET), "spaces": {}}
    old = [w["workspace_id"] for w in herdr.call("workspace.list").get("workspaces", [])]
    agents = []
    for space in DEMO["spaces"]:
        cwd = ROOT / (space["worktree"]["path"] if "worktree" in space else space["repo"])
        created = herdr.call("workspace.create", label=space["label"], cwd=str(cwd), env=env)
        workspace_id = created["workspace"]["workspace_id"]
        tabs = []
        for number, tab in enumerate(space["tabs"]):
            if number == 0:
                tab_id, root = created["tab"]["tab_id"], created["root_pane"]["pane_id"]
            else:
                made = herdr.call("tab.create", workspace_id=workspace_id, cwd=str(cwd), env=env)
                tab_id, root = made["tab"]["tab_id"], made["root_pane"]["pane_id"]
            herdr.call("tab.rename", tab_id=tab_id, label=tab["label"])
            panes = [root]
            directions = ["right", "down"]
            for index in range(1, len(tab["panes"])):
                split = herdr.call(
                    "pane.split", target_pane_id=panes[-1] if index > 1 else root,
                    direction=directions[min(index - 1, 1)], cwd=str(cwd), env=env,
                )
                panes.append(split["pane"]["pane_id"])
            time.sleep(0.5)
            for pane_id, spec in zip(panes, tab["panes"]):
                fill(herdr, pane_id, spec, cwd)
                agents.append((pane_id, spec))
            tabs.append({"tab_id": tab_id, "panes": panes})
        ids["spaces"][space["label"]] = {"workspace_id": workspace_id, "tabs": tabs}
    for workspace_id in old:
        herdr.call("workspace.close", workspace_id=workspace_id)
    # Let the fake agents draw before herdr takes their states.
    time.sleep(2)
    for pane_id, spec in agents:
        report(herdr, pane_id, spec)
    (ROOT / "ids.json").write_text(json.dumps(ids, indent=2) + "\n")
    return ids


def main():
    stop()
    if sys.argv[1:] == ["--stop"]:
        return
    ROOT.mkdir(parents=True)
    build_repos()
    write_conversations()
    env = shell_env()
    herdr = start_server()
    ids = build_spaces(herdr, env)
    print(f"seed: {len(ids['spaces'])} spaces in session {SESSION}, socket {SOCKET}")


if __name__ == "__main__":
    main()
