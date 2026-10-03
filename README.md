# FinMan for iOS (standalone)

A native SwiftUI budgeting app that runs entirely on the iPhone. There's no server and no account to create, and your data never leaves the device.

- **Requirements:** Xcode 26+ (built with Xcode 27), iOS 18+, iPhone.
- **No dependencies:** SwiftUI, SwiftData, Swift Charts, LocalAuthentication, and FoundationModels (optional, iOS 26+).

## Run it

Open `ios/FinManApp.xcodeproj` and run the **FinManApp** scheme. The first launch shows onboarding: enter your name, income and payday, then either start fresh or explore with sample data.

Debug-only launch arguments:
- `-sampleData` resets the store to fresh sample data and skips onboarding.
- `-tab activity|budgets|bills|insights` opens on that tab.

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
