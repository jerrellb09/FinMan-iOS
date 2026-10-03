import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Money coach. Uses Apple's on-device language model (Apple Intelligence, iOS 26+) when available,
/// otherwise falls back to rule-based tips. Nothing ever leaves the phone.
enum Coach {
    enum Mode: String, CaseIterable, Identifiable {
        case insights = "Insights", budgets = "Budget ideas", habits = "Habits"
        var id: Self { self }
        var icon: String {
            switch self {
            case .insights: "lightbulb.fill"
            case .budgets: "target"
            case .habits: "brain.head.profile"
            }
        }
        var ask: String {
            switch self {
            case .insights: "Give me 3 short, specific insights about my finances this month and one thing to celebrate."
            case .budgets: "Suggest realistic monthly budget amounts for my top spending categories, with a one-line reason each."
            case .habits: "Describe my spending habits and give me 3 small, practical changes that would save money."
            }
        }
    }

    struct Snapshot {
        let name: String
        let monthlyIncome: Double
        let analytics: Analytics
        let budgets: [Budget]
        let bills: [Bill]

        /// Compact, factual summary the model reasons over.
        var summary: String {
            let a = analytics
            var lines: [String] = []
            lines.append("Monthly income (expected): \(monthlyIncome.currency())")
            lines.append("Income so far this month: \(a.incomeThisMonth.currency())")
            lines.append("Spent so far this month: \(a.spentThisMonth.currency()) (same point last month: \(a.spentLastMonthToDate.currency()))")
            let cats = a.byCategory().prefix(6).map { "\($0.name) \($0.amount.currency())" }
            if !cats.isEmpty { lines.append("This month by category: " + cats.joined(separator: ", ")) }
            let trend = a.monthlyTrend(months: 4).map {
                "\($0.month.formatted(.dateTime.month(.abbreviated))): in \($0.income.currency(compact: true)), out \($0.spending.currency(compact: true))"
            }
            lines.append("Recent months: " + trend.joined(separator: "; "))
            let merchants = a.topMerchants(limit: 5).map { "\($0.name) (\($0.count)x, \($0.amount.currency()))" }
            if !merchants.isEmpty { lines.append("Top merchants: " + merchants.joined(separator: ", ")) }
            if !budgets.isEmpty {
                lines.append("Budgets: " + budgets.map {
                    "\($0.name) \($0.spent().currency(compact: true))/\($0.amount.currency(compact: true))"
                }.joined(separator: ", "))
            }
            let unpaid = bills.filter { !$0.isPaid }
            lines.append("Monthly bills total \(bills.reduce(0) { $0 + $1.amount }.currency()); unpaid: "
                         + (unpaid.isEmpty ? "none" : unpaid.map { "\($0.name) \($0.amount.currency()) due in \($0.daysUntilDue()) days" }.joined(separator: ", ")))
            lines.append("No-spend streak: \(a.noSpendStreak) days")
            return lines.joined(separator: "\n")
        }
    }

    static var isOnDeviceModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Streams the coach's answer; `onUpdate` receives the full text so far.
    static func advise(_ mode: Mode, snapshot: Snapshot, onUpdate: @escaping (String) -> Void) async throws {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isOnDeviceModelAvailable {
            let session = LanguageModelSession(instructions: """
                You are a friendly, upbeat personal finance coach inside a budgeting app called FinMan.
                Use only the numbers provided. Be concise and concrete, use short bullet points and a couple of emoji.
                Never give investment, tax or legal advice. Address the user as \(snapshot.name.isEmpty ? "you" : snapshot.name).
                """)
            let prompt = "\(mode.ask)\n\nMy finances:\n\(snapshot.summary)"
            for try await partial in session.streamResponse(to: prompt) {
                onUpdate(partial.content)
            }
            return
        }
        #endif
        onUpdate(ruleBasedTips(mode, snapshot: snapshot))
    }

    static func ruleBasedTips(_ mode: Mode, snapshot s: Snapshot) -> String {
        let a = s.analytics
        var tips: [String] = []
        switch mode {
        case .insights:
            if let change = a.spendingChange {
                tips.append(change <= 0
                    ? "🙌 You've spent \(abs(change).formatted(.percent.precision(.fractionLength(0)))) less than this time last month."
                    : "📈 Spending is up \(change.formatted(.percent.precision(.fractionLength(0)))) vs this time last month.")
            }
            if let top = a.byCategory().first {
                tips.append("\(CategoryStyle.forName(top.name).emoji) \(top.name) is your biggest category this month at \(top.amount.currency()).")
            }
            let income = max(a.incomeThisMonth, s.monthlyIncome)
            if income > 0 {
                let rate = (income - a.spentThisMonth) / income
                tips.append(rate >= 0.2 ? "💪 You're on pace to save \(rate.formatted(.percent.precision(.fractionLength(0)))) of your income. Great work!"
                                        : "🎯 Aim to keep at least 20% of income unspent. You're at \(max(0, rate).formatted(.percent.precision(.fractionLength(0)))) so far.")
            }
            if a.noSpendStreak >= 2 { tips.append("🔥 \(a.noSpendStreak)-day no-spend streak. Keep it going!") }
        case .budgets:
            let trend = a.monthlyTrend(months: 4).dropLast()
            let months = Double(max(trend.count, 1))
            let past = trend.isEmpty ? [] : a.transactions.filter { tx in trend.contains { a.calendar.isDate(tx.date, equalTo: $0.month, toGranularity: .month) } }
            for slice in a.byCategory(past).prefix(4) {
                let average = slice.amount / months
                let suggestion = (average * 0.9 / 10).rounded() * 10
                tips.append("\(CategoryStyle.forName(slice.name).emoji) \(slice.name): try \(suggestion.currency(compact: true))/month (you average \(average.currency(compact: true))).")
            }
            if tips.isEmpty { tips.append("Add a few weeks of transactions and I'll suggest budgets based on your real spending.") }
        case .habits:
            let merchants = a.topMerchants(limit: 3)
            if let top = merchants.first {
                tips.append("☕️ \(top.name) is your most-visited spot (\(top.count)x, \(top.amount.currency())). Could one visit a week be swapped out?")
            }
            let weekend = a.thisMonth.filter { $0.amount < 0 && a.calendar.isDateInWeekend($0.date) }
            let weekendShare = a.spentThisMonth > 0 ? Analytics.spending(weekend) / a.spentThisMonth : 0
            if weekendShare > 0.4 { tips.append("🎉 \(weekendShare.formatted(.percent.precision(.fractionLength(0)))) of your spending happens on weekends. Plan a free weekend activity.") }
            let small = a.thisMonth.filter { $0.amount < 0 && abs($0.amount) < 15 }
            if small.count >= 8 { tips.append("🪙 \(small.count) small purchases under $15 added up to \(Analytics.spending(small).currency()) this month.") }
            let subs = s.bills.filter { ($0.category?.name ?? "").contains("Subscri") }
            if !subs.isEmpty { tips.append("🔁 Subscriptions cost \(subs.reduce(0) { $0 + $1.amount }.currency())/month. Cancel any you haven't used lately.") }
            if tips.isEmpty { tips.append("Log a couple of weeks of spending and I'll spot patterns for you.") }
        }
        return tips.map { "• \($0)" }.joined(separator: "\n")
    }
}
