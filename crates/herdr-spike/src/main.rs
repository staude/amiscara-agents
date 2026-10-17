//! Read-only probe for the herdr socket API, locally or over SSH.
//!
//! Answers the spike questions: does SSH streamlocal to `herdr.sock` work,
//! and is request latency low enough for a live GUI?

use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use herdr_proto::{
    GLOBAL_SUBSCRIPTIONS, PaneList, PaneRead, PaneReadResult, Pong, SUPPORTED_PROTOCOL,
    WorkspaceList,
};
use herdr_transport::{Connection, SshTarget};
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
    let started = Instant::now();
    let conn = connect(&cli).await?;
    eprintln!("connected in {:.0} ms", ms(started.elapsed()));

    match cli.command {
        Command::Ping => ping(&conn).await,
        Command::List => list(&conn).await,
        Command::Read { pane, ansi } => read(&conn, &pane, ansi).await,
        Command::Watch { seconds } => watch(&conn, seconds).await,
        Command::Bench { count, pane } => bench(&conn, count, pane).await,
    }
}

#[cfg(unix)]
fn connect_local(cli: &Cli) -> Result<Connection> {
    let socket = match &cli.socket {
        Some(path) => PathBuf::from(path),
        None => Connection::default_local_socket().context("no home directory")?,
    };
    Ok(Connection::local(socket))
}

#[cfg(not(unix))]
fn connect_local(_cli: &Cli) -> Result<Connection> {
    bail!("a local herdr socket needs a Unix system; use --ssh")
}

async fn connect(cli: &Cli) -> Result<Connection> {
    let Some(spec) = &cli.ssh else {
        return connect_local(cli);
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
        identity: cli.identity.clone(),
        known_hosts,
        accept_new_host_key: cli.accept_new_host_key,
    };
    let socket = cli
        .socket
        .clone()
        .unwrap_or_else(|| format!("/Users/{user}/.config/herdr/herdr.sock"));
    Ok(Connection::ssh(&target, socket).await?)
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
            ws.label.as_deref().unwrap_or("-"),
            ws.agent_status.as_deref().unwrap_or("-")
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
                pane.agent_status.as_deref().unwrap_or("-"),
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
