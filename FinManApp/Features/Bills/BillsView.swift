import SwiftData
import SwiftUI

struct BillsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var state
    @Query private var allBills: [Bill]
    @AppStorage(ProfileKey.monthlyIncome) private var monthlyIncome = 0.0
    @State private var editing: Bill?
    @State private var showNew = false
    @State private var showPaid = true
    @State private var toggled = 0

    private var bills: [Bill] { allBills.sorted { $0.daysUntilDue() < $1.daysUntilDue() } }
    private var unpaid: [Bill] { bills.filter { !$0.isPaid } }
    private var paid: [Bill] { bills.filter(\.isPaid) }
    private var monthlyTotal: Double { bills.reduce(0) { $0 + $1.amount } }
    private var paidTotal: Double { paid.reduce(0) { $0 + $1.amount } }

    var body: some View {
        NavigationStack {
            List {
                if bills.isEmpty {
                    EmptyStateView(emoji: "📅", title: "No bills yet",
                                   message: "Add rent, subscriptions and utilities so you never miss a due date.",
                                   actionTitle: "Add a bill") { showNew = true }
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        summary
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }

                    if !unpaid.isEmpty {
                        Section("To pay · \(unpaid.reduce(0) { $0 + $1.amount }.currency())") {
                            ForEach(unpaid) { row($0) }
                        }
                    } else {
                        Section {
                            Text("🎉 Every bill is paid. You're a legend.")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                    }

                    if !paid.isEmpty {
                        Section(isExpanded: $showPaid) {
                            ForEach(paid) { row($0) }
                        } header: {
                            Text("Paid · \(paidTotal.currency())")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Bills")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                        .accessibilityLabel("Add bill")
                }
            }
            .sheet(isPresented: $showNew) { BillEditor(bill: nil) }
            .sheet(item: $editing) { BillEditor(bill: $0) }
            .sensoryFeedback(.success, trigger: toggled)
        }
    }

    private var summary: some View {
        let progress = monthlyTotal > 0 ? paidTotal / monthlyTotal : 0
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This month").font(.subheadline).foregroundStyle(.secondary)
                    Text(monthlyTotal.currency()).font(.system(.title, design: .rounded).bold()).monospacedDigit()
                }
                Spacer()
                Text("\(paid.count)/\(bills.count) paid").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.income)
            }
            ProgressCapsule(progress: progress, warning: 2, height: 12)
            if monthlyIncome > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.fill").foregroundStyle(Theme.brand)
                    Text("Bills are \(monthlyTotal / monthlyIncome, format: .percent.precision(.fractionLength(0))) of your income · \((monthlyIncome - monthlyTotal).currency()) left after bills")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private func row(_ bill: Bill) -> some View {
        BillRow(bill: bill) { toggle(bill) }
            .contentShape(.rect)
            .onTapGesture { editing = bill }
            .swipeActions(edge: .leading) {
                Button { toggle(bill) } label: {
                    Label(bill.isPaid ? "Unpay" : "Paid", systemImage: bill.isPaid ? "arrow.uturn.backward" : "checkmark")
                }
                .tint(bill.isPaid ? .gray : Theme.income)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    withAnimation { context.delete(bill) }
                    try? context.save()
                } label: { Label("Delete", systemImage: "trash") }
            }
    }

    private func toggle(_ bill: Bill) {
        let nowPaid = !bill.isPaid
        withAnimation(.bouncy) { bill.setPaid(nowPaid) }
        try? context.save()
        toggled += 1
        if nowPaid {
            state.celebrate()
            if unpaid.isEmpty { state.celebrate() }
        }
    }
}

struct BillRow: View {
    let bill: Bill
    var onToggle: () -> Void

    var body: some View {
        let days = bill.daysUntilDue()
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: bill.isPaid ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(bill.isPaid ? Theme.income : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(bill.isPaid ? "Mark unpaid" : "Mark paid")

            CategoryIcon(name: bill.category?.name ?? bill.name, size: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(bill.name).font(.subheadline.weight(.semibold))
                    .strikethrough(bill.isPaid, color: .secondary)
                    .foregroundStyle(bill.isPaid ? .secondary : .primary)
                Text(dueLabel(days)).font(.caption.weight(.medium)).foregroundStyle(dueColor(days))
            }
            Spacer()
            Text(bill.amount.currency()).font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(bill.isPaid ? .secondary : .primary)
        }
    }

    private func dueLabel(_ days: Int) -> String {
        if bill.isPaid { return "Paid · due the \(ordinal(bill.dueDay))" }
        switch days {
        case ..<0: return "Overdue by \(-days) day\(days == -1 ? "" : "s")"
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        default: return "Due in \(days) days · the \(ordinal(bill.dueDay))"
        }
    }

    private func dueColor(_ days: Int) -> Color {
        if bill.isPaid { return .secondary }
        return days < 0 ? Theme.expense : days <= 3 ? Theme.warning : .secondary
    }

    private func ordinal(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f.string(from: n as NSNumber) ?? "\(n)"
    }
}

struct BillEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    let bill: Bill?

    @State private var name = ""
    @State private var amount: Double?
    @State private var dueDay = 1
    @State private var isRecurring = true
    @State private var autoPay = false
    @State private var category: Category?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Netflix", text: $name)
                    TextField("Amount", value: $amount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                        .keyboardType(.decimalPad)
                    Picker("Category", selection: $category) {
                        Text("None").tag(Category?.none)
                        ForEach(categories.filter { !$0.isIncome }) { Text("\(CategoryStyle.forName($0.name).emoji) \($0.name)").tag(Optional($0)) }
                    }
                }
                Section("Due day") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                        ForEach(1...31, id: \.self) { day in
                            Button { dueDay = day } label: {
                                Text("\(day)")
                                    .font(.subheadline.weight(dueDay == day ? .bold : .regular))
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                    .foregroundStyle(dueDay == day ? .white : .primary)
                                    .background(dueDay == day ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.clear), in: .circle)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .sensoryFeedback(.selection, trigger: dueDay)
                    Toggle("Repeats monthly", isOn: $isRecurring)
                    Toggle("Autopay", isOn: $autoPay)
                }
            }
            .navigationTitle(bill == nil ? "New bill" : "Edit bill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).bold().disabled(name.isEmpty || (amount ?? 0) <= 0)
                }
            }
            .onAppear {
                guard let bill else { return }
                name = bill.name
                amount = bill.amount
                dueDay = bill.dueDay
                isRecurring = bill.isRecurring
                autoPay = bill.autoPay
                category = bill.category
            }
        }
    }

    private func save() {
        guard let amount else { return }
        let target = bill ?? Bill(name: name, amount: amount, dueDay: dueDay)
        target.name = name
        target.amount = amount
        target.dueDay = dueDay
        target.isRecurring = isRecurring
        target.autoPay = autoPay
        target.category = category
        if bill == nil { context.insert(target) }
        try? context.save()
        dismiss()
    }
}
