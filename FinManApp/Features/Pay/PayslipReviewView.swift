import SwiftData
import SwiftUI

/// Check and correct what was read from a payslip (or enter one by hand) before saving it.
struct PayslipReviewView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ProfileKey.monthlyIncome) private var monthlyIncome = 0.0
    @AppStorage(ProfileKey.paydayDay) private var payday = 1

    /// The saved payslip being edited, or nil for a new one.
    let payslip: Payslip?
    @State private var draft: PayslipDraft
    @State private var useForIncome: Bool

    private let currency = Locale.current.currency?.identifier ?? "USD"

    init(draft: PayslipDraft, payslip: Payslip? = nil, isLatest: Bool) {
        self.payslip = payslip
        _draft = State(initialValue: draft)
        _useForIncome = State(initialValue: isLatest)
    }

    var body: some View {
        NavigationStack {
            Form {
                checkSection

                Section("Details") {
                    TextField("Employer", text: $draft.employer)
                    DatePicker("Pay date", selection: $draft.payDate, displayedComponents: .date)
                    Picker("Paid", selection: $draft.frequency) {
                        ForEach(PayFrequency.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section {
                    amountField("Gross pay", value: $draft.grossPay)
                    amountField("Net pay (take-home)", value: $draft.netPay)
                } header: {
                    Text("This paycheck")
                }

                ForEach(PayLineKind.allCases) { kind in
                    linesSection(kind)
                }

                Section {
                    Toggle("Use for my monthly income", isOn: $useForIncome)
                } footer: {
                    Text("Sets your income to \(draft.monthlyNet.currency()) a month (take-home × \(Int(draft.frequency.periodsPerYear)) ÷ 12) and your payday to day \(Calendar.current.component(.day, from: draft.payDate)).")
                }
            }
            .navigationTitle(payslip == nil ? "Review payslip" : "Edit payslip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).bold().disabled(draft.netPay <= 0 && draft.grossPay <= 0)
                }
            }
        }
    }

    // MARK: Sections

    private var checkSection: some View {
        Section {
            if draft.addsUp {
                Label("Everything adds up", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.income)
                    .font(.subheadline.weight(.semibold))
            } else {
                Label("Off by \(abs(draft.discrepancy).currency()). Check for a missing or misread line.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .font(.subheadline.weight(.semibold))
            }
            Text("\(draft.grossPay.currency()) gross − \(draft.total(.tax).currency()) taxes − \((draft.total(.preTax) + draft.total(.postTax)).currency()) deductions = \(draft.computedNet.currency())")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } footer: {
            if draft.source != .saved {
                Text("\(draft.source.label) on this iPhone. Only these numbers are saved, not the document.")
            }
        }
    }

    @ViewBuilder
    private func linesSection(_ kind: PayLineKind) -> some View {
        let lines = draft.lines.filter { $0.kind == kind }
        Section {
            ForEach(lines) { line in
                LineEditorRow(line: binding(for: line.id), currency: currency)
            }
            .onDelete { offsets in
                let ids = Set(offsets.map { lines[$0].id })
                draft.lines.removeAll { ids.contains($0.id) }
            }
            Button {
                draft.lines.append(.init(name: "", kind: kind, amount: 0))
            } label: {
                Label("Add line", systemImage: "plus")
            }
        } header: {
            HStack {
                Text(kind.title)
                Spacer()
                if !lines.isEmpty { Text(draft.total(kind).currency()).monospacedDigit() }
            }
        } footer: {
            if kind == .employer && !lines.isEmpty { Text("Paid on top of your salary, so these don't come out of your pay.") }
        }
    }

    private func amountField(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .currency(code: currency))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
    }

    private func binding(for id: UUID) -> Binding<PayslipDraft.Line> {
        Binding {
            draft.lines.first { $0.id == id } ?? .init(name: "", kind: .tax, amount: 0)
        } set: { newValue in
            if let index = draft.lines.firstIndex(where: { $0.id == id }) { draft.lines[index] = newValue }
        }
    }

    // MARK: Save

    private func save() {
        draft.lines.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty && $0.amount == 0 }
        let target = payslip ?? {
            let new = Payslip()
            context.insert(new)
            return new
        }()
        target.apply(draft)
        try? context.save()
        if useForIncome {
            monthlyIncome = (draft.monthlyNet * 100).rounded() / 100
            payday = Calendar.current.component(.day, from: draft.payDate)
        }
        dismiss()
    }
}

private struct LineEditorRow: View {
    @Binding var line: PayslipDraft.Line
    let currency: String

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Type", selection: $line.kind) {
                    ForEach(PayLineKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                if line.kind.reducesNet {
                    Toggle("Counts as savings", isOn: $line.isSavings)
                }
            } label: {
                Image(systemName: line.isSavings ? "banknote.fill" : line.kind.symbol)
                    .foregroundStyle(line.isSavings ? .green : Theme.brand)
                    .frame(width: 24)
            }
            .accessibilityLabel("Change type")
            TextField("Name", text: $line.name)
            TextField("Amount", value: $line.amount, format: .currency(code: currency))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(maxWidth: 120)
        }
    }
}
