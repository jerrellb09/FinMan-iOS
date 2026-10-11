import SwiftData
import SwiftUI

/// Connect banks through Teller, see what's linked, sync and disconnect.
struct BanksView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var state
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    @State private var links = BankLinkStore.all()
    @State private var errors = BankSync.errors
    @State private var connecting: ConnectRequest?
    @State private var disconnecting: BankLink?
    @State private var isSyncing = false

    /// A Teller Connect session: a new bank, or repairing an existing enrollment.
    struct ConnectRequest: Identifiable {
        var enrollmentID: String?
        var id: String { enrollmentID ?? "new" }
    }

    var body: some View {
        Form {
            if let config = TellerConfig.shared {
                if links.isEmpty {
                    Section {
                        EmptyStateView(emoji: "🏦", title: "No banks linked",
                                       message: "Connect your bank to bring in balances and transactions automatically.",
                                       actionTitle: "Connect a bank") { connecting = ConnectRequest() }
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                }
                ForEach(links) { link in
                    section(for: link)
                }
                if !links.isEmpty {
                    Section {
                        Button { connecting = ConnectRequest() } label: { Label("Connect another bank", systemImage: "plus") }
                    } footer: {
                        Text(BankSync.lastSync.map { "Last synced \($0.formatted(.relative(presentation: .named)))." } ?? "")
                    }
                }
                Section {
                } footer: {
                    Text(footer(config))
                }
            } else {
                Section {
                    EmptyStateView(emoji: "🔌", title: "Not set up",
                                   message: "This build has no Teller credentials. Add Secrets/Teller.plist and Secrets/teller.p12 (see the README), then rebuild.")
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("Linked banks")
        .toolbar {
            if !links.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    if isSyncing { ProgressView() } else {
                        Button { Task { await syncAll() } } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Sync now")
                    }
                }
            }
        }
        .refreshable { await syncAll() }
        .onAppear(perform: reload)
        .sheet(item: $connecting) { request in
            if let config = TellerConfig.shared {
                TellerConnectView(config: config, enrollmentID: request.enrollmentID) { link in
                    connecting = nil
                    Task { await connect(link) }
                } onExit: { message in
                    connecting = nil
                    if let message { state.lastError = message }
                }
                .ignoresSafeArea(edges: .bottom)
                .presentationDragIndicator(.visible)
            }
        }
        .confirmationDialog("Disconnect \(disconnecting?.institution ?? "bank")?", isPresented: Binding(
            get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }
        ), titleVisibility: .visible, presenting: disconnecting) { link in
            Button("Disconnect, keep history") { Task { await disconnect(link, deleteData: false) } }
            Button("Disconnect and delete its data", role: .destructive) { Task { await disconnect(link, deleteData: true) } }
        } message: { _ in
            Text("Keeping history turns its accounts into manual ones that no longer update.")
        }
        .overlay {
            if isSyncing && !accounts.contains(where: \.isLinked) {
                ProgressView("Bringing in your accounts…").padding().background(.regularMaterial, in: .rect(cornerRadius: 16))
            }
        }
    }

    private func section(for link: BankLink) -> some View {
        Section {
            ForEach(accounts.filter { $0.enrollmentID == link.id }) { account in
                HStack {
                    Image(systemName: account.symbol).foregroundStyle(Theme.brand).frame(width: 24)
                    VStack(alignment: .leading) {
                        Text(account.name)
                        Text([account.kind.capitalized, account.lastFour.map { "••\($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(account.balance.currency()).monospacedDigit()
                }
            }
            if let error = errors[link.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
                Button { connecting = ConnectRequest(enrollmentID: link.id) } label: {
                    Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            Button(role: .destructive) { disconnecting = link } label: {
                Label("Disconnect", systemImage: "link.badge.minus")
            }
        } header: {
            Text(link.institution)
        }
    }

    private func footer(_ config: TellerConfig) -> String {
        var text = "Connections go through Teller. Your bank login is entered with Teller and your bank, never stored by FinMan; the access token stays in this iPhone's Keychain."
        if config.isSandbox {
            text += "\n\nSandbox mode: pick any bank and sign in with username \"username\" and password \"password\" to get test data."
        } else if !config.hasCertificate {
            text += "\n\nThe Teller certificate is missing, so syncing will fail. Add Secrets/teller.p12 and rebuild."
        }
        return text
    }

    private func connect(_ link: BankLink) async {
        isSyncing = true
        defer { isSyncing = false; reload() }
        do {
            try await BankSync.connect(link, context: context)
            state.celebrate()
        } catch {
            state.lastError = "Linked \(link.institution), but the first sync failed: \(error.localizedDescription)"
        }
    }

    private func syncAll() async {
        isSyncing = true
        defer { isSyncing = false; reload() }
        let failures = await BankSync.syncAll(context: context)
        if !failures.isEmpty { state.lastError = failures.joined(separator: "\n") }
    }

    private func disconnect(_ link: BankLink, deleteData: Bool) async {
        await BankSync.disconnect(link, deleteData: deleteData, context: context)
        reload()
    }

    private func reload() {
        links = BankLinkStore.all().sorted { $0.connectedAt < $1.connectedAt }
        errors = BankSync.errors
    }
}
