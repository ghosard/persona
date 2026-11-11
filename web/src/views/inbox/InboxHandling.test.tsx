// @vitest-environment jsdom
// "Inbox handling" in the Inbox's ⋯ menu (#4524, docs/assistant/inbox.md "Inbox handling settings"): the dialog shows the
// hub's value, saves only what it holds, goes back with the reason when refused, and says so when it can't read them.
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

vi.mock("../../ui/atoms", async (original) => ({ ...(await original<typeof import("../../ui/atoms")>()), toast: vi.fn() }));
import { initI18n, t } from "../../i18n";
import { toast } from "../../ui/atoms";
import { InboxHandlingDialog } from "./InboxHandling";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let host: HTMLDivElement;
let root: Root;
let fetcher: ReturnType<typeof vi.fn>;
/** What the hub keeps; a GET or PUT answers it. */
let stored: { forward_to_tasks: boolean };
/** A status the hub answers instead, when set. */
let refuse: { method: string; status: number; error: string } | undefined;
const flush = async () => {
  for (let i = 0; i < 6; i++) await act(async () => { await Promise.resolve(); });
};
const button = (text: string) => [...document.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent?.trim() === text);
const toggle = () => document.querySelector<HTMLButtonElement>(`[role="switch"][aria-label="${t("inbox-handling.forward_title")}"]`)!;
const puts = () => fetcher.mock.calls.filter(([u, init]) => u === "/api/v1/inbox/settings" && init?.method === "PUT").map(([, init]) => JSON.parse(init.body));

beforeEach(async () => {
  await initI18n("en");
  vi.mocked(toast).mockClear();
  stored = { forward_to_tasks: false };
  refuse = undefined;
  fetcher = vi.fn().mockImplementation(async (url: string, init?: { method?: string; body?: string }) => {
    if (url !== "/api/v1/inbox/settings") throw new Error(`unexpected ${url}`);
    const method = init?.method ?? "GET";
    if (refuse?.method === method) return { ok: false, status: refuse.status, text: async () => JSON.stringify({ error: refuse!.error }) };
    if (method === "PUT") stored = { ...stored, ...JSON.parse(init?.body ?? "{}") };
    return { ok: true, status: 200, text: async () => JSON.stringify(stored) };
  });
  vi.stubGlobal("fetch", fetcher);
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});
afterEach(() => {
  act(() => root.unmount());
  host.remove();
  vi.unstubAllGlobals();
});

async function open(onClose = vi.fn()) {
  act(() => root.render(<InboxHandlingDialog onClose={onClose} />));
  await flush();
  return onClose;
}

it("shows the hub's value, off by default, with what it does", async () => {
  await open();
  expect(toggle().getAttribute("aria-checked")).toBe("false");
  expect(document.body.textContent).toContain("Inbox handling");
  expect(document.body.textContent).toContain("tell that task's owner");
});

it("saves the switch and closes", async () => {
  const onClose = await open();
  act(() => toggle().click());
  act(() => button(t("common.save"))!.click());
  await flush();
  expect(puts()).toEqual([{ forward_to_tasks: true }]);
  expect(stored.forward_to_tasks).toBe(true);
  expect(onClose).toHaveBeenCalled();
  expect(toast).toHaveBeenCalledWith(t("inbox-handling.saved"), "ok");
});

it("keeps the dialog open with the hub's reason when the change is refused", async () => {
  refuse = { method: "PUT", status: 403, error: "Synthetic refusal" };
  const onClose = await open();
  act(() => toggle().click());
  act(() => button(t("common.save"))!.click());
  await flush();
  expect(toast).toHaveBeenCalledWith(expect.stringContaining("Synthetic refusal"), "error");
  expect(onClose).not.toHaveBeenCalled();
  expect(stored.forward_to_tasks).toBe(false);
});

it("says it can't read them from a hub that doesn't have them, and saves nothing", async () => {
  refuse = { method: "GET", status: 404, error: "not found" };
  await open();
  expect(document.querySelector('[role="alert"]')?.textContent).toContain("Couldn't read these settings");
  expect(toggle().disabled).toBe(true);
  expect(button(t("common.save"))!.disabled).toBe(true);
});
