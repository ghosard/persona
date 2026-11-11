// Screenshots and checks of "Inbox handling" (#4524, docs/assistant/inbox.md "Inbox handling settings"): the Inbox's
// ⋯ menu opens it beside Rules and Folders, "Forward related messages to their task" is off by default, saving it
// changes only that setting on the hub, and the assistant's settings no longer carry the old one.
//
// Needs the web page against the fake hub, and Chrome (playwright-core drives it):
//
//   PORT=18797 python3 scripts/mock/mock_hub.py &
//   (cd web && PERSONA_HUB_URL=http://127.0.0.1:18797 npx vite --port 5197 --strictPort &)
//   node web/e2e/inbox-handling.mjs http://127.0.0.1:5197 [--shots <dir>] [--locale en-US|zh-CN|ja-JP] [--chrome <path>]
//
// Runs wide (1280) and phone width (390), light and dark. Prints one line per check and a verdict; exits 1 on a failure
// and after three minutes.
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { chromium } from "playwright-core";

const args = process.argv.slice(2);
const flag = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const base = (args[0] ?? "").replace(/\/$/, "");
const shots = flag("--shots");
const locale = flag("--locale") ?? "en-US";
const chrome = flag("--chrome") ?? process.env.PERSONA_CHROME;
if (!base) {
  console.error("usage: node web/e2e/inbox-handling.mjs <web URL> [--shots <dir>] [--locale en-US|zh-CN|ja-JP] [--chrome <path>]");
  process.exit(2);
}
if (shots) mkdirSync(shots, { recursive: true });

const lang = locale.startsWith("zh") ? "zh" : locale.startsWith("ja") ? "ja" : "en";
const WORDS = {
  en: { more: "More actions", menu: "Inbox handling…", forward: "Forward related messages to their task", save: "Save" },
  zh: { more: "更多操作", menu: "收件箱处理…", forward: "把相关消息转给任务", save: "保存" },
  ja: { more: "その他の操作", menu: "受信トレイの処理…", forward: "関連メッセージをタスクに転送", save: "保存" },
}[lang];
const SIZES = { wide: { width: 1280, height: 860 }, narrow: { width: 390, height: 844 } };
const RUNS = [["wide", "light"], ["wide", "dark"], ["narrow", "light"], ["narrow", "dark"]];

const ok = (msg) => console.log(`ok  ${msg}`);
function fail(msg) {
  console.log(`FAIL ${msg}`);
  process.exit(1);
}

async function shot(page, name, tag) {
  if (!shots) return;
  await page.waitForTimeout(400); // entrances
  await page.screenshot({ path: join(shots, `${name}-${tag}.png`) });
}

async function run(browser, size, theme) {
  const tag = `${size}-${theme}`;
  const ctx = await browser.newContext({ viewport: SIZES[size], deviceScaleFactor: 2, hasTouch: size === "narrow", colorScheme: theme, locale });
  const page = await ctx.newPage();
  await page.goto(`${base}/inbox?token=mock`); // paired, the token traded for this browser's own
  const hub = (path, init) => page.evaluate(async ([p, i]) => (await fetch(`/api/v1${p}`, i)).json(), [path, init]);
  await page.locator("[data-item]").first().waitFor({ timeout: 10000 }).catch(() => fail(`${tag}: the Inbox did not load`));

  const open = async () => {
    await page.getByRole("button", { name: WORDS.more }).first().click();
    await page.getByRole("menuitem", { name: WORDS.menu }).click();
    await page.getByRole("dialog").waitFor({ timeout: 5000 }).catch(() => fail(`${tag}: no Inbox handling dialog`));
    const sw = page.getByRole("dialog").getByRole("switch", { name: WORDS.forward });
    await page.waitForFunction(() => !document.querySelector("[data-inbox-handling] [role=switch]")?.disabled, null, { timeout: 5000 })
      .catch(() => fail(`${tag}: the switch never became usable`));
    return sw;
  };

  const sw = await open();
  if ((await sw.getAttribute("aria-checked")) !== "false" || (await hub("/inbox/settings")).forward_to_tasks !== false) fail(`${tag}: forwarding is not off by default`);
  if (await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth)) fail(`${tag}: the page scrolls sideways`);
  ok(`${tag}: ⋯ › Inbox handling opens with forwarding off`);
  await shot(page, "inbox-handling", tag);

  await sw.click();
  await page.getByRole("dialog").getByRole("button", { name: WORDS.save }).click();
  await page.getByRole("dialog").waitFor({ state: "detached", timeout: 5000 }).catch(() => fail(`${tag}: the dialog stayed open after saving`));
  if ((await hub("/inbox/settings")).forward_to_tasks !== true) fail(`${tag}: forwarding did not save`);
  const again = await open();
  if ((await again.getAttribute("aria-checked")) !== "true") fail(`${tag}: the dialog does not show the saved value`);
  ok(`${tag}: turning it on saves, and the dialog shows it`);
  await shot(page, "inbox-handling-on", tag);

  // back off, so every run starts from the default
  await again.click();
  await page.getByRole("dialog").getByRole("button", { name: WORDS.save }).click();
  await page.getByRole("dialog").waitFor({ state: "detached", timeout: 5000 }).catch(() => fail(`${tag}: the dialog stayed open after saving`));
  if ((await hub("/inbox/settings")).forward_to_tasks !== false) fail(`${tag}: forwarding did not turn back off`);
  if ("inbox_signals" in (await hub("/assistant"))) fail(`${tag}: the assistant still has the old setting`);
  ok(`${tag}: turning it off saves; the assistant's settings no longer carry it`);
  await ctx.close();
}

const browser = await chromium.launch(chrome ? { executablePath: chrome, headless: true, args: ["--no-sandbox"] } : { channel: "chrome", headless: true });
const deadline = setTimeout(() => {
  console.log("FAIL inbox-handling: timed out after 3 minutes");
  process.exit(1);
}, 180000);
try {
  for (const [size, theme] of RUNS) await run(browser, size, theme);
  console.log("PASS inbox-handling");
} finally {
  clearTimeout(deadline);
  await browser.close();
}
