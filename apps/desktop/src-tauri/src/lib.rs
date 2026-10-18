//! Amiscara Agents for Windows and Linux: a Tauri shell around
//! `herdr-session`, the same core the Swift apps use through `herdr-ffi`.

/// What the frontend shows about this build.
#[derive(serde::Serialize)]
struct AppInfo {
    version: &'static str,
    protocol: u32,
}

#[tauri::command]
fn app_info() -> AppInfo {
    AppInfo {
        version: env!("CARGO_PKG_VERSION"),
        protocol: herdr_proto::SUPPORTED_PROTOCOL,
    }
}

/// Starts the app; returns when the last window is closed.
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![app_info])
        .run(tauri::generate_context!())
        .unwrap_or_else(|err| panic!("cannot run the app: {err}"));
}
