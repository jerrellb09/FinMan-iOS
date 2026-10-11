import Foundation

// Plaid (plaid.com) bank connections, called straight from the phone.
//
// ⚠️ PERSONAL USE ONLY: the Plaid client ID and secret ship inside the app bundle
// (FinManApp/Secrets/Plaid.plist), so anyone with a copy of the app could extract them.
// Before distributing the app (TestFlight, App Store, sharing a build), move every call that
// needs the secret to a server, delete Secrets/, and rotate the secret in the Plaid dashboard.

/// Settings read from the git-ignored `Secrets/Plaid.plist` in the app bundle.
nonisolated struct PlaidConfig: Sendable {
    let clientID: String
    let secret: String
    /// "sandbox" or "production" (the free Trial plan runs in production).
    let environment: String

    /// Nil when the build has no `Plaid.plist`, in which case bank connections are hidden.
    static let shared: PlaidConfig? = load()

    var isSandbox: Bool { environment != "production" }
    var baseURL: URL { URL(string: isSandbox ? "https://sandbox.plaid.com" : "https://production.plaid.com")! }

    private static func load() -> PlaidConfig? {
        guard let url = Bundle.main.url(forResource: "Plaid", withExtension: "plist"),
              let plist = NSDictionary(contentsOf: url) as? [String: Any],
              let clientID = plist["ClientID"] as? String, !clientID.isEmpty,
              let secret = plist["Secret"] as? String, !secret.isEmpty else { return nil }
        return PlaidConfig(clientID: clientID, secret: secret, environment: (plist["Environment"] as? String) ?? "sandbox")
    }
}

nonisolated enum PlaidError: LocalizedError {
    case notConfigured
    /// The bank login needs attention (password changed, consent expired…). Fixed by reconnecting.
    case needsReconnect(String)
    case api(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Bank connections aren't set up in this build."
        case .needsReconnect(let message): message.isEmpty ? "This bank needs you to sign in again." : message
        case .api(let code, let message): message.isEmpty ? "Plaid returned an error (\(code))." : message
        }
    }

    var needsReconnect: Bool { if case .needsReconnect = self { true } else { false } }
}

// MARK: - API types

nonisolated struct PlaidAccount: Decodable, Sendable {
    struct Balances: Decodable, Sendable {
        /// For credit cards and loans, the amount owed.
        let current: Double?
        let available: Double?
    }
    let accountId: String
    let name: String
    let officialName: String?
    let mask: String?
    /// "depository", "credit", "loan", "investment"…
    let type: String
    let subtype: String?
    let balances: Balances
}

nonisolated struct PlaidTransaction: Decodable, Sendable {
    struct Category: Decodable, Sendable { let primary: String; let detailed: String? }
    let transactionId: String
    let accountId: String
    /// Positive is money leaving the account, negative is money coming in (for every account type).
    let amount: Double
    /// "yyyy-MM-dd": posted date, or the day it happened while pending.
    let date: String
    let name: String
    let merchantName: String?
    let pending: Bool
    /// On a posted transaction, the ID of the pending transaction it replaces.
    let pendingTransactionId: String?
    let personalFinanceCategory: Category?
}

nonisolated struct PlaidTransactionsPage: Decodable, Sendable {
    struct Removed: Decodable, Sendable { let transactionId: String }
    let added: [PlaidTransaction]
    let modified: [PlaidTransaction]
    let removed: [Removed]
    let nextCursor: String
    let hasMore: Bool
}

/// A finished Hosted Link session's new Item, before its public token is exchanged.
nonisolated struct PlaidLinkResult: Sendable {
    let publicToken: String
    let institution: String
}

// MARK: - Client

nonisolated enum PlaidClient {
    /// FinMan's custom URL scheme; Hosted Link redirects here when the user finishes or exits.
    static let callbackScheme = "finman-plaid"

    /// Starts a Hosted Link session. Pass `accessToken` to repair an existing Item (update mode).
    static func createLinkToken(accessToken: String? = nil) async throws -> (token: String, url: URL) {
        var body: [String: Any] = [
            "client_name": "FinMan",
            "language": "en",
            "country_codes": ["US"],
            "user": ["client_user_id": installationID],
            "hosted_link": ["completion_redirect_uri": "\(callbackScheme)://link-complete"],
        ]
        if let accessToken {
            body["access_token"] = accessToken
        } else {
            body["products"] = ["transactions"]
            body["transactions"] = ["days_requested": 730]
        }
        struct Response: Decodable { let linkToken: String; let hostedLinkUrl: URL }
        let response: Response = try await post("/link/token/create", body)
        return (response.linkToken, response.hostedLinkUrl)
    }

    /// The Items added during a Hosted Link session (empty if the user exited without connecting).
    static func linkResults(linkToken: String) async throws -> [PlaidLinkResult] {
        struct Response: Decodable {
            struct Session: Decodable {
                struct Results: Decodable {
                    struct ItemAdd: Decodable {
                        struct Institution: Decodable { let name: String }
                        let publicToken: String
                        let institution: Institution?
                    }
                    let itemAddResults: [ItemAdd]?
                }
                let results: Results?
            }
            let linkSessions: [Session]?
        }
        let response: Response = try await post("/link/token/get", ["link_token": linkToken])
        return (response.linkSessions ?? [])
            .flatMap { $0.results?.itemAddResults ?? [] }
            .map { PlaidLinkResult(publicToken: $0.publicToken, institution: $0.institution?.name ?? "Bank") }
    }

    static func exchange(publicToken: String) async throws -> (accessToken: String, itemID: String) {
        struct Response: Decodable { let accessToken: String; let itemId: String }
        let response: Response = try await post("/item/public_token/exchange", ["public_token": publicToken])
        return (response.accessToken, response.itemId)
    }

    /// Accounts with the balances Plaid last fetched (refreshed alongside transactions).
    static func accounts(accessToken: String) async throws -> [PlaidAccount] {
        struct Response: Decodable { let accounts: [PlaidAccount] }
        let response: Response = try await post("/accounts/get", ["access_token": accessToken])
        return response.accounts
    }

    static func transactionsPage(accessToken: String, cursor: String?) async throws -> PlaidTransactionsPage {
        var body: [String: Any] = ["access_token": accessToken, "count": 500]
        if let cursor, !cursor.isEmpty { body["cursor"] = cursor }
        return try await post("/transactions/sync", body)
    }

    /// Revokes the access token and stops billing for the Item.
    static func removeItem(accessToken: String) async throws {
        struct Response: Decodable {}
        let _: Response = try await post("/item/remove", ["access_token": accessToken])
    }

    static func date(_ string: String) -> Date? {
        dayFormatter.date(from: string)
    }

    // MARK: Plumbing

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        // Noon local time, so a date never slips into the previous or next day.
        formatter.defaultDate = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: .now)
        return formatter
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// A random ID for this install, sent as Plaid's `client_user_id` (no personal information).
    private static var installationID: String {
        let key = "bank.installationID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    private struct ErrorBody: Decodable {
        let errorCode: String
        let errorMessage: String?
        let displayMessage: String?
    }

    private static func post<T: Decodable>(_ path: String, _ body: [String: Any]) async throws -> T {
        guard let config = PlaidConfig.shared else { throw PlaidError.notConfigured }
        var request = URLRequest(url: config.baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.clientID, forHTTPHeaderField: "PLAID-CLIENT-ID")
        request.setValue(config.secret, forHTTPHeaderField: "PLAID-SECRET")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let error = try? decoder.decode(ErrorBody.self, from: data)
            let message = error?.displayMessage ?? error?.errorMessage ?? ""
            switch error?.errorCode {
            case "ITEM_LOGIN_REQUIRED", "PENDING_EXPIRATION", "PENDING_DISCONNECT":
                throw PlaidError.needsReconnect(message)
            default:
                throw PlaidError.api(code: error?.errorCode ?? "HTTP \(status)", message: message)
            }
        }
        return try decoder.decode(T.self, from: data)
    }
}
