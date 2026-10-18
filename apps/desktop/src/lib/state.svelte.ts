// App-wide state: hosts and the last update of each live session.

import * as core from "./core";
import type { AppInfo, HostConfig, SessionUpdate } from "./types";

class AppModel {
  info = $state<AppInfo | null>(null);
  hosts = $state<HostConfig[]>([]);
  updates = $state<Record<string, SessionUpdate>>({});
  selectedHostId = $state<string | null>(null);
  error = $state<string | null>(null);

  get selectedHost(): HostConfig | undefined {
    return this.hosts.find((host) => host.id === this.selectedHostId);
  }

  async load() {
    await core.onSessionUpdate((hostId, update) => {
      this.updates[hostId] = update;
    });
    this.info = await core.appInfo();
    this.hosts = await core.listHosts();
    this.selectedHostId ??= this.hosts[0]?.id ?? null;
    for (const host of this.hosts) {
      core.connect(host.id).catch((err) => (this.error = core.errorText(err)));
    }
  }

  /** Saves and (re)connects; returns the saved host. */
  async save(host: HostConfig): Promise<HostConfig> {
    const saved = await core.saveHost(host);
    this.replace(saved);
    await core.connect(saved.id);
    return saved;
  }

  replace(host: HostConfig) {
    const index = this.hosts.findIndex((known) => known.id === host.id);
    if (index >= 0) this.hosts[index] = host;
    else this.hosts.push(host);
    this.selectedHostId = host.id;
  }

  async remove(hostId: string) {
    await core.deleteHost(hostId);
    this.hosts = this.hosts.filter((host) => host.id !== hostId);
    delete this.updates[hostId];
    if (this.selectedHostId === hostId) this.selectedHostId = this.hosts[0]?.id ?? null;
  }
}

export const model = new AppModel();
