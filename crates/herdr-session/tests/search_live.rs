//! Against the herdr test session only (writes: opens and closes a tab in
//! its first space, which has to exist):
//! `HERDR_SEARCH_SOCKET=~/.config/herdr/sessions/herdr-remote-test/herdr.sock HERDR_SEARCH_QUERY=<word> cargo test -p herdr-session --test search_live -- --ignored --nocapture --test-threads=1`

use std::sync::{Arc, Mutex};
use std::time::Duration;

use herdr_session::view::SessionUpdate;
use herdr_session::{ConversationHit, Endpoint, Route, SearchEnd, SearchSink, Session, SpaceSort};
use tokio::sync::mpsc;

enum Event {
    Progress(u64, u64),
    Hits(Vec<ConversationHit>),
    Finished(SearchEnd),
}

struct Sink(mpsc::UnboundedSender<Event>);

impl SearchSink for Sink {
    fn on_progress(&self, done: u64, total: u64) {
        let _ = self.0.send(Event::Progress(done, total));
    }

    fn on_hits(&self, hits: Vec<ConversationHit>) {
        let _ = self.0.send(Event::Hits(hits));
    }

    fn on_finished(&self, end: SearchEnd) {
        let _ = self.0.send(Event::Finished(end));
    }
}

/// A session on the test socket and its latest update, once the first
/// snapshot with a space is there.
async fn start() -> (Session, Arc<Mutex<Option<SessionUpdate>>>) {
    let socket = std::env::var("HERDR_SEARCH_SOCKET").expect("HERDR_SEARCH_SOCKET");
    let socket = socket.replacen('~', &std::env::var("HOME").expect("HOME"), 1);
    let latest = Arc::new(Mutex::new(None));
    let store = latest.clone();
    let session = Session::start(
        Endpoint::Local {
            socket_path: Some(socket),
        },
        false,
        SpaceSort::Herdr,
        move |update| *store.lock().expect("lock") = Some(update),
    )
    .expect("session");
    for _ in 0..50 {
        if tabs(&latest).is_some_and(|count| count > 0) {
            return (session, latest);
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    panic!("no space in the test session");
}

fn tabs(latest: &Mutex<Option<SessionUpdate>>) -> Option<usize> {
    let update = latest.lock().expect("lock");
    let update = update.as_ref()?;
    Some(update.workspaces.iter().map(|space| space.tabs.len()).sum())
}

async fn wait_for_tabs(latest: &Mutex<Option<SessionUpdate>>, count: usize) {
    for _ in 0..50 {
        if tabs(latest) == Some(count) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    panic!(
        "the search tab stayed: {:?} tabs, {count} before",
        tabs(latest)
    );
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs the herdr test session"]
async fn grep_on_the_host_finds_hits() {
    let query = std::env::var("HERDR_SEARCH_QUERY").expect("HERDR_SEARCH_QUERY");
    let (session, latest) = start().await;
    let before = tabs(&latest).expect("tabs");
    let (tx, mut rx) = mpsc::unbounded_channel();
    let _search = session
        .search_conversations_via(&query, Route::Host, Sink(tx))
        .expect("search");
    let mut hits = Vec::new();
    let end = loop {
        match tokio::time::timeout(Duration::from_secs(300), rx.recv()).await {
            Ok(Some(Event::Hits(found))) => hits.extend(found),
            Ok(Some(Event::Progress(done, total))) => eprintln!("{done}/{total}"),
            Ok(Some(Event::Finished(end))) => break end,
            other => panic!("no end: {}", other.is_ok()),
        }
    };
    println!("{end:?}");
    for hit in &hits {
        println!(
            "{:?} {} @{} {:?}: {}",
            hit.workspace_id, hit.session_path, hit.offset, hit.session_title, hit.snippet
        );
    }
    assert_eq!(end.error, None);
    assert!(!end.cancelled);
    assert!(!hits.is_empty(), "no hits for {query:?}");
    // The line of a hit opens there.
    let span = session
        .claude_history_at(&hits[0].session_path, hits[0].offset)
        .await
        .expect("span");
    let at = span.highlight.expect("highlight") as usize;
    println!("{:?}: {}", span.entries[at].kind, span.entries[at].text);
    wait_for_tabs(&latest, before).await;
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs the herdr test session"]
async fn a_cancelled_search_closes_its_tab() {
    let query = std::env::var("HERDR_SEARCH_QUERY").expect("HERDR_SEARCH_QUERY");
    let (session, latest) = start().await;
    let before = tabs(&latest).expect("tabs");
    let (tx, mut rx) = mpsc::unbounded_channel();
    let search = session
        .search_conversations_via(&query, Route::Host, Sink(tx))
        .expect("search");
    // Until the script reports progress, so the tab runs.
    loop {
        match tokio::time::timeout(Duration::from_secs(30), rx.recv()).await {
            Ok(Some(Event::Progress(_, total))) if total > 0 => break,
            Ok(Some(Event::Finished(end))) => panic!("ended before the cancel: {end:?}"),
            Ok(Some(_)) => {}
            other => panic!("no progress: {}", other.is_ok()),
        }
    }
    search.cancel();
    let end = loop {
        match tokio::time::timeout(Duration::from_secs(30), rx.recv()).await {
            Ok(Some(Event::Finished(end))) => break end,
            // Sent before the cancel.
            Ok(Some(_)) => {}
            other => panic!("no end: {}", other.is_ok()),
        }
    };
    assert!(end.cancelled);
    wait_for_tabs(&latest, before).await;
}
