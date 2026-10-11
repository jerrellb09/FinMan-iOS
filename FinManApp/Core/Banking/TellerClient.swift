import Foundation
import Security

// Teller (teller.io) bank connections. Every API call is authenticated twice: the enrollment's
// access token (HTTP basic auth) and the application's client certificate (mTLS).
//
// ⚠️ PERSONAL USE ONLY: the client certificate and private key ship inside the app bundle
// (FinManApp/Secrets/teller.p12), so anyone with a copy of the app could extract them.
// Before distributing the app (TestFlight, App Store, sharing a build), move the certificate to a
// server-side proxy, delete it from Secrets/, and rotate it in the Teller dashboard.

/// Settings read from the git-ignored `Secrets/Teller.plist` and `Secrets/teller.p12` in the app bundle.
nonisolated struct TellerConfig: Sendable {
    let applicationID: String
    /// "sandbox", "development" or "production".
    let environment: String
    fileprivate let identity: TellerIdentity?

    /// Nil when the build has no `Teller.plist`, in which case bank connections are hidden.
    static let shared: TellerConfig? = load()

    var isSandbox: Bool { environment == "sandbox" }
    var hasCertificate: Bool { identity != nil }

    private static func load() -> TellerConfig? {
        guard let url = Bundle.main.url(forResource: "Teller", withExtension: "plist"),
              let plist = NSDictionary(contentsOf: url) as? [String: Any],
              let appID = plist["ApplicationID"] as? String, !appID.isEmpty else { return nil }
        let environment = (plist["Environment"] as? String) ?? "sandbox"
        var identity: TellerIdentity?
        if let p12URL = Bundle.main.url(forResource: "teller", withExtension: "p12"),
           let data = try? Data(contentsOf: p12URL) {
            identity = TellerIdentity(p12: data, password: (plist["CertificatePassword"] as? String) ?? "")
        }
        return TellerConfig(applicationID: appID, environment: environment, identity: identity)
    }
}

/// The client certificate + private key, unpacked from the PKCS#12 file.
nonisolated private struct TellerIdentity: @unchecked Sendable {
    let credential: URLCredential

    init?(p12: Data, password: String) {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        guard SecPKCS12Import(p12 as CFData, options, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let ref = first[kSecImportItemIdentity as String] else { return nil }
        credential = URLCredential(identity: ref as! SecIdentity, certificates: nil, persistence: .forSession)
    }
}

/// Answers Teller's client-certificate challenge.
nonisolated private final class ClientCertificateDelegate: NSObject, URLSessionDelegate, Sendable {
    let credential: URLCredential?
    init(credential: URLCredential?) { self.credential = credential }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate, let credential {
            return (.useCredential, credential)
        }
        return (.performDefaultHandling, nil)
    }
}

nonisolated enum TellerError: LocalizedError {
    case notConfigured
    case missingCertificate
    /// The bank login needs attention (password changed, MFA expired…). Fixed by reconnecting.
    case needsReconnect(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Bank connections aren't set up in this build."
        case .missingCertificate: "The Teller certificate is missing or its password is wrong."
        case .needsReconnect(let message): message.isEmpty ? "This bank needs you to sign in again." : message
        case .http(let status, let message): message.isEmpty ? "Teller returned an error (\(status))." : message
        }
    }

    var needsReconnect: Bool { if case .needsReconnect = self { true } else { false } }
}

// MARK: - API types

nonisolated struct TellerAccount: Decodable, Sendable {
    struct Institution: Decodable, Sendable { let id: String?; let name: String }
    let id: String
    let enrollmentId: String
    let name: String
    /// "depository" or "credit".
    let type: String
    let subtype: String?
    let lastFour: String?
    let status: String
    let institution: Institution
}

nonisolated struct TellerBalance: Decodable, Sendable {
    let ledger: String?
    let available: String?
}

nonisolated struct TellerTransaction: Decodable, Sendable {
    struct Details: Decodable, Sendable {
        struct Counterparty: Decodable, Sendable { let name: String? }
        let category: String?
        let counterparty: Counterparty?
    }
    let id: String
    let amount: String
    /// "yyyy-MM-dd".
    let date: String
    let description: String
    /// "posted" or "pending".
    let status: String
    let details: Details?
}

// MARK: - Client

nonisolated struct TellerClient: Sendable {
    let accessToken: String

    private static let baseURL = URL(string: "https://api.teller.io")!
    private static let delegate = ClientCertificateDelegate(credential: TellerConfig.shared?.identity?.credential)
    private static let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func accounts() async throws -> [TellerAccount] {
        try await get("/accounts")
    }

    func balance(accountID: String) async throws -> TellerBalance {
        try await get("/accounts/\(accountID)/balances")
    }

    /// Newest first. Pages back until `since` (or the full history when nil).
    func transactions(accountID: String, since: Date?) async throws -> [TellerTransaction] {
        let pageSize = 250
        var all: [TellerTransaction] = []
        var fromID: String?
        for _ in 0..<40 {
            var query = [URLQueryItem(name: "count", value: String(pageSize))]
            if let fromID { query.append(URLQueryItem(name: "from_id", value: fromID)) }
            let page: [TellerTransaction] = try await get("/accounts/\(accountID)/transactions", query: query)
            all += page
            guard page.count == pageSize, let last = page.last else { break }
            if let since, let oldest = Self.date(last.date), oldest < since { break }
            fromID = last.id
        }
        return all
    }

    /// Revokes the app's access to every account in this enrollment.
    func revoke() async throws {
        let _: Empty? = try await send("DELETE", "/accounts")
    }

    static func date(_ string: String) -> Date? {
        dayFormatter.date(from: string)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        // Noon local time, so a date never slips into the previous or next day.
        formatter.defaultDate = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: .now)
        return formatter
    }()

    // MARK: Plumbing

    private struct Empty: Decodable {}
    private struct ErrorBody: Decodable {
        struct Inner: Decodable { let code: String?; let message: String? }
        let error: Inner
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard let value: T = try await send("GET", path, query: query) else { throw TellerError.http(204, "Empty response.") }
        return value
    }

    private func send<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> T? {
        guard let config = TellerConfig.shared else { throw TellerError.notConfigured }
        // Sandbox works without a certificate; development and production don't.
        if !config.isSandbox && !config.hasCertificate { throw TellerError.missingCertificate }

        var url = Self.baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Basic " + Data("\(accessToken):".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = try? Self.decoder.decode(ErrorBody.self, from: data)
            let code = body?.error.code ?? ""
            let message = body?.error.message ?? ""
            if code.hasPrefix("enrollment.disconnected") || status == 401 { throw TellerError.needsReconnect(message) }
            throw TellerError.http(status, message)
        }
        if data.isEmpty || status == 204 { return nil }
        return try Self.decoder.decode(T.self, from: data)
    }
}
