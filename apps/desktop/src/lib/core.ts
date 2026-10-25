// Typed calls into the Rust side (src-tauri/src/app.rs).

import { t, type MessageKey } from "./i18n.svelte";
import { Channel, invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type {
  AddHostLink,
  AppError,
  AppInfo,
  DemoTarget,
  HerdrSession,
  HostConfig,
  PaneContent,
  PaneEvent,
  ScrollStep,
  SessionUpdate,
  SpaceSortMode,
  TranscriptCursor,
  TranscriptPage,
} from "./types";

export const appInfo = () => invoke<AppInfo>("app_info");
export const demoTarget = () => invoke<DemoTarget | null>("demo_target");
export const listHosts = () => invoke<HostConfig[]>("list_hosts");
export const saveHost = (host: HostConfig) => invoke<HostConfig>("save_host", { host });
export const deleteHost = (hostId: string) => invoke<void>("delete_host", { hostId });
export const regenerateKey = (hostId: string) => invoke<HostConfig>("regenerate_key", { hostId });
export const setSpaceSort = (hostId: string, mode: SpaceSortMode, order: string[] | null) =>
  invoke<HostConfig>("set_space_sort", { hostId, mode, order });
export const keyLine = (hostId: string, allowSftp: boolean, allowWeb: boolean) =>
  invoke<string>("key_line", { hostId, allowSftp, allowWeb });
export const decodeLink = (text: string) => invoke<AddHostLink>("decode_link", { text });
export const keyFingerprint = (publicKey: string) =>
  invoke<string>("key_fingerprint", { publicKey });
export const addFromLink = (link: AddHostLink, trustHostKey: boolean) =>
  invoke<HostConfig>("add_from_link", { link, trustHostKey });
export const sessionSocket = (defaultSocket: string, name: string) =>
  invoke<string>("session_socket", { defaultSocket, name });
export const sessionOfSocket = (socketPath: string) =>
  invoke<string | null>("session_of_socket", { socketPath });
export const validSessionName = (name: string) => invoke<boolean>("valid_session_name", { name });
export const localDefaultSocket = () => invoke<string | null>("local_default_socket");
export const localSessions = () => invoke<HerdrSession[]>("local_sessions");
export const hostSessions = (hostId: string) => invoke<HerdrSession[]>("host_sessions", { hostId });
export const pendingLinks = () => invoke<string[]>("pending_links");
export const connect = (hostId: string) => invoke<void>("connect", { hostId });
export const disconnect = (hostId: string) => invoke<void>("disconnect", { hostId });
export const trustHostKey = (hostId: string, key: string) =>
  invoke<void>("trust_host_key", { hostId, key });
export const sendPrompt = (hostId: string, paneId: string, text: string) =>
  invoke<void>("send_prompt", { hostId, paneId, text });
export const sendKeys = (hostId: string, paneId: string, keys: string[]) =>
  invoke<void>("send_keys", { hostId, paneId, keys });
export const sendText = (hostId: string, paneId: string, text: string) =>
  invoke<void>("send_text", { hostId, paneId, text });

export const submit = (hostId: string, paneId: string, text: string, isAgent: boolean) =>
  invoke<void>("submit", { hostId, paneId, text, isAgent });
export const claudeHistory = (hostId: string, paneId: string, before: TranscriptCursor | null) =>
  invoke<TranscriptPage>("claude_history", { hostId, paneId, before });
export const agentHistory = (hostId: string, paneId: string) =>
  invoke<PaneContent>("agent_history", { hostId, paneId });
export const scrollAgent = (hostId: string, paneId: string, step: ScrollStep) =>
  invoke<void>("scroll_agent", { hostId, paneId, step });
/** The address to open for a page an agent asked for; localhost pages are forwarded. */
export const openRequestUrl = (hostId: string, url: string) =>
  invoke<string>("open_request_url", { hostId, url });
export const dismissOpenRequest = (hostId: string, paneId: string, requestId: string) =>
  invoke<void>("dismiss_open_request", { hostId, paneId, requestId });
export const quickReplies = () => invoke<string[]>("quick_replies");
export const setLanguage = (lang: string) => invoke<void>("set_language", { lang });
export const saveQuickReplies = (replies: string[]) =>
  invoke<void>("save_quick_replies", { replies });

/**
 * Uploads one file to `~/.amiscara-agents/uploads` on the host and returns
 * its path. `name` keeps the file's own name (any file), `extension` is for
 * a prepared image.
 */
export function upload(
  hostId: string,
  data: Uint8Array,
  target: { name: string } | { extension: string },
): Promise<string> {
  const headers: Record<string, string> = { "x-host-id": hostId };
  if ("name" in target) headers["x-file-name"] = encodeURIComponent(target.name);
  else headers["x-file-extension"] = target.extension;
  return invoke<string>("upload", data, { headers });
}

/** A new space or tab: its first pane. */
export interface Created {
  workspaceId: string;
  tabId: string;
  paneId: string;
}

export const setVisiblePane = (hostId: string | null, paneId: string | null) =>
  invoke<void>("set_visible_pane", { hostId, paneId });
export const agentKinds = (hostId: string) => invoke<string[]>("agent_kinds", { hostId });
export const createWorkspace = (hostId: string, label: string, directory: string) =>
  invoke<Created>("create_workspace", { hostId, label, directory });
export const createTab = (hostId: string, workspaceId: string) =>
  invoke<Created>("create_tab", { hostId, workspaceId });
export const createWorktree = (hostId: string, workspaceId: string, branch: string, base: string, label: string) =>
  invoke<Created>("create_worktree", { hostId, workspaceId, branch, base, label });
export const startAgent = (hostId: string, paneId: string, kind: string) =>
  invoke<string>("start_agent", { hostId, paneId, kind });
export const rename = (hostId: string, kind: "space" | "tab" | "agent", id: string, name: string) =>
  invoke<void>("rename", { hostId, kind, id, name });
export const close = (hostId: string, kind: "space" | "tab", id: string, withWorktrees: boolean) =>
  invoke<void>("close", { hostId, kind, id, withWorktrees });
export const autostart = () => invoke<boolean>("autostart");
export const setAutostart = (on: boolean) => invoke<void>("set_autostart", { on });

/** A running pane follower, see `follow_pane` in src-tauri. */
export interface Follower {
  stop(): void;
  setLive(live: boolean): void;
  setHistoryLines(lines: number): void;
  setUnwrap(unwrap: boolean): void;
}

/** Follows a pane until `stop`; events go to `onEvent`. */
export async function followPane(
  hostId: string,
  paneId: string,
  live: boolean,
  onEvent: (event: PaneEvent) => void,
): Promise<Follower> {
  const channel = new Channel<PaneEvent>();
  channel.onmessage = onEvent;
  const followId = await invoke<number>("follow_pane", { hostId, paneId, live, channel });
  return {
    stop() {
      channel.onmessage = () => {};
      void invoke("stop_follow", { followId });
    },
    setLive(live) {
      void invoke("set_follow_live", { followId, live });
    },
    setHistoryLines(lines) {
      void invoke("set_follow_history", { followId, lines });
    },
    setUnwrap(unwrap) {
      void invoke("set_follow_unwrap", { followId, unwrap });
    },
  };
}

/** Updates of all sessions; `generation` changes with every new session. */
export function onSessionUpdate(
  handler: (hostId: string, generation: number, update: SessionUpdate) => void,
): Promise<UnlistenFn> {
  return listen<{ hostId: string; generation: number; update: SessionUpdate }>("session-update", (event) =>
    handler(event.payload.hostId, event.payload.generation, event.payload.update),
  );
}

/** The tray menu, a notification or a link asks to show a pane. */
export function onOpenPane(
  handler: (target: { hostId: string; workspaceId: string; paneId: string }) => void,
): Promise<UnlistenFn> {
  return listen<{ hostId: string; workspaceId: string; paneId: string }>("open-pane", (event) =>
    handler(event.payload),
  );
}

export function onAddHostLink(handler: (url: string) => void): Promise<UnlistenFn> {
  return listen<string>("add-host-link", (event) => handler(event.payload));
}

/** The message of a failed command, in the user's language where the error is known. */
export function errorText(err: unknown): string {
  if (typeof err !== "object" || err === null || !("message" in err)) return String(err);
  const error = err as AppError;
  switch (error.kind) {
    case "invalidLink":
      return error.link ? linkErrorText(error.link) : error.message;
    case "config": {
      const key = CONFIG_ERRORS[error.code ?? ""];
      return key ? t(key, { host: error.host ?? "" }) : error.message;
    }
    case "notConnected":
      return t("errorNotConnected");
    case "agentBlocked":
      return t("errorAgentBlocked");
    case "upload":
      return t("errorUpload", { error: error.message });
    case "files":
      return t("errorFiles", { error: error.message });
    case "forward":
      return t("errorForward");
    case "key":
      return t("errorKey", { error: error.message });
    default:
      return error.message;
  }
}

const CONFIG_ERRORS: Record<string, MessageKey> = {
  missingHostUser: "errorMissingHostUser",
  relativeSocket: "errorRelativeSocket",
  localSocketUnix: "errorLocalSocketUnix",
  noOwnKey: "errorNoOwnKey",
  keyMissing: "errorKeyMissing",
  inputOff: "errorInputOff",
  uploadOff: "errorUploadOff",
};

/** Why an "add host" link was refused (`LinkError` in herdr-session). */
function linkErrorText(link: NonNullable<AppError["link"]>): string {
  const key = `link_${link.problem}` as MessageKey;
  return t(key, { field: link.field ?? "", host: link.host ?? "", user: link.user ?? "" });
}

/** Default `herdr.sock` for a login: macOS hosts use /Users, Linux /home. */
export function defaultSocket(user: string, macHost = true): string {
  return `${macHost ? "/Users" : "/home"}/${user}/.config/herdr/herdr.sock`;
}
