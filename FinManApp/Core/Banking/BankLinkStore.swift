import Foundation
import Security

/// One Plaid Item: a login at one bank, which can cover several accounts.
nonisolated struct BankLink: Codable, Identifiable, Hashable, Sendable {
    /// Plaid item ID.
    let id: String
    var institution: String
    var accessToken: String
    var connectedAt: Date = .now
    /// Where the last `/transactions/sync` left off; nil until the first full sync.
    var cursor: String?
}

/// Bank access tokens, kept in the Keychain (this device only, never backed up or synced).
nonisolated enum BankLinkStore {
    private static let service = "finman.bank-links"
    private static let account = "plaid"

    static func all() -> [BankLink] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return [] }
        return (try? JSONDecoder().decode([BankLink].self, from: data)) ?? []
    }

    /// Adds the link, or replaces the stored one with the same item ID (e.g. to save a new cursor).
    static func save(_ link: BankLink) {
        var links = all().filter { $0.id != link.id }
        links.append(link)
        write(links)
    }

    static func remove(id: String) {
        write(all().filter { $0.id != id })
    }

    static func removeAll() {
        write([])
    }

    private static func write(_ links: [BankLink]) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        guard !links.isEmpty, let data = try? JSONEncoder().encode(links) else { return }
        var item = match
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
