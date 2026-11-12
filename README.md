# Android Agents tab navigation evidence (#5638)

These are **Native JVM Compose renders**, not emulator or physical-device screenshots. The Linux build machine has no KVM and no attached Android device. All content is fictional fixture data.

The fixture uses the production `AppNavigator`, home chrome, Navigation 3 `NavDisplay`, `agentsEntries` and `ChatScreen`. Assistant is represented by a `JPage` hosting the embedded chat; this is not a full `PersonaShell`/live-hub end-to-end run.

## Reproduction

1. Start on Assistant.
2. Open an Agent through the targeted task/session navigation entry.
3. Select Assistant without popping the Agents detail stack.
4. Click the actual **Agents** home control.

Before the fix, the visible page is the earlier Agent detail. After the fix, it is the Agents list. Clicking the session row still opens the detail, and Back returns to the list.

- [Before/after comparison](review-before-after.png)
- [Three styles, light/dark overview](review-list-overview.png)
- `list-<glass|brief|board>-<light|dark>.png`: final list after the home control is clicked.
- `list-…-large.png`: the same at 2× Compose font scale. Existing large-text truncation/overlap is visible; no layout or design-system rendering code changes in this fix.
- `direct-detail-…png`: explicitly opening the Agent still shows its chat.
- `before-after-tab-glass-light.png`: the incorrect detail restored by the home control before production code changed.
- `before-assistant-glass-light.png`, `before-direct-detail-glass-light.png`: the preceding fixture pages.

## Tests

Production baseline: `ab972ad09`.

```sh
./gradlew :app:testDebugUnitTest \
  --tests persona.android.navigation.AgentsTabNavigationTest \
  --tests persona.android.ui.AgentsTabNavigationShotsTest.glassLight
```

Before the fix: **8 tests, 7 failures**. The six navigation failures cover task entry, app session link, hub `/s/…` link, notification/request detail, restored chat+terminal stack, and an explicit navigator call while Agents is selected. This last case tests the navigator API, not re-tapping the already selected Glass control: its existing menu remains unchanged. The Compose failure occurs after clicking the real home control from Assistant:

```text
expected: [AgentsRoute]
actual:   [AgentsRoute, ChatRoute(machineId=computer, sessionId=agent, kind=Agent, source=null)]
```

Targeted detail opening passes before the fix and remains covered afterward.

```sh
./gradlew :app:testDebugUnitTest \
  --tests 'persona.android.navigation.*' \
  --tests persona.android.ui.AgentsTabNavigationShotsTest
```

After the fix: **76 tests, 0 failures, 0 errors, 0 skipped; BUILD SUCCESSFUL**. This includes all seven new navigation tests and twelve Compose scenes (three styles × light/dark × default/large text).

Final integration verification at `2d50e475c` (main `3b4507aea` integrated):

```sh
./gradlew :app:test :core:navigation:test :app:assembleDebug :app:lintDebug
```

**App: 283 tests; core navigation: 35 tests; zero failures/errors/skips. BUILD SUCCESSFUL in 8m 27s.** Debug APK and app lint completed. Translation/token/slot guards, all four documentation guards and privacy scanning pass. No Release unit-test report or signed Release APK was produced.

The final PR head `8bbc0fff9` additionally merges main at `cde774ad3`. Its Android tree is byte-identical to the tested `2d50e475c` (`git diff --exit-code 2d50e475c HEAD -- android/` exits 0); doc/privacy checks pass again after keeping the current web rules alongside this Android rule. Screenshots were regenerated from the final integrated build. The six default list images are byte-identical to the earlier artifact the maintainer reviewed.

No APK has been installed on a phone and no production deployment is claimed. The fix needs to be included in a subsequent Android app release to reach installed devices.
