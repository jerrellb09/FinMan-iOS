import Foundation
import SwiftData
import WidgetKit

/// Writes the snapshot the Home Screen widgets read, and asks WidgetKit to redraw them.
enum WidgetSync {
    static func update(_ context: ModelContext) {
        let accounts = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let bills = (try? context.fetch(FetchDescriptor<Bill>())) ?? []
        let monthStart = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
        let thisMonth = (try? context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.date >= monthStart }))) ?? []

        let snapshot = WidgetSnapshot(
            accounts: accounts.map { .init(name: $0.name, kind: $0.kind, balance: $0.balance) },
            monthSpent: Analytics.spending(thisMonth),
            monthIncome: Analytics.income(thisMonth),
            monthlyIncome: UserDefaults.standard.double(forKey: ProfileKey.monthlyIncome),
            bills: bills.map {
                .init(id: "\(Int($0.createdAt.timeIntervalSince1970))-\($0.name)", name: $0.name, amount: $0.amount,
                      dueDay: $0.dueDay, isRecurring: $0.isRecurring, autoPay: $0.autoPay,
                      lastPaidDate: $0.lastPaidDate, category: $0.category?.name)
            })
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Clears the widgets (used by "Erase all data").
    static func erase() {
        WidgetSnapshot.erase()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
