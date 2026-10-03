import Foundation
import SwiftUI

/// Single source of truth for the signed-in session and the user's financial data.
@Observable
final class AppModel {
    enum Phase { case launching, signedOut, signedIn }

    let api = APIClient()
    private(set) var phase: Phase = .launching
    private(set) var user: User?

    var accounts: [Account] = []
    var transactions: [Transaction] = []
    var categories: [Category] = []
    var budgets: [Budget] = []
    var budgetSpending: [Int: BudgetSpending] = [:]
    var bills: [Bill] = []
    var billsVsIncome: BillsVsIncome?

    var isLoading = false
    var lastError: String?
    /// Bumped to fire celebratory UI (confetti) from anywhere.
    var celebrationTrigger = 0

    private static let tokenKey = "jwt"

    init() {
        api.onUnauthorized = { [weak self] in self?.signOut() }
    }

    // MARK: - Session

    func restoreSession() async {
        guard let token = KeychainStore.get(Self.tokenKey) else {
            phase = .signedOut
            return
        }
        api.token = token
        do {
            user = try await api.get("/api/auth/whoami")
            phase = .signedIn
            await refreshAll()
        } catch {
            signOut()
        }
    }

    func login(email: String, password: String) async throws {
        let response: AuthResponse = try await api.post("/api/auth/login", body: LoginRequest(email: email, password: password))
        await start(response)
    }

    func register(email: String, password: String, firstName: String, lastName: String) async throws {
        let body = RegisterRequest(email: email, password: password, firstName: firstName, lastName: lastName)
        let response: AuthResponse = try await api.post("/api/auth/register", body: body)
        await start(response)
    }

    func demoLogin() async throws {
        let response: AuthResponse = try await api.send(
            "/api/auth/demo-login", method: "GET", body: nil as Empty?, headers: ["X-Demo-Request": "true"]
        )
        await start(response)
    }

    private func start(_ response: AuthResponse) async {
        KeychainStore.set(response.token, for: Self.tokenKey)
        api.token = response.token
        user = response.user
        withAnimation(.snappy) { phase = .signedIn }
        await refreshAll()
    }

    func signOut() {
        KeychainStore.set(nil, for: Self.tokenKey)
        api.token = nil
        user = nil
        accounts = []; transactions = []; budgets = []; budgetSpending = [:]; bills = []; billsVsIncome = nil
        withAnimation(.snappy) { phase = .signedOut }
    }

    // MARK: - Loading

    func refreshAll() async {
        isLoading = true
        defer { isLoading = false }
        async let a: Void = loadAccounts()
        async let t: Void = loadTransactions()
        async let c: Void = loadCategories()
        async let b: Void = loadBudgets()
        async let bl: Void = loadBills()
        async let i: Void = loadBillsVsIncome()
        _ = await (a, t, c, b, bl, i)
    }

    func loadAccounts() async {
        await capture { self.accounts = try await self.api.get("/api/accounts") }
    }

    /// Loads ~6 months of history so insights and trends have something to chew on.
    func loadTransactions() async {
        let end = Date.now
        let start = Calendar.current.date(byAdding: .month, value: -6, to: end) ?? end
        await capture {
            let list: [Transaction] = try await self.api.get("/api/transactions", query: [
                "startDate": DateParsing.localDateString(start),
                "endDate": DateParsing.localDateString(end),
            ])
            self.transactions = list.sorted { $0.date > $1.date }
        }
    }

    func loadCategories() async {
        await capture {
            let list: [Category] = try await self.api.get("/api/categories")
            self.categories = list.sorted { $0.name < $1.name }
        }
    }

    func loadBudgets() async {
        await capture {
            let list: [Budget] = try await self.api.get("/api/budgets")
            self.budgets = list
            // Fetch each budget's spending concurrently.
            let tasks = list.map { budget in
                (budget.id, Task { try? await self.api.get("/api/budgets/\(budget.id)/spending") as BudgetSpending })
            }
            var spending: [Int: BudgetSpending] = [:]
            for (id, task) in tasks { spending[id] = await task.value }
            self.budgetSpending = spending
        }
    }

    func loadBills() async {
        guard let userId = user?.id else { return }
        await capture {
            let list: [Bill] = try await self.api.get("/api/bills/user/\(userId)/simple")
            self.bills = list.sorted { $0.daysUntilDue() < $1.daysUntilDue() }
        }
    }

    func loadBillsVsIncome() async {
        // Optional insight; ignore failures quietly.
        billsVsIncome = try? await api.get("/api/insights/bills-vs-income")
    }

    // MARK: - Transactions

    func saveTransaction(id: Int?, request: TransactionRequest) async throws {
        if let id {
            let _: Transaction = try await api.put("/api/transactions/\(id)", body: request)
        } else {
            let _: Transaction = try await api.post("/api/transactions", body: request)
        }
        await loadTransactions()
        await loadAccounts()
        await loadBudgets()
    }

    func deleteTransaction(_ tx: Transaction) async throws {
        try await api.delete("/api/transactions/\(tx.id)")
        withAnimation { transactions.removeAll { $0.id == tx.id } }
        await loadBudgets()
    }

    func categorize(_ tx: Transaction, as category: Category) async throws {
        let updated: Transaction = try await api.post("/api/transactions/categorize/\(tx.id)", body: ["categoryId": category.id])
        if let i = transactions.firstIndex(where: { $0.id == tx.id }) {
            var copy = updated
            if copy.category == nil { copy.category = category }
            transactions[i] = copy
        }
        await loadBudgets()
    }

    // MARK: - Budgets

    func saveBudget(id: Int?, request: BudgetRequest) async throws {
        if let id {
            let _: Budget = try await api.put("/api/budgets/\(id)", body: request)
        } else {
            let _: Budget = try await api.post("/api/budgets", body: request)
        }
        await loadBudgets()
    }

    func deleteBudget(_ budget: Budget) async throws {
        try await api.delete("/api/budgets/\(budget.id)")
        withAnimation { budgets.removeAll { $0.id == budget.id } }
    }

    // MARK: - Bills

    func saveBill(id: Int?, request: BillRequest) async throws {
        guard let userId = user?.id else { return }
        if let id {
            let _: Empty = try await api.send("/api/bills/\(id)", method: "PUT", body: request)
        } else {
            let _: Empty = try await api.send("/api/bills", method: "POST", query: ["userId": "\(userId)"], body: request)
        }
        await loadBills()
        await loadBillsVsIncome()
    }

    func togglePaid(_ bill: Bill) async throws {
        let action = bill.isPaid ? "unpay" : "pay"
        let _: Empty = try await api.patch("/api/bills/\(bill.id)/\(action)", body: nil as Empty?)
        if let i = bills.firstIndex(where: { $0.id == bill.id }) {
            withAnimation(.bouncy) { bills[i].isPaid.toggle() }
        }
        if !bill.isPaid { celebrationTrigger += 1 }
        await loadBillsVsIncome()
    }

    func deleteBill(_ bill: Bill) async throws {
        try await api.delete("/api/bills/\(bill.id)")
        withAnimation { bills.removeAll { $0.id == bill.id } }
        await loadBillsVsIncome()
    }

    // MARK: - Profile

    func updateIncome(_ income: Decimal, payday: Int) async throws {
        // This endpoint resolves the principal as `UserDetails` while the JWT filter sets a String,
        // so it can 401 even with a valid token; don't treat that as session expiry.
        do {
            let _: Empty = try await api.send("/api/users/income", method: "PATCH",
                                              body: IncomeRequest(monthlyIncome: income, paydayDay: payday),
                                              signOutOnUnauthorized: false)
        } catch APIError.unauthorized {
            throw APIError.server(status: 401, message: "The server couldn't save your income (backend /api/users/income auth issue).")
        }
        user?.monthlyIncome = income
        user?.paydayDay = payday
        await loadBillsVsIncome()
    }

    // MARK: - Helpers

    private func capture(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch APIError.unauthorized {
            // handled by onUnauthorized
        } catch {
            lastError = error.localizedDescription
        }
    }
}
