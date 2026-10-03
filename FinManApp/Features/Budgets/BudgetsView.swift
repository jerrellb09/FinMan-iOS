import SwiftUI

struct BudgetsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Budget?
    @State private var showNew = false
    @State private var pendingDelete: Budget?

    private var totalBudget: Double { model.budgets.reduce(0) { $0 + $1.amount.doubleValue } }
    private var totalSpent: Double { model.budgets.reduce(0) { $0 + (model.budgetSpending[$1.id]?.currentSpending.doubleValue ?? 0) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if model.budgets.isEmpty {
                        EmptyStateView(emoji: "🎯", title: "No budgets yet",
                                       message: "Set a spending goal for a category and we'll cheer you on as you stick to it.",
                                       actionTitle: "Create a budget") { showNew = true }
                            .card()
                    } else {
                        overview
                        LazyVStack(spacing: 14) {
                            ForEach(model.budgets) { budget in
                                Button { editing = budget } label: {
                                    BudgetCard(budget: budget, spending: model.budgetSpending[budget.id])
                                }
                                .buttonStyle(PressableStyle())
                                .contextMenu {
                                    Button { editing = budget } label: { Label("Edit", systemImage: "pencil") }
                                    Button(role: .destructive) { pendingDelete = budget } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .refreshable { await model.loadBudgets() }
            .navigationTitle("Budgets")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                        .accessibilityLabel("New budget")
                }
            }
            .sheet(isPresented: $showNew) { BudgetEditor(budget: nil) }
            .sheet(item: $editing) { BudgetEditor(budget: $0) }
            .confirmationDialog("Delete this budget?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { budget in
                Button("Delete \(budget.name)", role: .destructive) {
                    Task {
                        do { try await model.deleteBudget(budget) } catch { model.lastError = error.localizedDescription }
                    }
                }
            }
        }
    }

    private var overview: some View {
        let progress = totalBudget > 0 ? totalSpent / totalBudget : 0
        let onTrack = model.budgets.filter { (model.budgetSpending[$0.id]?.percentageUsed.doubleValue ?? 0) < 100 }.count
        return HStack(spacing: 20) {
            RingGauge(progress: progress, lineWidth: 14) {
                VStack(spacing: 0) {
                    Text(progress.formatted(.percent.precision(.fractionLength(0)))).font(.title2.bold()).monospacedDigit()
                    Text("used").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 110, height: 110)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(totalSpent.currency(compact: true)) of \(totalBudget.currency(compact: true))").font(.headline).monospacedDigit()
                Text("\(max(0, totalBudget - totalSpent).currency()) left to spend").font(.subheadline).foregroundStyle(.secondary)
                Text(onTrack == model.budgets.count ? "🏆 All budgets on track!" : "✅ \(onTrack) of \(model.budgets.count) on track")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.income.opacity(0.14), in: .capsule)
                    .foregroundStyle(Theme.income)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 20)
    }
}

struct BudgetCard: View {
    let budget: Budget
    let spending: BudgetSpending?

    var body: some View {
        let progress = (spending?.percentageUsed.doubleValue ?? 0) / 100
        let warning = budget.warningThreshold.doubleValue / 100
        let remaining = spending?.remaining.doubleValue ?? budget.amount.doubleValue
        let status: (String, Color) = progress >= 1 ? ("Over budget 😬", Theme.expense)
            : progress >= warning ? ("Getting close 👀", Theme.warning)
            : ("On track 🙌", Theme.income)

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CategoryIcon(name: budget.category?.name ?? budget.name, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(budget.name).font(.headline).foregroundStyle(.primary)
                    Text("\(budget.category?.name ?? "General") · \(budget.period.capitalized)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(status.0).font(.caption.weight(.bold)).foregroundStyle(status.1)
            }
            ProgressCapsule(progress: progress, warning: warning, height: 12)
            HStack {
                Text("\((spending?.currentSpending ?? 0).currency()) spent").foregroundStyle(.secondary)
                Spacer()
                Text(remaining >= 0 ? "\(remaining.currency()) left" : "\(abs(remaining).currency()) over")
                    .fontWeight(.semibold)
                    .foregroundStyle(remaining >= 0 ? Color.primary : Theme.expense)
            }
            .font(.subheadline)
            .monospacedDigit()
        }
        .card()
    }
}

struct BudgetEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let budget: Budget?

    @State private var name = ""
    @State private var amount: Double?
    @State private var categoryId: Int?
    @State private var period = "MONTHLY"
    @State private var startDate = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    @State private var hasEndDate = false
    @State private var endDate = Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now
    @State private var warning: Double = 80
    @State private var isSaving = false
    @State private var error: String?

    private var canSave: Bool { !name.isEmpty && (amount ?? 0) > 0 && categoryId != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Eating out", text: $name)
                    TextField("Amount", value: $amount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                        .keyboardType(.decimalPad)
                    Picker("Category", selection: $categoryId) {
                        Text("Choose…").tag(Int?.none)
                        ForEach(model.categories) { Text("\(CategoryStyle.forName($0.name).emoji) \($0.name)").tag(Optional($0.id)) }
                    }
                    .onChange(of: categoryId) { _, id in
                        if name.isEmpty, let c = model.categories.first(where: { $0.id == id }) { name = c.name }
                    }
                }
                Section("Timing") {
                    Picker("Period", selection: $period) {
                        Text("Weekly").tag("WEEKLY")
                        Text("Monthly").tag("MONTHLY")
                        Text("Yearly").tag("YEARLY")
                    }
                    DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                    Toggle("End date", isOn: $hasEndDate.animation())
                    if hasEndDate { DatePicker("Ends", selection: $endDate, in: startDate..., displayedComponents: .date) }
                }
                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Warn me at")
                            Spacer()
                            Text("\(Int(warning))%").monospacedDigit().foregroundStyle(Theme.warning).bold()
                        }
                        Slider(value: $warning, in: 50...100, step: 5)
                            .tint(Theme.warning)
                    }
                } footer: {
                    Text("We'll flag this budget once you've used this much of it.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(Theme.expense) }
                }
            }
            .navigationTitle(budget == nil ? "New budget" : "Edit budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).bold().disabled(!canSave || isSaving)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let budget else { return }
        name = budget.name
        amount = budget.amount.doubleValue
        categoryId = budget.category?.id
        period = budget.period.uppercased()
        if let s = budget.startDate { startDate = s }
        if let e = budget.endDate { hasEndDate = true; endDate = e }
        warning = budget.warningThreshold.doubleValue
    }

    private func save() {
        guard let categoryId, let amount else { return }
        isSaving = true
        let request = BudgetRequest(
            name: name, amount: Decimal(amount), categoryId: categoryId, period: period,
            startDate: DateParsing.localDateString(startDate),
            endDate: hasEndDate ? DateParsing.localDateString(endDate) : nil,
            warningThreshold: Decimal(warning)
        )
        Task {
            do {
                try await model.saveBudget(id: budget?.id, request: request)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }
}
