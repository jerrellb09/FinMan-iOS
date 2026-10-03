import Foundation

/// Analytics derived from on-device transactions.
struct Analytics {
    let transactions: [Transaction]
    var calendar = Calendar.current
    var now = Date.now

    struct CategorySlice: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let amount: Double
    }

    struct MonthPoint: Identifiable, Hashable {
        var id: Date { month }
        let month: Date
        let income: Double
        let spending: Double
    }

    struct DayPoint: Identifiable, Hashable {
        var id: Date { day }
        let day: Date
        let cumulative: Double
    }

    struct Merchant: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let amount: Double
        let count: Int
    }

    private func inMonth(_ offset: Int) -> [Transaction] {
        guard let ref = calendar.date(byAdding: .month, value: offset, to: now) else { return [] }
        return transactions.filter { calendar.isDate($0.date, equalTo: ref, toGranularity: .month) }
    }

    var thisMonth: [Transaction] { inMonth(0) }
    var lastMonth: [Transaction] { inMonth(-1) }

    /// Money out, excluding transfers into savings (those aren't really "spending").
    static func spending(_ txs: [Transaction]) -> Double {
        txs.filter { $0.amount < 0 && $0.category?.name != "Savings" }.reduce(0) { $0 + abs($1.amount) }
    }

    static func income(_ txs: [Transaction]) -> Double {
        txs.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
    }

    var spentThisMonth: Double { Self.spending(thisMonth) }
    var incomeThisMonth: Double { Self.income(thisMonth) }

    /// Spending over the same span of last month (day 1 through today's day-of-month).
    var spentLastMonthToDate: Double {
        let day = calendar.component(.day, from: now)
        return Self.spending(lastMonth.filter { calendar.component(.day, from: $0.date) <= day })
    }

    /// Fractional month-to-date change vs. last month (e.g. -0.12 = spent 12% less so far).
    var spendingChange: Double? {
        guard spentLastMonthToDate > 0 else { return nil }
        return (spentThisMonth - spentLastMonthToDate) / spentLastMonthToDate
    }

    func byCategory(_ txs: [Transaction]? = nil) -> [CategorySlice] {
        let source = (txs ?? thisMonth).filter { $0.amount < 0 && $0.category?.name != "Savings" }
        let grouped = Dictionary(grouping: source) { $0.category?.name ?? "Uncategorized" }
        return grouped
            .map { CategorySlice(name: $0.key, amount: Self.spending($0.value)) }
            .sorted { $0.amount > $1.amount }
    }

    func monthlyTrend(months: Int = 6) -> [MonthPoint] {
        (0..<months).reversed().compactMap { back in
            guard let ref = calendar.date(byAdding: .month, value: -back, to: now),
                  let start = calendar.dateInterval(of: .month, for: ref)?.start else { return nil }
            let txs = inMonth(-back)
            return MonthPoint(month: start, income: Self.income(txs), spending: Self.spending(txs))
        }
    }

    /// Running total of spending across the current month, one point per day so far.
    var cumulativeThisMonth: [DayPoint] {
        guard let interval = calendar.dateInterval(of: .month, for: now) else { return [] }
        let today = calendar.startOfDay(for: now)
        let byDay = Dictionary(grouping: thisMonth.filter { $0.amount < 0 && $0.category?.name != "Savings" }) {
            calendar.startOfDay(for: $0.date)
        }
        var total = 0.0
        var points: [DayPoint] = []
        var day = interval.start
        while day <= today {
            total += (byDay[day] ?? []).reduce(0) { $0 + abs($1.amount) }
            points.append(DayPoint(day: day, cumulative: total))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return points
    }

    func topMerchants(limit: Int = 5) -> [Merchant] {
        let expenses = thisMonth.filter { $0.amount < 0 && $0.category?.name != "Savings" }
        return Dictionary(grouping: expenses) { $0.title.trimmingCharacters(in: .whitespaces) }
            .map { Merchant(name: $0.key, amount: Self.spending($0.value), count: $0.value.count) }
            .sorted { $0.amount > $1.amount }
            .prefix(limit)
            .map { $0 }
    }

    /// Consecutive days (ending today, or yesterday if you've already spent today) with no spending.
    var noSpendStreak: Int {
        guard !transactions.isEmpty else { return 0 }
        let expenseDays = Set(transactions.filter { $0.amount < 0 }.map { calendar.startOfDay(for: $0.date) })
        var streak = 0
        var day = calendar.startOfDay(for: now)
        if expenseDays.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
        while !expenseDays.contains(day), streak < 365 {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    /// 0–100 "financial health" score blending savings rate, budget adherence and bill status.
    func healthScore(budgets: [Budget], bills: [Bill], monthlyIncome: Double) -> Int {
        let income = max(incomeThisMonth, monthlyIncome)
        let savingsRate = income > 0 ? max(0, min(1, (income - spentThisMonth) / income)) : 0.5
        let savingsPoints = min(1, savingsRate / 0.2) * 40 // a 20%+ savings rate earns full marks

        let budgetPoints: Double
        if budgets.isEmpty {
            budgetPoints = 20
        } else {
            let onTrack = budgets.filter { $0.progress(now: now) <= 1 }.count
            budgetPoints = Double(onTrack) / Double(budgets.count) * 35
        }

        let overdue = bills.filter { !$0.isPaid && $0.daysUntilDue(from: now) < 0 }.count
        let billPoints = bills.isEmpty ? 20 : max(0, 25 - Double(overdue) * 8)

        return Int((savingsPoints + budgetPoints + billPoints).rounded())
    }
}
