import Foundation
import SwiftData

/// Pulls accounts, balances and transactions from Plaid into the SwiftData store.
enum BankSync {
    private static let hiddenKey = "bank.hiddenTransactionIDs"
    private static let lastSyncKey = "bank.lastSync"
    private static let errorsKey = "bank.errors"

    static var isAvailable: Bool { PlaidConfig.shared != nil }
    static var lastSync: Date? { UserDefaults.standard.object(forKey: lastSyncKey) as? Date }

    /// The last sync error per item ID, shown on the Linked banks screen until a sync succeeds.
    static var errors: [String: String] {
        UserDefaults.standard.dictionary(forKey: errorsKey) as? [String: String] ?? [:]
    }

    /// Exchanges a finished Hosted Link session's public token and runs the first sync.
    /// Returns false when Plaid is still gathering the transaction history (balances are in already).
    @discardableResult
    static func connect(_ result: PlaidLinkResult, context: ModelContext) async throws -> Bool {
        let (accessToken, itemID) = try await PlaidClient.exchange(publicToken: result.publicToken)
        let link = BankLink(id: itemID, institution: result.institution, accessToken: accessToken)
        BankLinkStore.save(link)
        // A brand-new Item usually needs a few seconds before its first transactions are ready.
        for attempt in 0..<5 {
            if attempt > 0 { try await Task.sleep(for: .seconds(3)) }
            if try await sync(BankLinkStore.all().first { $0.id == itemID } ?? link, context: context) { return true }
        }
        return false
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

    /// Updates accounts and balances, then applies every transaction change since the link's cursor.
    /// Returns false when Plaid doesn't have transactions ready yet.
    @discardableResult
    static func sync(_ link: BankLink, context: ModelContext) async throws -> Bool {
        do {
            var accounts: [String: Account] = [:]
            let remoteAccounts = try await PlaidClient.accounts(accessToken: link.accessToken)
            for remote in remoteAccounts where remote.type == "depository" || remote.type == "credit" {
                accounts[remote.accountId] = findOrCreateAccount(remote, link: link, context: context)
            }

            let changes = try await fetchChanges(link)
            if let changes {
                apply(changes, to: accounts, context: context)
            }
            try context.save()

            // Match the bank's balance: startingBalance absorbs history older than what Plaid returns.
            // Credit cards report the amount owed, which this app shows as a negative balance.
            for remote in remoteAccounts {
                guard let account = accounts[remote.accountId], let current = remote.balances.current else { continue }
                let target = account.kind == "credit" ? -current : current
                account.startingBalance = target - (account.transactions ?? []).reduce(0) { $0 + $1.amount }
                account.lastSynced = .now
            }
            try context.save()

            if let changes {
                var updated = link
                updated.cursor = changes.cursor
                BankLinkStore.save(updated)
            }
            setError(nil, for: link.id)
            return changes != nil
        } catch {
            setError(error.localizedDescription, for: link.id)
            throw error
        }
    }

    /// Forgets the link on this device and asks Plaid to revoke it.
    /// When `deleteData` is true the bank's accounts and their transactions are removed too;
    /// otherwise they stay as ordinary manual accounts.
    static func disconnect(_ link: BankLink, deleteData: Bool, context: ModelContext) async {
        try? await PlaidClient.removeItem(accessToken: link.accessToken)
        BankLinkStore.remove(id: link.id)
        setError(nil, for: link.id)
        let linkID = link.id
        let accounts = (try? context.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.bankLinkID == linkID }))) ?? []
        for account in accounts {
            if deleteData {
                (account.transactions ?? []).forEach(context.delete)
                context.delete(account)
            } else {
                account.bankAccountID = nil
                account.bankLinkID = nil
                account.lastSynced = nil
                for tx in account.transactions ?? [] { tx.externalID = nil }
            }
        }
        try? context.save()
    }

    /// Remembers a deleted synced transaction so it doesn't come back when it posts.
    static func hide(_ transaction: Transaction) {
        guard let id = transaction.externalID, !id.hasPrefix(TransactionImporter.fingerprintPrefix) else { return }
        var hidden = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
        hidden.insert(id)
        UserDefaults.standard.set(Array(hidden), forKey: hiddenKey)
    }

    /// Clears tokens and sync bookkeeping (used by "Erase all data").
    static func reset() {
        BankLinkStore.removeAll()
        [hiddenKey, lastSyncKey, errorsKey].forEach(UserDefaults.standard.removeObject(forKey:))
    }

    // MARK: - Fetching

    private struct Changes {
        var added: [PlaidTransaction] = []
        var modified: [PlaidTransaction] = []
        var removed: [String] = []
        var cursor = ""
    }

    /// Every change since the link's cursor, or nil when Plaid has nothing ready yet.
    private static func fetchChanges(_ link: BankLink) async throws -> Changes? {
        restart: for _ in 0..<3 {
            var changes = Changes(cursor: link.cursor ?? "")
            while true {
                let page: PlaidTransactionsPage
                do {
                    page = try await PlaidClient.transactionsPage(accessToken: link.accessToken, cursor: changes.cursor)
                } catch PlaidError.api(code: "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION", _) {
                    // Plaid's data changed mid-way; start again from the original cursor.
                    continue restart
                }
                changes.added += page.added
                changes.modified += page.modified
                changes.removed += page.removed.map(\.transactionId)
                changes.cursor = page.nextCursor
                if !page.hasMore { break }
            }
            return changes.cursor.isEmpty ? nil : changes
        }
        throw PlaidError.api(code: "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION", message: "The bank's data kept changing during sync. Try again in a minute.")
    }

    // MARK: - Mapping

    private static func findOrCreateAccount(_ remote: PlaidAccount, link: BankLink, context: ModelContext) -> Account {
        let remoteID = remote.accountId
        let existing = try? context.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.bankAccountID == remoteID })).first
        let account = existing ?? {
            let name = remote.name.localizedCaseInsensitiveContains(link.institution) ? remote.name : "\(link.institution) \(remote.name)"
            let account = Account(name: name, kind: kind(for: remote))
            account.bankAccountID = remote.accountId
            context.insert(account)
            return account
        }()
        account.bankLinkID = link.id
        account.institution = link.institution
        account.lastFour = remote.mask
        return account
    }

    private static func kind(for remote: PlaidAccount) -> String {
        if remote.type == "credit" { return "credit" }
        switch remote.subtype {
        case "savings", "money market", "cd", "hsa", "cash management": return "savings"
        default: return "checking"
        }
    }

    private static func apply(_ changes: Changes, to accounts: [String: Account], context: ModelContext) {
        let hidden = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
        // Looked up across all accounts, so a re-created account picks its old transactions back up.
        let synced = (try? context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.externalID != nil }))) ?? []
        var byID = Dictionary(synced.compactMap { tx in tx.externalID.map { ($0, tx) } }, uniquingKeysWith: { first, _ in first })
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let categoryNames = categories.map(\.name)

        func update(_ tx: Transaction, from item: PlaidTransaction) {
            // Keep the user's title, category and note; refresh what the bank can change.
            tx.amount = -item.amount
            tx.date = PlaidClient.date(item.date) ?? tx.date
            tx.isPending = item.pending
        }

        for item in changes.added {
            guard let account = accounts[item.accountId], !hidden.contains(item.transactionId) else { continue }
            if let pendingID = item.pendingTransactionId, hidden.contains(pendingID) { continue }
            // A posted transaction replacing a pending one keeps the pending one's edits.
            if let tx = byID[item.transactionId] ?? item.pendingTransactionId.flatMap({ byID.removeValue(forKey: $0) }) {
                tx.externalID = item.transactionId
                tx.account = account
                byID[item.transactionId] = tx
                update(tx, from: item)
                continue
            }
            let title = cleanTitle(item)
            let categoryName = CategoryMatcher.match(title).flatMap { CategoryMatcher.existing($0, in: categoryNames) }
                ?? item.personalFinanceCategory.flatMap(categoryName(forPlaid:)).flatMap { CategoryMatcher.existing($0, in: categoryNames) }
            let tx = Transaction(title: title, amount: -item.amount, date: PlaidClient.date(item.date) ?? .now,
                                 category: categories.first { $0.name == categoryName }, account: account)
            tx.externalID = item.transactionId
            tx.isPending = item.pending
            context.insert(tx)
            byID[item.transactionId] = tx
        }
        for item in changes.modified {
            if let tx = byID[item.transactionId] { update(tx, from: item) }
        }
        for id in changes.removed {
            if let tx = byID.removeValue(forKey: id) { context.delete(tx) }
        }
    }

    /// The cleaned-up merchant name when Plaid has one, otherwise the bank's description.
    private static func cleanTitle(_ item: PlaidTransaction) -> String {
        if let name = item.merchantName?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        let description = item.name.trimmingCharacters(in: .whitespaces)
        return description == description.uppercased() ? description.capitalized : description
    }

    /// Plaid's personal finance categories mapped onto the app's defaults.
    private static func categoryName(forPlaid category: PlaidTransaction.Category) -> String? {
        switch category.primary {
        case "INCOME": "Income"
        case "FOOD_AND_DRINK": "Food"
        case "TRANSPORTATION": "Transportation"
        case "TRAVEL": "Travel"
        case "ENTERTAINMENT": "Entertainment"
        case "MEDICAL": "Healthcare"
        case "PERSONAL_CARE": "Personal"
        case "GENERAL_MERCHANDISE", "HOME_IMPROVEMENT": "Shopping"
        case "LOAN_PAYMENTS": "Debt"
        case "RENT_AND_UTILITIES": category.detailed == "RENT_AND_UTILITIES_RENT" ? "Housing" : "Utilities"
        default: nil
        }
    }

    private static func setError(_ message: String?, for id: String) {
        var errors = errors
        errors[id] = message
        UserDefaults.standard.set(errors, forKey: errorsKey)
    }
}
