# FinMan for iOS

Native SwiftUI client for the FinManApp Spring Boot backend.

- **Requirements:** Xcode 26+ (built with Xcode 27), iOS 18+ deployment target, iPhone.
- **No dependencies:** SwiftUI, Swift Charts, Observation, and Keychain only.

## Run it

1. Start the backend (for example `./run-app.sh` or `java -jar target/*.jar --spring.profiles.active=h2`).
2. Open `ios/FinManApp.xcodeproj` and run the **FinManApp** scheme on an iPhone simulator.
3. Sign in, create an account, or tap **Explore with demo data**.

The server address defaults to `http://localhost:8080`. To change it, tap the server label on the sign-in screen or go to Profile → Server. On a physical device, use your Mac's LAN IP. `NSAllowsLocalNetworking` permits plain HTTP to local hosts.

In Debug builds, the `-autoDemo` launch argument signs straight into the demo account.

## Structure

```
FinManApp/
  App/            entry point, root/tab navigation
  Core/           APIClient, AppModel (state + API calls), Analytics, Keychain, lenient JSON decoding
  Models/         API models (decoded defensively; the backend serialises JPA entities directly)
  DesignSystem/   theme, category styles, cards, ring/progress gauges, confetti
  Features/       Auth, Dashboard, Transactions, Budgets, Bills, Insights, Settings
```

The project uses Xcode's folder-synchronized groups, so new files under `FinManApp/` are picked up without editing the project file.

## Features

- **Home:** gradient balance card, month-over-month spending nudge, money-health score ring, no-spend streak, spending-pace chart, upcoming bills carousel, budget snapshot, recent activity.
- **Activity:** search, income/spending and category filter chips, day-grouped list, swipe to categorize or delete, and a calculator-style add/edit sheet with a category picker.
- **Budgets:** overall ring, per-budget progress with "on track / getting close / over" states, and an editor with a warning-threshold slider.
- **Bills:** paid/unpaid sections, one-tap or swipe to mark paid (confetti 🎉), due-day calendar picker, bills-vs-income summary.
- **Insights:** AI money coach (backend `/api/insights/ai/*`), interactive category donut, 6-month income vs. spending bars, top merchants.
- Haptics throughout, dark mode, and Dynamic Type-friendly system fonts.

Charts and analytics are computed on the device from transactions, because the backend's `InsightService` aggregation methods are still stubs that return `null`.

## Backend fixes required

The app needs the fixes on the `backend-fixes-for-ios` branch: the `jackson-annotations` 2.22 pin, the implemented `TransactionService`, bill creation without an `id`, `/api/users/*` auth, and positive budget spending. Without them, most endpoints return 500, transactions are empty, and creating bills or saving income fails.

`/api/csv/import` still always imports into the demo user, so the app doesn't expose CSV import.
