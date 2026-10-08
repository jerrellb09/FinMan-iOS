import SwiftData
import SwiftUI

/// Built-in categories plus your own, which can be added, renamed and deleted.
struct CategoriesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var editing: Category?
    @State private var adding = false
    @State private var name = ""

    private var custom: [Category] { categories.filter(\.isCustom) }

    var body: some View {
        List {
            Section {
                ForEach(custom) { category in
                    Button {
                        name = category.name
                        editing = category
                    } label: {
                        row(category)
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    offsets.map { custom[$0] }.forEach(context.delete)
                    try? context.save()
                }
                Button {
                    name = ""
                    adding = true
                } label: {
                    Label("Add category", systemImage: "plus")
                }
            } header: {
                Text("Your categories")
            } footer: {
                Text("Deleting a category keeps its transactions, budgets and bills; they just become uncategorized.")
            }

            Section("Built in") {
                ForEach(categories.filter { !$0.isCustom }) { row($0) }
            }
        }
        .navigationTitle("Categories")
        .alert("New category", isPresented: $adding) {
            TextField("Name", text: $name)
            Button("Add") { add() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename category", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Name", text: $name)
            Button("Save") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, !isTaken(trimmed, except: editing) { editing?.name = trimmed }
                try? context.save()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ category: Category) -> some View {
        HStack(spacing: 12) {
            CategoryIcon(name: category.name, size: 32)
            Text(category.name)
            Spacer()
            let count = category.transactions?.count ?? 0
            if count > 0 { Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
    }

    private func isTaken(_ name: String, except: Category? = nil) -> Bool {
        categories.contains { $0 !== except && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isTaken(trimmed) else { return }
        let category = Category(name: trimmed, sortOrder: (categories.map(\.sortOrder).max() ?? 0) + 1)
        category.isCustom = true
        context.insert(category)
        try? context.save()
    }
}
