import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case forbidden
    case server(status: Int, message: String?)
    case decoding(Error)
    case transport(Error)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Your session has expired. Please sign in again."
        case .forbidden: "You don't have access to that."
        case .server(let status, let message): message ?? "The server returned an error (\(status))."
        case .decoding: "We couldn't read the server's response."
        case .transport(let error): (error as? URLError)?.code == .cannotConnectToHost
            ? "Can't reach the server. Check the server address in Settings."
            : error.localizedDescription
        case .invalidURL: "The server address looks invalid."
        }
    }
}

/// Thin async wrapper around the FinManApp Spring Boot REST API.
@Observable
final class APIClient {
    static let defaultBaseURL = "http://localhost:8080"
    private static let baseURLKey = "serverBaseURL"

    var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Self.baseURLKey) }
    }

    @ObservationIgnored var token: String?
    /// Called when the server rejects our token so the session can sign out.
    @ObservationIgnored var onUnauthorized: (() -> Void)?

    @ObservationIgnored private let session: URLSession
    @ObservationIgnored let decoder: JSONDecoder = JSONDecoder()
    @ObservationIgnored let encoder: JSONEncoder = JSONEncoder()

    init(session: URLSession = .shared) {
        self.session = session
        self.baseURL = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? Self.defaultBaseURL
    }

    // MARK: - Request helpers

    func get<T: Decodable>(_ path: String, query: [String: String?] = [:]) async throws -> T {
        try await send(path, method: "GET", query: query, body: nil as Empty?)
    }

    func post<T: Decodable, B: Encodable>(_ path: String, query: [String: String?] = [:], body: B?) async throws -> T {
        try await send(path, method: "POST", query: query, body: body)
    }

    func put<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await send(path, method: "PUT", body: body)
    }

    func patch<T: Decodable, B: Encodable>(_ path: String, body: B?) async throws -> T {
        try await send(path, method: "PATCH", body: body)
    }

    func delete(_ path: String) async throws {
        let _: Empty = try await send(path, method: "DELETE", body: nil as Empty?)
    }

    func send<T: Decodable, B: Encodable>(
        _ path: String,
        method: String,
        query: [String: String?] = [:],
        body: B?,
        headers: [String: String] = [:],
        signOutOnUnauthorized: Bool = true
    ) async throws -> T {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: trimmed + path) else { throw APIError.invalidURL }
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            break
        case 401:
            if signOutOnUnauthorized { onUnauthorized?() }
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        default:
            let message = (try? decoder.decode(ServerMessage.self, from: data))?.message
            throw APIError.server(status: status, message: message)
        }

        if T.self == Empty.self { return Empty() as! T }
        // The backend returns `null` for some unimplemented endpoints; treat empty bodies as `null`.
        let payload = data.isEmpty ? Data("null".utf8) : data
        do {
            return try decoder.decode(T.self, from: payload)
        } catch {
            throw APIError.decoding(error)
        }
    }
}

struct Empty: Codable {}

private struct ServerMessage: Decodable {
    let message: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        message = c.string("message") ?? c.string("error")
    }
}
