import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query private var transactions: [Transaction]

    @AppStorage(ProfileKey.name) private var name = ""
    @AppStorage(ProfileKey.monthlyIncome) private var monthlyIncome = 0.0
    @AppStorage(ProfileKey.paydayDay) private var payday = 1
    @AppStorage(ProfileKey.hasOnboarded) private var hasOnboarded = true
    @AppStorage(ProfileKey.faceIDEnabled) private var faceIDEnabled = false

    @State private var editingAccount: Account?
    @State private var showNewAccount = false
    @State private var confirmErase = false
    @State private var confirmSample = false
    @State private var exportURL: URL?

    private let currency = Locale.current.currency?.identifier ?? "USD"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Text(name.initials)
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(Theme.brandGradient, in: .circle)
                        TextField("Your name", text: $name)
                            .font(.headline)
                            .textContentType(.givenName)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    TextField("Monthly income", value: $monthlyIncome, format: .currency(code: currency))
                        .keyboardType(.decimalPad)
                    Stepper("Payday: day \(payday)", value: $payday, in: 1...31)
                } header: {
                    Text("Income")
                } footer: {
                    Text("Used to work out what's left after bills and for your health score.")
                }

                Section {
                    ForEach(accounts) { account in
                        Button { editingAccount = account } label: {
                            HStack {
                                Image(systemName: account.symbol).foregroundStyle(Theme.brand).frame(width: 24)
                                VStack(alignment: .leading) {
                                    Text(account.name)
                                    Text(account.kind.capitalized).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(account.balance.currency()).monospacedDigit()
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { offsets in
                        offsets.map { accounts[$0] }.forEach(context.delete)
                        try? context.save()
                    }
                    Button { showNewAccount = true } label: { Label("Add account", systemImage: "plus") }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Balances are your starting balance plus everything you've logged.")
                }

                Section("Security") {
                    Toggle(isOn: Binding(get: { faceIDEnabled }, set: { newValue in
                        Task {
                            // Confirm it's really you before turning the lock on or off.
                            if await Biometrics.authenticate(reason: newValue ? "Turn on app lock" : "Turn off app lock") {
                                faceIDEnabled = newValue
                            }
                        }
                    })) {
                        Label("Lock with Face ID", systemImage: "faceid")
                    }
                    .disabled(!Biometrics.isAvailable)
                }

                Section {
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("Export transactions (CSV)", systemImage: "square.and.arrow.up") }
                    }
                    Button { confirmSample = true } label: { Label("Add sample data", systemImage: "wand.and.stars") }
                    Button(role: .destructive) { confirmErase = true } label: { Label("Erase all data", systemImage: "trash") }
                } header: {
                    Text("Your data")
                } footer: {
                    Text("Everything is stored privately on this iPhone. \(transactions.count) transactions.")
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showNewAccount) { AccountEditor(account: nil) }
            .sheet(item: $editingAccount) { AccountEditor(account: $0) }
            .confirmationDialog("Add sample data?", isPresented: $confirmSample, titleVisibility: .visible) {
                Button("Add sample data") { DataStore.loadSampleData(context, monthlyIncome: max(monthlyIncome, 3_000), paydayDay: payday) }
            } message: {
                Text("Adds three months of example transactions, budgets and bills alongside your own.")
            }
            .confirmationDialog("Erase everything?", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Erase all data", role: .destructive) {
                    DataStore.eraseAll(context)
                    faceIDEnabled = false
                    dismiss()
                    hasOnboarded = false
                }
            } message: {
                Text("This permanently deletes all accounts, transactions, budgets and bills on this iPhone.")
            }
            .task(id: transactions.count) { exportURL = DataStore.exportCSV(transactions) }
        }
    }
}

struct AccountEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let account: Account?

    @State private var name = ""
    @State private var kind = "checking"
    @State private var startingBalance: Double?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name, e.g. Chase Checking", text: $name)
                Picker("Type", selection: $kind) {
                    Text("Checking").tag("checking")
                    Text("Savings").tag("savings")
                    Text("Credit card").tag("credit")
                    Text("Cash").tag("cash")
                }
                TextField("Starting balance", value: $startingBalance, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                    .keyboardType(.numbersAndPunctuation)
            }
            .navigationTitle(account == nil ? "New account" : "Edit account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let target = account ?? Account(name: name)
                        target.name = name
                        target.kind = kind
                        target.startingBalance = startingBalance ?? 0
                        if account == nil { context.insert(target) }
                        try? context.save()
                        dismiss()
                    }
                    .bold()
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard let account else { return }
                name = account.name
                kind = account.kind
                startingBalance = account.startingBalance
            }
        }
        .presentationDetents([.medium])
    }
}
