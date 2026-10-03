import SwiftUI

struct TransactionsView: View {
    @Environment(AppModel.self) private var model

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", spending = "Spending", income = "Income"
        var id: Self { self }
    }

    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var categoryFilter: String?
    @State private var editing: Transaction?
    @State private var showNew = false
    @State private var categorizing: Transaction?
    @State private var deleteTrigger = 0

    private var filtered: [Transaction] {
        model.transactions.filter { tx in
            (filter == .all || (filter == .income ? tx.amount > 0 : tx.amount < 0))
            && (categoryFilter == nil || (tx.category?.name ?? "Uncategorized") == categoryFilter)
            && (search.isEmpty || tx.description.localizedCaseInsensitiveContains(search)
                || (tx.category?.name.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    private var grouped: [(day: Date, items: [Transaction])] {
        let cal = Calendar.current
        return Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
            .map { ($0.key, $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.0 > $1.0 }
    }

    private var categoryNames: [String] {
        Array(Set(model.transactions.map { $0.category?.name ?? "Uncategorized" })).sorted()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    filterBar
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                if filtered.isEmpty {
                    EmptyStateView(
                        emoji: search.isEmpty ? "🧾" : "🔍",
                        title: search.isEmpty ? "Nothing here yet" : "No matches",
                        message: search.isEmpty ? "Transactions from the last 6 months show up here." : "Try a different search or filter."
                    )
                    .listRowBackground(Color.clear)
                }

                ForEach(grouped, id: \.day) { group in
                    Section {
                        ForEach(group.items) { tx in
                            Button { if tx.isManualEntry { editing = tx } else { categorizing = tx } } label: {
                                TransactionRow(transaction: tx)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                if tx.isManualEntry {
                                    Button(role: .destructive) { delete(tx) } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button { categorizing = tx } label: { Label("Categorize", systemImage: "tag") }
                                    .tint(.purple)
                            }
                            .contextMenu {
                                Button { categorizing = tx } label: { Label("Change category", systemImage: "tag") }
                                if tx.isManualEntry {
                                    Button { editing = tx } label: { Label("Edit", systemImage: "pencil") }
                                    Button(role: .destructive) { delete(tx) } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(dayTitle(group.day))
                            Spacer()
                            let net = group.items.reduce(0) { $0 + $1.amount.doubleValue }
                            Text(net.currency(showSign: true)).monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Search transactions")
            .refreshable { await model.loadTransactions() }
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                        .accessibilityLabel("Add transaction")
                }
            }
            .sheet(isPresented: $showNew) { TransactionEditor(transaction: nil) }
            .sheet(item: $editing) { TransactionEditor(transaction: $0) }
            .sheet(item: $categorizing) { CategoryPickerSheet(transaction: $0) }
            .sensoryFeedback(.success, trigger: deleteTrigger)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { f in
                    chip(f.rawValue, selected: filter == f) { filter = f }
                }
                Divider().frame(height: 22)
                ForEach(categoryNames, id: \.self) { name in
                    chip("\(CategoryStyle.forName(name).emoji) \(name)", selected: categoryFilter == name) {
                        categoryFilter = categoryFilter == name ? nil : name
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(selected ? .white : .primary)
                .background(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: .capsule)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }

    private func delete(_ tx: Transaction) {
        Task {
            do {
                try await model.deleteTransaction(tx)
                deleteTrigger += 1
            } catch {
                model.lastError = error.localizedDescription
            }
        }
    }
}

struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(name: transaction.category?.name ?? (transaction.isIncome ? "Income" : nil))
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.description).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(transaction.category?.name ?? "Uncategorized")
                    if transaction.isManualEntry {
                        Image(systemName: "pencil.circle.fill").imageScale(.small)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            AmountText(amount: transaction.amount.doubleValue, font: .subheadline.weight(.semibold))
        }
        .contentShape(.rect)
    }
}

struct CategoryPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let transaction: Transaction

    @State private var picked = 0

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(transaction.description).font(.headline)
                        Spacer()
                        AmountText(amount: transaction.amount.doubleValue)
                    }
                    .card()

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.categories) { category in
                            let selected = transaction.category?.id == category.id
                            Button {
                                Task {
                                    do {
                                        try await model.categorize(transaction, as: category)
                                        picked += 1
                                        dismiss()
                                    } catch { model.lastError = error.localizedDescription }
                                }
                            } label: {
                                VStack(spacing: 8) {
                                    CategoryIcon(name: category.name, size: 44)
                                    Text(category.name).font(.caption.weight(.semibold)).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .strokeBorder(selected ? Theme.brand : .clear, lineWidth: 2)
                                }
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Pick a category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sensoryFeedback(.success, trigger: picked)
        }
        .presentationDetents([.medium, .large])
    }
}
