//! Read-only probe for the herdr socket API, locally or over SSH.
//!
//! Answers the spike questions: does SSH streamlocal to `herdr.sock` work,
//! and is request latency low enough for a live GUI?

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use herdr_core::pane::Pacing;
use herdr_core::terminal::Screen;
use herdr_core::{SessionState, SyncStatus};
use herdr_proto::{
    GLOBAL_SUBSCRIPTIONS, PaneList, PaneRead, PaneReadResult, Pong, SUPPORTED_PROTOCOL,
    WorkspaceList,
};
use herdr_transport::{Connection, HostKeyPolicy, Identity, SshTarget, TransportError};
use serde_json::json;

#[derive(Parser)]
#[command(about = "Read-only probe for a herdr server")]
struct Cli {
    /// Connect over SSH, e.g. `staude@work.staude.internal` or `user@host:2222`.
    #[arg(long)]
    ssh: Option<String>,
    /// Private key for SSH. Without it the SSH agent is used.
    #[arg(long)]
    identity: Option<PathBuf>,
    /// known_hosts file used for host key checks.
    #[arg(long)]
    known_hosts: Option<PathBuf>,
    /// Record the host key on first contact (trust on first use).
    #[arg(long)]
    accept_new_host_key: bool,
    /// Socket path on the server. Defaults to `~/.config/herdr/herdr.sock`
    /// (remote: `/Users/<user>/...`).
    #[arg(long)]
    socket: Option<String>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Server version and protocol check.
    Ping,
    /// Workspaces and panes with agent status.
    List,
    /// Print the visible screen of a pane.
    Read {
        pane: String,
        /// Keep ANSI escape sequences.
        #[arg(long)]
        ansi: bool,
    },
    /// Print events as they arrive.
    Watch {
        #[arg(long, default_value_t = 30)]
        seconds: u64,
    },
    /// Live agent board, most urgent first, kept current by events.
    Board {
        #[arg(long, default_value_t = 30)]
        seconds: u64,
    },
    /// Compare parsed ANSI screens with herdr's plain text for every pane.
    Check,
    /// Follow one pane and report each content change.
    View {
        pane: String,
        #[arg(long, default_value_t = 30)]
        seconds: u64,
    },
    /// Conversation of a Claude Code pane from its session file (read only).
    History {
        pane: String,
        /// Pages to read, newest first.
        #[arg(long, default_value_t = 1)]
        pages: usize,
    },
    /// Measure request round trips.
    Bench {
        #[arg(long, default_value_t = 50)]
        count: usize,
        /// Pane for the `pane.read` benchmark (default: first pane).
        #[arg(long)]
        pane: Option<String>,
    },
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let endpoint = Endpoint::from_cli(&cli)?;
    if let Command::Board { seconds } = cli.command {
        return board(endpoint, seconds).await;
    }
    let started = Instant::now();
    let conn = endpoint.connect().await?;
    eprintln!("connected in {:.0} ms", ms(started.elapsed()));

    match cli.command {
        Command::Ping => ping(&conn).await,
        Command::List => list(&conn).await,
        Command::Read { pane, ansi } => read(&conn, &pane, ansi).await,
        Command::Watch { seconds } => watch(&conn, seconds).await,
        Command::Bench { count, pane } => bench(&conn, count, pane).await,
        Command::Check => check(&conn).await,
        Command::View { pane, seconds } => view(&conn, &pane, seconds).await,
        Command::History { pane, pages } => history(&conn, &pane, pages).await,
        Command::Board { .. } => Ok(()),
    }
}

/// Where the server lives. Kept apart from the connection so the sync
/// driver can connect again after a drop.
enum Endpoint {
    #[cfg(unix)]
    Local(PathBuf),
    Ssh {
        target: SshTarget,
        socket: String,
    },
}

impl Endpoint {
    fn from_cli(cli: &Cli) -> Result<Self> {
        let Some(spec) = &cli.ssh else {
            return Self::local(cli);
        };

        let (user, host_port) = spec
            .split_once('@')
            .context("--ssh expects user@host[:port]")?;
        let (host, port) = match host_port.rsplit_once(':') {
            Some((host, port)) => (host, port.parse().context("invalid port")?),
            None => (host_port, 22),
        };
        let known_hosts = match &cli.known_hosts {
            Some(path) => path.clone(),
            None => dirs::home_dir()
                .context("no home directory")?
                .join(".ssh/known_hosts"),
        };
        let target = SshTarget {
            host: host.to_owned(),
            port,
            user: user.to_owned(),
            identity: cli.identity.clone().map_or(Identity::Agent, Identity::File),
            host_key: HostKeyPolicy::KnownHostsFile {
                path: known_hosts,
                accept_new: cli.accept_new_host_key,
            },
        };
        let socket = cli
            .socket
            .clone()
            .unwrap_or_else(|| format!("/Users/{user}/.config/herdr/herdr.sock"));
        Ok(Self::Ssh { target, socket })
    }

    #[cfg(unix)]
    fn local(cli: &Cli) -> Result<Self> {
        let socket = match &cli.socket {
            Some(path) => PathBuf::from(path),
            None => Connection::default_local_socket().context("no home directory")?,
        };
        Ok(Self::Local(socket))
    }

    #[cfg(not(unix))]
    fn local(_cli: &Cli) -> Result<Self> {
        bail!("a local herdr socket needs a Unix system; use --ssh")
    }

    async fn connect(&self) -> Result<Connection, TransportError> {
        match self {
            #[cfg(unix)]
            Self::Local(socket) => Ok(Connection::local(socket.clone())),
            Self::Ssh { target, socket } => Connection::ssh(target, socket.clone()).await,
        }
    }
}

async fn ping(conn: &Connection) -> Result<()> {
    let pong: Pong = serde_json::from_value(conn.request("ping", json!({})).await?)?;
    println!("herdr {} protocol {}", pong.version, pong.protocol);
    if pong.protocol != SUPPORTED_PROTOCOL {
        println!("warning: client expects protocol {SUPPORTED_PROTOCOL}");
    }
    Ok(())
}

async fn list(conn: &Connection) -> Result<()> {
    let workspaces: WorkspaceList =
        serde_json::from_value(conn.request("workspace.list", json!({})).await?)?;
    let panes: PaneList = serde_json::from_value(conn.request("pane.list", json!({})).await?)?;
    for ws in &workspaces.workspaces {
        println!(
            "{} {} [{}]",
            ws.workspace_id,
            ws.label,
            ws.agent_status.as_str()
        );
        for pane in panes
            .panes
            .iter()
            .filter(|p| p.workspace_id == ws.workspace_id)
        {
            println!(
                "  {:<8} {:<8} {:<8} rev {:<6} {}",
                pane.pane_id,
                pane.agent.as_deref().unwrap_or("shell"),
                pane.agent_status.as_str(),
                pane.revision,
                pane.terminal_title_stripped.as_deref().unwrap_or("")
            );
        }
    }
    Ok(())
}

async fn read_pane(conn: &Connection, pane: &str, ansi: bool) -> Result<PaneRead> {
    let params = json!({
        "pane_id": pane,
        "source": "visible",
        "format": if ansi { "ansi" } else { "text" },
        "strip_ansi": !ansi,
    });
    let result: PaneReadResult = serde_json::from_value(conn.request("pane.read", params).await?)?;
    Ok(result.read)
}

async fn history(conn: &Connection, pane: &str, pages: usize) -> Result<()> {
    let started = Instant::now();
    let session = herdr_core::claude::find_session(conn, pane).await?;
    eprintln!(
        "-- {} ({} bytes), found in {:?}",
        session.path,
        session.size,
        started.elapsed()
    );
    let mut end = session.size;
    let mut shown = Vec::new();
    for _ in 0..pages {
        let started = Instant::now();
        let page = herdr_core::claude::read_back(conn, &session, end).await?;
        eprintln!(
            "-- page {}..{}: {} entries in {:?}",
            page.start,
            end,
            page.entries.len(),
            started.elapsed()
        );
        end = page.start;
        shown.splice(0..0, page.entries);
        if end == 0 {
            break;
        }
    }
    for entry in shown.iter().rev().take(12).rev() {
        let text: String = entry.text.chars().take(100).collect();
        println!("{:?}: {}", entry.kind, text.replace('\n', " "));
    }
    Ok(())
}

async fn read(conn: &Connection, pane: &str, ansi: bool) -> Result<()> {
    let screen = read_pane(conn, pane, ansi).await?;
    print!("{}", screen.text);
    eprintln!(
        "\n-- {} rev {} ({} bytes{})",
        screen.pane_id,
        screen.revision,
        screen.text.len(),
        if screen.truncated { ", truncated" } else { "" }
    );
    Ok(())
}

async fn watch(conn: &Connection, seconds: u64) -> Result<()> {
    let mut sub = conn.subscribe(GLOBAL_SUBSCRIPTIONS).await?;
    let started = Instant::now();
    let deadline = Duration::from_secs(seconds);
    eprintln!("watching for {seconds} s");
    loop {
        let remaining = deadline.saturating_sub(started.elapsed());
        if remaining.is_zero() {
            return Ok(());
        }
        match tokio::time::timeout(remaining, sub.next()).await {
            Err(_) => return Ok(()),
            Ok(Ok(Some(event))) => {
                let mut line = event.to_string();
                line.truncate(200);
                println!("{:>8.1}s {line}", started.elapsed().as_secs_f64());
            }
            Ok(Ok(None)) => bail!("server closed the subscription"),
            Ok(Err(err)) => return Err(err.into()),
        }
    }
}

async fn bench(conn: &Connection, count: usize, pane: Option<String>) -> Result<()> {
    let mut samples = Vec::with_capacity(count);
    for _ in 0..count {
        let t = Instant::now();
        conn.request("ping", json!({})).await?;
        samples.push(t.elapsed());
    }
    report("ping", &mut samples);

    // Split the round trip: channel open vs. request on an already open channel.
    let mut opens = Vec::with_capacity(count);
    samples.clear();
    for _ in 0..count {
        let t = Instant::now();
        let channel = conn.open_channel().await?;
        opens.push(t.elapsed());
        let t = Instant::now();
        conn.request_on(channel, "ping", json!({})).await?;
        samples.push(t.elapsed());
    }
    report("  channel open", &mut opens);
    report("  ping on open channel", &mut samples);

    let pane = match pane {
        Some(pane) => pane,
        None => {
            let panes: PaneList =
                serde_json::from_value(conn.request("pane.list", json!({})).await?)?;
            panes
                .panes
                .into_iter()
                .next()
                .context("no panes on the server")?
                .pane_id
        }
    };
    samples.clear();
    let mut bytes = 0;
    for _ in 0..count {
        let t = Instant::now();
        bytes = read_pane(conn, &pane, true).await?.text.len();
        samples.push(t.elapsed());
    }
    report(
        &format!("pane.read ansi {pane} ({bytes} bytes)"),
        &mut samples,
    );
    Ok(())
}

async fn check(conn: &Connection) -> Result<()> {
    let panes: PaneList = serde_json::from_value(conn.request("pane.list", json!({})).await?)?;
    let mut failures = 0;
    for pane in &panes.panes {
        let ansi = read_pane(conn, &pane.pane_id, true).await?;
        let plain = read_pane(conn, &pane.pane_id, false).await?;
        if ansi.revision != plain.revision {
            println!("{:<8} skipped, changed between reads", pane.pane_id);
            continue;
        }
        let t = Instant::now();
        let screen = Screen::parse(&ansi.text);
        let parse = t.elapsed();
        let ours: Vec<String> = screen
            .text_lines()
            .iter()
            .map(|l| l.trim_end().to_owned())
            .collect();
        let theirs: Vec<String> = Screen::parse(&plain.text)
            .text_lines()
            .iter()
            .map(|l| l.trim_end().to_owned())
            .collect();
        let spans: usize = screen.lines.iter().map(|l| l.spans.len()).sum();
        let verdict = if ours == theirs { "ok" } else { "MISMATCH" };
        if ours != theirs {
            failures += 1;
        }
        println!(
            "{:<8} {verdict:<8} {} lines, {} spans, {} bytes, parsed in {:.0} µs",
            pane.pane_id,
            screen.lines.len(),
            spans,
            ansi.text.len(),
            parse.as_secs_f64() * 1e6
        );
        if let Some((n, (a, b))) = ours
            .iter()
            .zip(&theirs)
            .enumerate()
            .find(|(_, (a, b))| a != b)
        {
            println!("    line {n}:\n    ansi: {a:?}\n    text: {b:?}");
        }
    }
    if failures > 0 {
        bail!("{failures} pane(s) differ");
    }
    Ok(())
}

async fn view(conn: &Connection, pane: &str, seconds: u64) -> Result<()> {
    let (tx, mut rx) = tokio::sync::watch::channel(None);
    let started = Instant::now();
    let follow = herdr_core::pane::follow(conn, pane, Pacing::default(), &tx);
    let report = async {
        while rx.changed().await.is_ok() {
            let Some(screen) = rx.borrow_and_update().clone() else {
                continue;
            };
            let last = screen
                .screen
                .text_lines()
                .into_iter()
                .rev()
                .find(|l| !l.trim().is_empty())
                .unwrap_or_default();
            println!(
                "{:>6.1}s {} lines | {}",
                started.elapsed().as_secs_f64(),
                screen.screen.lines.len(),
                last.trim()
            );
        }
    };
    tokio::select! {
        result = follow => result?,
        () = report => {}
        () = tokio::time::sleep(Duration::from_secs(seconds)) => {}
    }
    Ok(())
}

async fn board(endpoint: Endpoint, seconds: u64) -> Result<()> {
    let endpoint = Arc::new(endpoint);
    let mut rx = herdr_core::sync::spawn(move || {
        let endpoint = Arc::clone(&endpoint);
        async move { endpoint.connect().await }
    });
    let started = Instant::now();
    let deadline = Duration::from_secs(seconds);
    loop {
        let remaining = deadline.saturating_sub(started.elapsed());
        match tokio::time::timeout(remaining, rx.changed()).await {
            Err(_) => return Ok(()),
            Ok(Err(_)) => bail!("sync driver stopped"),
            Ok(Ok(())) => {}
        }
        let state = rx.borrow_and_update().clone();
        let at = started.elapsed().as_secs_f64();
        match (&state.status, &state.session) {
            (SyncStatus::Live, Some(session)) => print_board(at, session),
            (SyncStatus::Retrying { attempt, error }, _) => {
                println!("{at:>6.1}s retrying (attempt {attempt}): {error}");
            }
            (status, _) => println!("{at:>6.1}s {status:?}"),
        }
    }
}

fn print_board(at: f64, session: &SessionState) {
    let board = session.board();
    println!(
        "{at:>6.1}s herdr {} protocol {}, {} agents",
        session.version,
        session.protocol,
        board.len()
    );
    for entry in board {
        let pane = entry.pane;
        let place = format!(
            "{} / {}",
            entry.workspace.map_or("?", |ws| ws.label.as_str()),
            entry.tab.map_or("?", |tab| tab.label.as_str())
        );
        let title = pane
            .terminal_title_stripped
            .as_deref()
            .or(pane.title.as_deref())
            .unwrap_or("");
        println!(
            "        {:<8} {:<8} {:<20} {:<8} {}",
            pane.agent_status.as_str(),
            pane.pane_id,
            place,
            pane.display_agent
                .as_deref()
                .or(pane.agent.as_deref())
                .unwrap_or(""),
            title
        );
    }
}

fn report(label: &str, samples: &mut [Duration]) {
    samples.sort();
    let n = samples.len();
    if n == 0 {
        return;
    }
    let avg = samples.iter().map(|d| ms(*d)).sum::<f64>() / n as f64;
    let p95 = samples[(n * 95 / 100).min(n - 1)];
    println!(
        "{label}: n={n} min {:.1} ms, avg {avg:.1} ms, p95 {:.1} ms, max {:.1} ms",
        ms(samples[0]),
        ms(p95),
        ms(samples[n - 1])
    );
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}
