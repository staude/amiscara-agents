// App-wide state: hosts, the last update of each live session, what the
// sidebar selects.

import * as core from "./core";
import { prefs } from "./prefs.svelte";
import type { AppInfo, HostConfig, SessionUpdate, SpaceSortMode, WorkspaceItem } from "./types";

/** A host (its settings), a space, or a space with one of its panes. */
export interface Selection {
  hostId: string;
  workspaceId: string | null;
  paneId: string | null;
}

class AppModel {
  info = $state<AppInfo | null>(null);
  hosts = $state<HostConfig[]>([]);
  updates = $state<Record<string, SessionUpdate>>({});
  /** Session generation per host; pane followers restart when it changes. */
  generations = $state<Record<string, number>>({});
  selection = $state<Selection | null>(null);
  /** The named herdr session each host points at; missing for the default. */
  sessionNames = $state<Record<string, string>>({});
  error = $state<string | null>(null);

  get selectedHost(): HostConfig | undefined {
    return this.hosts.find((host) => host.id === this.selection?.hostId);
  }

  get selectedWorkspace(): WorkspaceItem | undefined {
    const sel = this.selection;
    if (!sel?.workspaceId) return undefined;
    return this.updates[sel.hostId]?.workspaces.find((w) => w.workspaceId === sel.workspaceId);
  }

  host(id: string): HostConfig | undefined {
    return this.hosts.find((host) => host.id === id);
  }

  isLive(hostId: string): boolean {
    return this.updates[hostId]?.status.kind === "live";
  }

  async load() {
    await core.onSessionUpdate((hostId, generation, update) => {
      this.updates[hostId] = update;
      if (this.generations[hostId] !== generation) this.generations[hostId] = generation;
    });
    this.info = await core.appInfo();
    this.hosts = await core.listHosts();
    for (const host of this.hosts) void this.readSessionName(host);
    if (!this.selection && this.hosts[0]) this.select(this.hosts[0].id);
    for (const host of this.hosts) {
      core.connect(host.id).catch((err) => (this.error = core.errorText(err)));
    }
  }

  select(hostId: string, workspaceId: string | null = null, paneId: string | null = null) {
    this.selection = { hostId, workspaceId, paneId };
  }

  /** Saves and (re)connects; returns the saved host. */
  async save(host: HostConfig): Promise<HostConfig> {
    const saved = await core.saveHost(host);
    this.replace(saved);
    await core.connect(saved.id);
    return saved;
  }

  /** Changes the order of spaces; the session sends a rebuilt update. */
  async setSpaceSort(hostId: string, mode: SpaceSortMode, order: string[] | null) {
    this.replace(await core.setSpaceSort(hostId, mode, order));
  }

  /** The session name for the sidebar, from the host's socket. */
  async readSessionName(host: HostConfig) {
    const name = host.socketPath ? await core.sessionOfSocket(host.socketPath).catch(() => null) : null;
    if (name) this.sessionNames[host.id] = name;
    else delete this.sessionNames[host.id];
  }

  replace(host: HostConfig) {
    void this.readSessionName(host);
    const index = this.hosts.findIndex((known) => known.id === host.id);
    if (index >= 0) this.hosts[index] = host;
    else {
      this.hosts.push(host);
      this.select(host.id);
    }
  }

  async remove(hostId: string) {
    await core.deleteHost(hostId);
    this.hosts = this.hosts.filter((host) => host.id !== hostId);
    delete this.updates[hostId];
    delete this.sessionNames[hostId];
    prefs.forgetHost(hostId);
    if (this.selection?.hostId === hostId) {
      this.selection = this.hosts[0] ? { hostId: this.hosts[0].id, workspaceId: null, paneId: null } : null;
    }
  }
}

export const model = new AppModel();
