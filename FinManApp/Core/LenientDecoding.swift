import Foundation

/// The backend serialises JPA entities directly, so payloads vary (e.g. Lombok turns `isPaid` into `paid`,
/// dates may be ISO strings or `[y, m, d, h, m, s]` arrays, nested lazy relations may be partial).
/// These helpers decode defensively so one odd field never breaks a whole screen.
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { stringValue = "\(intValue)"; self.intValue = intValue }
}

extension KeyedDecodingContainer where Key == AnyKey {
    func string(_ keys: String...) -> String? {
        for key in keys {
            if let v = try? decodeIfPresent(String.self, forKey: AnyKey(key)) { return v }
        }
        return nil
    }

    func int(_ keys: String...) -> Int? {
        for key in keys {
            if let v = try? decodeIfPresent(Int.self, forKey: AnyKey(key)) { return v }
            if let s = try? decodeIfPresent(String.self, forKey: AnyKey(key)), let v = Int(s) { return v }
        }
        return nil
    }

    func decimal(_ keys: String...) -> Decimal? {
        for key in keys {
            if let v = try? decodeIfPresent(Decimal.self, forKey: AnyKey(key)) { return v }
            if let s = try? decodeIfPresent(String.self, forKey: AnyKey(key)), let v = Decimal(string: s) { return v }
        }
        return nil
    }

    func bool(_ keys: String...) -> Bool? {
        for key in keys {
            if let v = try? decodeIfPresent(Bool.self, forKey: AnyKey(key)) { return v }
        }
        return nil
    }

    func date(_ keys: String...) -> Date? {
        for key in keys {
            if let s = try? decodeIfPresent(String.self, forKey: AnyKey(key)), let d = DateParsing.parse(s) { return d }
            if let parts = try? decodeIfPresent([Int].self, forKey: AnyKey(key)), let d = DateParsing.fromArray(parts) { return d }
        }
        return nil
    }

    func nested<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        try? decodeIfPresent(T.self, forKey: AnyKey(key))
    }
}

enum DateParsing {
    private static let localDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private static let localDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        // Strip fractional seconds / offsets that Java's LocalDateTime may include.
        var s = raw
        if let dot = s.firstIndex(of: ".") { s = String(s[..<dot]) }
        if s.hasSuffix("Z") { s.removeLast() }
        if s.count > 19, let plus = s.lastIndex(where: { $0 == "+" }) { s = String(s[..<plus]) }
        if s.count == 16 { s += ":00" }
        return localDateTime.date(from: s) ?? localDate.date(from: s)
    }

    static func fromArray(_ p: [Int]) -> Date? {
        guard p.count >= 3 else { return nil }
        var c = DateComponents()
        c.year = p[0]; c.month = p[1]; c.day = p[2]
        if p.count > 3 { c.hour = p[3] }
        if p.count > 4 { c.minute = p[4] }
        if p.count > 5 { c.second = p[5] }
        return Calendar.current.date(from: c)
    }

    /// `LocalDateTime` wire format, e.g. `2026-10-03T14:05:00`.
    static func localDateTimeString(_ date: Date) -> String { localDateTime.string(from: date) }
    /// `LocalDate` wire format, e.g. `2026-10-03`.
    static func localDateString(_ date: Date) -> String { localDate.string(from: date) }
}
