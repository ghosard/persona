# Handoff: #4206 One sidebar (branch `feat/4206-one-sidebar`)

> **Temporary.** Delete this file — and `docs/handoff/4206-one-sidebar.md` and `docs/handoff/4206-one-sidebar-prototype.html`,
> left by an earlier handoff — in a commit on this branch **before opening the PR**. The doc-path check fails while they exist.

Written for an Agent picking this up on another computer. Everything it needs is in this file and the repository; nothing
refers to files outside it.

## 1. Goal and scope

On the iPad and the open iPhone Duo (both postures) one sidebar replaces the Assistant | Agents switch: Persona's places,
Pinned, All Chats and the Agents list in one column, as in the web app. Design and behavior: `docs/apple/ios.md`,
"One sidebar".

- The PR closes: **Fixes #4206 #4852 #4853 #4854 #4855**, and **Refs #3641** (do not close #3641; its reporter has not replied).
- **#5795** (the open agent shows no selected row when it sits in a folded Idle Repositories card) was opened and claimed
  while testing this branch. It is **not fixed here** and not part of this PR.
- Claims: #4206 and #4852–#4855 have `Progress:` comments, and #5795 a `Claim:`, all with **ETA 2026-11-15**. Renew with a
  `Progress:` comment before it lapses (ask the owner first, see section 8).

## 2. Done on the branch

Branch state: merged with `origin/main` up to commit `f81398879` (2026-11-13; merge only, never rebased or force-pushed).
If `main` moves again before the PR, merge it once more (section 6).

The commits of the last stretch (`git log --first-parent`):

| Commit | What |
|---|---|
| `f2187b05c` | One Show Sidebar button at a time: on the open Duo held on its side Persona's page shows the system's bar (New Chat in the side column, #4854), and the split adds its own Show Sidebar there; the page no longer draws a second one. Test `OneSidebarTests.testOneButtonForTheColumnAtATime` (fails before the fix, passes after). |
| `a625755e0` | Merge `origin/main` (kept main's split of `AssistantView`'s stack for Xcode 26.0, #5333; the one sidebar's system bar is its own property `barredRoot`). |
| `e8c18b896` | An open agent is no longer lost when a second agent opens over it: agent rows in the one sidebar were `NavigationLink(value:)`, which in a split's sidebar drives a selection of its own and emptied the page's path; they are buttons now (`AgentsList.openLink`), as the Mac's repo rows. Messages leaves its top corner to the system's Show Sidebar on the Duo's side, like Persona's page. Test fixes. |
| `c250954f7` | Merge `origin/main`: the Recordings row follows #5517 (named Recordings, opens the page); the drawer's `collapse` is left out (the one sidebar folds itself). |
| `06f22a6b3` | Tests after #5587 (the list shows only the current assistant's computers; tests open an agent of the current assistant), the iPad top-strip check samples under the top bar, ReturnToChat scrolls until the row can be tapped and times its tree swap after the pick. |
| `3570fe23a` | **One color down the sidebar, and a foot without a band** (below). |
| `4878dafb3` | Handoff. |
| `ad1f80d94` | Merge `origin/main` (110 commits). Conflicts in `ChatsView` and `RootView` against #5641 (selecting Agents returns to the list): `ChatsView` keeps main's `agentNavigationLink` and folds the one sidebar's `openLink` into it (under the one sidebar a row is always a button that sets the bound path); `RootView` keeps the one sidebar on iOS and main's `selectHomeTab` tab binding elsewhere. `AgentsTabNavigationTests.testNativeTabReselectionAndSwitchBackShowList` skips under the one sidebar (no tabs there); `test_apple_rename.py` expects main's tab binding; `DESIGN_SYSTEM.md` 3.5 names the one sidebar. |
| `011dca2f6`, `72c6d0b43` | Merge `origin/main` again (6 commits, no conflicts; the second brings main's own build fix #5899). |
| `5eaff049d` | **The open Duo's sidebar is 320 pt** (below). |

### The color fix (`3570fe23a`)

The owner saw three bands down the column in the dark screenshots of the open Duo. Cause, measured from screenshots:

| Part | Where its color came from | Dark |
|---|---|---|
| Rows | the system sidebar's background (`OneSidebarMetrics.padColumn` was iPad-only) | 56,59,63 grey-blue |
| Header (mark, name, fold button) | `.background(OneSidebarMetrics.chromeBackground)` = `Theme.pageBackground` on the Duo | 0,0,0 on its side; 28,28,30 upright (the overlaid column is elevated) |
| Foot (New Chat, Search · Settings) | the same `chromeBackground` | as the header |
| Status-bar strip | `SplitNavigation.topFillColor`, nil on the Duo | as the header |

In light the system's sidebar and the page are both white, so it did not show; the iPad was already one color (#4855).

Now: `OneSidebarMetrics.columnColor` (renamed from `padColumn`) is `Theme.Shell.drawer` on the iPad **and** the open Duo
in the glass styles — **dark 23,23,23, light 249,249,249** — behind the rows, the header and the status-bar strip. The foot
has no background: its buttons float on the column and the rows scroll on behind them (as ChatGPT's iPad sidebar).
Files: `apple/Persona/Views/OneSidebar.swift`, `apple/Persona/Views/SplitNavigation.swift`, `docs/apple/ios.md` (#4855 entry).
The other styles keep their column as it was (the foot is transparent in all styles).

### The width (`5eaff049d`)

The owner found the column too narrow on the open Duo and asked for ChatGPT's width there: ChatGPT's sidebar on the open Duo
upright (669 × 951 pt) is **320 pt** wide (48 % of the screen). Ours had no width of its own and took the system's, about
199 pt upright and 239 pt on its side. Now `Theme.Size.sidebarPhone` = **320 pt** is the open Duo's column in both postures
(`SidebarWidth`); a width dragged on the handle still wins, and a double tap on it gives 320 back. The iPad keeps its
340–480 pt (400 measured), already wider. The narrow-column fallbacks (`ViewThatFits`) stay for a column dragged narrower.
`OneSidebarTests.testTheColumnHasThePlacesPinnedAndAgents` checks the width (320 ± 4 pt on the Duo, at least 320 on the
iPad) and the tests launch with `-agents.list.width 0`. Docs: `docs/apple/ios.md`, "One sidebar" ("The column's width").

## 3. Test status (on `5eaff049d`, mock hub with `MOCK_LEADERS=1`, simulators, Xcode 27.1; 26.0 not verified)

One `build-for-testing`, then `test-without-building` per device and posture.

| Where | Groups | Result |
|---|---|---|
| iPad (iPad Pro 13-inch) | `OneSidebarTests`, `DuoOpenChromeTests`, `SplitDividerTests`, `IPadLayoutTests`, `IPadSidebarTests`, `TreeSwapFoldTests`, `ReturnToChatTests` | 26 run: **18 passed, 7 skipped, 1 failed** |
| iPhone Duo, Open, upright | `OneSidebarTests`, `DuoOpenChromeTests`, `SplitDividerTests` | 17 run: **16 passed, 1 skipped, 0 failed** |
| iPhone Duo, Open, on its side (`TEST_RUNNER_PERSONA_ORIENTATION=landscape`) | same three | 17 run: **15 passed, 2 skipped, 0 failed** |

Before the width change, on the merge `72c6d0b43`, the Duo gave the same counts upright and on its side.

- Skips are by design: Duo-only tests skip on the iPad; upright-only and beside-the-page-only tests skip in the other posture.
- The one failure, `TreeSwapFoldTests.testHealthReportsStillGoUpAfterAFold`, **also fails on `main`**; not this PR's.

## 4. Status

The six screenshots and the montage were retaken on `5eaff049d` (2026-11-13) and checked: the size, one top-left button,
one color down the column (dark 23,23,23, light 249,249,249), and the column's width (iPad 400 pt, the Duo 320 pt upright
and on its side). They live outside the repository with the owner, with short videos of the one sidebar in use, and are
**waiting for the owner's review**. Nothing has been posted on GitHub; no PR yet.

Putting the Duo into the Open posture needs the Device Hub window (Xcode's Devices window). No command line
way was found: `simctl` has no posture command, `simctl io … screenConfig power` changes a panel's power but not the
posture, `devicectl` only reads the hinge angle, and the device type profile has no posture field (the Duo always boots
Closed). Rotation does have a command (`xcrun devicectl device orientation set --device <UDID> landscapeLeft`), but only
matters once the Duo is Open. So this part needs a logged-in, unlocked session.

## 5. How to finish

Run everything from the repository root unless a step says otherwise.

### Build

```sh
python3 scripts/persona_config.py xcconfig
eval "$(python3 scripts/persona_config.py env)"      # PERSONA_BUNDLE_ID etc., from your build config
(cd apple && xcodegen generate -q)                   # apple/Persona.xcodeproj is generated, never committed
(cd apple && xcodebuild -project Persona.xcodeproj -scheme Persona \
  -destination "generic/platform=iOS Simulator" -derivedDataPath ../build/DerivedData build-for-testing)
```

`build-for-testing` does not install the app; tests install it themselves, screenshots need
`xcrun simctl install <UDID> build/DerivedData/Build/Products/Debug-iphonesimulator/Persona.app` first.

### Mock hub (demo data only)

```sh
MOCK_LEADERS=1 PORT=18842 python3 scripts/mock/mock_hub.py     # any free port; check with lsof first
```

Stop it by its port (`lsof -nP -iTCP:18842 -sTCP:LISTEN -t | xargs kill`), never `pkill -f mock_hub.py` (other Agents).

### Simulators

Only through `scripts/app/sim-boot.sh` (one simulator at a time; the machine is busy):

```sh
DUO=$(scripts/app/sim-boot.sh --device-type "iPhone Duo" "Persona 4206 Duo")
IPAD=$(scripts/app/sim-boot.sh --device-type "iPad Pro 13-inch (M5)" "Persona 4206 iPad")
xcrun simctl shutdown <the other one>
```

### Duo: Open, on its side (needs the screen)

1. Xcode › Window › Devices and Simulators (Device Hub). Select **iPhone Duo** in the list; check the window's title names the
   Duo before every click (another session may be using the same window).
2. Click **Open** (posture), then **Rotate Right** until the inner display is landscape. Verify:
   `xcrun simctl io $DUO screenshot --display=3 /tmp/check.png && sips -g pixelWidth -g pixelHeight /tmp/check.png` →
   2853 × 2007 is on its side, 2007 × 2853 upright (`--display=3` is the inner display, `--display=1` the cover).
3. When done, select again whatever was selected before.

### UI tests

```sh
cd apple
TEST_RUNNER_PERSONA_MOCK_HUB=http://127.0.0.1:18842 TEST_RUNNER_PERSONA_ORIENTATION=landscape \
xcodebuild -project Persona.xcodeproj -scheme Persona -destination "platform=iOS Simulator,id=$DUO" \
  -derivedDataPath ../build/DerivedData test-without-building \
  -only-testing:PersonaUITests/OneSidebarTests -only-testing:PersonaUITests/DuoOpenChromeTests \
  -only-testing:PersonaUITests/SplitDividerTests
```

- `TEST_RUNNER_PERSONA_MOCK_HUB` must be a URL. Upright: drop `TEST_RUNNER_PERSONA_ORIENTATION`.
- A Duo back in Closed makes these tests skip: put it in Open first.
- iPad: same command with `-destination "platform=iOS Simulator,id=$IPAD"` and also
  `-only-testing:PersonaUITests/IPadLayoutTests -only-testing:PersonaUITests/IPadSidebarTests
  -only-testing:PersonaUITests/TreeSwapFoldTests -only-testing:PersonaUITests/ReturnToChatTests`.

### Screenshots (six, demo data only)

Launch Persona against the mock hub in zh-Hans, glass style, sidebar out, then capture:

```sh
U=$DUO; MODE=dark; OUT=shots/duo-landscape-$MODE.png; DISPLAY_N=3     # iPad: U=$IPAD and no --display
xcrun simctl terminate $U "$PERSONA_BUNDLE_ID"
xcrun simctl ui $U appearance $MODE
xcrun simctl spawn $U defaults write "$PERSONA_BUNDLE_ID" agents.list.closed -bool NO
xcrun simctl launch $U "$PERSONA_BUNDLE_ID" -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN \
  -pairURL 'persona://pair?url=http%3A%2F%2F127.0.0.1%3A18842&token=mock' -tab assistant -app.tab assistant \
  -dev.openChat '' -dev.grouping repo -agents.list.closed NO -agents.list.width 0 -ui.style glass
sleep 12
xcrun simctl io $U screenshot --display=$DISPLAY_N "$OUT"
```

Files: `ipad-light.png`, `ipad-dark.png`, `duo-portrait-light.png`, `duo-portrait-dark.png`, `duo-landscape-light.png`,
`duo-landscape-dark.png`. Check each before using it: the size (Duo 2853 × 2007 on its side, 2007 × 2853 upright), the
column's width (the Duo's screenshots are 3×, so 320 pt is 960 px; the iPad's 2×, 400 pt is 800 px), one
top-left button, and **one color down the column** (status strip, header and rows the same: dark 23,23,23, light
249,249,249; between the foot's buttons you see whatever row scrolled behind them). Set the appearance back to light after.
Never commit screenshots or mockups.

### Montage

Save as `m.swift` (outside the repository), run `swift m.swift <screenshot directory> <output.jpg>`. The labels are for the
owner, who reads Chinese.

```swift
import AppKit
let dir = CommandLine.arguments[1], out = CommandLine.arguments[2]
func img(_ n: String) -> NSImage { NSImage(contentsOfFile: "\(dir)/\(n).png")! }
func px(_ i: NSImage) -> NSSize { let r = i.representations[0]; return NSSize(width: r.pixelsWide, height: r.pixelsHigh) }
let gap: CGFloat = 40, label: CGFloat = 70, pad: CGFloat = 50
let row1: [(String,String)] = [("ipad-light","iPad 浅色"),("ipad-dark","iPad 深色"),("duo-portrait-light","Duo 竖握 浅色"),("duo-portrait-dark","Duo 竖握 深色")] // i18n-ignore
let row2: [(String,String)] = [("duo-landscape-light","Duo 横握 浅色"),("duo-landscape-dark","Duo 横握 深色")] // i18n-ignore
let h1: CGFloat = 1100
let w1 = row1.map { let s = px(img($0.0)); return s.width * h1 / s.height }
let W = w1.reduce(0,+) + gap * CGFloat(row1.count - 1)
let w2 = (W - gap) / 2
let s2 = px(img(row2[0].0)); let h2 = w2 * s2.height / s2.width
let totalW = W + pad*2, totalH = pad + label + h1 + gap + label + h2 + pad
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(totalW), pixelsHigh: Int(totalH), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: totalW, height: totalH)
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: totalW, height: totalH).fill()
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44, weight: .semibold), .foregroundColor: NSColor.black]
func draw(_ n: String, _ t: String, _ x: CGFloat, _ yTop: CGFloat, _ w: CGFloat, _ h: CGFloat) {
  (t as NSString).draw(at: NSPoint(x: x, y: totalH - yTop - label + 12), withAttributes: attrs)
  img(n).draw(in: NSRect(x: x, y: totalH - yTop - label - h, width: w, height: h))
}
var x = pad
for (i, r) in row1.enumerated() { draw(r.0, r.1, x, pad, w1[i], h1); x += w1[i] + gap }
x = pad
for r in row2 { draw(r.0, r.1, x, pad + label + h1 + gap, w2, h2); x += w2 + gap }
NSGraphicsContext.current = nil
let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!
try! jpg.write(to: URL(fileURLWithPath: out))
print(Int(totalW), Int(totalH))
```

Row one: iPad light, iPad dark, Duo upright light, Duo upright dark; row two: Duo on its side light and dark, each half the width.

Send the six paths (and the montage) to the owner and **stop** until they approve.

## 6. Before merging (after the owner approves)

1. Delete this file and `docs/handoff/4206-one-sidebar*` in a commit.
2. `git fetch && git merge origin/main` (merge only; never rebase, never force-push), if `main` moved since `f81398879`.
   Resolve conflicts keeping main's structure; rebuild; rerun the three groups on the iPad, the Duo upright and the Duo on
   its side.
3. Local checks: `python3 scripts/test/test_doc_paths.py`, `test_doc_go_paths.py`, `test_doc_sections.py`,
   `test_doc_wire.py`, `scripts/test/test_apple_rename.py`, `python3 scripts/privacy_check.py`; `scripts/ci/apple.sh` where
   it runs. CI on the PR: hosted CI does not run on PRs here; follow `docs/operations/testing.md` ("Hosted CI").
4. With the owner's go-ahead, post the screenshots to #4206, then open the PR from `.github/pull_request_template.md`:

   ```
   Title: feat(apple): one sidebar on the iPad and the open iPhone Duo

   Fixes #4206 #4852 #4853 #4854 #4855
   Refs #3641

   ## What changed and why
   (one sidebar replaces the Assistant | Agents switch; #4852 upright overlay; #4853 top margin on its side;
   #4854 New Chat in the system's side column; #4855 the column's color, now one color on the Duo too; the open Duo's
   column 320 pt, as ChatGPT's there; the one-button, lost-agent and three-band fixes from section 2)

   ## Principles self-check (docs/design/PRINCIPLES.md) and UI change self-check (docs/design/DESIGN_SYSTEM.md)
   ## Performance rules followed (docs/apple/performance.md)
   ## Verification (tests per device and posture, screenshots)
   ## Xcode used (and "26.0 not verified" if not 26.0)
   ```

5. Merge only with `scripts/hooks/merge-pr.sh <PR number>`, then check the issues closed (not #3641).

## 7. Commits

Identity: the GitHub account doing the work and its noreply address. Messages in English, ending with
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. `git config core.hooksPath scripts/hooks` runs the
privacy scan on commit and push. Stage only your files; `apple/Persona.xcodeproj/` is generated, never committed.

## 8. Rules for this work

- **Ask the owner before** opening the PR, merging, or posting anything on GitHub (comments, screenshots, closing issues).
- Do not close #3641.
- Claims are comments only (`Claim:` / `Progress:`), never GitHub's assign; current claims run to 2026-11-15.
- Mockups and screenshots use demo data only (the mock hub) and are never committed or pushed.
- Nothing machine-specific in the repository: no tokens, IPs, intranet addresses, host names, user names or local paths.
  Run `python3 scripts/privacy_check.py` before every push.
- Only run the tests the change touches; UI tests in simulators only.
