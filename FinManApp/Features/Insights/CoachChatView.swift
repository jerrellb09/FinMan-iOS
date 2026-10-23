import SwiftData
import SwiftUI

/// Chat with the money coach about anything in your finances.
struct CoachChatView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var transactions: [Transaction]
    @Query private var budgets: [Budget]
    @Query private var bills: [Bill]
    @Query(sort: \Payslip.payDate, order: .reverse) private var payslips: [Payslip]
    @AppStorage(ProfileKey.name) private var name = ""
    @AppStorage(ProfileKey.monthlyIncome) private var monthlyIncome = 0.0

    /// Sent as soon as the chat opens (typed into the coach card).
    var initialQuestion: String?

    @State private var chat = CoachChat()
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private static let suggestions = [
        "How much did I spend on food last month?",
        "What are my biggest expenses this month?",
        "Can I afford a $500 purchase this month?",
        "Which subscriptions could I cut?",
    ]
    /// Only the on-device model can propose fixes.
    private static let fixSuggestion = "Find transactions in the wrong category and fix them"


    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.messages.isEmpty { intro }
                        ForEach(chat.messages) { message in
                            bubble(message).id(message.id)
                            if !message.changes.isEmpty { changesCard(message) }
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.messages.last?.text) {
                    if let last = chat.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: chat.messages.last?.changes.count) {
                    if let last = chat.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
                }
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle("Money coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { withAnimation { chat.reset() } } label: { Label("New chat", systemImage: "square.and.pencil") }
                        .disabled(chat.messages.isEmpty || chat.isResponding)
                }
            }
            .task {
                chat.configure(snapshot: Coach.Snapshot(name: name, monthlyIncome: monthlyIncome, analytics: Analytics(transactions: transactions),
                                                        budgets: budgets, bills: bills, payslip: payslips.first),
                               context: context)
                if let initialQuestion { await chat.send(initialQuestion) } else { inputFocused = true }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(chat.usesModel ? "Ask anything about your money" : "Ask about a merchant or category", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(Theme.brand)
            Text(chat.usesModel
                 ? "Answers use your transactions, bills and budgets, worked out by Apple Intelligence on this iPhone. Ask and I can fix transactions and bills too; you approve every change. Nothing leaves your phone."
                 : "Apple Intelligence isn't available, so I can total up a merchant or category you name. Nothing leaves your phone.")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(Self.suggestions + (chat.usesModel ? [Self.fixSuggestion] : []), id: \.self) { suggestion in
                Button { Task { await chat.send(suggestion) } } label: {
                    Text(suggestion)
                        .font(.subheadline)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func bubble(_ message: CoachChat.Message) -> some View {
        switch message.role {
        case .user:
            Text(verbatim: message.text)
                .font(.subheadline)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(Theme.brand, in: .rect(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
        case .coach:
            Group {
                if message.text.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Thinking…").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    Text(LocalizedStringKey(message.text))
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 32)
        }
    }

    /// The fixes the coach proposed in one answer, with buttons to apply or dismiss them.
    private func changesCard(_ message: CoachChat.Message) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message.changes.count == 1 ? "1 suggested change" : "\(message.changes.count) suggested changes", systemImage: "wand.and.stars")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.brand)
            ForEach(message.changes) { change in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: change.title).font(.subheadline)
                    Text(verbatim: change.detail)
                        .font(.caption)
                        .foregroundStyle(change.isDelete ? Theme.expense : .secondary)
                }
            }
            switch message.changesState {
            case .pending:
                HStack {
                    Button { withAnimation { chat.applyChanges(in: message.id) } } label: {
                        Text(message.changes.count == 1 ? "Apply" : "Apply all").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { withAnimation { chat.dismissChanges(in: message.id) } } label: {
                        Text("Dismiss").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(chat.isResponding)
            case .applied:
                Label("Applied", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(Theme.income)
            case .dismissed:
                Label("Dismissed, nothing changed", systemImage: "xmark.circle").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 32)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask the coach…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isResponding)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let question = draft
        draft = ""
        Task { await chat.send(question) }
    }
}
