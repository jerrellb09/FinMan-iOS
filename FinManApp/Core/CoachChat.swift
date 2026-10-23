import Foundation
import Observation
import SwiftData
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A transaction as the coach's tools see it: plain values, safe to read off the main thread.
nonisolated struct CoachRecord: Sendable {
    /// Short ID the model uses to name the transaction, like T12.
    var ref: String
    var date: Date
    var title: String
    /// Positive = income, negative = expense.
    var amount: Double
    var category: String
    var account: String
    var note: String
}

/// A free-form conversation with the money coach. Follow-up questions keep the earlier ones in context,
/// and the model can look up transactions beyond this month's summary through two tools. When the user asks, it can also
/// propose fixes to transactions and bills, which wait in the chat until the user applies them.
@Observable
final class CoachChat {
    struct Message: Identifiable {
        enum Role { case user, coach }
        enum ChangesState { case pending, applied, dismissed }
        let id = UUID()
        let role: Role
        var text: String
        /// Fixes the coach proposed in this answer. Nothing is saved until the user applies them.
        var changes: [CoachLedger.Change] = []
        var changesState = ChangesState.pending
    }

    private(set) var messages: [Message] = []
    private(set) var isResponding = false

    @ObservationIgnored private var name = ""
    @ObservationIgnored private var summary = ""
    @ObservationIgnored private let ledger = CoachLedger()
    /// The model session (a `LanguageModelSession` on iOS 26+), kept between questions so it remembers the conversation.
    @ObservationIgnored private var session: AnyObject?

    var usesModel: Bool { Coach.isOnDeviceModelAvailable }

    func configure(snapshot: Coach.Snapshot, context: ModelContext) {
        name = snapshot.name
        summary = snapshot.summary
        ledger.load(context)
        session = nil
    }

    func reset() {
        messages = []
        _ = ledger.takePending()
        session = nil
    }

    func applyChanges(in messageID: Message.ID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }), messages[index].changesState == .pending else { return }
        ledger.apply(messages[index].changes)
        messages[index].changesState = .applied
    }

    func dismissChanges(in messageID: Message.ID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }), messages[index].changesState == .pending else { return }
        messages[index].changesState = .dismissed
    }

    func send(_ question: String) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }
        messages.append(Message(role: .user, text: question))
        messages.append(Message(role: .coach, text: ""))
        let index = messages.count - 1
        isResponding = true
        defer { isResponding = false }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), usesModel {
            do {
                try await respond(to: question) { self.messages[index].text = $0 }
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                // The conversation outgrew the model's memory: start over with just this question.
                session = nil
                do {
                    try await respond(to: question) { self.messages[index].text = "_Started a fresh conversation; I lost track of the earlier messages._\n\n" + $0 }
                } catch {
                    messages[index].text = Self.failureText(error)
                }
            } catch {
                messages[index].text = Self.failureText(error)
            }
            messages[index].changes = ledger.takePending()
            return
        }
        #endif
        messages[index].text = CoachTools.answerWithoutModel(question, records: ledger.records)
    }

    private static func failureText(_ error: Error) -> String {
        "Sorry, I couldn't answer that one. Try rephrasing it, or ask about a specific category, merchant or month."
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func respond(to question: String, onUpdate: @escaping (String) -> Void) async throws {
        let session = (self.session as? LanguageModelSession) ?? makeSession()
        self.session = session
        for try await partial in session.streamResponse(to: question) {
            onUpdate(partial.content)
        }
    }

    @available(iOS 26.0, *)
    private func makeSession() -> LanguageModelSession {
        let today = Date.now.formatted(.iso8601.year().month().day())
        let calendar = Calendar.current
        let monthStart = calendar.dateInterval(of: .month, for: .now)?.start ?? .now
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
        func iso(_ date: Date) -> String { date.formatted(.iso8601.year().month().day()) }
        let dates = "This month started \(iso(monthStart)); last month ran \(iso(lastMonth)) to \(iso(calendar.date(byAdding: .day, value: -1, to: monthStart) ?? monthStart)). "
            + "\"The last N months\" means from N months before today up to today."
        let tools: [any Tool] = [FindTransactionsTool(ledger: ledger), CategoryTotalsTool(ledger: ledger),
                                 ChangeTransactionTool(ledger: ledger), ChangeBillTool(ledger: ledger)]
        return LanguageModelSession(tools: tools, instructions: """
            You are a friendly personal finance coach inside a budgeting app called FinMan, chatting with \(name.isEmpty ? "the user" : name).
            Today is \(today). \(dates)
            Answer the user's questions about their money using only the numbers below and what the tools return; \
            never make up figures. For anything not in the summary (a merchant, a past month, a date range, specific purchases), \
            call findTransactions or categoryTotals. Dates are written yyyy-MM-dd.
            Be concise and concrete; use short bullet points when listing things. Never give investment, tax or legal advice; \
            for those, suggest a professional.

            You can also fix their transactions and bills, but only when they ask you to fix, change, correct, recategorize, \
            rename, mark paid or delete something. Never propose changes when they're only asking a question. \
            Find transactions with findTransactions, then pass each one's ID (like T12) to changeTransaction; pass a bill's ID \
            (like B3) to changeBill. Call the tool once per record. Changes wait for the user to tap Apply, so afterwards \
            briefly list what you proposed.

            Categories: \(ledger.categoryNames.joined(separator: ", "))
            Bills:
            \(ledger.billLines.isEmpty ? "none" : ledger.billLines.joined(separator: "\n"))

            Their finances this month:
            \(summary)
            """)
    }
    #endif
}

// MARK: - Tools

#if canImport(FoundationModels)
@available(iOS 26.0, *)
nonisolated struct FindTransactionsTool: Tool {
    let ledger: CoachLedger
    let name = "findTransactions"
    let description = "Searches the user's transactions by merchant, category, account or note, optionally between two dates. Returns totals, totals by month and the most recent matches with their IDs."

    @Generable
    struct Arguments {
        @Guide(description: "Words to look for, such as a merchant (Starbucks) or a category (Food). Empty matches every transaction.")
        var search: String
        @Guide(description: "First day to include, as yyyy-MM-dd, or empty for no limit")
        var from: String
        @Guide(description: "Last day to include, as yyyy-MM-dd, or empty for no limit")
        var to: String
    }

    func call(arguments: Arguments) async throws -> String {
        CoachTools.find(await ledger.records, search: arguments.search, from: arguments.from, to: arguments.to)
    }
}

@available(iOS 26.0, *)
nonisolated struct CategoryTotalsTool: Tool {
    let ledger: CoachLedger
    let name = "categoryTotals"
    let description = "Totals the user's spending by category, and their income, between two dates."

    @Generable
    struct Arguments {
        @Guide(description: "First day to include, as yyyy-MM-dd")
        var from: String
        @Guide(description: "Last day to include, as yyyy-MM-dd")
        var to: String
    }

    func call(arguments: Arguments) async throws -> String {
        CoachTools.categoryTotals(await ledger.records, from: arguments.from, to: arguments.to)
    }
}

@available(iOS 26.0, *)
nonisolated struct ChangeTransactionTool: Tool {
    let ledger: CoachLedger
    let name = "changeTransaction"
    let description = "Proposes a fix to one transaction, named by its ID from findTransactions. The user approves it before anything changes. Use only when the user asks you to fix or change something."

    @Generable
    struct Arguments {
        @Guide(description: "The transaction's ID from findTransactions, like T12")
        var id: String
        @Guide(description: "New name, or empty to keep it")
        var title: String
        @Guide(description: "New amount as a positive number, like 12.50, or empty to keep it")
        var amount: String
        @Guide(description: "income or expense to change which it is, or empty to keep it")
        var kind: String
        @Guide(description: "New date as yyyy-MM-dd, or empty to keep it")
        var date: String
        @Guide(description: "New category, exactly one of the user's categories, or empty to keep it")
        var category: String
        @Guide(description: "New note, or empty to keep it")
        var note: String
        @Guide(description: "true to delete the transaction, such as a duplicate")
        var delete: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        await ledger.proposeTransactionChange(ref: arguments.id, title: arguments.title, amount: arguments.amount, kind: arguments.kind,
                                              date: arguments.date, category: arguments.category, note: arguments.note, delete: arguments.delete)
    }
}

@available(iOS 26.0, *)
nonisolated struct ChangeBillTool: Tool {
    let ledger: CoachLedger
    let name = "changeBill"
    let description = "Proposes a fix to one bill, named by its ID from the bill list, like B3. The user approves it before anything changes. Use only when the user asks you to fix or change something."

    @Generable
    struct Arguments {
        @Guide(description: "The bill's ID, like B3")
        var id: String
        @Guide(description: "New name, or empty to keep it")
        var name: String
        @Guide(description: "New monthly amount as a positive number, like 79.99, or empty to keep it")
        var amount: String
        @Guide(description: "New day of the month it's due, 1 to 31, or empty to keep it")
        var dueDay: String
        @Guide(description: "New category, exactly one of the user's categories, or empty to keep it")
        var category: String
        @Guide(description: "yes to mark it paid this month, no to mark it unpaid, or empty to keep it")
        var paid: String
        @Guide(description: "yes or no to turn autopay on or off, or empty to keep it")
        var autoPay: String
        @Guide(description: "true to delete the bill")
        var delete: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        await ledger.proposeBillChange(ref: arguments.id, name: arguments.name, amount: arguments.amount, dueDay: arguments.dueDay,
                                       category: arguments.category, paid: arguments.paid, autoPay: arguments.autoPay, delete: arguments.delete)
    }
}
#endif

/// What the coach's tools compute, as text the model (or the user, without Apple Intelligence) can read.
nonisolated enum CoachTools {
    private static func money(_ value: Double) -> String {
        value.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
    }

    static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func inRange(_ records: [CoachRecord], from: String, to: String) -> [CoachRecord] {
        let start = day(from)
        let end = day(to).flatMap { Calendar.current.date(byAdding: .day, value: 1, to: $0) }
        return records.filter { (start == nil || $0.date >= start!) && (end == nil || $0.date < end!) }
    }

    private static func rangeText(from: String, to: String) -> String {
        switch (day(from), day(to)) {
        case let (start?, end?): " from \(start.formatted(date: .abbreviated, time: .omitted)) to \(end.formatted(date: .abbreviated, time: .omitted))"
        case let (start?, nil): " since \(start.formatted(date: .abbreviated, time: .omitted))"
        case let (nil, end?): " up to \(end.formatted(date: .abbreviated, time: .omitted))"
        default: ""
        }
    }

    /// Records that match every word of `search` (or, failing that, any word). A word matches a record's name, category,
    /// account or note, or names the kind of spending it is: "groceries" finds the Food category and Kroger.
    static func matching(_ records: [CoachRecord], search: String) -> [CoachRecord] {
        let words = search.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 }
        guard !words.isEmpty else { return records }
        let texts = records.map { "\($0.title) \($0.category) \($0.account) \($0.note)".lowercased() }
        let titleCategories = records.map { CategoryMatcher.match($0.title) }
        // Only words that aren't a name in the data stand for a category: "kroger" finds Kroger, not all Food.
        let wordCategories = Dictionary(words.map { word in
            (word, texts.contains { $0.contains(word) } ? nil : CategoryMatcher.match(word))
        }, uniquingKeysWith: { first, _ in first })
        func matches(_ i: Int, _ word: String) -> Bool {
            if texts[i].contains(word) { return true }
            guard let category = wordCategories[word] ?? nil else { return false }
            return records[i].category.caseInsensitiveCompare(category) == .orderedSame || titleCategories[i] == category
        }
        let all = records.indices.filter { i in words.allSatisfy { matches(i, $0) } }
        let found = all.isEmpty ? records.indices.filter { i in words.contains { matches(i, $0) } } : all
        return found.map { records[$0] }
    }

    static func find(_ records: [CoachRecord], search: String, from: String, to: String) -> String {
        let matches = matching(inRange(records, from: from, to: to), search: search).sorted { $0.date > $1.date }
        let label = search.trimmingCharacters(in: .whitespaces).isEmpty ? "All transactions" : "Transactions matching “\(search)”"
        guard !matches.isEmpty else { return "No transactions matched “\(search)”\(rangeText(from: from, to: to))." }

        let spent = -matches.filter { $0.amount < 0 }.reduce(0) { $0 + $1.amount }
        let received = matches.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
        var lines = ["\(label)\(rangeText(from: from, to: to)): \(matches.count), spent \(money(spent)), received \(money(received))."]

        let calendar = Calendar.current
        let months = Dictionary(grouping: matches) { calendar.dateInterval(of: .month, for: $0.date)?.start ?? $0.date }
            .sorted { $0.key > $1.key }.prefix(6)
        if months.count > 1 {
            lines.append("By month: " + months.map { month, items in
                "\(month.formatted(.dateTime.month(.abbreviated).year())) spent \(money(-items.filter { $0.amount < 0 }.reduce(0) { $0 + $1.amount }))"
            }.joined(separator: "; "))
        }
        lines.append("Most recent: " + matches.prefix(10).map { record in
            "\(record.ref) \(record.date.formatted(.iso8601.year().month().day())) \(record.title) \(money(record.amount)) (\(record.category)\(record.account.isEmpty ? "" : ", \(record.account)"))"
        }.joined(separator: "; "))
        return lines.joined(separator: "\n")
    }

    static func categoryTotals(_ records: [CoachRecord], from: String, to: String) -> String {
        let range = inRange(records, from: from, to: to)
        guard !range.isEmpty else { return "No transactions\(rangeText(from: from, to: to))." }
        let spending = Dictionary(grouping: range.filter { $0.amount < 0 }, by: \.category)
            .map { (name: $0.key, total: -$0.value.reduce(0) { $0 + $1.amount }, count: $0.value.count) }
            .sorted { $0.total > $1.total }
        let income = range.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
        return """
            Spending by category\(rangeText(from: from, to: to)): \(spending.map { "\($0.name) \(money($0.total)) (\($0.count))" }.joined(separator: ", ")).
            Total spent \(money(spending.reduce(0) { $0 + $1.total })); income received \(money(income)).
            """
    }

    private static let stopWords: Set<String> = [
        "how", "much", "did", "spend", "spent", "on", "at", "the", "my", "for", "what", "was", "is", "are", "this", "last", "month",
        "year", "week", "do", "and", "in", "of", "to", "a", "an", "money", "many", "times", "have", "has", "can", "you", "me", "show",
        "total", "all", "since", "from", "with", "go", "went", "pay", "paid", "buy", "bought", "whats", "about", "tell", "i",
    ]

    /// Without Apple Intelligence: totals for whatever merchant or category the question names.
    static func answerWithoutModel(_ question: String, records: [CoachRecord], now: Date = .now) -> String {
        let words = question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
        let calendar = Calendar.current
        for word in words {
            let matches = matching(records, search: word)
            guard !matches.isEmpty, matches.count < records.count else { continue }
            let label = word.capitalized
            func spent(in month: Date) -> Double {
                -matches.filter { $0.amount < 0 && calendar.isDate($0.date, equalTo: month, toGranularity: .month) }.reduce(0) { $0 + $1.amount }
            }
            let lastMonth = calendar.date(byAdding: .month, value: -1, to: now) ?? now
            let yearAgo = calendar.date(byAdding: .year, value: -1, to: now) ?? now
            let year = -matches.filter { $0.amount < 0 && $0.date >= yearAgo }.reduce(0) { $0 + $1.amount }
            return """
                **\(label)** (\(matches.count) transactions):
                • This month: \(money(spent(in: now)))
                • Last month: \(money(spent(in: lastMonth)))
                • Past 12 months: \(money(year))
                """
        }
        return "Without Apple Intelligence I can only total up a merchant or category you name, like “Starbucks” or “Food”. Turn on Apple Intelligence in Settings for full answers."
    }
}
