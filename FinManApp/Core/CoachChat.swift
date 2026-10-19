import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A transaction as the coach's tools see it: plain values, safe to read off the main thread.
nonisolated struct CoachRecord: Sendable {
    var date: Date
    var title: String
    /// Positive = income, negative = expense.
    var amount: Double
    var category: String
    var account: String
    var note: String
}

/// A free-form conversation with the money coach. Follow-up questions keep the earlier ones in context,
/// and the model can look up transactions beyond this month's summary through two tools.
@Observable
final class CoachChat {
    struct Message: Identifiable {
        enum Role { case user, coach }
        let id = UUID()
        let role: Role
        var text: String
    }

    private(set) var messages: [Message] = []
    private(set) var isResponding = false

    @ObservationIgnored private var name = ""
    @ObservationIgnored private var summary = ""
    @ObservationIgnored private var records: [CoachRecord] = []
    /// The model session (a `LanguageModelSession` on iOS 26+), kept between questions so it remembers the conversation.
    @ObservationIgnored private var session: AnyObject?

    var usesModel: Bool { Coach.isOnDeviceModelAvailable }

    func configure(snapshot: Coach.Snapshot, transactions: [Transaction]) {
        name = snapshot.name
        summary = snapshot.summary
        records = transactions.map {
            CoachRecord(date: $0.date, title: $0.title, amount: $0.amount, category: $0.category?.name ?? "Uncategorized",
                        account: $0.account?.name ?? "", note: $0.note)
        }
        session = nil
    }

    func reset() {
        messages = []
        session = nil
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
            return
        }
        #endif
        messages[index].text = CoachTools.answerWithoutModel(question, records: records)
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
        return LanguageModelSession(tools: [FindTransactionsTool(records: records), CategoryTotalsTool(records: records)], instructions: """
            You are a friendly personal finance coach inside a budgeting app called FinMan, chatting with \(name.isEmpty ? "the user" : name).
            Today is \(today). \(dates)
            Answer the user's questions about their money using only the numbers below and what the tools return; \
            never make up figures. For anything not in the summary (a merchant, a past month, a date range, specific purchases), \
            call findTransactions or categoryTotals. Dates are written yyyy-MM-dd.
            Be concise and concrete; use short bullet points when listing things. Never give investment, tax or legal advice; \
            for those, suggest a professional.

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
    let records: [CoachRecord]
    let name = "findTransactions"
    let description = "Searches the user's transactions by merchant, category, account or note, optionally between two dates. Returns totals, totals by month and the most recent matches."

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
        CoachTools.find(records, search: arguments.search, from: arguments.from, to: arguments.to)
    }
}

@available(iOS 26.0, *)
nonisolated struct CategoryTotalsTool: Tool {
    let records: [CoachRecord]
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
        CoachTools.categoryTotals(records, from: arguments.from, to: arguments.to)
    }
}
#endif

/// What the coach's tools compute, as text the model (or the user, without Apple Intelligence) can read.
nonisolated enum CoachTools {
    private static func money(_ value: Double) -> String {
        value.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
    }

    private static func day(_ text: String) -> Date? {
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
            "\(record.date.formatted(.iso8601.year().month().day())) \(record.title) \(money(record.amount)) (\(record.category)\(record.account.isEmpty ? "" : ", \(record.account)"))"
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
