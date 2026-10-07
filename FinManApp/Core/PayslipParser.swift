import Foundation

/// Rule-based payslip parsing over text rows (each row is one visual line of the document, read left to right).
/// Tried first; Apple Intelligence is only asked when these rules can't make the figures add up.
nonisolated enum PayslipParser {

    // MARK: Entry point

    static func parse(rows: [String], now: Date = .now) -> PayslipDraft { read(rows: rows, now: now).draft }

    /// The draft, and whether it can be trusted as is: gross and net were both printed, and the lines add up.
    static func read(rows rawRows: [String], now: Date = .now) -> (draft: PayslipDraft, isConfident: Bool) {
        let rows = rawRows.map(sanitize)
        let hasYTDColumn = rows.contains { row in
            let l = row.lowercased()
            return l.contains("ytd") || l.contains("year to date") || l.contains("year-to-date") || l.contains("y-t-d")
        }

        var draft = PayslipDraft(source: .rules)
        var section: Section?
        var seen = Set<String>()

        for row in rows {
            let groups = groups(in: row)
            if !groups.contains(where: { $0.hasMoney }) {
                // A row without amounts may start a new section ("Taxes", "Pre-tax deductions"...).
                if let header = Section(header: row) { section = header }
                continue
            }
            for group in groups {
                guard let (current, ytd) = amounts(group, hasYTDColumn: hasYTDColumn) else { continue }
                let name = group.label.trimmingCharacters(in: labelTrim)
                guard name.contains(where: \.isLetter) else { continue }

                var label = classify(name)
                switch section {
                case .ignore?: label = .ignore
                case .employer?: if case .line = label { label = .line(.employer, isSavings: false) }
                case .kind(let kind)?: if label == .unknown { label = .line(kind, isSavings: isSavings(name)) }
                case nil: break
                }

                switch label {
                case .gross:
                    if draft.grossPay == 0 { draft.grossPay = current }
                    if draft.ytdGross == nil { draft.ytdGross = ytd }
                case .net:
                    if draft.netPay == 0 { draft.netPay = current }
                    if draft.ytdNet == nil { draft.ytdNet = ytd }
                case .line(let kind, let savings):
                    // Summary boxes often repeat lines from the main table.
                    guard seen.insert("\(name.lowercased())|\(current)").inserted else { continue }
                    draft.lines.append(.init(name: tidy(name), kind: kind, amount: current, ytd: ytd, isSavings: savings))
                case .ignore, .unknown:
                    break
                }
            }
        }

        draft.dropImplausibleYTD()
        let printedBoth = draft.grossPay > 0 && draft.netPay > 0
        if draft.grossPay == 0 { draft.grossPay = draft.total(.earning) }
        if draft.netPay == 0, draft.grossPay > 0 { draft.netPay = max(0, draft.computedNet) }
        // Gross wasn't printed and there are no earnings lines: work back from net plus everything withheld.
        if draft.grossPay == 0, draft.netPay > 0 { draft.grossPay = draft.netPay - draft.computedNet }
        dropStrayEarning(&draft)
        if !draft.lines.contains(where: { $0.kind == .earning }), draft.grossPay > 0 {
            draft.lines.insert(.init(name: "Gross pay", kind: .earning, amount: draft.grossPay, ytd: draft.ytdGross), at: 0)
        }

        draft.employer = employer(in: rows)
        applyDates(rows, to: &draft, now: now)
        draft.frequency = frequency(rows, draft: draft) ?? .biweekly
        let hasWithholdings = draft.lines.contains(where: \.kind.reducesNet)
        return (draft, printedBoth && hasWithholdings && draft.addsUp)
    }

    private static let labelTrim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":-–*$#|"))

    /// Side-by-side tables can put an unrelated row (say, a time-off balance) next to an earning.
    /// If earnings overshoot gross by exactly one line's amount, that line isn't pay.
    private static func dropStrayEarning(_ draft: inout PayslipDraft) {
        let excess = draft.total(.earning) - draft.grossPay
        guard draft.grossPay > 0, excess > 0.05,
              let index = draft.lines.lastIndex(where: { $0.kind == .earning && abs($0.amount - excess) < 0.05 }) else { return }
        draft.lines.remove(at: index)
    }

    /// Masks Social Security and long account numbers; nothing downstream needs them.
    static func sanitize(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in [(#"\b\d{3}-\d{2}-\d{4}\b"#, "XXX-XX-XXXX"), (#"\b\d{7,}\b"#, "#######")] {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }

    // MARK: Classification

    enum Label: Equatable {
        case gross, net, ignore, unknown
        case line(PayLineKind, isSavings: Bool)
    }

    static func classify(_ name: String) -> Label {
        let l = name.lowercased()
        let words = Set(l.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let squashed = l.filter { $0.isLetter || $0.isNumber }
        func has(_ parts: String...) -> Bool { parts.contains { l.contains($0) } }
        func word(_ candidates: String...) -> Bool { candidates.contains { words.contains($0) } }

        if has("taxable", "deposit", "checking", "routing", "account", "acct", "exempt", "filing", "marital", "accru", "balance", "employee id", "employee no")
            || word("rate", "rates", "allowances", "available", "used") {
            return .ignore
        }
        if has("net pay", "net check", "take home", "take-home", "net amount", "net earnings", "net wages", "net income") || words == ["net"] {
            return .net
        }
        if word("total", "totals") { return word("gross") || has("total earnings", "total wages") ? .gross : .ignore }
        if word("gross") { return .gross }
        if has("employer", "company contribution", "company match", "company paid", "er match", "er contribution") || word("er") {
            return .line(.employer, isSavings: false)
        }
        if isSavings(name) {
            let afterTax = has("roth", "espp", "stock purchase", "after tax", "after-tax", "post tax", "post-tax") || squashed.contains("aftertax")
            return .line(afterTax ? .postTax : .preTax, isSavings: true)
        }
        if has("after tax", "after-tax", "post tax", "post-tax") || squashed.contains("aftertax") || squashed.contains("posttax") {
            return .line(.postTax, isSavings: false)
        }
        if has("pre tax", "pre-tax", "before tax", "before-tax", "section 125", "sec 125") || squashed.contains("pretax") {
            return .line(.preTax, isSavings: false)
        }
        if has("medicare", "social security", "soc sec", "oasdi", "fica", "federal", "withholding", "income tax", "unemployment",
               "state disab", "family leave", "paid leave", "workers comp")
            || word("tax", "taxes", "fed", "fit", "fwt", "sit", "swt", "sdi", "sui", "suta", "pfl", "fli", "ss", "med", "lit",
                    "city", "local", "county", "state", "school") {
            return .line(.tax, isSavings: false)
        }
        if has("medical", "dental", "vision", "health", "flexible spending", "dependent care", "commuter", "transit", "parking", "cafeteria")
            || word("fsa", "dcap", "dcfsa") {
            return .line(.preTax, isSavings: false)
        }
        if has("life", "ad&d", "disability", "garnish", "child support", "levy", "union", "dues", "charit", "united way", "donation",
               "loan", "legal", "critical illness", "accident", "hospital", "insurance")
            || word("ltd", "std") {
            return .line(.postTax, isSavings: false)
        }
        if has("regular", "salary", "overtime", "bonus", "holiday", "vacation", "sick", "commission", "shift", "differential", "retro",
               "tips", "stipend", "reimburs", "wages", "earnings", "incentive", "severance", "paid time off", "bereavement", "jury")
            || word("ot", "reg", "hol", "vac", "pto") {
            return .line(.earning, isSavings: false)
        }
        return .unknown
    }

    /// Retirement, HSA and stock-purchase contributions count toward savings.
    static func isSavings(_ name: String) -> Bool {
        let l = name.lowercased()
        let squashed = l.filter { $0.isLetter || $0.isNumber }
        let words = Set(l.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return ["401k", "403b", "457b", "retire", "pension", "roth", "espp", "stockpurchase"].contains { squashed.contains($0) }
            || ["457", "tsp", "ira", "hsa", "401a"].contains { words.contains($0) }
    }

    enum Section: Equatable {
        case kind(PayLineKind), employer, ignore

        init?(header: String) {
            let l = header.lowercased()
            var found: [Section] = []
            if ["time off", "accrual", "leave balance", "pto balance", "balances", "taxable wages"].contains(where: l.contains) { found.append(.ignore) }
            if l.contains("employer") || l.contains("company paid") || l.contains("company contribution") { found.append(.employer) }
            var matches: [PayLineKind] = []
            if l.contains("earning") || l.contains("hours and") { matches.append(.earning) }
            if l.contains("pre-tax") || l.contains("pretax") || l.contains("before-tax") || l.contains("before tax") { matches.append(.preTax) }
            else if l.contains("after-tax") || l.contains("post-tax") || l.contains("after tax") || l.contains("post tax") { matches.append(.postTax) }
            else if l.contains("tax") || l.contains("withholding") { matches.append(.tax) }
            if l.contains("deduction") && !matches.contains(.preTax) && !matches.contains(.postTax) { matches.append(.postTax) }
            found += matches.map { .kind($0) }
            // Side-by-side headers ("Earnings    Deductions") don't tell us which column a row belongs to.
            guard found.count == 1, let section = found.first else { return nil }
            self = section
        }
    }

    // MARK: Rows → label/amount groups

    struct Group {
        struct Number { let value: Double; let isMoney: Bool; let token: String }
        var label: String
        var numbers: [Number]
        var hasMoney: Bool { numbers.contains(where: \.isMoney) }
    }

    /// Splits a row into label + numbers groups, so side-by-side columns become separate items.
    static func groups(in row: String) -> [Group] {
        var groups: [Group] = []
        var label: [String] = []
        var numbers: [Group.Number] = []

        for token in row.split(whereSeparator: \.isWhitespace).map(String.init) where token != "$" {
            if let number = number(token) {
                numbers.append(number)
                continue
            }
            if numbers.contains(where: \.isMoney) {
                // Bare numbers right before the next label belong to it ("457 Plan", "401 k").
                var carried: [String] = []
                while let last = numbers.last, !last.isMoney {
                    carried.insert(last.token, at: 0)
                    numbers.removeLast()
                }
                groups.append(Group(label: label.joined(separator: " "), numbers: numbers))
                label = carried
                numbers = []
            } else if !numbers.isEmpty {
                label += numbers.map(\.token)
                numbers = []
            }
            label.append(token)
        }
        if !label.isEmpty || !numbers.isEmpty { groups.append(Group(label: label.joined(separator: " "), numbers: numbers)) }
        return groups
    }

    private static let moneyPattern = #"^\(?-?\$?-?\d{1,3}(,\d{3})*\.\d{2}\)?-?$|^\(?-?\$?-?\d+\.\d{2}\)?-?$"#
    private static let numberPattern = #"^\$?\d[\d,]*(\.\d+)?$"#

    static func number(_ token: String) -> Group.Number? {
        let isMoney = token.range(of: moneyPattern, options: .regularExpression) != nil
        guard isMoney || token.range(of: numberPattern, options: .regularExpression) != nil else { return nil }
        let digits = token.filter { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return nil }
        return .init(value: value, isMoney: isMoney, token: token)
    }

    /// This period's amount and year-to-date amount for a group.
    static func amounts(_ group: Group, hasYTDColumn: Bool) -> (Double, Double?)? {
        let n = group.numbers.map(\.value)
        // Hours × rate = current (earnings rows).
        if n.count >= 3, abs(n[0] * n[1] - n[2]) <= max(1, n[2] * 0.01) {
            return (n[2], n.count >= 4 ? n[3] : nil)
        }
        let money = group.numbers.drop { !$0.isMoney }.filter(\.isMoney).map(\.value)
        guard let last = money.last else { return nil }
        if money.count == 1 || !hasYTDColumn { return (last, nil) }
        let current = money[money.count - 2]
        return last >= current ? (current, last) : (last, nil)
    }

    private static func tidy(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Employer

    static func employer(in rows: [String]) -> String {
        let suffixes = ["inc", "llc", "corp", "corporation", "company", "co", "ltd", "group", "technologies", "holdings", "plc", "lp", "llp"]
        let titles = ["earnings statement", "pay stub", "paystub", "payslip", "pay slip", "statement of earnings", "pay statement", "advice", "pay date", "employee"]
        func firstColumn(_ row: String) -> String {
            var text = row.components(separatedBy: "   ").first ?? row
            // PDF text can run the company name and the document title together.
            for title in titles {
                if let range = text.range(of: title, options: .caseInsensitive), range.lowerBound > text.startIndex {
                    text = String(text[..<range.lowerBound])
                }
            }
            return text.trimmingCharacters(in: .whitespaces)
        }
        for row in rows.prefix(12) {
            let text = firstColumn(row)
            let words = text.lowercased().split { !$0.isLetter }.map(String.init)
            if words.contains(where: suffixes.contains) { return text }
        }
        for row in rows.prefix(6) {
            let text = firstColumn(row)
            let l = text.lowercased()
            if text.count >= 3, !titles.contains(where: l.contains), !text.contains(where: \.isNumber) { return text }
        }
        return ""
    }

    // MARK: Dates

    static func dates(in text: String) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        func make(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            let year = y < 100 ? 2000 + y : y
            guard (1...12).contains(m), (1...31).contains(d), (2000...2100).contains(year) else { return nil }
            return calendar.date(from: DateComponents(year: year, month: m, day: d, hour: 12))
        }
        let patterns: [(String, ([String]) -> Date?)] = [
            (#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#, { make(Int($0[0])!, Int($0[1])!, Int($0[2])!) }),
            (#"\b(\d{1,2})[/-](\d{1,2})[/-](\d{4}|\d{2})\b"#, { make(Int($0[2])!, Int($0[0])!, Int($0[1])!) }),
            (#"\b([A-Za-z]{3})[a-z]*\.? (\d{1,2}),? (\d{4})\b"#, { g in months.firstIndex(of: g[0].lowercased()).flatMap { make(Int(g[2])!, $0 + 1, Int(g[1])!) } }),
            (#"\b(\d{1,2}) ([A-Za-z]{3})[a-z]* (\d{4})\b"#, { g in months.firstIndex(of: g[1].lowercased()).flatMap { make(Int(g[2])!, $0 + 1, Int(g[0])!) } }),
        ]
        var found: [(Int, Date)] = []
        let ns = text as NSString
        for (pattern, build) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let groups = (1..<match.numberOfRanges).map { ns.substring(with: match.range(at: $0)) }
                if let date = build(groups), !found.contains(where: { $0.0 == match.range.location }) {
                    found.append((match.range.location, date))
                }
            }
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func applyDates(_ rows: [String], to draft: inout PayslipDraft, now: Date) {
        let payKeys = ["pay date", "check date", "payment date", "pay day", "payday", "deposit date", "advice date", "date paid"]
        let skipKeys = ["hire", "birth", "dob", "printed"]
        let latestPlausible = now.addingTimeInterval(45 * 86_400)
        var all: [Date] = []
        var payDate: Date?
        var period: (Date, Date)?

        for row in rows {
            let l = row.lowercased()
            guard !skipKeys.contains(where: l.contains) else { continue }
            let found = dates(in: row).filter { $0 <= latestPlausible }
            all += found
            if payDate == nil, payKeys.contains(where: l.contains), let first = found.last { payDate = first }
            if period == nil, l.contains("period") || l.contains("begin") || l.contains("ending"), found.count >= 2 {
                let pair = found.prefix(2).sorted()
                period = (pair[0], pair[1])
            }
        }
        let unique = Array(Set(all)).sorted()
        draft.payDate = payDate ?? unique.last ?? now
        if let period {
            draft.periodStart = period.0
            draft.periodEnd = period.1
        } else {
            let before = unique.filter { $0 < draft.payDate }
            if before.count >= 2 {
                draft.periodStart = before[before.count - 2]
                draft.periodEnd = before[before.count - 1]
            }
        }
    }

    // MARK: Frequency

    static func frequency(_ rows: [String], draft: PayslipDraft) -> PayFrequency? {
        let text = rows.joined(separator: " ").lowercased()
        if text.contains("bi-weekly") || text.contains("biweekly") || text.contains("bi weekly") || text.contains("every two weeks") { return .biweekly }
        if text.contains("semi-monthly") || text.contains("semimonthly") || text.contains("semi monthly") || text.contains("twice a month") { return .semimonthly }
        if text.range(of: #"\bweekly\b"#, options: .regularExpression) != nil { return .weekly }
        if text.range(of: #"\bmonthly\b"#, options: .regularExpression) != nil { return .monthly }

        if let start = draft.periodStart, let end = draft.periodEnd {
            let days = (Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0) + 1
            switch days {
            case 5...8: return .weekly
            case 14: return .biweekly
            case 12...17: return .semimonthly
            case 27...31: return .monthly
            default: break
            }
        }
        // Year-to-date gross ÷ this period's gross ≈ paychecks so far this year.
        if let ytd = draft.ytdGross, draft.grossPay > 0, ytd >= draft.grossPay {
            let paychecks = ytd / draft.grossPay
            let dayOfYear = Double(Calendar.current.ordinality(of: .day, in: .year, for: draft.payDate) ?? 1)
            return PayFrequency.allCases.min { abs($0.periodsPerYear * dayOfYear / 365 - paychecks) < abs($1.periodsPerYear * dayOfYear / 365 - paychecks) }
        }
        return nil
    }
}
