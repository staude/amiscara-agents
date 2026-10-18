// Typed calls into the Rust side (src-tauri/src/app.rs).

import { Channel, invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type {
  AddHostLink,
  AppError,
  AppInfo,
  HostConfig,
  PaneEvent,
  SessionUpdate,
} from "./types";

export const appInfo = () => invoke<AppInfo>("app_info");
export const listHosts = () => invoke<HostConfig[]>("list_hosts");
export const saveHost = (host: HostConfig) => invoke<HostConfig>("save_host", { host });
export const deleteHost = (hostId: string) => invoke<void>("delete_host", { hostId });
export const regenerateKey = (hostId: string) => invoke<HostConfig>("regenerate_key", { hostId });
export const keyLine = (hostId: string, allowSftp: boolean) =>
  invoke<string>("key_line", { hostId, allowSftp });
export const decodeLink = (text: string) => invoke<AddHostLink>("decode_link", { text });
export const keyFingerprint = (publicKey: string) =>
  invoke<string>("key_fingerprint", { publicKey });
export const addFromLink = (link: AddHostLink, trustHostKey: boolean) =>
  invoke<HostConfig>("add_from_link", { link, trustHostKey });
export const pendingLinks = () => invoke<string[]>("pending_links");
export const connect = (hostId: string) => invoke<void>("connect", { hostId });
export const disconnect = (hostId: string) => invoke<void>("disconnect", { hostId });
export const trustHostKey = (hostId: string, key: string) =>
  invoke<void>("trust_host_key", { hostId, key });
export const sendPrompt = (hostId: string, paneId: string, text: string) =>
  invoke<void>("send_prompt", { hostId, paneId, text });
export const sendKeys = (hostId: string, paneId: string, keys: string[]) =>
  invoke<void>("send_keys", { hostId, paneId, keys });

/** Follows a pane until the returned function is called. */
export async function followPane(
  hostId: string,
  paneId: string,
  live: boolean,
  onEvent: (event: PaneEvent) => void,
): Promise<() => void> {
  const channel = new Channel<PaneEvent>();
  channel.onmessage = onEvent;
  const followId = await invoke<number>("follow_pane", { hostId, paneId, live, channel });
  return () => {
    channel.onmessage = () => {};
    void invoke("stop_follow", { followId });
  };
}

export function onSessionUpdate(
  handler: (hostId: string, update: SessionUpdate) => void,
): Promise<UnlistenFn> {
  return listen<{ hostId: string; update: SessionUpdate }>("session-update", (event) =>
    handler(event.payload.hostId, event.payload.update),
  );
}

export function onAddHostLink(handler: (url: string) => void): Promise<UnlistenFn> {
  return listen<string>("add-host-link", (event) => handler(event.payload));
}

/** The message of a failed command, for the user. */
export function errorText(err: unknown): string {
  if (typeof err === "object" && err !== null && "message" in err) {
    return String((err as AppError).message);
  }
  return String(err);
}

/** Default `herdr.sock` for a login: macOS hosts use /Users, Linux /home. */
export function defaultSocket(user: string, macHost = true): string {
  return `${macHost ? "/Users" : "/home"}/${user}/.config/herdr/herdr.sock`;
}
