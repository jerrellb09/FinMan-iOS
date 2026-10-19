import Foundation

/// Transactions read from an app's or bank's export (Rocket Money and similar), ready to review.
nonisolated struct TransactionExport: Sendable {
    struct Row: Identifiable, Sendable {
        var id = UUID()
        var date: Date
        var title: String
        /// Positive = income, negative = expense, like `Transaction.amount`.
        var amount: Double
        var category: String?
        /// The category as the export names it ("Dining & Drinks").
        var sourceCategory: String
        var note: String
        /// Which account in the export the row came from; see `TransactionExport.accounts`.
        var accountKey: String
        /// The export marks it as left out of its totals (transfers, card payments).
        var ignored: Bool
        /// Stable across exports, so importing an overlapping file again recognizes rows already imported.
        var fingerprint: String
    }

    struct SourceAccount: Identifiable, Sendable {
        var id: String { key }
        var key: String
        var name: String
        var institution: String
        var lastFour: String
        /// "checking", "savings", "credit" or "cash", as `Account.kind` uses.
        var kind: String

        var title: String {
            let base = name.isEmpty ? (institution.isEmpty ? "Account" : institution) : name
            return lastFour.isEmpty ? base : "\(base) ••\(lastFour)"
        }
    }

    var source: String
    var rows: [Row] = []
    var accounts: [SourceAccount] = []
    var skipped = 0
}

/// Reads transaction exports by their column headings. Returns nil for files that aren't one,
/// so they can go to the budget spreadsheet importer instead.
nonisolated enum TransactionImporter {
    static let fingerprintPrefix = "import:"

    struct Columns {
        var date: Int
        var amount: Int
        var name: Int
        var customName: Int?
        var category: Int?
        var note: Int?
        var account: Int?
        var accountType: Int?
        var accountNumber: Int?
        var institution: Int?
        var ignored: Int?
        var isRocketMoney: Bool
    }

    static func read(_ spreadsheet: Spreadsheet, categories: [String]) -> TransactionExport? {
        guard let sheet = spreadsheet.sheets.first else { return nil }
        for headerIndex in 0..<min(5, sheet.rows.count) {
            guard let columns = columns(sheet.rows[headerIndex]) else { continue }
            return parse(Array(sheet.rows.dropFirst(headerIndex + 1)), columns: columns, categories: categories)
        }
        return nil
    }

    /// Recognizes the header row of a transaction export: a date, an amount, a name, and either an account
    /// column or Rocket Money's own columns.
    static func columns(_ header: [String]) -> Columns? {
        let names = header.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        func find(_ candidates: String...) -> Int? {
            for candidate in candidates { if let index = names.firstIndex(of: candidate) { return index } }
            return nil
        }
        guard let date = find("date", "transaction date", "posted date", "posting date"),
              let amount = find("amount", "transaction amount"),
              let name = find("name", "merchant", "payee", "description", "original description")
        else { return nil }
        let account = find("account name", "account")
        let isRocketMoney = find("custom name") != nil || find("ignored from") != nil
        guard account != nil || isRocketMoney else { return nil }
        return Columns(date: date, amount: amount, name: name, customName: find("custom name"),
                       category: find("category"), note: find("note", "notes", "memo"), account: account,
                       accountType: find("account type"), accountNumber: find("account number", "account mask", "mask"),
                       institution: find("institution name", "institution", "bank"),
                       ignored: find("ignored from"), isRocketMoney: isRocketMoney)
    }

    private struct Raw {
        var date: Date
        var name: String
        var title: String
        var amount: Double
        var category: String
        var note: String
        var account: TransactionExport.SourceAccount
        var ignored: Bool
    }

    static func parse(_ rows: [[String]], columns: Columns, categories: [String]) -> TransactionExport {
        func cell(_ row: [String], _ column: Int?) -> String {
            guard let column, column < row.count else { return "" }
            return row[column].trimmingCharacters(in: .whitespaces)
        }
        var export = TransactionExport(source: columns.isRocketMoney ? "Rocket Money" : "Transaction export")
        var raws: [Raw] = []
        var accounts: [String: TransactionExport.SourceAccount] = [:]

        for row in rows {
            guard let date = BudgetImporter.date(cell(row, columns.date)),
                  let amount = BudgetImporter.number(cell(row, columns.amount)) else {
                if row.contains(where: { !$0.isEmpty }) { export.skipped += 1 }
                continue
            }
            let name = cell(row, columns.name)
            let custom = cell(row, columns.customName)
            let title = custom.isEmpty ? name : custom
            guard !title.isEmpty, abs(amount) >= 0.005 else { export.skipped += 1; continue }

            let lastFour = String(cell(row, columns.accountNumber).filter(\.isNumber).suffix(4))
            let account = TransactionExport.SourceAccount(
                key: [cell(row, columns.institution), cell(row, columns.account), lastFour].joined(separator: "|").lowercased(),
                name: cell(row, columns.account), institution: cell(row, columns.institution), lastFour: lastFour,
                kind: kind(cell(row, columns.accountType), name: cell(row, columns.account)))
            if accounts[account.key] == nil { accounts[account.key] = account }
            let ignoredText = cell(row, columns.ignored).lowercased()
            raws.append(Raw(date: date, name: name.isEmpty ? title : name, title: title, amount: amount,
                            category: cell(row, columns.category), note: cell(row, columns.note), account: account,
                            ignored: !ignoredText.isEmpty && !["false", "no", "0"].contains(ignoredText)))
        }

        // Rocket Money (like Plaid) lists spending as positive amounts; most bank exports list it as negative.
        // Income rows settle which this file does; failing those, spending is whichever sign most rows have.
        let incomeRows = raws.filter { $0.category.lowercased().contains("income") || $0.category.lowercased().contains("paycheck") }
        let spendingIsPositive = incomeRows.isEmpty
            ? raws.filter { $0.amount > 0 }.count > raws.count / 2
            : incomeRows.filter { $0.amount < 0 }.count > incomeRows.count / 2

        var occurrences: [String: Int] = [:]
        export.rows = raws.map { raw in
            let amount = spendingIsPositive ? -raw.amount : raw.amount
            let base = "\(dayString(raw.date))|\(Int((amount * 100).rounded()))|\(raw.name.lowercased())|\(raw.account.key)"
            let occurrence = occurrences[base, default: 0]
            occurrences[base] = occurrence + 1
            return TransactionExport.Row(date: raw.date, title: raw.title, amount: amount,
                                         category: category(raw.category, title: raw.title, amount: amount, existing: categories),
                                         sourceCategory: raw.category, note: raw.note, accountKey: raw.account.key,
                                         ignored: raw.ignored, fingerprint: "\(fingerprintPrefix)\(base)|\(occurrence)")
        }
        export.accounts = accounts.values.sorted { $0.title < $1.title }
        return export
    }

    private static func dayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func kind(_ type: String, name: String) -> String {
        let text = (type + " " + name).lowercased()
        if text.contains("credit") || text.contains("card") { return "credit" }
        if text.contains("saving") { return "savings" }
        if text.contains("cash") { return "cash" }
        return "checking"
    }

    // MARK: Categories

    /// Rocket Money's categories, mapped onto FinMan's defaults.
    private static let knownCategories: [String: String] = [
        "groceries": "Food", "dining & drinks": "Food", "restaurants": "Food", "food & drink": "Food", "coffee shops": "Food",
        "auto & transport": "Transportation", "gas": "Transportation", "auto": "Transportation", "transportation": "Transportation",
        "bills & utilities": "Utilities", "utilities": "Utilities", "phone": "Utilities", "internet": "Utilities",
        "shopping": "Shopping", "clothing": "Shopping", "electronics": "Shopping",
        "entertainment & rec.": "Entertainment", "entertainment & recreation": "Entertainment", "entertainment": "Entertainment",
        "health & wellness": "Healthcare", "medical": "Healthcare", "fitness": "Healthcare", "healthcare": "Healthcare",
        "travel & vacation": "Travel", "travel": "Travel",
        "personal care": "Personal", "pets": "Personal", "gifts": "Personal", "charitable donations": "Personal", "kids": "Personal",
        "childcare": "Personal", "gifts & donations": "Personal",
        "home & garden": "Housing", "home": "Housing", "rent": "Housing", "mortgage": "Housing",
        "software & tech": "Subscriptions", "subscriptions": "Subscriptions",
        "education": "Education",
        "loan payment": "Debt", "credit card payment": "Debt", "loans": "Debt",
        "savings": "Savings", "investments": "Savings", "investment": "Savings",
        "income": "Income", "paychecks": "Income", "paycheck": "Income", "interest income": "Income",
    ]

    /// A category name that already exists wins (a custom "Groceries" stays "Groceries"); otherwise the export's
    /// category is mapped to a default, and failing that the transaction's name is matched by keyword.
    static func category(_ source: String, title: String, amount: Double, existing: [String]) -> String? {
        let known = Array(Set(existing + Category.defaultNames))
        if !source.isEmpty, let match = CategoryMatcher.existing(source, in: existing) { return match }
        if let mapped = knownCategories[source.lowercased()] {
            // Refunds filed under Income-like names stay with spending; real income stays income.
            if mapped == "Income", amount < 0 { return nil }
            return CategoryMatcher.existing(mapped, in: known)
        }
        let guess = CategoryMatcher.match(source) ?? CategoryMatcher.match(title)
        if guess == "Income", amount < 0 { return nil }
        return guess.flatMap { CategoryMatcher.existing($0, in: known) }
    }
}
