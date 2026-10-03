import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var income: Double?
    @State private var payday = 1
    @State private var savingIncome = false
    @State private var incomeMessage: String?
    @State private var showServer = false
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Text(model.user?.initials ?? "?")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(Theme.brandGradient, in: .circle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(model.user?.firstName ?? "") \(model.user?.lastName ?? "")").font(.headline)
                            Text(model.user?.email ?? "").font(.subheadline).foregroundStyle(.secondary)
                            if model.user?.isDemo == true {
                                Text("Demo account").font(.caption.bold()).foregroundStyle(Theme.brand)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    TextField("Monthly income", value: $income, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                        .keyboardType(.decimalPad)
                    Stepper("Payday: day \(payday)", value: $payday, in: 1...31)
                    Button {
                        Task { await saveIncome() }
                    } label: {
                        HStack {
                            Text("Save income")
                            if savingIncome { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(income == nil || savingIncome)
                } header: {
                    Text("Income")
                } footer: {
                    if let incomeMessage { Text(incomeMessage) } else {
                        Text("Used to work out how much is left after bills and your health score.")
                    }
                }

                Section("Accounts") {
                    if model.accounts.isEmpty {
                        Text("No linked accounts").foregroundStyle(.secondary)
                    }
                    ForEach(model.accounts) { account in
                        HStack {
                            Image(systemName: "building.columns.fill").foregroundStyle(Theme.brand)
                            VStack(alignment: .leading) {
                                Text(account.name)
                                if let inst = account.institutionName ?? account.type {
                                    Text(inst).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(account.balance.currency()).monospacedDigit()
                        }
                    }
                }

                Section("App") {
                    Button { showServer = true } label: {
                        LabeledContent("Server", value: model.api.baseURL)
                    }
                    .foregroundStyle(.primary)
                }

                Section {
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showServer) { ServerSettingsSheet() }
            .confirmationDialog("Sign out of FinMan?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    dismiss()
                    model.signOut()
                }
            }
            .onAppear {
                income = model.user?.monthlyIncome?.doubleValue
                payday = model.user?.paydayDay ?? 1
            }
        }
    }

    private func saveIncome() async {
        guard let income else { return }
        savingIncome = true
        defer { savingIncome = false }
        do {
            try await model.updateIncome(Decimal(income), payday: payday)
            incomeMessage = "Saved ✅"
        } catch {
            incomeMessage = error.localizedDescription
        }
    }
}
