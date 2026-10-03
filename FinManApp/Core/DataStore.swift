import Foundation
import SwiftData

/// Seeding, sample data, export and reset for the on-device store.
enum DataStore {
    static func seedCategoriesIfNeeded(_ context: ModelContext) {
        let existing = (try? context.fetchCount(FetchDescriptor<Category>())) ?? 0
        guard existing == 0 else { return }
        for (index, entry) in Category.defaults.enumerated() {
            context.insert(Category(name: entry.0, isIncome: entry.1, sortOrder: index))
        }
        try? context.save()
    }

    static func category(_ name: String, in context: ModelContext) -> Category? {
        let descriptor = FetchDescriptor<Category>(predicate: #Predicate { $0.name == name })
        return try? context.fetch(descriptor).first
    }

    /// Wipes every record and reseeds the default categories.
    static func eraseAll(_ context: ModelContext) {
        try? context.delete(model: Transaction.self)
        try? context.delete(model: Bill.self)
        try? context.delete(model: Budget.self)
        try? context.delete(model: Account.self)
        try? context.delete(model: Category.self)
        try? context.save()
        seedCategoriesIfNeeded(context)
    }

    /// Roughly three months of realistic activity, modelled on the backend's DemoDataService.
    static func loadSampleData(_ context: ModelContext, monthlyIncome: Double, paydayDay: Int) {
        seedCategoriesIfNeeded(context)
        let cal = Calendar.current
        let now = Date.now
        func cat(_ name: String) -> Category? { category(name, in: context) }

        let checking = Account(name: "Everyday Checking", kind: "checking", startingBalance: 2_400)
        let savings = Account(name: "Rainy Day Savings", kind: "savings", startingBalance: 8_500)
        let credit = Account(name: "Rewards Card", kind: "credit", startingBalance: 0)
        [checking, savings, credit].forEach(context.insert)

        func add(_ title: String, _ amount: Double, _ date: Date, _ category: String, _ account: Account) {
            guard date <= now else { return }
            context.insert(Transaction(title: title, amount: amount, date: date, category: cat(category), account: account))
        }

        for back in 0...3 {
            guard let month = cal.date(byAdding: .month, value: -back, to: now),
                  let start = cal.dateInterval(of: .month, for: month)?.start else { continue }
            func day(_ d: Int, hour: Int = 12) -> Date {
                let range = cal.range(of: .day, in: .month, for: start) ?? 1..<29
                return cal.date(byAdding: DateComponents(day: min(d, range.upperBound - 1) - 1, hour: hour), to: start) ?? start
            }

            add("Payroll deposit", monthlyIncome, day(paydayDay, hour: 8), "Income", checking)
            add("Rent", -1_500, day(1, hour: 9), "Housing", checking)
            add("City Power & Light", -.random(in: 90...140), day(15), "Utilities", checking)
            add("Water utility", -.random(in: 60...90), day(20), "Utilities", checking)
            add("Fiber internet", -80, day(5), "Utilities", checking)
            add("Netflix", -15.49, day(18), "Subscriptions", credit)
            add("Spotify", -11.99, day(9), "Subscriptions", credit)
            add("Transfer to savings", -300, day(paydayDay + 1), "Savings", checking)

            let food = ["Trader Joe's", "Whole Foods", "Chipotle", "Blue Bottle Coffee", "Sweetgreen", "Local Pizza Co.", "Safeway", "Taco Truck"]
            for _ in 0..<Int.random(in: 12...16) {
                add(food.randomElement()!, -.random(in: 6...95).rounded(toPlaces: 2), day(.random(in: 1...28), hour: .random(in: 8...21)), "Food", Bool.random() ? checking : credit)
            }
            let transport = ["Shell", "Chevron", "Uber", "Lyft", "Metro card reload"]
            for _ in 0..<Int.random(in: 4...7) {
                add(transport.randomElement()!, -.random(in: 9...65).rounded(toPlaces: 2), day(.random(in: 1...28)), "Transportation", credit)
            }
            let fun = ["AMC Theatres", "Steam", "Bowling night", "Concert tickets", "Mini golf"]
            for _ in 0..<Int.random(in: 2...4) {
                add(fun.randomElement()!, -.random(in: 12...120).rounded(toPlaces: 2), day(.random(in: 1...28), hour: 19), "Entertainment", credit)
            }
            let shops = ["Target", "Amazon", "IKEA", "Uniqlo"]
            for _ in 0..<Int.random(in: 2...5) {
                add(shops.randomElement()!, -.random(in: 15...160).rounded(toPlaces: 2), day(.random(in: 1...28)), "Shopping", credit)
            }
            if Bool.random() { add("CVS Pharmacy", -.random(in: 10...45).rounded(toPlaces: 2), day(.random(in: 1...28)), "Healthcare", credit) }
        }

        let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? now
        let budgets: [(String, Double, String)] = [
            ("Groceries & dining", 600, "Food"), ("Getting around", 250, "Transportation"),
            ("Fun money", 200, "Entertainment"), ("Shopping", 300, "Shopping"), ("Utilities", 320, "Utilities"),
        ]
        for (name, amount, category) in budgets {
            context.insert(Budget(name: name, amount: amount, category: cat(category), startDate: monthStart))
        }

        let today = cal.component(.day, from: now)
        let bills: [(String, Double, Int, String)] = [
            ("Rent", 1_500, 1, "Housing"), ("Fiber internet", 80, 5, "Utilities"), ("Spotify", 11.99, 9, "Subscriptions"),
            ("Electric", 125, 15, "Utilities"), ("Netflix", 15.49, 18, "Subscriptions"), ("Water", 75, 20, "Utilities"),
            ("Gym membership", 45, 23, "Healthcare"), ("Car insurance", 140, 27, "Transportation"),
        ]
        for (name, amount, dueDay, category) in bills {
            let bill = Bill(name: name, amount: amount, dueDay: dueDay, category: cat(category))
            // Bills due earlier this month are already paid, except one left overdue to show the state.
            if dueDay < today && name != "Fiber internet" { bill.lastPaidDate = now }
            context.insert(bill)
        }
        try? context.save()
    }

    /// CSV of every transaction, newest first, for sharing/backups.
    static func exportCSV(_ transactions: [Transaction]) -> URL? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        func escape(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        var lines = ["Date,Description,Amount,Category,Account,Note"]
        for tx in transactions.sorted(by: { $0.date > $1.date }) {
            lines.append([
                formatter.string(from: tx.date), escape(tx.title), String(format: "%.2f", tx.amount),
                escape(tx.category?.name ?? ""), escape(tx.account?.name ?? ""), escape(tx.note),
            ].joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FinMan-transactions.csv")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
