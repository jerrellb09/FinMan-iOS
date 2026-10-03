import Foundation
import SwiftData

// All properties have defaults and relationships are optional so the schema stays
// compatible with CloudKit sync if it's switched on later.

@Model
final class Account {
    var name: String = ""
    /// "checking", "savings", "credit" or "cash".
    var kind: String = "checking"
    var startingBalance: Double = 0
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \Transaction.account)
    var transactions: [Transaction]? = []

    init(name: String, kind: String = "checking", startingBalance: Double = 0) {
        self.name = name
        self.kind = kind
        self.startingBalance = startingBalance
    }

    var balance: Double { startingBalance + (transactions ?? []).reduce(0) { $0 + $1.amount } }

    var symbol: String {
        switch kind {
        case "savings": "banknote.fill"
        case "credit": "creditcard.fill"
        case "cash": "dollarsign.circle.fill"
        default: "building.columns.fill"
        }
    }
}

@Model
final class Category {
    var name: String = ""
    var isIncome: Bool = false
    var sortOrder: Int = 0

    @Relationship(deleteRule: .nullify, inverse: \Transaction.category)
    var transactions: [Transaction]? = []
    @Relationship(deleteRule: .nullify, inverse: \Budget.category)
    var budgets: [Budget]? = []
    @Relationship(deleteRule: .nullify, inverse: \Bill.category)
    var bills: [Bill]? = []

    init(name: String, isIncome: Bool = false, sortOrder: Int = 0) {
        self.name = name
        self.isIncome = isIncome
        self.sortOrder = sortOrder
    }

    /// Same defaults the Spring Boot backend seeds, plus Income.
    static let defaults: [(String, Bool)] = [
        ("Housing", false), ("Transportation", false), ("Food", false), ("Entertainment", false),
        ("Healthcare", false), ("Personal", false), ("Education", false), ("Savings", false),
        ("Debt", false), ("Travel", false), ("Shopping", false), ("Utilities", false),
        ("Subscriptions", false), ("Income", true),
    ]
}

@Model
final class Transaction {
    var title: String = ""
    /// Positive = income, negative = expense.
    var amount: Double = 0
    var date: Date = Date.now
    var note: String = ""
    var category: Category?
    var account: Account?
    var createdAt: Date = Date.now

    init(title: String, amount: Double, date: Date = .now, category: Category? = nil, account: Account? = nil) {
        self.title = title
        self.amount = amount
        self.date = date
        self.category = category
        self.account = account
    }

    var isIncome: Bool { amount > 0 }
}

@Model
final class Budget {
    var name: String = ""
    var amount: Double = 0
    /// "WEEKLY", "MONTHLY" or "YEARLY".
    var period: String = "MONTHLY"
    var startDate: Date = Date.now
    var endDate: Date?
    /// Percentage (0–100) at which the budget is flagged as "getting close".
    var warningThreshold: Double = 80
    var category: Category?
    var createdAt: Date = Date.now

    init(name: String, amount: Double, category: Category?, period: String = "MONTHLY",
         startDate: Date = .now, endDate: Date? = nil, warningThreshold: Double = 80) {
        self.name = name
        self.amount = amount
        self.category = category
        self.period = period
        self.startDate = startDate
        self.endDate = endDate
        self.warningThreshold = warningThreshold
    }

    /// The window the budget currently measures (this week / month / year), clipped to its dates.
    func currentInterval(now: Date = .now, calendar: Calendar = .current) -> DateInterval {
        let component: Calendar.Component = switch period {
        case "WEEKLY": .weekOfYear
        case "YEARLY": .year
        default: .month
        }
        var interval = calendar.dateInterval(of: component, for: now) ?? DateInterval(start: now, duration: 0)
        if startDate > interval.start, startDate < interval.end { interval = DateInterval(start: startDate, end: interval.end) }
        if let endDate, endDate < interval.end, endDate > interval.start { interval = DateInterval(start: interval.start, end: endDate) }
        return interval
    }

    /// Net spending in the budget's category during the current window (refunds offset it).
    func spent(now: Date = .now) -> Double {
        guard let category else { return 0 }
        let interval = currentInterval(now: now)
        let net = (category.transactions ?? [])
            .filter { interval.contains($0.date) }
            .reduce(0) { $0 + $1.amount }
        return net < 0 ? -net : 0
    }

    func progress(now: Date = .now) -> Double { amount > 0 ? spent(now: now) / amount : 0 }
}

@Model
final class Bill {
    var name: String = ""
    var amount: Double = 0
    var dueDay: Int = 1
    var isRecurring: Bool = true
    var autoPay: Bool = false
    /// When the bill was last marked paid. Recurring bills count as paid only within that month,
    /// so they reset automatically when a new month starts.
    var lastPaidDate: Date?
    var category: Category?
    var createdAt: Date = Date.now

    init(name: String, amount: Double, dueDay: Int, isRecurring: Bool = true, category: Category? = nil) {
        self.name = name
        self.amount = amount
        self.dueDay = dueDay
        self.isRecurring = isRecurring
        self.category = category
    }

    var isPaid: Bool {
        guard let lastPaidDate else { return false }
        return isRecurring ? Calendar.current.isDate(lastPaidDate, equalTo: .now, toGranularity: .month) : true
    }

    func setPaid(_ paid: Bool) { lastPaidDate = paid ? .now : nil }

    /// Next calendar date this bill falls due (clamped to the month length).
    func nextDueDate(from now: Date = .now, calendar: Calendar = .current) -> Date {
        func date(in month: Date) -> Date {
            let range = calendar.range(of: .day, in: .month, for: month) ?? 1..<29
            var comps = calendar.dateComponents([.year, .month], from: month)
            comps.day = min(dueDay, range.upperBound - 1)
            return calendar.date(from: comps) ?? month
        }
        let today = calendar.startOfDay(for: now)
        let thisMonth = date(in: today)
        if thisMonth >= today || !isPaid { return thisMonth }
        return date(in: calendar.date(byAdding: .month, value: 1, to: today) ?? today)
    }

    func daysUntilDue(from now: Date = .now) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: nextDueDate(from: now)).day ?? 0
    }
}

/// Everything the app persists, in one place for the model container.
enum AppSchema {
    static let models: [any PersistentModel.Type] = [Account.self, Category.self, Transaction.self, Budget.self, Bill.self]
}
