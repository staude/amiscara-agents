//! Amiscara Agents for Windows and Linux: a Tauri shell around
//! `herdr-session`, the same core the Swift apps use through `herdr-ffi`.

mod app;
mod error;
mod hosts;

use tauri::Manager;
use tauri_plugin_deep_link::DeepLinkExt;

/// Starts the app; returns when the last window is closed.
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = tauri::Builder::default();
    // A second start (e.g. from an opened link) hands its arguments to the
    // running app instead; with the deep-link feature it forwards links.
    #[cfg(any(windows, target_os = "linux"))]
    let builder = builder.plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
        app::open_links(app, []);
    }));
    builder
        .plugin(tauri_plugin_deep_link::init())
        .setup(|app| {
            let dir = app.path().app_data_dir()?;
            app.manage(app::AppState::new(hosts::HostStore::load(dir)?));
            // Installers register the scheme; a dev build does it itself.
            #[cfg(any(windows, target_os = "linux"))]
            if cfg!(debug_assertions) {
                let _ = app.deep_link().register_all();
            }
            let handle = app.handle().clone();
            app.deep_link().on_open_url(move |event| {
                app::open_links(&handle, event.urls().iter().map(ToString::to_string));
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            app::app_info,
            app::list_hosts,
            app::save_host,
            app::regenerate_key,
            app::delete_host,
            app::key_line,
            app::decode_link,
            app::key_fingerprint,
            app::add_from_link,
            app::connect,
            app::disconnect,
            app::trust_host_key,
            app::follow_pane,
            app::stop_follow,
            app::set_follow_live,
            app::set_follow_history,
            app::send_prompt,
            app::send_keys,
            app::send_text,
            pending_links,
        ])
        .run(tauri::generate_context!())
        .unwrap_or_else(|err| panic!("cannot run the app: {err}"));
}

/// Links the app was started with, read once by the window when it loads.
#[tauri::command]
fn pending_links(app: tauri::AppHandle) -> Vec<String> {
    app.deep_link()
        .get_current()
        .ok()
        .flatten()
        .unwrap_or_default()
        .iter()
        .map(ToString::to_string)
        .collect()
}
