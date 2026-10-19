import SwiftData
import SwiftUI

/// Finds transactions recorded more than once and removes the extra copies the user picks.
struct DuplicatesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]

    @State private var groups: [[Transaction]] = []
    /// Transactions marked for removal.
    @State private var removing: Set<PersistentIdentifier> = []
    @State private var loaded = false
    @State private var removedTrigger = 0

    var body: some View {
        NavigationStack {
            List {
                if loaded && groups.isEmpty {
                    EmptyStateView(emoji: "✨", title: "No duplicates", message: "Every transaction appears once.", actionTitle: nil) {}
                        .listRowBackground(Color.clear)
                }
                ForEach(groups, id: \.first!.persistentModelID) { group in
                    Section {
                        ForEach(group) { tx in
                            let marked = removing.contains(tx.persistentModelID)
                            Button {
                                if marked { removing.remove(tx.persistentModelID) } else { removing.insert(tx.persistentModelID) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: marked ? "trash.circle.fill" : "checkmark.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(marked ? Theme.expense : Theme.income)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tx.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Text([tx.date.formatted(date: .abbreviated, time: .omitted), tx.category?.name ?? "Uncategorized", tx.account?.name, Self.origin(tx)]
                                            .compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    AmountText(amount: tx.amount, font: .subheadline.weight(.semibold))
                                }
                                .opacity(marked ? 0.5 : 1)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(marked ? "Will be removed" : "Kept")
                        }
                        Button("Not duplicates, keep all") {
                            group.forEach { removing.remove($0.persistentModelID) }
                        }
                        .font(.caption)
                    }
                }
            }
            .navigationTitle("Duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Remove \(removing.count)", role: .destructive, action: remove)
                        .bold()
                        .disabled(removing.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !groups.isEmpty {
                    Text("Same amount within \(DuplicateFinder.dayWindow) days under a similar name. One of each is kept; tap to change which.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal).padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
            .task { find() }
            .sensoryFeedback(.success, trigger: removedTrigger)
        }
    }

    private static func origin(_ tx: Transaction) -> String {
        guard let id = tx.externalID else { return "Added by hand" }
        return id.hasPrefix(TransactionImporter.fingerprintPrefix) ? "Imported" : "From bank"
    }

    private func find() {
        let items = transactions.map { DuplicateFinder.Item(date: $0.date, amount: $0.amount, title: $0.title, externalID: $0.externalID) }
        groups = DuplicateFinder.groups(in: items)
            .map { $0.map { transactions[$0] } }
            .sorted { ($0.first?.date ?? .distantPast) > ($1.first?.date ?? .distantPast) }
        // Keep the copy with the most behind it: bank-synced, then in an account, then categorized.
        removing = Set(groups.flatMap { group in
            let keeper = group.max { score($0) < score($1) }
            return group.filter { $0 !== keeper }.map(\.persistentModelID)
        })
        loaded = true
    }

    private func score(_ tx: Transaction) -> Int {
        var score = 0
        if let id = tx.externalID { score += id.hasPrefix(TransactionImporter.fingerprintPrefix) ? 2 : 8 }
        if tx.account != nil { score += 4 }
        if tx.category != nil { score += 1 }
        if !tx.isPending { score += 1 }
        return score
    }

    private func remove() {
        for tx in groups.joined() where removing.contains(tx.persistentModelID) {
            BankSync.hide(tx)
            context.delete(tx)
        }
        try? context.save()
        WidgetSync.update(context)
        withAnimation {
            groups = groups.map { $0.filter { !removing.contains($0.persistentModelID) } }.filter { $0.count > 1 }
        }
        removing = []
        removedTrigger += 1
    }
}
