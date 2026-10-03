import Foundation

// MARK: - Auth

struct User: Decodable, Hashable {
    var id: Int
    var email: String
    var firstName: String
    var lastName: String
    var monthlyIncome: Decimal?
    var paydayDay: Int?
    var isDemo: Bool

    var displayName: String { firstName.isEmpty ? email : firstName }
    var initials: String {
        let letters = [firstName.first, lastName.first].compactMap { $0 }
        return letters.isEmpty ? String(email.prefix(1)).uppercased() : String(letters).uppercased()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.int("id") ?? 0
        email = c.string("email") ?? ""
        firstName = c.string("firstName") ?? ""
        lastName = c.string("lastName") ?? ""
        monthlyIncome = c.decimal("monthlyIncome")
        paydayDay = c.int("paydayDay")
        isDemo = c.bool("isDemo", "demo") ?? false
    }
}

struct AuthResponse: Decodable {
    let token: String
    let user: User
}

struct LoginRequest: Encodable { let email: String; let password: String }
struct RegisterRequest: Encodable { let email: String; let password: String; let firstName: String; let lastName: String }

// MARK: - Category

struct Category: Decodable, Hashable, Identifiable {
    var id: Int
    var name: String
    var description: String?
    var iconUrl: String?

    init(id: Int, name: String) { self.id = id; self.name = name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.int("id") ?? 0
        name = c.string("name") ?? "Uncategorized"
        description = c.string("description")
        iconUrl = c.string("iconUrl")
    }
}

// MARK: - Account

struct Account: Decodable, Hashable, Identifiable {
    var id: Int
    var name: String
    var type: String?
    var balance: Decimal
    var institutionName: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.int("id") ?? 0
        name = c.string("name") ?? "Account"
        type = c.string("type")
        balance = c.decimal("balance") ?? 0
        institutionName = c.string("institutionName")
    }
}

// MARK: - Transaction

struct Transaction: Decodable, Hashable, Identifiable {
    var id: Int
    var description: String
    /// Positive = income, negative = expense (matches the backend convention).
    var amount: Decimal
    var date: Date
    var category: Category?
    var isManualEntry: Bool
    var accountId: Int?

    var isIncome: Bool { amount > 0 }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.int("id") ?? 0
        description = c.string("description") ?? "Transaction"
        amount = c.decimal("amount") ?? 0
        date = c.date("date") ?? .now
        category = c.nested(Category.self, "category")
        isManualEntry = c.bool("manualEntry", "isManualEntry") ?? false
        accountId = c.nested(IDOnly.self, "account")?.id
    }
}

struct IDOnly: Decodable { let id: Int? }

struct TransactionRequest: Encodable {
    var accountId: Int?
    var description: String
    var amount: Decimal
    var date: String
    var categoryId: Int?
}

// MARK: - Budget

struct Budget: Decodable, Hashable, Identifiable {
    var id: Int
    var name: String
    var amount: Decimal
    var category: Category?
    var period: String
    var startDate: Date?
    var endDate: Date?
    var warningThreshold: Decimal

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.int("id") ?? 0
        name = c.string("name") ?? "Budget"
        amount = c.decimal("amount") ?? 0
        category = c.nested(Category.self, "category")
        period = c.string("period") ?? "MONTHLY"
        startDate = c.date("startDate")
        endDate = c.date("endDate")
        warningThreshold = c.decimal("warningThreshold") ?? 80
    }
}

struct BudgetSpending: Decodable, Hashable {
    var currentSpending: Decimal
    var percentageUsed: Decimal
    var remaining: Decimal

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        currentSpending = c.decimal("currentSpending") ?? 0
        percentageUsed = c.decimal("percentageUsed") ?? 0
        remaining = c.decimal("remaining") ?? 0
    }
}

struct BudgetRequest: Encodable {
    var name: String
    var amount: Decimal
    var categoryId: Int
    var period: String
    var startDate: String
    var endDate: String?
    var warningThreshold: Decimal
}

// MARK: - Bill

struct Bill: Decodable, Hashable, Identifiable {
    var id: Int
    var name: String
    var amount: Decimal
    var dueDay: Int
    var isPaid: Bool
    var isRecurring: Bool
    var categoryId: Int?
    var categoryName: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.int("id") ?? 0
        name = c.string("name") ?? "Bill"
        amount = c.decimal("amount") ?? 0
        dueDay = c.int("dueDay") ?? 1
        isPaid = c.bool("paid", "isPaid") ?? false
        isRecurring = c.bool("recurring", "isRecurring") ?? true
        let category = c.nested(Category.self, "category")
        categoryId = c.int("categoryId") ?? category?.id
        categoryName = c.string("categoryName") ?? category?.name
    }

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

/// Body shape the backend's `Bill` entity deserialises from (Lombok `isPaid` -> `paid`).
/// `id` is required on updates because `Bill` uses `@JsonIdentityInfo`.
struct BillRequest: Encodable {
    struct CategoryRef: Encodable { let id: Int }
    var id: Int?
    var name: String
    var amount: Decimal
    var dueDay: Int
    var paid: Bool
    var recurring: Bool
    var recurringPeriod = "MONTHLY"
    var category: CategoryRef?
}

// MARK: - Insights

struct BillsVsIncome: Decodable {
    var monthlyIncome: Decimal
    var totalBills: Decimal
    var remainingIncome: Decimal
    var billPercentage: Decimal

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        monthlyIncome = c.decimal("monthlyIncome") ?? 0
        totalBills = c.decimal("totalBills") ?? 0
        remainingIncome = c.decimal("remainingIncome") ?? 0
        billPercentage = c.decimal("billPercentage") ?? 0
    }
}

struct AIText: Decodable {
    var text: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        text = c.string("insights", "suggestions", "analysis", "message", "error")
    }
}

struct IncomeRequest: Encodable { var monthlyIncome: Decimal; var paydayDay: Int }
