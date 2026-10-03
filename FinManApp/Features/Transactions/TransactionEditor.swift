import SwiftUI

/// Calculator-style editor for adding or editing a manual transaction.
struct TransactionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let transaction: Transaction?

    @State private var isIncome: Bool
    @State private var amountText: String
    @State private var description: String
    @State private var date: Date
    @State private var categoryId: Int?
    @State private var accountId: Int?
    @State private var isSaving = false
    @State private var error: String?
    @State private var keyTap = 0
    @State private var saved = 0

    init(transaction: Transaction?, startAsIncome: Bool = false) {
        self.transaction = transaction
        let amount = transaction.map { abs($0.amount.doubleValue) }
        _isIncome = State(initialValue: transaction.map { $0.amount > 0 } ?? startAsIncome)
        _amountText = State(initialValue: amount.map { String(format: "%g", $0) } ?? "")
        _description = State(initialValue: transaction?.description ?? "")
        _date = State(initialValue: transaction?.date ?? .now)
        _categoryId = State(initialValue: transaction?.category?.id)
        _accountId = State(initialValue: transaction?.accountId)
    }

    private var amount: Decimal { Decimal(string: amountText) ?? 0 }
    private var canSave: Bool { amount > 0 && !description.trimmingCharacters(in: .whitespaces).isEmpty && (transaction != nil || resolvedAccountId != nil) }
    private var resolvedAccountId: Int? { accountId ?? model.accounts.first?.id }
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
                        if transaction == nil && model.accounts.count > 1 {
                            Divider()
                            HStack {
                                Image(systemName: "building.columns").foregroundStyle(.secondary).frame(width: 24)
                                Picker("Account", selection: Binding(get: { resolvedAccountId }, set: { accountId = $0 })) {
                                    ForEach(model.accounts) { Text($0.name).tag(Optional($0.id)) }
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))

                    categoryStrip

                    keypad

                    if transaction == nil && model.accounts.isEmpty {
                        Label("You need a linked account before adding transactions.", systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle.fill").font(.footnote).foregroundStyle(Theme.expense)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(transaction == nil ? "New transaction" : "Edit transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if isSaving { ProgressView() } else { Text("Save").bold() }
                    }
                    .disabled(!canSave || isSaving)
                }
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
                ForEach(model.categories) { category in
                    let selected = categoryId == category.id
                    Button {
                        withAnimation(.snappy) { categoryId = selected ? nil : category.id }
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
        isSaving = true
        error = nil
        let request = TransactionRequest(
            accountId: transaction == nil ? resolvedAccountId : nil,
            description: description.trimmingCharacters(in: .whitespaces),
            amount: isIncome ? amount : -amount,
            date: DateParsing.localDateTimeString(date),
            categoryId: categoryId
        )
        Task {
            do {
                try await model.saveTransaction(id: transaction?.id, request: request)
                saved += 1
                if isIncome { model.celebrationTrigger += 1 }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }
}
