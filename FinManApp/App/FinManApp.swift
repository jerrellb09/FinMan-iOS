import SwiftUI

@main
struct FinManApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    #if DEBUG
                    // `-autoDemo` launch argument signs straight into the demo account (handy for UI work).
                    if ProcessInfo.processInfo.arguments.contains("-autoDemo") {
                        try? await model.demoLogin()
                        return
                    }
                    #endif
                    await model.restoreSession()
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.phase {
            case .launching:
                LaunchView()
            case .signedOut:
                AuthView().transition(.opacity)
            case .signedIn:
                MainTabView().transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            ConfettiView(trigger: model.celebrationTrigger)
        }
        .animation(.snappy, value: model.phase)
    }
}

private struct LaunchView: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Theme.brandGradient.ignoresSafeArea()
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 72, weight: .bold))
                .foregroundStyle(.white)
                .scaleEffect(pulse ? 1.08 : 0.94)
                .animation(.easeInOut(duration: 0.8).repeatForever(), value: pulse)
                .onAppear { pulse = true }
        }
    }
}

enum AppTab: Hashable { case home, activity, budgets, bills, insights }

struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: AppTab = .home

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: .home) {
                DashboardView(selectedTab: $tab)
            }
            Tab("Activity", systemImage: "list.bullet.rectangle.portrait.fill", value: .activity) {
                TransactionsView()
            }
            Tab("Budgets", systemImage: "chart.pie.fill", value: .budgets) {
                BudgetsView()
            }
            Tab("Bills", systemImage: "calendar.badge.clock", value: .bills) {
                BillsView()
            }
            .badge(model.bills.filter { !$0.isPaid && $0.daysUntilDue() <= 3 }.count)
            Tab("Insights", systemImage: "sparkles", value: .insights) {
                InsightsView()
            }
        }
        .sensoryFeedback(.selection, trigger: tab)
        .overlay(alignment: .top) {
            if let error = model.lastError {
                ErrorBanner(message: error) { withAnimation { model.lastError = nil } }
                    .task {
                        try? await Task.sleep(for: .seconds(5))
                        withAnimation { model.lastError = nil }
                    }
            }
        }
        .animation(.snappy, value: model.lastError)
    }
}
