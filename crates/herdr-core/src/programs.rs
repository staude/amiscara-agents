//! What runs in a pane (#337): a fixed table of common programs with name,
//! colour and kind, and the rules that pick one from an agent kind or from
//! the pane's foreground processes (`pane.process_info`). Interpreters and
//! runners are looked through, so `npm run dev` with Vite shows Vite. The
//! apps choose the icon by [`Program::id`].

use herdr_proto::{PaneProcess, PaneProcessInfo};

/// One known program.
#[derive(Debug, PartialEq, Eq)]
pub struct Program {
    /// Stable key the apps map to an icon, e.g. `claude`, `vite`, `zsh`.
    pub id: &'static str,
    /// Name to show, e.g. `Claude Code`.
    pub name: &'static str,
    /// Brand or theme colour as `#RRGGBB`.
    pub color: &'static str,
    pub kind: ProgramKind,
    /// Process names that mean this program, after [`normalize`].
    names: &'static [&'static str],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProgramKind {
    /// A coding agent herdr reports as the pane's agent.
    Agent,
    /// A program worth showing: editor, dev server, database client ...
    Tool,
    /// Starts something else (`npm`, `npx`); the started program wins.
    Runner,
    /// Runs a script (`node`, `python`); the script wins if it is known.
    Interpreter,
    /// An idle shell at its prompt.
    Shell,
}

/// What the foreground processes of a pane amount to.
#[derive(Debug, Clone, PartialEq)]
pub enum ProgramMatch {
    Known(&'static Program),
    /// No table entry; carries the process name for a tooltip.
    Unknown(String),
}

const fn program(
    id: &'static str,
    name: &'static str,
    color: &'static str,
    kind: ProgramKind,
    names: &'static [&'static str],
) -> Program {
    Program {
        id,
        name,
        color,
        kind,
        names,
    }
}

use ProgramKind::{Agent, Interpreter, Runner, Shell, Tool};

/// The table. Not editable; the order only matters for names listed twice
/// (none are).
static PROGRAMS: &[Program] = &[
    // Agents, keyed by herdr's agent kind.
    program("claude", "Claude Code", "#D97757", Agent, &["claude"]),
    program("codex", "Codex", "#10A37F", Agent, &["codex"]),
    program("opencode", "opencode", "#F5A742", Agent, &["opencode"]),
    program("gemini", "Gemini CLI", "#4285F4", Agent, &["gemini"]),
    program("amp", "Amp", "#F34E3F", Agent, &["amp"]),
    program(
        "cursor",
        "Cursor Agent",
        "#7A7A80",
        Agent,
        &["cursor", "cursor-agent"],
    ),
    program("droid", "Droid", "#EE6018", Agent, &["droid"]),
    program("pi", "Pi", "#8B5CF6", Agent, &["pi"]),
    program("qwen", "Qwen Code", "#615CED", Agent, &["qwen"]),
    program("copilot", "GitHub Copilot", "#8957E5", Agent, &["copilot"]),
    program("grok", "Grok", "#9A9AA0", Agent, &["grok"]),
    program("kimi", "Kimi", "#1783FF", Agent, &["kimi"]),
    program("aider", "Aider", "#14B014", Agent, &["aider"]),
    // Editors and pagers.
    program(
        "vim",
        "Vim",
        "#019733",
        Tool,
        &["vim", "vi", "view", "vimdiff"],
    ),
    program("nvim", "Neovim", "#57A143", Tool, &["nvim"]),
    program("emacs", "Emacs", "#7F5AB6", Tool, &["emacs", "emacsclient"]),
    program("nano", "nano", "#4A86C8", Tool, &["nano", "pico"]),
    program("helix", "Helix", "#8E6CEF", Tool, &["hx", "helix"]),
    program("micro", "micro", "#2E9E6B", Tool, &["micro"]),
    program("less", "less", "#8E8E93", Tool, &["less", "more", "most"]),
    program("man", "man", "#8E8E93", Tool, &["man"]),
    // System and remote.
    program(
        "htop",
        "htop",
        "#3FA34D",
        Tool,
        &["htop", "top", "btop", "btm"],
    ),
    program(
        "ssh",
        "SSH",
        "#6B7280",
        Tool,
        &["ssh", "mosh", "mosh-client"],
    ),
    program("tmux", "tmux", "#1BB91F", Tool, &["tmux"]),
    program(
        "docker",
        "Docker",
        "#2496ED",
        Tool,
        &["docker", "docker-compose", "lazydocker"],
    ),
    program(
        "kubectl",
        "Kubernetes",
        "#326CE5",
        Tool,
        &["kubectl", "k9s", "helm"],
    ),
    program("ollama", "Ollama", "#9A9AA0", Tool, &["ollama"]),
    // Version control.
    program("git", "Git", "#F05032", Tool, &["git", "tig"]),
    program("lazygit", "lazygit", "#F05032", Tool, &["lazygit"]),
    program("gh", "GitHub CLI", "#8957E5", Tool, &["gh"]),
    // Build tools and compilers.
    program("make", "make", "#6D8086", Tool, &["make", "gmake", "just"]),
    program(
        "cargo",
        "Cargo",
        "#DEA584",
        Tool,
        &["cargo", "rustc", "rustup"],
    ),
    program("go", "Go", "#00ADD8", Tool, &["go"]),
    program("swift", "Swift", "#F05138", Tool, &["swift", "swiftc"]),
    program(
        "xcodebuild",
        "Xcode",
        "#147EFB",
        Tool,
        &["xcodebuild", "xcrun"],
    ),
    program("gradle", "Gradle", "#209BC4", Tool, &["gradle", "gradlew"]),
    program(
        "tsc",
        "TypeScript",
        "#3178C6",
        Tool,
        &["tsc", "tsx", "ts-node"],
    ),
    // Dev servers and test runners, mostly behind node.
    program("vite", "Vite", "#646CFF", Tool, &["vite"]),
    program("next", "Next.js", "#9A9AA0", Tool, &["next"]),
    program("nuxt", "Nuxt", "#00DC82", Tool, &["nuxt", "nuxi"]),
    program("astro", "Astro", "#FF5D01", Tool, &["astro"]),
    program(
        "webpack",
        "webpack",
        "#8DD6F9",
        Tool,
        &["webpack", "webpack-dev-server"],
    ),
    program("nodemon", "nodemon", "#76D04B", Tool, &["nodemon"]),
    program("tauri", "Tauri", "#FFC131", Tool, &["tauri"]),
    program("eslint", "ESLint", "#4B32C3", Tool, &["eslint"]),
    program("jest", "Jest", "#C21325", Tool, &["jest"]),
    program("vitest", "Vitest", "#6E9F18", Tool, &["vitest"]),
    program("playwright", "Playwright", "#2EAD33", Tool, &["playwright"]),
    program("pytest", "pytest", "#0A9EDC", Tool, &["pytest", "py.test"]),
    program("artisan", "Laravel", "#FF2D20", Tool, &["artisan"]),
    program("composer", "Composer", "#885630", Tool, &["composer"]),
    program("wp", "WP-CLI", "#21759B", Tool, &["wp"]),
    // Database clients.
    program(
        "psql",
        "PostgreSQL",
        "#336791",
        Tool,
        &["psql", "pgcli", "postgres"],
    ),
    program(
        "mysql",
        "MySQL",
        "#4479A1",
        Tool,
        &["mysql", "mariadb", "mycli"],
    ),
    program(
        "sqlite",
        "SQLite",
        "#0F80CC",
        Tool,
        &["sqlite3", "sqlite", "litecli"],
    ),
    program(
        "redis",
        "Redis",
        "#DC382D",
        Tool,
        &["redis-cli", "redis-server"],
    ),
    // Runners.
    program("npm", "npm", "#CB3837", Runner, &["npm", "npx"]),
    program("pnpm", "pnpm", "#F69220", Runner, &["pnpm", "pnpx"]),
    program("yarn", "Yarn", "#2C8EBB", Runner, &["yarn"]),
    program("uv", "uv", "#DE5FE9", Runner, &["uv", "uvx", "pipx"]),
    // Interpreters.
    program(
        "node",
        "Node.js",
        "#5FA04E",
        Interpreter,
        &["node", "nodejs"],
    ),
    program(
        "python",
        "Python",
        "#3776AB",
        Interpreter,
        &["python", "python3"],
    ),
    program("ruby", "Ruby", "#CC342D", Interpreter, &["ruby", "irb"]),
    program("bun", "Bun", "#D9A441", Interpreter, &["bun", "bunx"]),
    program("deno", "Deno", "#12B886", Interpreter, &["deno"]),
    program("php", "PHP", "#777BB4", Interpreter, &["php"]),
    // Shells.
    program("zsh", "zsh", "#98989D", Shell, &["zsh"]),
    program("bash", "bash", "#98989D", Shell, &["bash"]),
    program("fish", "fish", "#98989D", Shell, &["fish"]),
    program("sh", "sh", "#98989D", Shell, &["sh", "dash", "ksh"]),
    program("nu", "Nushell", "#98989D", Shell, &["nu"]),
    program(
        "pwsh",
        "PowerShell",
        "#98989D",
        Shell,
        &["pwsh", "powershell"],
    ),
];

/// The table, for apps that list it.
pub fn all() -> &'static [Program] {
    PROGRAMS
}

/// The agent herdr reports as `agent` (the raw kind, not `display_agent`).
pub fn for_agent(kind: &str) -> Option<&'static Program> {
    let kind = normalize(kind);
    PROGRAMS
        .iter()
        .filter(|program| program.kind == Agent)
        .find(|program| program.id == kind || program.names.contains(&kind.as_str()))
}

/// What runs in a pane: the group leader decides; a runner or interpreter
/// gives way to the first other process that is a tool or agent (`npm run
/// dev` starts `node …/vite`). `None` without any process.
pub fn for_processes(info: &PaneProcessInfo) -> Option<ProgramMatch> {
    let processes = &info.foreground_processes;
    let leader = info
        .foreground_process_group_id
        .and_then(|pgid| processes.iter().find(|process| process.pid == pgid))
        .or_else(|| processes.first())?;
    let Some(program) = resolve(leader) else {
        return Some(ProgramMatch::Unknown(leader.name.clone()));
    };
    if matches!(program.kind, Runner | Interpreter)
        && let Some(started) = processes
            .iter()
            .filter(|process| process.pid != leader.pid)
            .filter_map(resolve)
            .find(|found| matches!(found.kind, Tool | Agent))
    {
        return Some(ProgramMatch::Known(started));
    }
    Some(ProgramMatch::Known(program))
}

/// One process: the first of `argv0`, `argv[0]` and `name` that is in the
/// table; an interpreter or runner is replaced by its script if that is.
fn resolve(process: &PaneProcess) -> Option<&'static Program> {
    let argv = process.argv.as_deref().unwrap_or_default();
    let program = process
        .argv0
        .iter()
        .chain(argv.first())
        .chain(std::iter::once(&process.name))
        .find_map(|candidate| lookup(candidate))?;
    if matches!(program.kind, Runner | Interpreter)
        && let Some(script) = script_of(argv).and_then(|script| lookup(&script))
        && !matches!(script.kind, Shell)
    {
        return Some(script);
    }
    Some(program)
}

/// The script or package an interpreter runs: the first argument after
/// `argv[0]` that is not a flag, as the package below `node_modules` or
/// the file name without its script extension.
fn script_of(argv: &[String]) -> Option<String> {
    let arg = argv.iter().skip(1).find(|arg| !arg.starts_with('-'))?;
    if let Some((_, rest)) = arg.rsplit_once("node_modules/") {
        let rest = rest.strip_prefix(".bin/").unwrap_or(rest);
        let mut parts = rest.split('/');
        let first = parts.next()?;
        // A scoped package (`@scope/name`) is known by its name.
        let package = if first.starts_with('@') {
            parts.next()?
        } else {
            first
        };
        return Some(package.to_owned());
    }
    let base = arg.rsplit('/').next().unwrap_or(arg);
    let base = [".js", ".mjs", ".cjs", ".ts", ".py"]
        .iter()
        .find_map(|ext| base.strip_suffix(ext))
        .unwrap_or(base);
    Some(base.to_owned())
}

/// The table entry for one name, trying it as is, then without version
/// endings (`python3.12` → `python3` → `python`).
fn lookup(raw: &str) -> Option<&'static Program> {
    let mut name = normalize(raw);
    loop {
        if name.is_empty() {
            return None;
        }
        if let Some(program) = PROGRAMS
            .iter()
            .find(|program| program.names.contains(&name.as_str()))
        {
            return Some(program);
        }
        let shorter = match name.rsplit_once('.') {
            Some((head, tail)) if !tail.is_empty() && tail.bytes().all(|b| b.is_ascii_digit()) => {
                head.to_owned()
            }
            _ => name
                .trim_end_matches(|c: char| c.is_ascii_digit() || c == '.' || c == '-')
                .to_owned(),
        };
        if shorter == name {
            return None;
        }
        name = shorter;
    }
}

/// Base name in lower case, without a login shell's leading `-` and a
/// Windows `.exe`.
fn normalize(raw: &str) -> String {
    let base = raw.trim().rsplit(['/', '\\']).next().unwrap_or_default();
    let base = base.strip_prefix('-').unwrap_or(base);
    let lower = base.to_ascii_lowercase();
    lower.strip_suffix(".exe").unwrap_or(&lower).to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn process(pid: u32, name: &str, argv0: Option<&str>, argv: &[&str]) -> PaneProcess {
        PaneProcess {
            pid,
            name: name.to_owned(),
            argv0: argv0.map(str::to_owned),
            argv: (!argv.is_empty()).then(|| argv.iter().map(|arg| (*arg).to_owned()).collect()),
        }
    }

    fn info(pgid: Option<u32>, processes: Vec<PaneProcess>) -> PaneProcessInfo {
        PaneProcessInfo {
            pane_id: "w1:p1".into(),
            foreground_process_group_id: pgid,
            foreground_processes: processes,
        }
    }

    fn id(found: Option<ProgramMatch>) -> Option<String> {
        found.map(|found| match found {
            ProgramMatch::Known(program) => program.id.to_owned(),
            ProgramMatch::Unknown(name) => format!("?{name}"),
        })
    }

    #[test]
    fn node_running_vite_is_vite() {
        let pane = info(
            Some(10),
            vec![process(
                10,
                "node",
                Some("node"),
                &["node", "/p/node_modules/.bin/vite", "--port", "5173"],
            )],
        );
        assert_eq!(id(for_processes(&pane)).as_deref(), Some("vite"));
        let package = info(
            None,
            vec![process(
                10,
                "node",
                None,
                &["node", "/p/node_modules/vite/bin/vite.js"],
            )],
        );
        assert_eq!(id(for_processes(&package)).as_deref(), Some("vite"));
    }

    #[test]
    fn npm_run_dev_shows_the_started_tool() {
        let pane = info(
            Some(20),
            vec![
                process(
                    22,
                    "node",
                    Some("node"),
                    &["node", "/p/node_modules/.bin/vite"],
                ),
                process(21, "sh", Some("sh"), &["sh", "-c", "vite"]),
                process(20, "node", Some("npm run dev"), &["npm run dev"]),
            ],
        );
        assert_eq!(id(for_processes(&pane)).as_deref(), Some("vite"));
    }

    #[test]
    fn login_shell_is_a_shell() {
        let pane = info(Some(5), vec![process(5, "zsh", Some("zsh"), &["-zsh"])]);
        let found = for_processes(&pane);
        assert_eq!(id(found.clone()).as_deref(), Some("zsh"));
        assert!(matches!(found, Some(ProgramMatch::Known(p)) if p.kind == Shell));
        let bare = info(Some(5), vec![process(5, "-bash", None, &[])]);
        assert_eq!(id(for_processes(&bare)).as_deref(), Some("bash"));
    }

    #[test]
    fn unknown_program_keeps_its_name() {
        let pane = info(
            Some(7),
            vec![process(
                7,
                "caffeinate",
                Some("caffeinate"),
                &["caffeinate", "-i"],
            )],
        );
        assert_eq!(id(for_processes(&pane)).as_deref(), Some("?caffeinate"));
    }

    #[test]
    fn interpreter_without_a_known_script_stays_the_interpreter() {
        let pane = info(
            Some(8),
            vec![process(
                8,
                "python3.12",
                Some("python"),
                &["/u/bin/python", "/u/bin/serena", "start-mcp-server"],
            )],
        );
        assert_eq!(id(for_processes(&pane)).as_deref(), Some("python"));
        // Without argv0 and argv the version ending is dropped.
        let bare = info(Some(8), vec![process(8, "python3.12", None, &[])]);
        assert_eq!(id(for_processes(&bare)).as_deref(), Some("python"));
        let module = info(
            Some(8),
            vec![process(8, "python3", None, &["python3", "-m", "pytest"])],
        );
        assert_eq!(id(for_processes(&module)).as_deref(), Some("pytest"));
    }

    #[test]
    fn the_group_leader_decides_over_its_children() {
        // vim runs a language server through node; vim stays.
        let pane = info(
            Some(30),
            vec![
                process(31, "node", None, &["node", "/x/node_modules/.bin/vite"]),
                process(30, "nvim", Some("nvim"), &["nvim", "main.rs"]),
            ],
        );
        assert_eq!(id(for_processes(&pane)).as_deref(), Some("nvim"));
    }

    #[test]
    fn empty_list_is_nothing() {
        assert_eq!(for_processes(&info(Some(1), Vec::new())), None);
    }

    #[test]
    fn agents_are_found_by_kind() {
        assert_eq!(for_agent("claude").map(|p| p.id), Some("claude"));
        assert_eq!(for_agent("Codex").map(|p| p.id), Some("codex"));
        assert_eq!(for_agent("cursor-agent").map(|p| p.id), Some("cursor"));
        assert_eq!(for_agent("vim"), None);
        assert_eq!(for_agent("hal9000"), None);
    }

    #[test]
    fn table_is_consistent() {
        let mut ids = std::collections::BTreeSet::new();
        let mut names = std::collections::BTreeSet::new();
        for program in all() {
            assert!(ids.insert(program.id), "id {} twice", program.id);
            assert!(
                program.color.len() == 7
                    && program.color.starts_with('#')
                    && program.color[1..].bytes().all(|b| b.is_ascii_hexdigit()),
                "colour of {}",
                program.id
            );
            for name in program.names {
                assert_eq!(*name, normalize(name), "{name} not normalised");
                assert!(names.insert(*name), "name {name} twice");
            }
        }
    }
}
