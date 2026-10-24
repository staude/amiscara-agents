//! Against a herdr test session only (writes: opens and closes a tab):
//! `HERDR_DIFF_SOCKET=<socket> HERDR_DIFF_PANE=<pane id> cargo test -p herdr-session --test diff_live -- --ignored --nocapture`

use std::time::Duration;

use herdr_session::{Endpoint, Session};

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs a herdr test session"]
async fn diff_of_a_demo_pane() {
    let socket = std::env::var("HERDR_DIFF_SOCKET").expect("HERDR_DIFF_SOCKET");
    let pane = std::env::var("HERDR_DIFF_PANE").expect("HERDR_DIFF_PANE");
    let session = Session::start(
        Endpoint::Local {
            socket_path: Some(socket),
        },
        false,
        |_| {},
    )
    .expect("session");
    // Wait for the first snapshot.
    let mut files = None;
    for _ in 0..50 {
        tokio::time::sleep(Duration::from_millis(200)).await;
        match session.working_tree_diff(&pane).await {
            Ok(found) => {
                files = Some(found);
                break;
            }
            Err(err) => eprintln!("not yet: {err}"),
        }
    }
    let files = files.expect("diff");
    println!("truncated: {}", files.truncated);
    for file in &files.files {
        println!(
            "{:?} {} +{} -{} hunks {}",
            file.status,
            file.path,
            file.additions,
            file.deletions,
            file.hunks.len()
        );
    }
}
