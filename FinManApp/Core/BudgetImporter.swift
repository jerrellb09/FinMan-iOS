import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What a budget spreadsheet turned into: budgets, bills, income and past transactions, ready to review.
nonisolated struct BudgetImportDraft: Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case budget, bill, income
        var id: Self { self }
        var title: String {
            switch self {
            case .budget: "Budget"
            case .bill: "Bill"
            case .income: "Income"
            }
        }
    }

    struct Item: Identifiable, Sendable {
        var id = UUID()
        var include = true
        var kind: Kind
        var name: String
        /// Amount per `period`.
        var amount: Double
        /// "WEEKLY", "MONTHLY" or "YEARLY", as budgets use.
        var period = "MONTHLY"
        var category = ""
        var dueDay: Int?
        /// What the sheet says was actually spent (or received) so far.
        var actual: Double?

        var monthlyAmount: Double {
            switch period {
            case "WEEKLY": amount * 52 / 12
            case "YEARLY": amount / 12
            default: amount
            }
        }
    }

    struct Entry: Identifiable, Sendable {
        var id = UUID()
        var date: Date
        var title: String
        /// Positive = income, negative = expense, like `Transaction.amount`.
        var amount: Double
        var category: String?
    }

    var items: [Item] = []
    var transactions: [Entry] = []
    /// Rows that looked like data but were left out, and why.
    var skipped: [String] = []
    var sheetCount = 0
    var usedModel = false
}

/// Reads budget spreadsheets people made themselves. Rules work out the layout and categories first;
/// Apple Intelligence is asked only for sheets the rules can't make sense of and names no keyword fits.
nonisolated enum BudgetImporter {

    // MARK: Entry point

    /// Reads a CSV or Excel file and interprets it, off the main thread.
    @concurrent
    static func read(data: Data, fileExtension: String, categories: [String]) async throws -> BudgetImportDraft {
        let spreadsheet = try Spreadsheet.read(data: data, fileExtension: fileExtension)
        return await interpret(spreadsheet, categories: categories)
    }

    @concurrent
    static func interpret(_ spreadsheet: Spreadsheet, categories: [String], now: Date = .now) async -> BudgetImportDraft {
        var draft = BudgetImportDraft(sheetCount: spreadsheet.sheets.count)
        var hints: [UUID: String] = [:]

        for sheet in spreadsheet.sheets {
            var parsed = layout(sheet.rows, sheetName: sheet.name).map { parse($0.rows, layout: $0.layout, now: now) }
            if (parsed?.count ?? 0) < 2, let modelLayout = await layoutWithModel(sheet) {
                let retry = parse(sheet.rows, layout: modelLayout, now: now)
                if retry.count > (parsed?.count ?? 0) {
                    parsed = retry
                    draft.usedModel = true
                }
            }
            guard let parsed else {
                draft.skipped.append("Sheet “\(sheet.name)”: no budget items or transactions found")
                continue
            }
            draft.items += parsed.items
            draft.transactions += parsed.entries
            draft.skipped += parsed.skipped
            hints.merge(parsed.hints) { first, _ in first }
        }

        if await assignCategories(&draft, hints: hints, existing: categories) { draft.usedModel = true }
        return draft
    }

    // MARK: Cells

    static func number(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.contains(where: \.isNumber), !t.hasSuffix("%") else { return nil }
        var negative = false
        if t.hasPrefix("("), t.hasSuffix(")") { negative = true; t = String(t.dropFirst().dropLast()) }
        if t.hasSuffix("-") { negative = true; t.removeLast() }
        t = t.replacingOccurrences(of: #"[$€£¥,\s]|USD"#, with: "", options: [.regularExpression, .caseInsensitive])
        if t.hasPrefix("-") { negative.toggle(); t.removeFirst() }
        guard t.allSatisfy({ $0.isNumber || $0 == "." }), let value = Double(t) else { return nil }
        return negative ? -value : value
    }

    static func date(_ text: String) -> Date? {
        guard text.count <= 30, text.contains(where: \.isNumber) else { return nil }
        return PayslipParser.dates(in: text).first
    }

    private static let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

    /// "Jan", "January", "Sept 2026", "Mar-26" → month number.
    static func month(_ header: String) -> Int? {
        let first = header.lowercased().split { !$0.isLetter }.first.map(String.init) ?? ""
        guard first.count >= 3, header.count <= 14 else { return nil }
        return monthNames.firstIndex { $0.hasPrefix(first) }.map { $0 + 1 }
    }

    private static func cell(_ row: [String], _ column: Int?) -> String {
        guard let column, column >= 0, column < row.count else { return "" }
        return row[column]
    }

    static func isTotal(_ name: String) -> Bool {
        let l = name.lowercased()
        return ["total", "subtotal", "sum", "remaining", "left over", "leftover", "balance", "difference", "surplus", "deficit", "cash flow",
                "net income", "available to", "unallocated", "grand"].contains(where: l.contains)
    }

    // MARK: Layout

    struct Layout {
        enum Kind { case plan, ledger }
        var kind = Kind.plan
        var header: Int?
        var name: Int?
        var amount: Int?
        var actual: Int?
        var category: Int?
        var date: Int?
        var due: Int?
        var type: Int?
        var frequency: Int?
        var debit: Int?
        var credit: Int?
        /// Column → month number, for sheets with a column per month.
        var months: [Int: Int] = [:]
        var period = "MONTHLY"
        /// Converts amounts to `period` (e.g. biweekly figures × 26 ÷ 12 to monthly).
        var multiplier = 1.0
    }

    enum Role: Equatable {
        case name, amount(rank: Int), actual, date, due, category, type, frequency, debit, credit, month(Int)
    }

    static func role(_ header: String) -> Role? {
        let l = header.lowercased()
        guard !l.isEmpty, number(header) == nil else { return nil }
        if let m = month(header) { return .month(m) }
        let words = Set(l.split { !$0.isLetter }.map(String.init))
        func has(_ parts: String...) -> Bool { parts.contains(where: l.contains) }
        func word(_ candidates: String...) -> Bool { candidates.contains(where: words.contains) }

        if has("due") { return .due }
        if has("actual", "spent", "so far", "to date") || word("real") { return .actual }
        if has("debit", "withdrawal", "outflow", "money out", "paid out") { return .debit }
        if (has("credit", "deposit", "inflow", "money in")) && !has("credit card") { return .credit }
        if has("frequency", "how often", "cadence", "interval") || words == ["period"] { return .frequency }
        if has("date") || word("day", "posted", "when") { return .date }
        if words == ["type"] || has("income/expense", "in/out", "income or expense") { return .type }
        if has("item", "description", "name", "payee", "merchant", "details") { return .name }
        if has("category", "group", "section", "bucket") || word("class") { return .category }
        if has("budget", "planned", "plan", "projected", "estimate", "limit", "goal", "target", "allocated", "allotted") { return .amount(rank: 3) }
        if has("amount", "monthly", "cost", "price", "value", "payment", "$", "weekly", "yearly", "annual", "per month", "per week", "per year") {
            return .amount(rank: 2)
        }
        if has("total") { return .amount(rank: 1) }
        if word("expense", "expenses", "bill", "bills", "source", "what", "line", "for") { return .name }
        return nil
    }

    /// Excel stores dates as day counts (46296 = Oct 1, 2026). Only trusted in columns whose heading says they hold dates.
    static func excelDate(_ text: String) -> String? {
        guard let serial = Double(text), (25_569...73_051).contains(serial) else { return nil }
        let date = Date(timeIntervalSince1970: (serial.rounded(.down) - 25_569) * 86_400)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Finds the header row and what each column holds, or nil if the sheet has no recognizable items.
    /// Returns the rows too, with Excel day counts in date columns turned into dates.
    static func layout(_ original: [[String]], sheetName: String) -> (layout: Layout, rows: [[String]])? {
        for headerIndex in 0..<min(15, original.count) {
            let roles = original[headerIndex].enumerated().compactMap { index, text in role(text).map { (index, $0) } }
            let dateColumns = Set(roles.filter { $0.1 == .date || $0.1 == .due }.map(\.0))
            let rows = dateColumns.isEmpty ? original : original.enumerated().map { rowIndex, row in
                rowIndex <= headerIndex ? row : row.enumerated().map { dateColumns.contains($0.offset) ? excelDate($0.element) ?? $0.element : $0.element }
            }
            let monthCount = roles.filter { if case .month = $0.1 { true } else { false } }.count
            let isAmountHeader = roles.count == 1 && { if case .amount = roles[0].1 { true } else { false } }()
            guard roles.count >= 2 || monthCount >= 3 || (isAmountHeader && rows[headerIndex].filter { !$0.isEmpty }.count >= 2) else { continue }
            let data = Array(rows.dropFirst(headerIndex + 1).prefix(300))
            guard data.contains(where: { $0.contains { number($0) != nil } }) else { continue }

            var layout = Layout(header: headerIndex)
            var amountRank = 0
            for (index, role) in roles {
                switch role {
                case .name: layout.name = layout.name ?? index
                case .amount(let rank) where rank > amountRank: layout.amount = index; amountRank = rank
                case .amount: break
                case .actual: layout.actual = layout.actual ?? index
                case .date: layout.date = layout.date ?? index
                case .due: layout.due = layout.due ?? index
                case .category: layout.category = layout.category ?? index
                case .type: layout.type = layout.type ?? index
                case .frequency: layout.frequency = layout.frequency ?? index
                case .debit: layout.debit = layout.debit ?? index
                case .credit: layout.credit = layout.credit ?? index
                case .month(let m): layout.months[index] = m
                }
            }
            if layout.months.count < 3 { layout.months = [:] } else if amountRank < 3 { layout.amount = nil }
            let context = ([sheetName] + rows.prefix(headerIndex + 1).flatMap { $0 } + [cell(rows[headerIndex], layout.amount)]).joined(separator: " ")
            if let finished = finish(layout, data: data, context: context) { return (finished, rows) }
        }
        return finish(Layout(), data: Array(original.prefix(300)), context: sheetName).map { ($0, original) }
    }

    /// Checks the header's guesses against the data and fills gaps from the data itself.
    static func finish(_ start: Layout, data: [[String]], context: String) -> Layout? {
        var layout = start
        let width = data.map(\.count).max() ?? 0
        func share(_ column: Int?, _ test: (String) -> Bool) -> Double {
            guard let column else { return 0 }
            let filled = data.filter { !cell($0, column).isEmpty }
            return filled.isEmpty ? 0 : Double(filled.filter { test(cell($0, column)) }.count) / Double(filled.count)
        }
        let isNumber = { (s: String) in number(s) != nil }
        let isDate = { (s: String) in date(s) != nil && number(s) == nil }
        let isText = { (s: String) in number(s) == nil && date(s) == nil }

        for keyPath in [\Layout.amount, \Layout.actual, \Layout.debit, \Layout.credit] where share(layout[keyPath: keyPath], isNumber) < 0.3 {
            layout[keyPath: keyPath] = nil
        }
        if share(layout.name, isText) < 0.4 { layout.name = nil }
        if share(layout.date, isDate) < 0.5 { layout.date = nil }
        // "Category | Budgeted | Actual": the category column is the list of items.
        if layout.name == nil, let category = layout.category, share(category, isText) >= 0.4 {
            layout.name = category
            layout.category = nil
        }
        var used: Set<Int?> { [layout.name, layout.amount, layout.actual, layout.category, layout.date, layout.due, layout.type, layout.frequency, layout.debit, layout.credit] }
        if layout.name == nil {
            layout.name = (0..<width).filter { !used.contains($0) && layout.months[$0] == nil }
                .max { share($0, isText) < share($1, isText) }
                .flatMap { share($0, isText) >= 0.5 ? $0 : nil }
        }
        if layout.date == nil {
            layout.date = (0..<width).first { !used.contains($0) && share($0, isDate) >= 0.6 }
        }
        if layout.amount == nil, layout.months.isEmpty, layout.debit == nil, layout.credit == nil, let name = layout.name {
            let candidates = (0..<width).filter { !used.contains($0) && share($0, isNumber) >= 0.4 }
            layout.amount = candidates.first { $0 > name } ?? candidates.first
        }
        guard layout.name != nil, layout.amount != nil || !layout.months.isEmpty || layout.debit != nil || layout.credit != nil else { return nil }

        layout.kind = layout.date != nil && layout.months.isEmpty ? .ledger : .plan
        (layout.period, layout.multiplier) = period(in: context)
        return layout
    }

    /// The period amounts are expressed in, from wording such as "Weekly budget" or "Annual".
    static func period(in text: String) -> (String, Double) {
        let l = text.lowercased()
        if l.contains("biweekly") || l.contains("bi-weekly") || l.contains("every 2 weeks") || l.contains("every two weeks") { return ("MONTHLY", 26.0 / 12) }
        if l.contains("quarter") { return ("MONTHLY", 1.0 / 3) }
        if l.contains("weekly") || l.contains("per week") || l.contains("/week") || l.contains("/wk") { return ("WEEKLY", 1) }
        if l.contains("annual") || l.contains("yearly") || l.contains("per year") || l.contains("/year") || l.contains("/yr") { return ("YEARLY", 1) }
        return ("MONTHLY", 1)
    }

    // MARK: Rows

    struct Parsed {
        var items: [BudgetImportDraft.Item] = []
        var entries: [BudgetImportDraft.Entry] = []
        var skipped: [String] = []
        /// Category names the sheet itself gives (a category column or a section heading), by item or entry id.
        var hints: [UUID: String] = [:]
        var count: Int { items.count + entries.count }
    }

    private static let genericSections: Set<String> = [
        "expenses", "expense", "monthly expenses", "fixed expenses", "variable expenses", "fixed", "variable", "bills", "monthly bills",
        "income", "budget", "spending", "other", "misc", "miscellaneous", "needs", "wants", "essentials", "non-essentials", "discretionary",
        "outgoing", "outgoings", "monthly", "recurring", "flexible", "category", "categories", "item", "items",
    ]

    static func parse(_ rows: [[String]], layout: Layout, now: Date) -> Parsed {
        let data = rows.dropFirst((layout.header ?? -1) + 1)
        return layout.kind == .ledger ? parseLedger(Array(data), layout: layout) : parsePlan(Array(data), layout: layout, now: now)
    }

    private static func parsePlan(_ rows: [[String]], layout: Layout, now: Date) -> Parsed {
        var result = Parsed()
        var section = ""
        let currentMonth = Calendar.current.component(.month, from: now)

        for row in rows {
            let name = cell(row, layout.name)
            guard !name.isEmpty, number(name) == nil else { continue }

            var amount: Double?
            if !layout.months.isEmpty {
                // This month's figure, or for items that only come up some months (gifts, insurance), the yearly average.
                let values = layout.months.compactMap { column, _ in number(cell(row, column)) }
                let thisMonth = layout.months.first { $0.value == currentMonth }.flatMap { number(cell(row, $0.key)) }
                let average = values.reduce(0, +) / Double(layout.months.count)
                amount = thisMonth.flatMap { $0 != 0 ? $0 : nil } ?? (average != 0 ? average : nil)
            } else {
                amount = number(cell(row, layout.amount))
            }
            let actual = number(cell(row, layout.actual))

            if amount == nil && actual == nil {
                // A label with no figures anywhere in the row is a section heading ("INCOME", "Food & Dining").
                if !row.contains(where: { number($0) != nil }), !isTotal(name) { section = name }
                continue
            }
            if isTotal(name) { continue }
            guard let amount, abs(amount) >= 0.005 else {
                result.skipped.append("“\(name)”: no planned amount")
                continue
            }

            var (period, multiplier) = (layout.period, layout.multiplier)
            let frequency = cell(row, layout.frequency)
            if !frequency.isEmpty { (period, multiplier) = self.period(in: frequency) }
            let dueText = cell(row, layout.due)
            let dueDay = date(dueText).map { Calendar.current.component(.day, from: $0) }
                ?? Int(dueText.filter(\.isNumber)).flatMap { (1...31).contains($0) ? $0 : nil }

            // A category column saying "Income" or "Fixed" says as much about the kind of line as a section heading does.
            let group = cell(row, layout.category).isEmpty ? section : cell(row, layout.category)
            var item = BudgetImportDraft.Item(kind: kind(name: name, section: group, type: cell(row, layout.type), dueDay: dueDay),
                                              name: name, amount: (abs(amount) * multiplier * 100).rounded() / 100, period: period,
                                              dueDay: dueDay, actual: actual.map(abs))
            // Bills and income are tracked monthly in the app.
            if item.kind != .budget, item.period != "MONTHLY" {
                item.amount = (item.monthlyAmount * 100).rounded() / 100
                item.period = "MONTHLY"
            }
            let hint = cell(row, layout.category).isEmpty ? section : cell(row, layout.category)
            if !hint.isEmpty, !genericSections.contains(hint.lowercased()) { result.hints[item.id] = hint }
            result.items.append(item)
        }
        return result
    }

    private static func kind(name: String, section: String, type: String, dueDay: Int?) -> BudgetImportDraft.Kind {
        let t = type.lowercased()
        let s = section.lowercased()
        if ["income", "earning", "revenue", "paycheck", "salary"].contains(where: t.contains) { return .income }
        if ["income", "earnings", "salary", "paycheck", "money in"].contains(where: s.contains) { return .income }
        if t.isEmpty, CategoryMatcher.match(name) == "Income", !name.lowercased().contains("tax") { return .income }
        if dueDay != nil { return .bill }
        if ["bill", "fixed", "recurring"].contains(where: t.contains) || ["bill", "fixed", "recurring", "subscription"].contains(where: s.contains) { return .bill }
        return isBill(name) ? .bill : .budget
    }

    /// Fixed monthly payments that belong on the Bills tab rather than as a spending budget.
    static func isBill(_ name: String) -> Bool {
        let l = name.lowercased()
        let words = Set(l.split { !$0.isLetter }.map(String.init))
        if ["Utilities", "Subscriptions"].contains(CategoryMatcher.match(name)) { return true }
        return ["mortgage", "insurance", "car payment", "car note", "student loan", "membership", "daycare", "childcare", "tuition", "phone"].contains(where: l.contains)
            || ["rent", "loan", "hoa"].contains(where: words.contains)
    }

    private static func parseLedger(_ rows: [[String]], layout: Layout) -> Parsed {
        var result = Parsed()
        var raw: [(entry: BudgetImportDraft.Entry, typed: Bool)] = []

        for row in rows {
            guard let date = date(cell(row, layout.date)) else { continue }
            let title = cell(row, layout.name).isEmpty ? cell(row, layout.category) : cell(row, layout.name)
            guard !title.isEmpty, !isTotal(title) else { continue }
            var amount: Double
            if layout.debit != nil || layout.credit != nil {
                amount = abs(number(cell(row, layout.credit)) ?? 0) - abs(number(cell(row, layout.debit)) ?? 0)
            } else {
                guard let value = number(cell(row, layout.amount)) else { continue }
                amount = value
            }
            guard abs(amount) >= 0.005 else { continue }
            let type = cell(row, layout.type).lowercased()
            var typed = layout.debit != nil || layout.credit != nil
            if ["income", "credit", "deposit", "earning"].contains(where: type.contains) { amount = abs(amount); typed = true }
            else if ["expense", "debit", "withdrawal", "payment", "bill"].contains(where: type.contains) { amount = -abs(amount); typed = true }
            let entry = BudgetImportDraft.Entry(date: date, title: title, amount: amount)
            if !cell(row, layout.category).isEmpty, cell(row, layout.category) != title { result.hints[entry.id] = cell(row, layout.category) }
            raw.append((entry, typed))
        }

        // Bank exports sign their amounts; hand-kept logs usually list spending as positive numbers.
        let signed = raw.contains { !$0.typed && $0.entry.amount < 0 }
        result.entries = raw.map { item in
            var entry = item.entry
            if !item.typed, !signed {
                let looksLikeIncome = CategoryMatcher.match(entry.title) == "Income" || CategoryMatcher.match(result.hints[entry.id] ?? "") == "Income"
                entry.amount = looksLikeIncome ? abs(entry.amount) : -abs(entry.amount)
            }
            return entry
        }
        return result
    }

    // MARK: Categories

    /// Gives every item a category and fills in transaction categories. Returns whether the model was used.
    static func assignCategories(_ draft: inout BudgetImportDraft, hints: [UUID: String], existing: [String]) async -> Bool {
        let defaults = Category.defaultNames
        let known = Array(Set(existing + defaults))
        func resolve(_ text: String) -> String? {
            CategoryMatcher.existing(text, in: known) ?? CategoryMatcher.match(text).flatMap { CategoryMatcher.existing($0, in: known) }
        }

        // Sheet-given categories and keywords first.
        for index in draft.items.indices {
            let item = draft.items[index]
            if item.kind == .income { draft.items[index].category = "Income"; continue }
            if let hint = hints[item.id] {
                // An unfamiliar group name in the sheet becomes a category of its own.
                draft.items[index].category = resolve(hint) ?? hint
            } else if let match = resolve(item.name) {
                draft.items[index].category = match
            }
        }
        // Then the model, for names no keyword fits.
        var usedModel = false
        let unresolvedItems = draft.items.indices.filter { draft.items[$0].category.isEmpty }
        let unresolvedTitles = Array(Set(draft.transactions.filter { entry in
            hints[entry.id].flatMap(resolve) == nil && resolve(entry.title) == nil
        }.map(\.title))).sorted().prefix(120)
        let names = Array(Set(unresolvedItems.map { draft.items[$0].name } + unresolvedTitles)).sorted()
        var choices: [String: String] = [:]
        if !names.isEmpty, let answer = await categorizeWithModel(names, allowed: known) {
            usedModel = true
            choices = answer
            for index in unresolvedItems { draft.items[index].category = answer[draft.items[index].name] ?? "" }
        }

        // Anything still unplaced: budgets get a category named after themselves.
        for index in draft.items.indices where draft.items[index].category.isEmpty && draft.items[index].kind == .budget {
            draft.items[index].category = draft.items[index].name
        }

        // Several budgets in one default category (Groceries and Dining out → Food) each get their own,
        // since a budget tracks everything in its category.
        let budgetIndices = draft.items.indices.filter { draft.items[$0].kind == .budget }
        let crowded = Dictionary(grouping: budgetIndices) { draft.items[$0].category }.filter { defaults.contains($0.key) && $0.value.count > 1 }
        for (category, indices) in crowded {
            for index in indices where CategoryMatcher.existing(draft.items[index].name, in: [category]) == nil {
                draft.items[index].category = CategoryMatcher.existing(draft.items[index].name, in: known) ?? draft.items[index].name
            }
        }

        // Transactions go where the imported budgets will look for them: a sheet category matching a budget's
        // category (Kroger, filed as "Groceries") lands in that category.
        let itemCategories = draft.items.map(\.category).filter { !$0.isEmpty }
        for index in draft.transactions.indices {
            let entry = draft.transactions[index]
            let hint = hints[entry.id]
            draft.transactions[index].category = hint.flatMap { CategoryMatcher.existing($0, in: itemCategories) }
                ?? hint.flatMap(resolve) ?? resolve(entry.title) ?? choices[entry.title]
                ?? (entry.amount > 0 && CategoryMatcher.match(entry.title) == "Income" ? "Income" : nil)
        }
        return usedModel
    }

    // MARK: Apple Intelligence

    static var isModelAvailable: Bool { PayslipReader.isModelAvailable }

    /// Asks the model which columns hold what, for sheets the rules couldn't read.
    static func layoutWithModel(_ sheet: Spreadsheet.Sheet) async -> Layout? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *), isModelAvailable else { return nil }
        let preview = sheet.rows.prefix(30).enumerated().map { index, row in
            "R\(index): " + row.prefix(12).map { String($0.prefix(28)) }.joined(separator: " | ")
        }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
            You work out the layout of personal budget spreadsheets. Rows are numbered R0, R1, ... and cells in a row are separated by " | ", \
            numbered from 0. Answer with row and column numbers only; use -1 when something isn't present.
            """)
        do {
            let answer = try await session.respond(to: "Sheet “\(sheet.name)”:\n\(preview)", generating: ModelSheetLayout.self,
                                                   options: GenerationOptions(sampling: .greedy)).content
            let width = sheet.rows.map(\.count).max() ?? 0
            func column(_ value: Int) -> Int? { (0..<width).contains(value) ? value : nil }
            guard answer.kind != .other, let name = column(answer.nameColumn) else { return nil }
            var layout = Layout(header: (0..<sheet.rows.count).contains(answer.headerRow) ? answer.headerRow : nil, name: name)
            layout.amount = column(answer.amountColumn)
            layout.actual = column(answer.actualColumn)
            layout.category = column(answer.categoryColumn)
            layout.date = column(answer.dateColumn)
            layout.due = column(answer.dueDayColumn)
            layout.kind = answer.kind == .transactionList && layout.date != nil ? .ledger : .plan
            layout.period = switch answer.amountsAre {
            case .weekly: "WEEKLY"
            case .yearly: "YEARLY"
            case .monthly: "MONTHLY"
            }
            return layout.amount == nil ? nil : layout
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Asks the model to file names under the allowed categories. Nil when unavailable.
    static func categorizeWithModel(_ names: [String], allowed: [String]) async -> [String: String]? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *), isModelAvailable else { return nil }
        var result: [String: String] = [:]
        for start in stride(from: 0, to: names.count, by: 40) {
            let batch = Array(names[start..<min(start + 40, names.count)])
            let session = LanguageModelSession(instructions: """
                You sort personal budget items and purchases into categories. Choose exactly one of these categories for each numbered item: \
                \(allowed.sorted().joined(separator: ", ")). If none fits, answer Other.
                """)
            let list = batch.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            guard let answer = try? await session.respond(to: list, generating: ModelCategoryChoices.self,
                                                          options: GenerationOptions(sampling: .greedy)).content else { continue }
            for choice in answer.choices where (1...batch.count).contains(choice.number) {
                if let category = CategoryMatcher.existing(choice.category, in: allowed) { result[batch[choice.number - 1]] = category }
            }
        }
        return result
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable
nonisolated struct ModelSheetLayout {
    var kind: ModelSheetKind
    @Guide(description: "Row number holding the column headings, or -1 if there are none")
    var headerRow: Int
    @Guide(description: "Column number holding each budget item's name, or each transaction's description")
    var nameColumn: Int
    @Guide(description: "Column number holding the planned or budgeted amount, or each transaction's amount; -1 if none")
    var amountColumn: Int
    @Guide(description: "Column number holding the actual amount spent, separate from the planned amount; -1 if none")
    var actualColumn: Int
    @Guide(description: "Column number holding a category or group name for each row; -1 if none")
    var categoryColumn: Int
    @Guide(description: "Column number holding transaction dates; -1 if none")
    var dateColumn: Int
    @Guide(description: "Column number holding the day of the month a bill is due; -1 if none")
    var dueDayColumn: Int
    @Guide(description: "Whether the planned amounts are per week, per month or per year")
    var amountsAre: ModelAmountPeriod
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
nonisolated enum ModelSheetKind { case budgetPlan, transactionList, other }

@available(iOS 26.0, macOS 26.0, *)
@Generable
nonisolated enum ModelAmountPeriod { case weekly, monthly, yearly }

@available(iOS 26.0, macOS 26.0, *)
@Generable
nonisolated struct ModelCategoryChoices {
    @Guide(description: "One choice per numbered item")
    var choices: [ModelCategoryChoice]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
nonisolated struct ModelCategoryChoice {
    @Guide(description: "The item's number")
    var number: Int
    @Guide(description: "One of the allowed category names, exactly as written, or Other")
    var category: String
}
#endif
