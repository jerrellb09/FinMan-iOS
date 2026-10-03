import SwiftData
import SwiftUI

/// Calculator-style editor for adding or editing a manual transaction.
struct TransactionEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    let transaction: Transaction?

    @State private var isIncome: Bool
    @State private var amountText: String
    @State private var description: String
    @State private var date: Date
    @State private var note: String
    @State private var category: Category?
    @State private var account: Account?
    @State private var keyTap = 0
    @State private var saved = 0

    init(transaction: Transaction?, startAsIncome: Bool = false) {
        self.transaction = transaction
        let amount = transaction.map { abs($0.amount) }
        _isIncome = State(initialValue: transaction.map { $0.amount > 0 } ?? startAsIncome)
        _amountText = State(initialValue: amount.map { String(format: "%g", $0) } ?? "")
        _description = State(initialValue: transaction?.title ?? "")
        _date = State(initialValue: transaction?.date ?? .now)
        _note = State(initialValue: transaction?.note ?? "")
        _category = State(initialValue: transaction?.category)
        _account = State(initialValue: transaction?.account)
    }

    private var amount: Double { Double(amountText) ?? 0 }
    private var canSave: Bool { amount > 0 && !description.trimmingCharacters(in: .whitespaces).isEmpty }
    private var resolvedAccount: Account? { account ?? accounts.first }
    private var accent: Color { isIncome ? Theme.income : Theme.expense }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker("Type", selection: $isIncome.animation(.snappy)) {
                        Text("Expense").tag(false)
                        Text("Income").tag(true)
                    }
                    .pickerStyle(.segmented)

                    amountDisplay

                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: "text.cursor").foregroundStyle(.secondary).frame(width: 24)
                            TextField(isIncome ? "Where's it from?" : "What was it for?", text: $description)
                                .submitLabel(.done)
                        }
                        .padding(.vertical, 14)
                        Divider()
                        HStack {
                            Image(systemName: "calendar").foregroundStyle(.secondary).frame(width: 24)
                            DatePicker("Date", selection: $date, in: ...Date.now.addingTimeInterval(86_400 * 365))
                        }
                        .padding(.vertical, 8)
                        if accounts.count > 1 {
                            Divider()
                            HStack {
                                Image(systemName: "building.columns").foregroundStyle(.secondary).frame(width: 24)
                                Picker("Account", selection: Binding(get: { resolvedAccount }, set: { account = $0 })) {
                                    ForEach(accounts) { Text($0.name).tag(Optional($0)) }
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        Divider()
                        HStack {
                            Image(systemName: "note.text").foregroundStyle(.secondary).frame(width: 24)
                            TextField("Note (optional)", text: $note)
                        }
                        .padding(.vertical, 14)
                    }
                    .padding(.horizontal, 16)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))

                    categoryStrip

                    keypad
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(transaction == nil ? "New transaction" : "Edit transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).bold().disabled(!canSave)
                }
            }
            .onChange(of: isIncome, initial: true) { _, income in
                // Default new income to the Income category; drop it if switching back to an expense.
                guard transaction == nil else { return }
                if income, category == nil { category = categories.first(where: \.isIncome) }
                if !income, category?.isIncome == true { category = nil }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: keyTap)
            .sensoryFeedback(.success, trigger: saved)
        }
    }

    private var amountDisplay: some View {
        VStack(spacing: 4) {
            Text(amountText.isEmpty ? "0" : amountText)
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(amountText.isEmpty ? .tertiary : .primary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(isIncome ? "money in 💰" : "money out 💸")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(categories.filter { isIncome || !$0.isIncome }) { category in
                    let selected = self.category?.id == category.id
                    Button {
                        withAnimation(.snappy) { self.category = selected ? nil : category }
                        keyTap += 1
                    } label: {
                        VStack(spacing: 6) {
                            CategoryIcon(name: category.name, size: 44)
                                .scaleEffect(selected ? 1.1 : 1)
                            Text(category.name).font(.caption2.weight(.semibold)).lineLimit(1)
                        }
                        .frame(width: 72)
                        .padding(.vertical, 8)
                        .background(selected ? CategoryStyle.forName(category.name).color.opacity(0.15) : .clear,
                                    in: .rect(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var keypad: some View {
        let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "0", "⌫"]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(keys, id: \.self) { key in
                Button { press(key) } label: {
                    Group {
                        if key == "⌫" { Image(systemName: "delete.left") } else { Text(key) }
                    }
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .foregroundStyle(.primary)
            }
        }
    }

    private func press(_ key: String) {
        keyTap += 1
        withAnimation(.snappy(duration: 0.15)) {
            switch key {
            case "⌫": if !amountText.isEmpty { amountText.removeLast() }
            case ".": if !amountText.contains(".") { amountText += amountText.isEmpty ? "0." : "." }
            default:
                if let dot = amountText.firstIndex(of: "."), amountText.distance(from: dot, to: amountText.endIndex) > 2 { return }
                if amountText == "0" { amountText = key } else if amountText.count < 9 { amountText += key }
            }
        }
    }

    private func save() {
        let title = description.trimmingCharacters(in: .whitespaces)
        let signed = isIncome ? amount : -amount
        if let transaction {
            transaction.title = title
            transaction.amount = signed
            transaction.date = date
            transaction.note = note
            transaction.category = category
            transaction.account = resolvedAccount
        } else {
            let tx = Transaction(title: title, amount: signed, date: date, category: category, account: resolvedAccount)
            tx.note = note
            context.insert(tx)
        }
        try? context.save()
        saved += 1
        if isIncome && transaction == nil { state.celebrate() }
        dismiss()
    }
}
