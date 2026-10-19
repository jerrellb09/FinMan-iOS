import SwiftData
import SwiftUI

/// Review transactions from an export (such as Rocket Money's) before saving: pick which accounts they go to,
/// and decide what to do with any that are already in FinMan.
struct TransactionImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    struct Duplicate {
        var strength: DuplicateFinder.Strength
        var title: String
        var date: Date
        var amount: Double
        var account: String?
    }

    /// Where a source account's transactions go.
    enum Destination: Hashable {
        case none, new, existing(PersistentIdentifier)
    }

    let export: TransactionExport
    let fileName: String
    /// Rows already in FinMan, by row id.
    let duplicates: [UUID: Duplicate]
    /// Rows that appear more than once in the file itself.
    let repeats: Set<UUID>

    /// Choices that differ from the default (duplicates skipped, everything else added).
    @State private var overrides: [UUID: Bool] = [:]
    @State private var includeIgnored = false
    @State private var destinations: [String: Destination] = [:]
    @State private var showAllNew = false

    init(export: TransactionExport, fileName: String, existing: [Transaction]) {
        self.export = export
        self.fileName = fileName
        let found = DuplicateFinder.matches(
            export.rows.map { .init(date: $0.date, amount: $0.amount, title: $0.title, externalID: $0.fingerprint) },
            against: existing.map { .init(date: $0.date, amount: $0.amount, title: $0.title, externalID: $0.externalID) })
        var duplicates: [UUID: Duplicate] = [:]
        for (index, match) in found {
            let tx = existing[match.existing]
            duplicates[export.rows[index].id] = Duplicate(strength: match.strength, title: tx.title, date: tx.date, amount: tx.amount, account: tx.account?.name)
        }
        self.duplicates = duplicates
        // Each repeat after the first, so the first copy reads as new and the others as possible doubles.
        var seen = Set<String>()
        self.repeats = Set(export.rows.filter { row in
            !seen.insert("\(DuplicateFinder.cents(row.amount))|\(Calendar.current.startOfDay(for: row.date))|\(DuplicateFinder.key(row.title))|\(row.accountKey)").inserted
        }.map(\.id))
    }

    // MARK: Derived

    private func isDuplicate(_ row: TransactionExport.Row) -> Bool { duplicates[row.id] != nil }

    private func defaultIncluded(_ row: TransactionExport.Row) -> Bool {
        if isDuplicate(row) { return false }
        if row.ignored { return includeIgnored }
        return true
    }

    private func included(_ row: TransactionExport.Row) -> Bool { overrides[row.id] ?? defaultIncluded(row) }

    private func includeBinding(_ row: TransactionExport.Row) -> Binding<Bool> {
        Binding { included(row) } set: { overrides[row.id] = $0 }
    }

    private var duplicateRows: [TransactionExport.Row] {
        export.rows.filter(isDuplicate).sorted { $0.date > $1.date }
    }
    private var repeatRows: [TransactionExport.Row] {
        export.rows.filter { repeats.contains($0.id) && !isDuplicate($0) && !$0.ignored }.sorted { $0.date > $1.date }
    }
    private var ignoredRows: [TransactionExport.Row] {
        export.rows.filter { $0.ignored && !isDuplicate($0) }
    }
    private var newRows: [TransactionExport.Row] {
        export.rows.filter { !isDuplicate($0) && !repeats.contains($0.id) && !$0.ignored }.sorted { $0.date > $1.date }
    }
    private var importCount: Int { export.rows.filter(included).count }

    private func destination(for account: TransactionExport.SourceAccount) -> Destination {
        if let chosen = destinations[account.key] { return chosen }
        let match = accounts.first { existing in
            (!account.lastFour.isEmpty && existing.lastFour == account.lastFour)
                || (!account.name.isEmpty && existing.name.caseInsensitiveCompare(account.name) == .orderedSame)
        }
        return match.map { .existing($0.persistentModelID) } ?? .none
    }

    private func accountTitle(_ key: String) -> String? {
        export.accounts.count > 1 ? export.accounts.first { $0.key == key }?.title : nil
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                summarySection
                accountsSection
                duplicatesSection
                repeatsSection
                ignoredSection
                newSection
            }
            .navigationTitle("Import transactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: save).bold().disabled(importCount == 0)
                }
            }
            #if DEBUG
            // `-importAutoSave` (with `-importSheet <file>`) imports without waiting for a tap, for screenshots.
            .task {
                if ProcessInfo.processInfo.arguments.contains("-importAutoSave") {
                    try? await Task.sleep(for: .seconds(1))
                    save()
                }
            }
            #endif
        }
    }

    private var summarySection: some View {
        Section {
            Label(fileName, systemImage: "doc.text")
                .font(.subheadline.weight(.semibold))
            LabeledContent("Transactions in file", value: "\(export.rows.count)")
            if !duplicates.isEmpty {
                LabeledContent("Already in FinMan", value: "\(duplicates.count)")
            }
            LabeledContent("Will be imported", value: "\(importCount)")
                .bold()
        } footer: {
            let dates = export.rows.map(\.date)
            if let first = dates.min(), let last = dates.max() {
                Text("\(export.source) export, \(first.formatted(date: .abbreviated, time: .omitted)) to \(last.formatted(date: .abbreviated, time: .omitted))."
                     + (export.skipped > 0 ? " \(export.skipped) row\(export.skipped == 1 ? "" : "s") without a date or amount were left out." : ""))
            }
        }
    }

    @ViewBuilder
    private var accountsSection: some View {
        if !export.accounts.isEmpty {
            Section {
                ForEach(export.accounts) { account in
                    Picker(selection: Binding(get: { destination(for: account) }, set: { destinations[account.key] = $0 })) {
                        Text("No account").tag(Destination.none)
                        ForEach(accounts) { Text($0.name).tag(Destination.existing($0.persistentModelID)) }
                        Text("New account").tag(Destination.new)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.title).font(.subheadline.weight(.semibold))
                            Text("\(export.rows.filter { $0.accountKey == account.key }.count) transactions")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Transactions added to an account change its balance. A new account is named after the one in the file and starts at $0; set its starting balance afterwards so the total matches your bank.")
            }
        }
    }

    @ViewBuilder
    private var duplicatesSection: some View {
        let rows = duplicateRows
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    ImportRow(row: row, account: accountTitle(row.accountKey), included: includeBinding(row)) {
                        if let match = duplicates[row.id] {
                            Label {
                                Text("\(match.strength == .exact ? "Same as" : "Looks like") “\(match.title)”, \(match.date.formatted(date: .abbreviated, time: .omitted))"
                                     + (match.account.map { " · \($0)" } ?? ""))
                            } icon: {
                                Image(systemName: match.strength == .exact ? "equal.circle.fill" : "questionmark.circle.fill")
                            }
                            .font(.caption2)
                            .foregroundStyle(match.strength == .exact ? Color.secondary : Theme.warning)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Already in FinMan")
                    Spacer()
                    Menu("Choose") {
                        Button("Skip all duplicates", systemImage: "minus.circle") { rows.forEach { overrides[$0.id] = false } }
                        Button("Add all anyway", systemImage: "plus.circle") { rows.forEach { overrides[$0.id] = true } }
                        Button("Add only the “looks like” ones", systemImage: "questionmark.circle") {
                            rows.forEach { overrides[$0.id] = duplicates[$0.id]?.strength == .likely }
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .textCase(nil)
                }
            } footer: {
                Text("These match transactions you already have, so they're skipped. “Looks like” means the same amount within \(DuplicateFinder.dayWindow) days under a similar name; tick any that are really separate purchases.")
            }
        }
    }

    @ViewBuilder
    private var repeatsSection: some View {
        let rows = repeatRows
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    ImportRow(row: row, account: accountTitle(row.accountKey), included: includeBinding(row)) { EmptyView() }
                }
            } header: {
                HStack {
                    Text("Listed twice in this file")
                    Spacer()
                    Menu("Choose") {
                        Button("Keep all", systemImage: "plus.circle") { rows.forEach { overrides[$0.id] = true } }
                        Button("Remove the extra copies", systemImage: "minus.circle") { rows.forEach { overrides[$0.id] = false } }
                    }
                    .font(.caption.weight(.semibold))
                    .textCase(nil)
                }
            } footer: {
                Text("Same day, amount and name as another row from the same account. That's usually two real purchases (two coffees), so they're kept; untick any that are true doubles. The first copy is imported either way.")
            }
        }
    }

    @ViewBuilder
    private var ignoredSection: some View {
        let rows = ignoredRows
        if !rows.isEmpty {
            Section {
                Toggle(rows.count == 1 ? "Include 1 transfer or payment" : "Include \(rows.count) transfers and payments", isOn: Binding(get: { includeIgnored }, set: { value in
                    includeIgnored = value
                    rows.forEach { overrides[$0.id] = nil }
                }))
                .tint(Theme.brand)
                if includeIgnored {
                    ForEach(rows.sorted { $0.date > $1.date }) { row in
                        ImportRow(row: row, account: accountTitle(row.accountKey), included: includeBinding(row)) { EmptyView() }
                    }
                }
            } footer: {
                Text("\(export.source) leaves these out of spending, usually moves between your own accounts and credit card payments. Importing them would count that money twice.")
            }
        }
    }

    @ViewBuilder
    private var newSection: some View {
        let rows = newRows
        if !rows.isEmpty {
            let shown = showAllNew ? rows : Array(rows.prefix(15))
            Section {
                ForEach(shown) { row in
                    ImportRow(row: row, account: accountTitle(row.accountKey), included: includeBinding(row)) { EmptyView() }
                }
                if rows.count > shown.count {
                    Button("Show all \(rows.count)") { showAllNew = true }.font(.subheadline)
                }
            } header: {
                Text("New")
            } footer: {
                let uncategorized = rows.filter { $0.category == nil }.count
                if uncategorized > 0 {
                    Text("\(uncategorized) have no matching category and will show as Uncategorized.")
                }
            }
        }
    }

    // MARK: Save

    private func save() {
        var byName = Dictionary(categories.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        func category(_ name: String?) -> Category? {
            guard let name, let match = CategoryMatcher.existing(name, in: Array(byName.values.map(\.name))) else { return nil }
            return byName[match.lowercased()]
        }
        // Defaults deleted by the user come back only if an imported transaction needs one.
        func ensureCategory(_ name: String?) -> Category? {
            guard let name, !name.isEmpty else { return nil }
            if let found = category(name) { return found }
            let created = Category(name: name, isIncome: name == "Income", sortOrder: (categories.map(\.sortOrder).max() ?? 0) + byName.count + 1)
            context.insert(created)
            byName[name.lowercased()] = created
            return created
        }

        var targets: [String: Account] = [:]
        for source in export.accounts {
            switch destination(for: source) {
            case .none: break
            case .existing(let id): targets[source.key] = accounts.first { $0.persistentModelID == id }
            case .new:
                let account = Account(name: source.name.isEmpty ? source.title : source.name, kind: source.kind)
                account.institution = source.institution.isEmpty ? nil : source.institution
                account.lastFour = source.lastFour.isEmpty ? nil : source.lastFour
                context.insert(account)
                targets[source.key] = account
            }
        }

        for row in export.rows where included(row) {
            let tx = Transaction(title: row.title, amount: row.amount, date: row.date, category: ensureCategory(row.category), account: targets[row.accountKey])
            tx.note = row.note
            tx.externalID = row.fingerprint
            context.insert(tx)
        }
        try? context.save()
        WidgetSync.update(context)
        state.celebrate()
        dismiss()
    }
}

private struct ImportRow<Detail: View>: View {
    let row: TransactionExport.Row
    let account: String?
    @Binding var included: Bool
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        Button { included.toggle() } label: {
            HStack(spacing: 12) {
                Image(systemName: included ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(included ? Theme.brand : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text([row.date.formatted(date: .abbreviated, time: .omitted), row.category ?? "Uncategorized", account].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    detail()
                }
                Spacer()
                Text(row.amount.currency(showSign: row.amount > 0))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(row.amount > 0 ? Theme.income : .primary)
            }
            .opacity(included ? 1 : 0.5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(included ? "Will be imported" : "Skipped")
    }
}
