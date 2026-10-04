# FinMan for iOS (standalone)

A native SwiftUI budgeting app that runs entirely on the iPhone. There's no server and no account to create, and your data never leaves the device.

- **Requirements:** Xcode 26+ (built with Xcode 27), iOS 18+, iPhone.
- **No dependencies:** SwiftUI, SwiftData, Swift Charts, LocalAuthentication, and FoundationModels (optional, iOS 26+).

## Run it

Open `ios/FinManApp.xcodeproj` and run the **FinManApp** scheme. The first launch shows onboarding: enter your name, income and payday, then either start fresh or explore with sample data.

Debug-only launch arguments:
- `-sampleData` resets the store to fresh sample data and skips onboarding.
- `-tab activity|budgets|bills|insights` opens on that tab.

## Keep it on your iPhone (free Apple ID)

Apps signed with a free Apple ID stop opening after 7 days. `scripts/refresh-on-device.sh` rebuilds the latest commit on `ios-standalone` and reinstalls it on your iPhone. Reinstalling keeps the app's data.

One-time setup:
1. Plug in the iPhone, open the project in Xcode, choose your Personal Team under Signing & Capabilities, and press Run once. Trust the developer on the phone under Settings → General → VPN & Device Management.
2. Unplug the iPhone, unlock it, and open Xcode → Window → Devices and Simulators (⇧⌘2). Select the iPhone and wait until it shows as connected over the network. Recent Xcode has no "Connect via network" checkbox; once the phone has been paired by cable, this sets up Wi-Fi. Check with `xcrun devicectl list devices`.
3. Run `ios/scripts/refresh-on-device.sh --install`. It copies the script to `~/bin/refresh-finman-ios.sh` and schedules it with launchd for Sundays and Wednesdays at 7 PM. Running twice a week means one missed run doesn't let the app expire.

Run it now with `launchctl kickstart -k gui/$(id -u)/com.jerrell.finman-ios-refresh`. Check results in `~/Library/Logs/finman-ios-refresh.log`; you also get a macOS notification for each run. Remove the schedule with `--uninstall`.

The job builds from its own git worktree at `~/Library/Developer/FinManRefresh/source`, so switching branches in the repo doesn't affect it. It needs the Mac awake and logged in (a run missed during sleep happens on wake) and the iPhone reachable on the same Wi-Fi. The first run may ask to let `codesign` use your keychain; choose **Always Allow**.

## How it works

- **Storage:** SwiftData models (`Account`, `Category`, `Transaction`, `Budget`, `Bill`) live in `Models/Models.swift`. The profile (name, income, payday) and settings live in `@AppStorage`. Every property has a default and every relationship is optional, so turning on iCloud (CloudKit) sync later only needs the iCloud capability and a container.
- **Balances:** an account's balance is its starting balance plus every transaction logged against it.
- **Budgets:** net spending in the budget's category during the current week, month or year. Refunds offset it.
- **Bills:** recurring bills count as paid only for the month they were marked paid, so they reset automatically each month.
- **Money coach:** uses Apple's on-device language model (Apple Intelligence, iOS 26+) when it's available, and falls back to rule-based tips otherwise. See `Core/Coach.swift`.
- **Privacy:** optional Face ID / passcode lock, CSV export, and "Erase all data" are in Profile.

## Structure

```
FinManApp/
  App/            entry point, model container, lock, tabs
  Core/           AppState, DataStore (seed/sample/export/erase), Analytics, Coach, Face ID lock
  Models/         SwiftData models
  DesignSystem/   theme, category styles, cards, ring/progress gauges, confetti
  Features/       Onboarding, Dashboard, Transactions, Budgets, Bills, Insights, Settings
```

The project uses Xcode's folder-synchronized groups, so new files under `FinManApp/` are picked up without editing the project file.

The version of this app that talks to the Spring Boot backend lives on the `ios-app` branch.
