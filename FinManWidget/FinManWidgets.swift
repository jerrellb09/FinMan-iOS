import SwiftUI
import WidgetKit

@main
struct FinManWidgets: WidgetBundle {
    var body: some Widget {
        BalanceWidget()
        BillsWidget()
        OverviewWidget()
    }
}

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// Nil until the app has been opened once with widgets installed.
    let snapshot: WidgetSnapshot?
}

/// Reads the app's snapshot and adds an entry at each of the next few midnights,
/// so "due in N days" counts down even when the app isn't opened.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview ? WidgetSnapshot.load() ?? .preview : WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let midnights = (1...7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let entries = [SnapshotEntry(date: .now, snapshot: snapshot)] + midnights.map { SnapshotEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// MARK: - Shared styling

enum WidgetStyle {
    static let brand = Color(red: 0.40, green: 0.31, blue: 0.97)
    static let income = Color(red: 0.13, green: 0.73, blue: 0.47)
    static let expense = Color(red: 0.95, green: 0.33, blue: 0.38)
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.10)

    /// Red when overdue, orange within 3 days, otherwise `normal`.
    static func color(forDays days: Int, normal: Color = .secondary) -> Color {
        days < 0 ? expense : days <= 3 ? warning : normal
    }
}

extension Double {
    func widgetCurrency(compact: Bool = false) -> String {
        let code = Locale.current.currency?.identifier ?? "USD"
        if compact && abs(self) >= 10_000 {
            return formatted(.currency(code: code).notation(.compactName).precision(.significantDigits(3)))
        }
        return formatted(.currency(code: code).precision(.fractionLength(abs(self) >= 1_000 ? 0 : 2)))
    }
}

/// Shown before the app has written its first snapshot.
struct OpenAppPrompt: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "dollarsign.circle.fill").font(.title).foregroundStyle(WidgetStyle.brand)
            Text("Open FinMan to set up this widget").font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
}

extension WidgetSnapshot {
    /// Sample data for the widget gallery.
    static var preview: WidgetSnapshot {
        let today = Calendar.current.component(.day, from: .now)
        func day(_ offset: Int) -> Int { (today + offset - 1) % 28 + 1 }
        return WidgetSnapshot(
            accounts: [.init(name: "Checking", kind: "checking", balance: 2_480.12), .init(name: "Savings", kind: "savings", balance: 8_500)],
            monthSpent: 1_842.55, monthIncome: 5_000, monthlyIncome: 5_000,
            bills: [
                .init(id: "1", name: "Rent", amount: 1_500, dueDay: day(2), isRecurring: true, autoPay: false, category: "Housing"),
                .init(id: "2", name: "Electric", amount: 125, dueDay: day(5), isRecurring: true, autoPay: true, category: "Utilities"),
                .init(id: "3", name: "Netflix", amount: 15.49, dueDay: day(9), isRecurring: true, autoPay: true, category: "Subscriptions"),
                .init(id: "4", name: "Car insurance", amount: 140, dueDay: day(14), isRecurring: true, autoPay: false, category: "Transportation"),
            ])
    }
}
