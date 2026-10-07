import Foundation
import SwiftData

// Only the numbers read off a payslip are stored, never the document itself.

nonisolated enum PayFrequency: String, CaseIterable, Identifiable, Sendable {
    case weekly = "WEEKLY", biweekly = "BIWEEKLY", semimonthly = "SEMIMONTHLY", monthly = "MONTHLY"
    var id: Self { self }

    var periodsPerYear: Double {
        switch self {
        case .weekly: 52
        case .biweekly: 26
        case .semimonthly: 24
        case .monthly: 12
        }
    }

    var label: String {
        switch self {
        case .weekly: "Weekly"
        case .biweekly: "Every 2 weeks"
        case .semimonthly: "Twice a month"
        case .monthly: "Monthly"
        }
    }
}

nonisolated enum PayLineKind: String, CaseIterable, Identifiable, Sendable {
    case earning = "EARNING", tax = "TAX", preTax = "PRETAX", postTax = "POSTTAX", employer = "EMPLOYER"
    var id: Self { self }

    var title: String {
        switch self {
        case .earning: "Earnings"
        case .tax: "Taxes"
        case .preTax: "Pre-tax deductions"
        case .postTax: "After-tax deductions"
        case .employer: "Paid by your employer"
        }
    }

    var symbol: String {
        switch self {
        case .earning: "dollarsign.circle.fill"
        case .tax: "building.columns.fill"
        case .preTax: "arrow.down.circle.fill"
        case .postTax: "minus.circle.fill"
        case .employer: "gift.fill"
        }
    }

    /// Whether the line comes out of gross pay on the way to net pay.
    var reducesNet: Bool { self == .tax || self == .preTax || self == .postTax }
}

@Model
final class Payslip {
    var employer: String = ""
    var payDate: Date = Date.now
    var periodStart: Date?
    var periodEnd: Date?
    /// A `PayFrequency` raw value.
    var frequencyRaw: String = PayFrequency.biweekly.rawValue
    var grossPay: Double = 0
    var netPay: Double = 0
    var ytdGross: Double?
    var ytdNet: Double?
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \PayslipItem.payslip)
    var items: [PayslipItem]? = []

    /// Insert it into a context, then `apply` a draft to fill it in.
    init() {}

    var frequency: PayFrequency {
        get { PayFrequency(rawValue: frequencyRaw) ?? .biweekly }
        set { frequencyRaw = newValue.rawValue }
    }

    var lines: [PayslipItem] { (items ?? []).sorted { $0.sortOrder < $1.sortOrder } }
    func lines(_ kind: PayLineKind) -> [PayslipItem] { lines.filter { $0.kind == kind } }
    func total(_ kind: PayLineKind) -> Double { lines(kind).reduce(0) { $0 + $1.amount } }

    var taxes: Double { total(.tax) }
    var deductions: Double { total(.preTax) + total(.postTax) }
    /// Retirement, HSA and similar contributions taken out of pay.
    var savingsContributions: Double { lines.filter { $0.isSavings && $0.kind.reducesNet }.reduce(0) { $0 + $1.amount } }
    var effectiveTaxRate: Double { grossPay > 0 ? taxes / grossPay : 0 }

    /// Converts a per-paycheck amount to a monthly one (e.g. biweekly × 26 ÷ 12).
    func monthly(_ amount: Double) -> Double { amount * frequency.periodsPerYear / 12 }
    var monthlyNet: Double { monthly(netPay) }
    var monthlySavings: Double { monthly(savingsContributions) }

    /// Replaces this payslip's values and line items with the draft's.
    func apply(_ draft: PayslipDraft) {
        for item in items ?? [] { modelContext?.delete(item) }
        employer = draft.employer
        payDate = draft.payDate
        periodStart = draft.periodStart
        periodEnd = draft.periodEnd
        frequency = draft.frequency
        grossPay = draft.grossPay
        netPay = draft.netPay
        ytdGross = draft.ytdGross
        ytdNet = draft.ytdNet
        items = draft.lines.enumerated().map { index, line in
            PayslipItem(name: line.name, kind: line.kind, amount: line.amount, ytd: line.ytd, isSavings: line.isSavings, sortOrder: index)
        }
    }

    var draft: PayslipDraft {
        PayslipDraft(employer: employer, payDate: payDate, periodStart: periodStart, periodEnd: periodEnd, frequency: frequency,
                     grossPay: grossPay, netPay: netPay, ytdGross: ytdGross, ytdNet: ytdNet,
                     lines: lines.map { .init(name: $0.name, kind: $0.kind, amount: $0.amount, ytd: $0.ytd, isSavings: $0.isSavings) },
                     source: .saved)
    }
}

@Model
final class PayslipItem {
    var name: String = ""
    /// A `PayLineKind` raw value.
    var kindRaw: String = PayLineKind.tax.rawValue
    /// This period's amount, always positive.
    var amount: Double = 0
    var ytd: Double?
    var isSavings: Bool = false
    var sortOrder: Int = 0
    var payslip: Payslip?

    init(name: String, kind: PayLineKind, amount: Double, ytd: Double? = nil, isSavings: Bool = false, sortOrder: Int = 0) {
        self.name = name
        self.kindRaw = kind.rawValue
        self.amount = amount
        self.ytd = ytd
        self.isSavings = isSavings
        self.sortOrder = sortOrder
    }

    var kind: PayLineKind {
        get { PayLineKind(rawValue: kindRaw) ?? .postTax }
        set { kindRaw = newValue.rawValue }
    }
}

/// An editable, unsaved payslip: what the reader extracts and the review screen edits.
nonisolated struct PayslipDraft: Sendable, Equatable {
    struct Line: Identifiable, Sendable, Equatable {
        var id = UUID()
        var name: String
        var kind: PayLineKind
        var amount: Double
        var ytd: Double?
        var isSavings = false
    }

    enum Source: Sendable, Equatable {
        case appleIntelligence, rules, manual, saved

        var label: String {
            switch self {
            case .appleIntelligence: "Read with Apple Intelligence"
            case .rules: "Read with smart parsing"
            case .manual: "Entered by hand"
            case .saved: "Saved payslip"
            }
        }
    }

    var employer = ""
    var payDate = Date.now
    var periodStart: Date?
    var periodEnd: Date?
    var frequency = PayFrequency.biweekly
    var grossPay = 0.0
    var netPay = 0.0
    var ytdGross: Double?
    var ytdNet: Double?
    var lines: [Line] = []
    var source = Source.manual

    func total(_ kind: PayLineKind) -> Double { lines.filter { $0.kind == kind }.reduce(0) { $0 + $1.amount } }

    /// Gross minus everything withheld, i.e. what net pay should be.
    var computedNet: Double { grossPay - lines.filter(\.kind.reducesNet).reduce(0) { $0 + $1.amount } }
    /// How far the stated net pay is from gross minus withholdings (0 when it all adds up).
    var discrepancy: Double { ((netPay - computedNet) * 100).rounded() / 100 }
    var addsUp: Bool { abs(discrepancy) < 0.05 }
    var monthlyNet: Double { netPay * frequency.periodsPerYear / 12 }

    /// Year-to-date totals can't be below this period's, and net is never a small slice of gross.
    mutating func dropImplausibleYTD() {
        if let ytd = ytdGross, ytd < grossPay { ytdGross = nil }
        if let ytd = ytdNet, ytd < netPay || ytd > (ytdGross ?? .infinity) || ytd < (ytdGross ?? 0) * 0.4 { ytdNet = nil }
    }
}
