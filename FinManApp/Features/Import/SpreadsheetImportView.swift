import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Adds "import a budget spreadsheet": pick a file, read it on device, then review before anything is saved.
struct SpreadsheetImportModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(\.modelContext) private var context
    @State private var reading = false
    @State private var error: String?
    @State private var review: Review?

    struct Review: Identifiable {
        let id = UUID()
        let draft: BudgetImportDraft
        let fileName: String
    }

    static let types: [UTType] = [.commaSeparatedText, .tabSeparatedText, .plainText]
        + ["org.openxmlformats.spreadsheetml.sheet", "com.apple.iwork.numbers.sffnumbers"].compactMap { UTType($0) }

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: Self.types) { result in
                guard case .success(let url) = result else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    error = Spreadsheet.ReadError.unreadable.localizedDescription
                    return
                }
                load(data, fileName: url.lastPathComponent)
            }
            .overlay {
                if reading {
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text("Reading your spreadsheet…").font(.headline)
                        Text(BudgetImporter.isModelAvailable ? "On this iPhone, with Apple Intelligence if needed" : "On this iPhone")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: .rect(cornerRadius: 24, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.15))
                }
            }
            .sheet(item: $review) { SpreadsheetImportView(draft: $0.draft, fileName: $0.fileName) }
            .alert("Couldn't import that file", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
            #if DEBUG
            // `-importSheet <file>` imports that CSV or Excel file on launch.
            .task {
                let args = ProcessInfo.processInfo.arguments
                guard let i = args.firstIndex(of: "-importSheet"), i + 1 < args.count,
                      let data = FileManager.default.contents(atPath: args[i + 1]) else { return }
                load(data, fileName: (args[i + 1] as NSString).lastPathComponent)
            }
            #endif
    }

    private func load(_ data: Data, fileName: String) {
        let categories = ((try? context.fetch(FetchDescriptor<Category>())) ?? []).map(\.name)
        let fileExtension = (fileName as NSString).pathExtension
        reading = true
        Task {
            defer { reading = false }
            do {
                let draft = try await BudgetImporter.read(data: data, fileExtension: fileExtension, categories: categories)
                if draft.items.isEmpty && draft.transactions.isEmpty {
                    error = "No budget items or transactions were found. Check the file has a column of names and a column of amounts."
                } else {
                    review = Review(draft: draft, fileName: fileName)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

extension View {
    func spreadsheetImporter(isPresented: Binding<Bool>) -> some View {
        modifier(SpreadsheetImportModifier(isPresented: isPresented))
    }
}

/// Review what was read from a spreadsheet, adjust it, then import.
struct SpreadsheetImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query private var budgets: [Budget]
    @Query private var bills: [Bill]
    @Query private var transactions: [Transaction]
    @Query private var payslips: [Payslip]
    @AppStorage(ProfileKey.monthlyIncome) private var monthlyIncome = 0.0

    let fileName: String
    @State private var draft: BudgetImportDraft
    @State private var setIncome: Bool?
    @State private var importTransactions = true
    @State private var importActuals = false
    @State private var actualsDate = Date.now
    @State private var newCategoryFor: UUID?
    @State private var newCategoryName = ""

    private let currency = Locale.current.currency?.identifier ?? "USD"

    init(draft: BudgetImportDraft, fileName: String) {
        self.fileName = fileName
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                summarySection
                ForEach(BudgetImportDraft.Kind.allCases) { kind in
                    itemsSection(kind)
                }
                actualsSection
                transactionsSection
            }
            .navigationTitle("Import budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: save).bold().disabled(!hasAnythingToImport)
                }
            }
            #if DEBUG
            // `-importAutoSave` (with `-importSheet <file>`) imports without waiting for a tap, for screenshots.
            .task {
                if ProcessInfo.processInfo.arguments.contains("-importAutoSave") {
                    try? await Task.sleep(for: .seconds(1))
                    importActuals = false
                    save()
                }
            }
            #endif
            .alert("New category", isPresented: Binding(get: { newCategoryFor != nil }, set: { if !$0 { newCategoryFor = nil } })) {
                TextField("Name", text: $newCategoryName)
                Button("Add") {
                    let name = newCategoryName.trimmingCharacters(in: .whitespaces)
                    if let id = newCategoryFor, !name.isEmpty, let index = draft.items.firstIndex(where: { $0.id == id }) {
                        draft.items[index].category = name
                    }
                    newCategoryName = ""
                }
                Button("Cancel", role: .cancel) { newCategoryName = "" }
            }
        }
    }

    // MARK: Derived

    private var existingNames: [String] { categories.map(\.name) }
    private var newCategories: [String] {
        var seen = Set<String>()
        return draft.items.filter { $0.include && !$0.category.isEmpty && CategoryMatcher.existing($0.category, in: existingNames) == nil }
            .map(\.category)
            .filter { seen.insert($0.lowercased()).inserted }
    }
    private var categoryOptions: [String] {
        existingNames.filter { $0 != "Income" } + newCategories.filter { name in !existingNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
    }
    private var incomeTotal: Double { draft.items.filter { $0.include && $0.kind == .income }.reduce(0) { $0 + $1.monthlyAmount } }
    private var shouldSetIncome: Bool { setIncome ?? payslips.isEmpty }

    private var duplicateIDs: Set<UUID> {
        let calendar = Calendar.current
        let existing = Set(transactions.map { "\(calendar.startOfDay(for: $0.date).timeIntervalSince1970)|\(Int(($0.amount * 100).rounded()))|\($0.title.lowercased())" })
        return Set(draft.transactions.filter {
            existing.contains("\(calendar.startOfDay(for: $0.date).timeIntervalSince1970)|\(Int(($0.amount * 100).rounded()))|\($0.title.lowercased())")
        }.map(\.id))
    }
    private var withActuals: [BudgetImportDraft.Item] { draft.items.filter { $0.include && ($0.actual ?? 0) > 0 } }
    private var hasAnythingToImport: Bool {
        draft.items.contains(where: \.include) || (importTransactions && draft.transactions.count > duplicateIDs.count)
    }

    // MARK: Sections

    private var summarySection: some View {
        Section {
            Label(fileName, systemImage: "tablecells")
                .font(.subheadline.weight(.semibold))
            if !draft.skipped.isEmpty {
                DisclosureGroup("\(draft.skipped.count) row\(draft.skipped.count == 1 ? "" : "s") left out") {
                    ForEach(draft.skipped, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                .font(.subheadline)
            }
        } footer: {
            Text("\(draft.sheetCount) sheet\(draft.sheetCount == 1 ? "" : "s") read on this iPhone\(draft.usedModel ? " with help from Apple Intelligence" : ""). Check the categories and amounts, then import."
                 + (newCategories.isEmpty ? "" : " New categories: \(newCategories.joined(separator: ", ")).")
            )
        }
    }

    @ViewBuilder
    private func itemsSection(_ kind: BudgetImportDraft.Kind) -> some View {
        let items = draft.items.filter { $0.kind == kind }
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    ImportItemRow(item: binding(for: item.id), currency: currency, categoryOptions: categoryOptions,
                                  isNewCategory: CategoryMatcher.existing(item.category, in: existingNames) == nil,
                                  updatesExisting: updatesExisting(item)) {
                        newCategoryName = ""
                        newCategoryFor = item.id
                    }
                }
            } header: {
                HStack {
                    Text(kind == .budget ? "Budgets" : kind == .bill ? "Bills" : "Income")
                    Spacer()
                    Text("\(items.filter(\.include).count) of \(items.count)")
                }
            } footer: {
                if kind == .income, incomeTotal > 0 {
                    Toggle("Set my monthly income to \(incomeTotal.currency())", isOn: Binding(get: { shouldSetIncome }, set: { setIncome = $0 }))
                        .font(.footnote)
                        .tint(Theme.brand)
                } else if kind == .bill {
                    Text("Bills without a due day in the sheet are set to the 1st. Tap a bill's day to change it.")
                }
            }
        }
    }

    @ViewBuilder
    private var actualsSection: some View {
        if !withActuals.isEmpty {
            Section {
                Toggle("Add what's been spent so far", isOn: $importActuals)
                if importActuals {
                    DatePicker("Dated", selection: $actualsDate, displayedComponents: .date)
                }
            } footer: {
                Text("The sheet has actual amounts for \(withActuals.count) items (\(withActuals.reduce(0) { $0 + ($1.kind == .income ? 0 : $1.actual ?? 0) }.currency()) spent). Adding them creates one transaction per item so budgets start from where you are.")
            }
        }
    }

    @ViewBuilder
    private var transactionsSection: some View {
        if !draft.transactions.isEmpty {
            let duplicates = duplicateIDs
            let dates = draft.transactions.map(\.date)
            Section {
                Toggle("Import \(draft.transactions.count - duplicates.count) transactions", isOn: $importTransactions)
                ForEach(draft.transactions.prefix(12)) { entry in
                    HStack {
                        CategoryIcon(name: entry.category ?? entry.title, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title).font(.subheadline).lineLimit(1)
                            Text("\(entry.date.formatted(date: .abbreviated, time: .omitted)) · \(entry.category ?? "Uncategorized")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.amount.currency(showSign: entry.amount > 0)).font(.subheadline).monospacedDigit()
                            .foregroundStyle(entry.amount > 0 ? Theme.income : .primary)
                    }
                    .opacity(duplicates.contains(entry.id) || !importTransactions ? 0.4 : 1)
                }
                if draft.transactions.count > 12 {
                    Text("and \(draft.transactions.count - 12) more").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Transactions")
            } footer: {
                if let first = dates.min(), let last = dates.max() {
                    Text("\(first.formatted(date: .abbreviated, time: .omitted)) to \(last.formatted(date: .abbreviated, time: .omitted))."
                         + (duplicates.isEmpty ? "" : " \(duplicates.count) already in FinMan will be skipped.")
                         + " They aren't added to an account, so your balances don't change.")
                }
            }
        }
    }

    private func updatesExisting(_ item: BudgetImportDraft.Item) -> Bool {
        switch item.kind {
        case .budget: budgets.contains { $0.name.caseInsensitiveCompare(item.name) == .orderedSame }
        case .bill: bills.contains { $0.name.caseInsensitiveCompare(item.name) == .orderedSame }
        case .income: false
        }
    }

    private func binding(for id: UUID) -> Binding<BudgetImportDraft.Item> {
        Binding {
            draft.items.first { $0.id == id } ?? .init(kind: .budget, name: "", amount: 0)
        } set: { newValue in
            if let index = draft.items.firstIndex(where: { $0.id == id }) { draft.items[index] = newValue }
        }
    }

    // MARK: Save

    private func save() {
        var byName = Dictionary(categories.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var nextOrder = (categories.map(\.sortOrder).max() ?? 0) + 1
        func category(_ name: String?) -> Category? {
            guard let name, !name.isEmpty else { return nil }
            if let match = CategoryMatcher.existing(name, in: Array(byName.values.map(\.name))), let found = byName[match.lowercased()] { return found }
            let created = Category(name: name, sortOrder: nextOrder)
            created.isCustom = true
            nextOrder += 1
            context.insert(created)
            byName[name.lowercased()] = created
            return created
        }

        let calendar = Calendar.current
        for item in draft.items where item.include {
            switch item.kind {
            case .budget:
                let component: Calendar.Component = item.period == "WEEKLY" ? .weekOfYear : item.period == "YEARLY" ? .year : .month
                let start = calendar.dateInterval(of: component, for: .now)?.start ?? .now
                if let existing = budgets.first(where: { $0.name.caseInsensitiveCompare(item.name) == .orderedSame }) {
                    existing.amount = item.amount
                    existing.period = item.period
                    existing.category = category(item.category) ?? existing.category
                } else {
                    context.insert(Budget(name: item.name, amount: item.amount, category: category(item.category), period: item.period, startDate: start))
                }
            case .bill:
                let bill = bills.first { $0.name.caseInsensitiveCompare(item.name) == .orderedSame }
                    ?? { let new = Bill(name: item.name, amount: item.amount, dueDay: item.dueDay ?? 1); context.insert(new); return new }()
                bill.amount = item.amount
                if let day = item.dueDay { bill.dueDay = day }
                bill.category = category(item.category) ?? bill.category
                // The sheet already shows it paid in full this month.
                if let actual = item.actual, actual >= item.amount - 0.005 { bill.lastPaidDate = .now }
            case .income:
                break
            }
        }
        if shouldSetIncome, incomeTotal > 0 { monthlyIncome = (incomeTotal * 100).rounded() / 100 }

        if importTransactions {
            let duplicates = duplicateIDs
            for entry in draft.transactions where !duplicates.contains(entry.id) {
                context.insert(Transaction(title: entry.title, amount: entry.amount, date: entry.date, category: category(entry.category)))
            }
        }
        if importActuals {
            for item in withActuals {
                let amount = item.kind == .income ? item.actual ?? 0 : -(item.actual ?? 0)
                context.insert(Transaction(title: item.name, amount: amount, date: actualsDate,
                                           category: category(item.kind == .income ? "Income" : item.category)))
            }
        }
        try? context.save()
        state.celebrate()
        dismiss()
    }
}

private struct ImportItemRow: View {
    @Binding var item: BudgetImportDraft.Item
    let currency: String
    let categoryOptions: [String]
    let isNewCategory: Bool
    let updatesExisting: Bool
    var onNewCategory: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { item.include.toggle() } label: {
                Image(systemName: item.include ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.include ? Theme.brand : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.include ? "Included" : "Left out")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Name", text: $item.name).font(.subheadline.weight(.semibold))
                    TextField("Amount", value: $item.amount, format: .currency(code: currency))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(maxWidth: 110)
                }
                HStack(spacing: 8) {
                    if item.kind != .income { categoryMenu }
                    switch item.kind {
                    case .budget:
                        Menu {
                            Picker("Period", selection: $item.period) {
                                Text("Weekly").tag("WEEKLY")
                                Text("Monthly").tag("MONTHLY")
                                Text("Yearly").tag("YEARLY")
                            }
                        } label: { chip(item.period.capitalized, symbol: "calendar") }
                    case .bill:
                        Menu {
                            Picker("Due day", selection: Binding(get: { item.dueDay ?? 1 }, set: { item.dueDay = $0 })) {
                                ForEach(1...31, id: \.self) { Text("Day \($0)").tag($0) }
                            }
                        } label: { chip("Due day \(item.dueDay ?? 1)", symbol: "calendar.badge.clock") }
                    case .income:
                        EmptyView()
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Picker("Import as", selection: $item.kind) {
                            ForEach(BudgetImportDraft.Kind.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Import as")
                }
                if updatesExisting || (isNewCategory && item.kind != .income && !item.category.isEmpty) {
                    Text(updatesExisting ? "Updates your existing \(item.kind == .bill ? "bill" : "budget") with this name" : "Creates the category “\(item.category)”")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .opacity(item.include ? 1 : 0.45)
        }
        .padding(.vertical, 2)
    }

    private var categoryMenu: some View {
        Menu {
            Picker("Category", selection: $item.category) {
                ForEach(categoryOptions, id: \.self) { Text("\(CategoryStyle.forName($0).emoji) \($0)").tag($0) }
            }
            Button { onNewCategory() } label: { Label("New category…", systemImage: "plus") }
        } label: {
            chip(item.category.isEmpty ? "No category" : item.category, symbol: CategoryStyle.forName(item.category).symbol)
        }
    }

    private func chip(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(.tertiarySystemFill), in: .capsule)
            .foregroundStyle(.primary)
    }
}
