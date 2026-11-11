// Inbox handling settings (docs/assistant/inbox.md "Inbox handling settings", #4524): the Inbox's own switches for what
// it does with an item past triage, one object on the hub (GET / PUT /api/v1/inbox/settings, a PUT changes only the
// fields it names). The page that gathers the Inbox's handling (#4501) adds its fields here.

import { api } from "./api";
import { itemHeaders } from "./manager-choice";

/** The Inbox's handling settings, as the hub keeps them. */
export interface InboxSettings {
  /** Forward new messages linked to a running task to that task's owner (the conversation supervising it). Off by default. */
  forward_to_tasks: boolean;
}

const settingsOf = (r: Partial<InboxSettings> | null | undefined): InboxSettings => ({ forward_to_tasks: r?.forward_to_tasks === true });

/** Reads the settings (the default manager's); throws when the hub can't say (an older one has no such route). */
export async function loadInboxSettings(): Promise<InboxSettings> {
  return settingsOf(await api<Partial<InboxSettings>>("/inbox/settings", { headers: itemHeaders(undefined) }));
}

/** Saves what is given; resolves to the settings the hub answered (throws when it refused). */
export async function saveInboxSettings(patch: Partial<InboxSettings>): Promise<InboxSettings> {
  return settingsOf(await api<Partial<InboxSettings>>("/inbox/settings", { method: "PUT", json: patch, headers: itemHeaders(undefined) }));
}
