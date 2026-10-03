import SwiftData
import SwiftUI

@main
struct FinManApp: App {
    @State private var state = AppState()
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Schema(AppSchema.models))
        } catch {
            fatalError("Couldn't open the FinMan data store: \(error)")
        }
        DataStore.seedCategoriesIfNeeded(container.mainContext)
        #if DEBUG
        // `-sampleData` launch argument resets to fresh sample data (handy for UI work and screenshots).
        if ProcessInfo.processInfo.arguments.contains("-sampleData") {
            DataStore.eraseAll(container.mainContext)
            DataStore.loadSampleData(container.mainContext, monthlyIncome: 5_000, paydayDay: 15)
            let defaults = UserDefaults.standard
            defaults.set("Alex", forKey: ProfileKey.name)
            defaults.set(5_000.0, forKey: ProfileKey.monthlyIncome)
            defaults.set(15, forKey: ProfileKey.paydayDay)
            defaults.set(true, forKey: ProfileKey.hasOnboarded)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ProfileKey.hasOnboarded) private var hasOnboarded = false
    @AppStorage(ProfileKey.faceIDEnabled) private var faceIDEnabled = false
    @State private var isLocked = UserDefaults.standard.bool(forKey: ProfileKey.faceIDEnabled)

    var body: some View {
        ZStack {
            if hasOnboarded {
                MainTabView().transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                OnboardingView().transition(.opacity)
            }
            ConfettiView(trigger: state.celebrationTrigger)
            if isLocked && faceIDEnabled {
                LockScreen { withAnimation(.snappy) { isLocked = false } }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.snappy, value: hasOnboarded)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && faceIDEnabled { isLocked = true }
        }
    }
}

enum AppTab: Hashable { case home, activity, budgets, bills, insights }

struct MainTabView: View {
    @Environment(AppState.self) private var state
    @Query private var bills: [Bill]
    @State private var tab: AppTab = Self.launchTab

    /// Debug builds accept `-tab activity|budgets|bills|insights` to open on a specific tab.
    private static var launchTab: AppTab {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count {
            switch args[i + 1] {
            case "activity": return .activity
            case "budgets": return .budgets
            case "bills": return .bills
            case "insights": return .insights
            default: break
            }
        }
        #endif
        return .home
    }

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
            .badge(bills.filter { !$0.isPaid && $0.daysUntilDue() <= 3 }.count)
            Tab("Insights", systemImage: "sparkles", value: .insights) {
                InsightsView()
            }
        }
        .sensoryFeedback(.selection, trigger: tab)
        .overlay(alignment: .top) {
            if let error = state.lastError {
                ErrorBanner(message: error) { withAnimation { state.lastError = nil } }
                    .task {
                        try? await Task.sleep(for: .seconds(5))
                        withAnimation { state.lastError = nil }
                    }
            }
        }
        .animation(.snappy, value: state.lastError)
    }
}
