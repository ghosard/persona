# Synthetic verification screenshots for #5780

These images contain only Robolectric fixtures. They contain no real accounts, messages, tokens or device data.

- `before-*`: baseline `079904e98661e24aa850d37bb9ac0aa35c21481a`.
- `after-*`: PR head `55eac531ebc004cba0ac3235b180ba434baf5995`.
- Main screens: `ShellShotsTest`, all three styles and languages, light and dark.
- Chat content: `ChatParityShotsTest`, all three styles, light and dark.
- Inbox events: `InboxEventShotsTest`, all three styles, light and dark.

Commands were run with JDK 21 and the Android SDK:

```sh
./gradlew :app:testDebugUnitTest --tests '*ShellShotsTest*'
./gradlew :feature:chat:testDebugUnitTest --tests '*ChatParityShotsTest*'
./gradlew :feature:inbox:testDebugUnitTest --tests '*InboxEventShotsTest*'
```
