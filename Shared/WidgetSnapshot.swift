import Foundation
import Security

// Compiled into both the app and the widget extension. The widget can't open the app's SwiftData
// store, so the app saves this small snapshot where the widget can read it instead.

/// What the widgets show, as of the last time the app saved it.
nonisolated struct WidgetSnapshot: Codable, Sendable {
    struct Account: Codable, Sendable {
        var name: String
        var kind: String
        var balance: Double
    }

    struct Bill: Codable, Sendable, Identifiable {
        var id: String
        var name: String
        var amount: Double
        var dueDay: Int
        var isRecurring: Bool
        var autoPay: Bool
        var lastPaidDate: Date?
        var category: String?

        var schedule: BillSchedule {
            BillSchedule(dueDay: dueDay, isRecurring: isRecurring, lastPaidDate: lastPaidDate)
        }
    }

    var updatedAt: Date = .now
    var accounts: [Account] = []
    /// Spending and income in the month the snapshot was taken (`updatedAt`).
    var monthSpent: Double = 0
    var monthIncome: Double = 0
    /// The income the user entered in their profile.
    var monthlyIncome: Double = 0
    var bills: [Bill] = []

    var totalBalance: Double { accounts.reduce(0) { $0 + $1.balance } }

    /// Unpaid bills ordered by their next due date as seen from `date`, overdue first.
    func upcomingBills(at date: Date = .now) -> [(bill: Bill, due: Date)] {
        bills.compactMap { bill in bill.schedule.nextUnpaidDue(from: date).map { (bill, $0) } }
            .sorted { $0.due < $1.due }
    }

    // MARK: Storage

    // Kept in a Keychain item shared by the app and the widget. (An App Group container would be the
    // usual choice, but a free Apple ID can't register App Group IDs; Keychain sharing works on any team.)
    // Both targets list the shared access group first in keychain-access-groups, which makes it the
    // default group for new items, so no team prefix is needed here.
    private static let service = "finman.widget-snapshot"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "snapshot"]
    }

    static func load() -> WidgetSnapshot? {
        var request = query
        request[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let update = [kSecValueData as String: data]
        if SecItemUpdate(Self.query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var item = Self.query
            item[kSecValueData as String] = data
            // Readable by the widget whenever the phone has been unlocked once since restarting.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func erase() {
        SecItemDelete(query as CFDictionary)
    }
}

/// When a bill next needs paying. Recurring bills count as paid only for the month they were paid in.
nonisolated struct BillSchedule: Sendable {
    var dueDay: Int
    var isRecurring: Bool
    var lastPaidDate: Date?

    /// The bill's due date in the month containing `month` (clamped to the month's length).
    func dueDate(inMonthOf month: Date, calendar: Calendar = .current) -> Date {
        let range = calendar.range(of: .day, in: .month, for: month) ?? 1..<29
        var comps = calendar.dateComponents([.year, .month], from: month)
        comps.day = min(max(dueDay, 1), range.upperBound - 1)
        return calendar.date(from: comps) ?? month
    }

    /// The next due date that still needs paying: this month's (even if it has passed, i.e. overdue),
    /// or next month's when this month's is paid. Nil for a one-off bill that's been paid.
    func nextUnpaidDue(from now: Date = .now, calendar: Calendar = .current) -> Date? {
        let thisMonth = dueDate(inMonthOf: now, calendar: calendar)
        guard let lastPaidDate else { return thisMonth }
        guard isRecurring else { return nil }
        if calendar.isDate(lastPaidDate, equalTo: now, toGranularity: .month),
           let next = calendar.date(byAdding: .month, value: 1, to: calendar.startOfDay(for: now)) {
            return dueDate(inMonthOf: next, calendar: calendar)
        }
        return thisMonth
    }

    /// Whole days from `now` until `due`; negative when overdue.
    static func daysUntil(_ due: Date, from now: Date = .now, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
    }

    /// "Due today", "Due tomorrow", "Due in 5 days", "2 days overdue".
    static func dueText(_ due: Date, from now: Date = .now) -> String {
        switch daysUntil(due, from: now) {
        case 0: "Due today"
        case 1: "Due tomorrow"
        case let days where days > 1: "Due in \(days) days"
        case -1: "1 day overdue"
        case let days: "\(-days) days overdue"
        }
    }
}
