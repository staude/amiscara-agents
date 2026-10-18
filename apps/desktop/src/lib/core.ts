import { invoke } from "@tauri-apps/api/core";

/** What the Rust side reports about itself, see `app_info` in src-tauri. */
export interface AppInfo {
  version: string;
  protocol: number;
}

export function appInfo(): Promise<AppInfo> {
  return invoke<AppInfo>("app_info");
}
