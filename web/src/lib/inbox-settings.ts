// Inbox handling settings (docs/assistant/inbox.md "Inbox handling settings", #4524): the Inbox's own switches for what
// it does with an item past triage, one object on the hub (GET / PUT /api/v1/inbox/settings, a PUT changes only the
// fields it names). The page that gathers the Inbox's handling (#4501) adds its fields here.

import { api } from "./api";
import { stampedHeaders } from "./manager-choice";
import { useStore } from "./store";

/** The hub feature saying it has these settings (server/internal/proto/proto.go); a hub without it gets no menu entry. */
export const INBOX_SETTINGS_FEATURE = "inbox_settings";

/** The Inbox's ⋯ menu offers Inbox handling: the hub says it has the settings. */
export function useInboxSettingsShown(): boolean {
  return useStore((s) => s.features.includes(INBOX_SETTINGS_FEATURE));
}

/** The Inbox's handling settings, as the hub keeps them. */
export interface InboxSettings {
  /** Forward new messages linked to a running task to the conversation following that task up. Off by default. */
  forward_to_tasks: boolean;
}

const settingsOf = (r: Partial<InboxSettings> | null | undefined): InboxSettings => ({ forward_to_tasks: r?.forward_to_tasks === true });

/** Reads the settings; throws when the hub can't say (an older one has no such route). `manager`: whose, asked of it by
 *  name with several assistants (the current one, as the Rules dialog does); none: the default's, nothing named. */
export async function loadInboxSettings(manager?: string): Promise<InboxSettings> {
  return settingsOf(await api<Partial<InboxSettings>>("/inbox/settings", { headers: stampedHeaders(manager) }));
}

/** Saves what is given to `manager`'s (as loadInboxSettings); resolves to the settings the hub answered (throws when it
 *  refused). */
export async function saveInboxSettings(patch: Partial<InboxSettings>, manager?: string): Promise<InboxSettings> {
  return settingsOf(await api<Partial<InboxSettings>>("/inbox/settings", { method: "PUT", json: patch, headers: stampedHeaders(manager) }));
}
