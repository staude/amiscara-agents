import { terminalTheme, type TerminalAppearance, type TerminalScheme, type TerminalTheme } from "./term";

// Per-device view settings, kept in the webview's storage. Losing them
// (private mode, cleared data) only resets the view.

function read<T>(key: string, fallback: T): T {
  try {
    const raw = localStorage.getItem(key);
    return raw === null ? fallback : (JSON.parse(raw) as T);
  } catch {
    return fallback;
  }
}

function write(key: string, value: unknown) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // Storage blocked: the setting lasts until the window closes.
  }
}

export type AgentOrder = "grouped" | "status";

/** Light or dark look: as the system (default) or fixed. */
export type Theme = "system" | "light" | "dark";

export const FONT_MIN = 8;
export const FONT_MAX = 28;
export const FONT_DEFAULT = 13;

class Prefs {
  /** Folded sections as "hostId/spaces", "hostId/agents", "hostId/group/<name>". */
  collapsed = $state<string[]>(read("collapsedSections", []));
  agentOrder = $state<AgentOrder>(read("agentOrder", "grouped"));
  fontSize = $state<number>(read("terminalFontSize", FONT_DEFAULT));
  theme = $state<Theme>(read("theme", "system"));
  terminalAppearance = $state<TerminalAppearance>(read("terminalAppearance", "app"));
  terminalScheme = $state<TerminalScheme>(read("terminalScheme", "standard"));
  minContrast = $state<boolean>(read("terminalMinContrast", true));
  /** Offer the steps through full-screen agents, which move the host's view too (#187). */
  fullscreenScroll = $state<boolean>(read("scrollFullscreenAgents", false));
  /** The system's look, for "system" in `theme`. */
  systemDark = $state(false);

  constructor() {
    try {
      const query = matchMedia("(prefers-color-scheme: dark)");
      this.systemDark = query.matches;
      query.addEventListener("change", (e) => (this.systemDark = e.matches));
    } catch {
      // No media queries: light.
    }
  }

  /** Colors of the panes from the terminal settings and the app's look. */
  get terminal(): TerminalTheme {
    const appDark = this.theme === "dark" || (this.theme === "system" && this.systemDark);
    const dark = this.terminalAppearance === "app" ? appDark : this.terminalAppearance === "dark";
    return terminalTheme(this.terminalScheme, dark, this.minContrast);
  }

  isCollapsed(hostId: string, section: string): boolean {
    return this.collapsed.includes(`${hostId}/${section}`);
  }

  toggle(hostId: string, section: string) {
    const key = `${hostId}/${section}`;
    this.collapsed = this.collapsed.includes(key)
      ? this.collapsed.filter((k) => k !== key)
      : [...this.collapsed, key];
    write("collapsedSections", this.collapsed);
  }

  toggleAgentOrder() {
    this.agentOrder = this.agentOrder === "grouped" ? "status" : "grouped";
    write("agentOrder", this.agentOrder);
  }

  zoom(step: number | null) {
    const next = step === null ? FONT_DEFAULT : this.fontSize + step;
    this.fontSize = Math.min(FONT_MAX, Math.max(FONT_MIN, next));
    write("terminalFontSize", this.fontSize);
  }

  setTheme(theme: Theme) {
    this.theme = theme;
    write("theme", theme);
  }

  setTerminalAppearance(appearance: TerminalAppearance) {
    this.terminalAppearance = appearance;
    write("terminalAppearance", appearance);
  }

  setTerminalScheme(scheme: TerminalScheme) {
    this.terminalScheme = scheme;
    write("terminalScheme", scheme);
  }

  setMinContrast(on: boolean) {
    this.minContrast = on;
    write("terminalMinContrast", on);
  }

  setFullscreenScroll(on: boolean) {
    this.fullscreenScroll = on;
    write("scrollFullscreenAgents", on);
  }
}

/**
 * Applies `theme` to the page (`data-theme` on the root, see app.css) and
 * to the window frame; "system" follows the system again.
 */
export function applyTheme(theme: Theme) {
  if (theme === "system") delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = theme;
  if (import.meta.env.MODE === "mock") return;
  import("@tauri-apps/api/window")
    .then(({ getCurrentWindow }) => getCurrentWindow().setTheme(theme === "system" ? null : theme))
    .catch(() => {});
}

export const prefs = new Prefs();
