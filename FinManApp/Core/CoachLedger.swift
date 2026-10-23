import Foundation
import SwiftData

/// The transactions and bills the money coach can see and fix. Each record gets a short ID (T12, B3) that the model uses to
/// name it, and the IDs stay the same for the whole conversation. Fixes the model proposes wait here until the user applies them.
final class CoachLedger {
    /// One proposed fix, shown to the user before anything is saved.
    struct Change: Identifiable {
        let id = UUID()
        /// The record's ID, like T12 or B3.
        let ref: String
        /// Which record, such as "Starbucks on 2026-10-03".
        let title: String
        /// What changes, such as "Category: Food → Coffee".
        let detail: String
        let isDelete: Bool
        fileprivate let apply: () -> Void
    }

    private(set) var records: [CoachRecord] = []
    private(set) var categoryNames: [String] = []
    /// One line per bill, with its ID, for the model's instructions.
    private(set) var billLines: [String] = []

    private var context: ModelContext?
    private var refs: [PersistentIdentifier: String] = [:]
    private var transactionCount = 0
    private var billCount = 0
    private var transactions: [String: Transaction] = [:]
    private var bills: [String: Bill] = [:]
    private var categories: [Category] = []
    private var pending: [Change] = []

    func load(_ context: ModelContext) {
        self.context = context
        refs = [:]
        transactionCount = 0
        billCount = 0
        pending = []
        refresh()
    }

    /// Reads the store again. Records seen before keep their IDs; new ones get the next number.
    func refresh() {
        guard let context else { return }
        let allTransactions = (try? context.fetch(FetchDescriptor<Transaction>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        let allBills = (try? context.fetch(FetchDescriptor<Bill>(sortBy: [SortDescriptor(\.dueDay)]))) ?? []
        categories = (try? context.fetch(FetchDescriptor<Category>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        categoryNames = categories.map(\.name)

        transactions = [:]
        records = allTransactions.map { tx in
            let ref = ref(for: tx.persistentModelID, prefix: "T", counter: &transactionCount)
            transactions[ref] = tx
            return CoachRecord(ref: ref, date: tx.date, title: tx.title, amount: tx.amount, category: tx.category?.name ?? "Uncategorized",
                               account: tx.account?.name ?? "", note: tx.note)
        }
        bills = [:]
        billLines = allBills.map { bill in
            let ref = ref(for: bill.persistentModelID, prefix: "B", counter: &billCount)
            bills[ref] = bill
            return "\(ref) \(bill.name) \(bill.amount.currency()), due on day \(bill.dueDay), \(bill.category?.name ?? "Uncategorized"), "
                + "\(bill.isRecurring ? "monthly" : "one-off"), autopay \(bill.autoPay ? "on" : "off"), \(bill.isPaid ? "paid" : "unpaid")"
        }
    }

    private func ref(for id: PersistentIdentifier, prefix: String, counter: inout Int) -> String {
        if let ref = refs[id] { return ref }
        counter += 1
        let ref = "\(prefix)\(counter)"
        refs[id] = ref
        return ref
    }

    // MARK: - Proposing

    /// Stages a fix to one transaction. Empty fields keep their current value. Returns what happened, for the model.
    func proposeTransactionChange(ref: String, title: String, amount: String, kind: String, date: String,
                                  category: String, note: String, delete: Bool) -> String {
        let key = Self.key(ref)
        guard let tx = transactions[key], !tx.isDeleted else {
            return "There's no transaction \(ref). Look it up with findTransactions and use the ID it shows, like T12."
        }
        let title = title.trimmingCharacters(in: .whitespaces)
        let name = "\(tx.title) on \(tx.date.formatted(.iso8601.year().month().day()))"
        if delete {
            let context = context
            return stage(Change(ref: key, title: name, detail: "Delete (\(tx.amount.currency()))", isDelete: true) {
                if !tx.isDeleted { context?.delete(tx) }
            })
        }

        var details: [String] = []
        var edits: [(Transaction) -> Void] = []
        if !title.isEmpty, title != tx.title {
            details.append("Name: \(tx.title) → \(title)")
            edits.append { $0.title = title }
        }

        var magnitude = abs(tx.amount)
        if !amount.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let value = Self.number(amount) else { return "“\(amount)” isn't an amount. Use a number like 12.50." }
            magnitude = abs(value)
        }
        var isIncome = tx.amount > 0
        switch kind.lowercased().trimmingCharacters(in: .whitespaces) {
        case "income": isIncome = true
        case "expense", "spending": isIncome = false
        default: break
        }
        let signed = isIncome ? magnitude : -magnitude
        if signed != tx.amount {
            details.append("Amount: \(tx.amount.currency()) → \(signed.currency())")
            edits.append { $0.amount = signed }
        }

        if !date.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let day = CoachTools.day(date) else { return "“\(date)” isn't a date. Use yyyy-MM-dd." }
            if !Calendar.current.isDate(day, inSameDayAs: tx.date) {
                // Keep the time of day; only the day moves.
                let time = Calendar.current.dateComponents([.hour, .minute, .second], from: tx.date)
                let moved = Calendar.current.date(byAdding: time, to: day) ?? day
                details.append("Date: \(tx.date.formatted(date: .abbreviated, time: .omitted)) → \(moved.formatted(date: .abbreviated, time: .omitted))")
                edits.append { $0.date = moved }
            }
        }

        if !category.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let match = self.category(named: category) else {
                return "There's no category “\(category)”. Use one of: \(categoryNames.joined(separator: ", "))."
            }
            if match != tx.category {
                details.append("Category: \(tx.category?.name ?? "Uncategorized") → \(match.name)")
                edits.append { $0.category = match }
            }
        }

        let note = note.trimmingCharacters(in: .whitespaces)
        if !note.isEmpty, note != tx.note {
            details.append(tx.note.isEmpty ? "Note: \(note)" : "Note: \(tx.note) → \(note)")
            edits.append { $0.note = note }
        }

        guard !details.isEmpty else { return "\(key) already looks like that; there's nothing to change." }
        return stage(Change(ref: key, title: name, detail: details.joined(separator: "; "), isDelete: false) {
            if !tx.isDeleted { edits.forEach { $0(tx) } }
        })
    }

    /// Stages a fix to one bill. Empty fields keep their current value. Returns what happened, for the model.
    func proposeBillChange(ref: String, name: String, amount: String, dueDay: String, category: String,
                           paid: String, autoPay: String, delete: Bool) -> String {
        let key = Self.key(ref)
        guard let bill = bills[key], !bill.isDeleted else {
            return "There's no bill \(ref). Use a bill ID from the list in your instructions, like B3."
        }
        let label = "\(bill.name) (bill)"
        if delete {
            let context = context
            return stage(Change(ref: key, title: label, detail: "Delete (\(bill.amount.currency()) a month)", isDelete: true) {
                if !bill.isDeleted { context?.delete(bill) }
            })
        }

        var details: [String] = []
        var edits: [(Bill) -> Void] = []
        let name = name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != bill.name {
            details.append("Name: \(bill.name) → \(name)")
            edits.append { $0.name = name }
        }
        if !amount.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let number = Self.number(amount), number != 0 else { return "“\(amount)” isn't an amount. Use a number like 79.99." }
            let value = abs(number)
            if value != bill.amount {
                details.append("Amount: \(bill.amount.currency()) → \(value.currency())")
                edits.append { $0.amount = value }
            }
        }
        if !dueDay.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let day = Int(dueDay.filter(\.isNumber)), (1...31).contains(day) else { return "“\(dueDay)” isn't a day of the month (1 to 31)." }
            if day != bill.dueDay {
                details.append("Due day: \(bill.dueDay) → \(day)")
                edits.append { $0.dueDay = day }
            }
        }
        if !category.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let match = self.category(named: category) else {
                return "There's no category “\(category)”. Use one of: \(categoryNames.joined(separator: ", "))."
            }
            if match != bill.category {
                details.append("Category: \(bill.category?.name ?? "Uncategorized") → \(match.name)")
                edits.append { $0.category = match }
            }
        }
        if let paid = Self.yesNo(paid), paid != bill.isPaid {
            details.append(paid ? "Mark paid this month" : "Mark unpaid")
            edits.append { $0.setPaid(paid) }
        }
        if let autoPay = Self.yesNo(autoPay), autoPay != bill.autoPay {
            details.append("Autopay: \(autoPay ? "on" : "off")")
            edits.append { $0.autoPay = autoPay }
        }

        guard !details.isEmpty else { return "\(key) already looks like that; there's nothing to change." }
        return stage(Change(ref: key, title: label, detail: details.joined(separator: "; "), isDelete: false) {
            if !bill.isDeleted { edits.forEach { $0(bill) } }
        })
    }

    private func stage(_ change: Change) -> String {
        // A second proposal for the same record replaces the first.
        pending.removeAll { $0.ref == change.ref }
        pending.append(change)
        return "Proposed for \(change.ref) (\(change.title)): \(change.detail). The user sees it with an Apply button; nothing changes until they tap it."
    }

    /// The fixes proposed since the last call, for the answer that proposed them.
    func takePending() -> [Change] {
        defer { pending = [] }
        return pending
    }

    // MARK: - Applying

    func apply(_ changes: [Change]) {
        guard let context, !changes.isEmpty else { return }
        changes.forEach { $0.apply() }
        try? context.save()
        WidgetSync.update(context)
        BillReminders.reschedule(context)
        refresh()
    }

    // MARK: - Parsing

    private func category(named name: String) -> Category? {
        let name = name.trimmingCharacters(in: .whitespaces)
        return categories.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func key(_ ref: String) -> String {
        ref.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func number(_ text: String) -> Double? {
        Double(text.filter { $0.isNumber || $0 == "." || $0 == "-" })
    }

    private static func yesNo(_ text: String) -> Bool? {
        switch text.lowercased().trimmingCharacters(in: .whitespaces) {
        case "yes", "true", "on", "paid": true
        case "no", "false", "off", "unpaid": false
        default: nil
        }
    }
}
