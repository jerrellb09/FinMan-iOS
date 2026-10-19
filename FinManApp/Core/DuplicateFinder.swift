import Foundation

/// Spots the same transaction entered twice: imported again, typed in by hand and also synced from a bank,
/// or exported by two apps under slightly different names ("STARBUCKS #1234" and "Starbucks").
nonisolated enum DuplicateFinder {
    struct Item: Sendable {
        var date: Date
        var amount: Double
        var title: String
        /// Plaid's transaction ID or an import fingerprint, when there is one.
        var externalID: String?
    }

    enum Strength: Sendable {
        /// Same import fingerprint or bank ID, or same day, amount and name.
        case exact
        /// Same amount within a few days under a similar name, or the same day under a different one.
        case likely
    }

    struct Match: Sendable {
        var existing: Int
        var strength: Strength
    }

    /// How far apart two records of one transaction can be dated (a pending charge posts a few days later).
    static let dayWindow = 3

    /// For each new item that duplicates an existing one, the index of that existing item. Each existing
    /// item matches at most one new item, so two genuine $5 coffees on one day don't both disappear.
    static func matches(_ new: [Item], against existing: [Item], calendar: Calendar = .current) -> [Int: Match] {
        let existingDays = existing.map { day($0.date, calendar) }
        let existingKeys = existing.map { key($0.title) }
        var byCents: [Int: [Int]] = [:]
        for (index, item) in existing.enumerated() { byCents[cents(item.amount), default: []].append(index) }
        let byExternalID = Dictionary(existing.enumerated().compactMap { index, item in item.externalID.map { ($0, index) } },
                                      uniquingKeysWith: { first, _ in first })

        var result: [Int: Match] = [:]
        var used = Set<Int>()

        // Strongest evidence first, so a looser match can't take an existing item an exact one needs.
        for (index, item) in new.enumerated() {
            if let id = item.externalID, let match = byExternalID[id], used.insert(match).inserted {
                result[index] = Match(existing: match, strength: .exact)
            }
        }
        for pass in 0..<3 {
            for (index, item) in new.enumerated() where result[index] == nil {
                let itemDay = day(item.date, calendar)
                let itemKey = key(item.title)
                let candidates = (byCents[cents(item.amount)] ?? []).filter { candidate in
                    guard !used.contains(candidate) else { return false }
                    // Two records that each carry their own ID from the same source are separate transactions.
                    if distinctSameSource(item.externalID, existing[candidate].externalID) { return false }
                    let gap = abs(existingDays[candidate] - itemDay)
                    switch pass {
                    case 0: return gap == 0 && existingKeys[candidate] == itemKey
                    case 1: return gap <= dayWindow && similar(existingKeys[candidate], itemKey)
                    default: return gap == 0
                    }
                }
                guard let best = candidates.min(by: { abs(existingDays[$0] - itemDay) < abs(existingDays[$1] - itemDay) }) else { continue }
                used.insert(best)
                result[index] = Match(existing: best, strength: pass == 0 ? .exact : .likely)
            }
        }
        return result
    }

    /// Groups of items that look like one transaction recorded more than once, for cleaning up.
    static func groups(in items: [Item], calendar: Calendar = .current) -> [[Int]] {
        let order = items.indices.sorted { items[$0].date < items[$1].date }
        var groupOf: [Int: Int] = [:]
        var groups: [[Int]] = []
        var byCents: [Int: [Int]] = [:]
        for index in order { byCents[cents(items[index].amount), default: []].append(index) }

        for indices in byCents.values where indices.count > 1 {
            for (position, a) in indices.enumerated() where groupOf[a] == nil {
                var group = [a]
                for b in indices[(position + 1)...] where groupOf[b] == nil {
                    let gap = abs(day(items[b].date, calendar) - day(items[a].date, calendar))
                    if gap > dayWindow { break }
                    // Records that each carry their own ID from the same source are separate transactions.
                    if group.contains(where: { distinctSameSource(items[$0].externalID, items[b].externalID) }) { continue }
                    let ka = key(items[a].title), kb = key(items[b].title)
                    if (gap == 0 && ka == kb) || similar(ka, kb) { group.append(b) }
                }
                if group.count > 1 {
                    group.forEach { groupOf[$0] = groups.count }
                    groups.append(group)
                }
            }
        }
        return groups
    }

    // MARK: Comparing

    static func cents(_ amount: Double) -> Int { Int((amount * 100).rounded()) }

    private static func day(_ date: Date, _ calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: c).map { Int(($0.timeIntervalSinceReferenceDate / 86_400).rounded()) } ?? 0
    }

    private static func distinctSameSource(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a != b && origin(a) == origin(b)
    }

    /// Where an external ID came from: a file import or a bank.
    private static func origin(_ id: String) -> String {
        id.hasPrefix(TransactionImporter.fingerprintPrefix) ? "import" : "bank"
    }

    private static let noise: Set<String> = [
        "pos", "debit", "credit", "purchase", "card", "ach", "the", "inc", "llc", "co", "corp", "online", "www", "com",
        "payment", "pmt", "recurring", "checkcard", "visa", "mastercard", "transaction", "sq", "tst", "pending", "dbt", "crd",
    ]

    /// Words of a name that identify the merchant, without store numbers and card-processing noise.
    static func key(_ title: String) -> String {
        title.lowercased()
            .split { !$0.isLetter }
            .map(String.init)
            .filter { $0.count > 1 && !noise.contains($0) }
            .joined(separator: " ")
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let compactA = a.replacingOccurrences(of: " ", with: ""), compactB = b.replacingOccurrences(of: " ", with: "")
        if min(compactA.count, compactB.count) >= 4, compactA.contains(compactB) || compactB.contains(compactA) { return true }
        let wordsA = Set(a.split(separator: " ")), wordsB = Set(b.split(separator: " "))
        if let first = a.split(separator: " ").first, first.count >= 4, first == b.split(separator: " ").first { return true }
        let shared = wordsA.intersection(wordsB).count
        return Double(shared) / Double(wordsA.union(wordsB).count) >= 0.5
    }
}
