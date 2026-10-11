import Foundation
import SwiftData

/// Pulls accounts, balances and transactions from Teller into the SwiftData store.
enum BankSync {
    private static let hiddenKey = "bank.hiddenTransactionIDs"
    private static let lastSyncKey = "bank.lastSync"
    private static let errorsKey = "bank.errors"
    /// How far back each sync re-reads, so pending transactions that posted or vanished get updated.
    private static let overlap: TimeInterval = 14 * 86_400

    static var isAvailable: Bool { TellerConfig.shared != nil }
    static var lastSync: Date? { UserDefaults.standard.object(forKey: lastSyncKey) as? Date }

    /// The last sync error per enrollment ID, shown on the Linked banks screen until a sync succeeds.
    static var errors: [String: String] {
        UserDefaults.standard.dictionary(forKey: errorsKey) as? [String: String] ?? [:]
    }

    /// Stores a new (or repaired) enrollment and runs its first sync.
    static func connect(_ link: BankLink, context: ModelContext) async throws {
        BankLinkStore.save(link)
        try await sync(link, context: context)
    }

    /// Syncs every linked bank. Returns a message for each one that failed.
    @discardableResult
    static func syncAll(context: ModelContext) async -> [String] {
        var failures: [String] = []
        for link in BankLinkStore.all() {
            do { try await sync(link, context: context) } catch {
                failures.append("\(link.institution): \(error.localizedDescription)")
            }
        }
        UserDefaults.standard.set(Date.now, forKey: lastSyncKey)
        return failures
    }

    /// Syncs on launch/foreground when it's been a while.
    static func syncIfStale(context: ModelContext, olderThan interval: TimeInterval = 4 * 3_600) async {
        guard isAvailable, !BankLinkStore.all().isEmpty else { return }
        if let lastSync, Date.now.timeIntervalSince(lastSync) < interval { return }
        await syncAll(context: context)
    }

    static func sync(_ link: BankLink, context: ModelContext) async throws {
        let client = TellerClient(accessToken: link.accessToken)
        do {
            for remote in try await client.accounts() where remote.status == "open" {
                let account = findOrCreateAccount(remote, context: context)
                let since = account.lastSynced.map { $0.addingTimeInterval(-overlap) }
                let balance = try await client.balance(accountID: remote.id)
                let transactions = try await client.transactions(accountID: remote.id, since: since)
                apply(transactions, balance: balance, to: account, context: context)
            }
            try context.save()
            setError(nil, for: link.id)
        } catch {
            setError(error.localizedDescription, for: link.id)
            throw error
        }
    }

    /// Forgets the enrollment on this device and asks Teller to revoke access.
    /// When `deleteData` is true the bank's accounts and their transactions are removed too;
    /// otherwise they stay as ordinary manual accounts.
    static func disconnect(_ link: BankLink, deleteData: Bool, context: ModelContext) async {
        try? await TellerClient(accessToken: link.accessToken).revoke()
        BankLinkStore.remove(id: link.id)
        setError(nil, for: link.id)
        let linkID = link.id
        let accounts = (try? context.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.enrollmentID == linkID }))) ?? []
        for account in accounts {
            if deleteData {
                (account.transactions ?? []).forEach(context.delete)
                context.delete(account)
            } else {
                account.tellerAccountID = nil
                account.enrollmentID = nil
                account.lastSynced = nil
                for tx in account.transactions ?? [] { tx.externalID = nil }
            }
        }
        try? context.save()
    }

    /// Remembers a deleted synced transaction so the next sync doesn't bring it back.
    static func hide(_ transaction: Transaction) {
        guard let id = transaction.externalID else { return }
        var hidden = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
        hidden.insert(id)
        UserDefaults.standard.set(Array(hidden), forKey: hiddenKey)
    }

    /// Clears tokens and sync bookkeeping (used by "Erase all data").
    static func reset() {
        BankLinkStore.removeAll()
        [hiddenKey, lastSyncKey, errorsKey].forEach(UserDefaults.standard.removeObject(forKey:))
    }

    // MARK: - Mapping

    private static func findOrCreateAccount(_ remote: TellerAccount, context: ModelContext) -> Account {
        let remoteID = remote.id
        let existing = try? context.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.tellerAccountID == remoteID })).first
        let account = existing ?? {
            let institution = remote.institution.name
            let name = remote.name.localizedCaseInsensitiveContains(institution) ? remote.name : "\(institution) \(remote.name)"
            let account = Account(name: name, kind: kind(for: remote))
            account.tellerAccountID = remote.id
            context.insert(account)
            return account
        }()
        account.enrollmentID = remote.enrollmentId
        account.institution = remote.institution.name
        account.lastFour = remote.lastFour
        return account
    }

    private static func kind(for remote: TellerAccount) -> String {
        if remote.type == "credit" { return "credit" }
        switch remote.subtype {
        case "savings", "money_market", "certificate_of_deposit", "treasury": return "savings"
        default: return "checking"
        }
    }

    private static func apply(_ remote: [TellerTransaction], balance: TellerBalance, to account: Account, context: ModelContext) {
        let hidden = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
        // Looked up across all accounts, so a re-created account picks its old transactions back up.
        let synced = (try? context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.externalID != nil }))) ?? []
        let existing = Dictionary(synced.compactMap { tx in tx.externalID.map { ($0, tx) } }, uniquingKeysWith: { first, _ in first })
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let categoryNames = categories.map(\.name)

        for item in remote where !hidden.contains(item.id) {
            guard let amount = Double(item.amount), let date = TellerClient.date(item.date) else { continue }
            if let tx = existing[item.id] {
                // Keep the user's title, category and note; refresh what the bank can change.
                tx.amount = amount
                tx.date = date
                tx.isPending = item.status == "pending"
                tx.account = account
                continue
            }
            let title = cleanTitle(item)
            let categoryName = CategoryMatcher.match(title).flatMap { CategoryMatcher.existing($0, in: categoryNames) }
                ?? item.details?.category.flatMap(categoryName(forTeller:)).flatMap { CategoryMatcher.existing($0, in: categoryNames) }
            let tx = Transaction(title: title, amount: amount, date: date,
                                 category: categories.first { $0.name == categoryName }, account: account)
            tx.externalID = item.id
            tx.isPending = item.status == "pending"
            context.insert(tx)
        }

        // Pending transactions that are no longer reported were dropped or re-issued with a new ID.
        let reported = Set(remote.map(\.id))
        let oldestFetched = remote.compactMap { TellerClient.date($0.date) }.min() ?? .distantFuture
        for tx in account.transactions ?? [] where tx.isPending && tx.date >= oldestFetched {
            if let id = tx.externalID, !reported.contains(id) { context.delete(tx) }
        }

        // Match the bank's balance: startingBalance absorbs history older than what Teller returns.
        // Credit cards report the amount owed, which this app shows as a negative balance.
        try? context.save()
        if let ledger = balance.ledger.flatMap(Double.init) {
            let target = account.kind == "credit" ? -ledger : ledger
            let logged = (account.transactions ?? []).reduce(0) { $0 + $1.amount }
            account.startingBalance = target - logged
        }
        account.lastSynced = .now
    }

    /// The merchant name when Teller recognized one, otherwise the bank's description in title case.
    private static func cleanTitle(_ item: TellerTransaction) -> String {
        if let name = item.details?.counterparty?.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name.capitalized
        }
        let description = item.description.trimmingCharacters(in: .whitespaces)
        return description == description.uppercased() ? description.capitalized : description
    }

    private static func categoryName(forTeller category: String) -> String? {
        switch category {
        case "dining", "bar", "groceries": "Food"
        case "fuel", "transport", "transportation": "Transportation"
        case "utilities", "phone": "Utilities"
        case "entertainment", "sport": "Entertainment"
        case "health": "Healthcare"
        case "education": "Education"
        case "accommodation": "Travel"
        case "clothing", "electronics", "shopping", "home": "Shopping"
        case "software": "Subscriptions"
        case "income": "Income"
        case "loan": "Debt"
        case "investment": "Savings"
        case "charity": "Personal"
        default: nil
        }
    }

    private static func setError(_ message: String?, for id: String) {
        var errors = errors
        errors[id] = message
        UserDefaults.standard.set(errors, forKey: errorsKey)
    }
}
