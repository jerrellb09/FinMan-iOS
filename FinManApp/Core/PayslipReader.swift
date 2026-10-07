import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns a payslip (PDF, photo or scan) into a `PayslipDraft`, entirely on device. The document itself is never stored.
nonisolated enum PayslipReader {
    enum ReadError: LocalizedError {
        case unreadable, noText, notAPayslip

        var errorDescription: String? {
            switch self {
            case .unreadable: "That file couldn't be opened. Try a PDF, a photo, or scanning the payslip."
            case .noText: "No text was found. Try a sharper photo in good light, or the PDF from your payroll site."
            case .notAPayslip: "Couldn't find gross or net pay. Check it's a payslip, or enter the numbers by hand."
            }
        }
    }

    /// A piece of text and where it sits on the page (normalized, origin bottom-left).
    struct Fragment: Sendable {
        let text: String
        let rect: CGRect
    }

    // MARK: Inputs

    @concurrent
    static func read(pdf data: Data) async throws -> PayslipDraft {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw ReadError.unreadable }
        var rows: [String] = []
        for index in 0..<min(document.pageCount, 4) {
            guard let page = document.page(at: index) else { continue }
            var fragments = textFragments(on: page)
            // Scanned PDFs are just pictures of text.
            if fragments.count < 5, let image = render(page) {
                fragments = try await recognize(image, orientation: .up)
            }
            rows += self.rows(from: fragments)
        }
        return try await draft(from: rows)
    }

    /// Photos or scanned pages (JPEG/PNG/HEIC data), in page order.
    @concurrent
    static func read(images: [Data]) async throws -> PayslipDraft {
        var rows: [String] = []
        for data in images {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ReadError.unreadable }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init) ?? .up
            rows += self.rows(from: try await recognize(image, orientation: orientation))
        }
        return try await draft(from: rows)
    }

    // MARK: Text extraction

    static func textFragments(on page: PDFPage) -> [Fragment] {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0, let selection = page.selection(for: bounds) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let r = line.bounds(for: page)
            return Fragment(text: text, rect: CGRect(x: (r.minX - bounds.minX) / bounds.width, y: (r.minY - bounds.minY) / bounds.height,
                                                     width: r.width / bounds.width, height: r.height / bounds.height))
        }
    }

    static func render(_ page: PDFPage, scale: CGFloat = 2.5) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard let context = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(context.width), height: CGFloat(context.height)))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    static func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation) async throws -> [Fragment] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Language correction "fixes" figures and codes; payslips are mostly both.
        request.usesLanguageCorrection = false
        let observations = try await request.perform(on: image, orientation: orientation)
        return observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return Fragment(text: text, rect: observation.boundingBox.cgRect)
        }
    }

    /// Groups fragments into visual rows, top to bottom, with columns separated by three spaces.
    static func rows(from fragments: [Fragment]) -> [String] {
        var rows: [[Fragment]] = []
        for fragment in fragments.sorted(by: { $0.rect.midY > $1.rect.midY }) {
            if let anchor = rows.last?.first,
               abs(anchor.rect.midY - fragment.rect.midY) < min(anchor.rect.height, fragment.rect.height) * 0.5 {
                rows[rows.count - 1].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        return rows.map { $0.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: "   ") }
    }

    // MARK: Rows → draft

    static func draft(from rawRows: [String], now: Date = .now) async throws -> PayslipDraft {
        let rows = rawRows.map(PayslipParser.sanitize).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !rows.isEmpty else { throw ReadError.noText }

        // The rules are fast and classify lines consistently, so the model only steps in when they can't reconcile the figures.
        let (ruled, isConfident) = PayslipParser.read(rows: rows, now: now)
        var best = ruled
        if !isConfident, var modelled = await extractWithModel(rows, fallback: ruled), modelled.grossPay > 0 || modelled.netPay > 0 {
            // Pay period dates and wording settle the frequency more reliably than the model does.
            modelled.frequency = PayslipParser.frequency(rows, draft: modelled) ?? modelled.frequency
            modelled.dropImplausibleYTD()
            if modelled.addsUp || !ruled.addsUp { best = modelled }
        }
        guard best.grossPay > 0 || best.netPay > 0 else { throw ReadError.notAPayslip }
        return best
    }

    static var isModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    /// Structured extraction with Apple's on-device model. Nil when it's unavailable or fails.
    static func extractWithModel(_ rows: [String], fallback: PayslipDraft) async -> PayslipDraft? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *), isModelAvailable else { return nil }
        // Column gaps become pipes, and the text is capped to stay inside the model's context window.
        let text = String(rows.map { $0.replacingOccurrences(of: #" {3,}"#, with: " | ", options: .regularExpression) }
            .joined(separator: "\n").prefix(6_000))
        let session = LanguageModelSession(instructions: """
            You extract figures from payslips (pay stubs). The text was read from the document one visual row per line, \
            with " | " between columns. Rows often hold two side-by-side tables, such as earnings on the left and deductions on the right. \
            Amounts usually appear as a current-period column followed by a year-to-date column. \
            Copy numbers exactly as printed; never calculate, round or invent values. Use 0 or empty text for anything not shown.
            """)
        do {
            let response = try await session.respond(to: "Payslip text:\n\n\(text)", generating: ModelPayslip.self,
                                                     options: GenerationOptions(sampling: .greedy))
            return response.content.draft(fallback: fallback)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable
nonisolated struct ModelPayslip {
    @Guide(description: "Name of the company that issued the payslip, or empty if not shown")
    var employer: String
    @Guide(description: "Date this pay was issued (the pay date or check date) as YYYY-MM-DD")
    var payDate: String
    @Guide(description: "First day of the pay period as YYYY-MM-DD, or empty if not shown")
    var periodStart: String
    @Guide(description: "Last day of the pay period as YYYY-MM-DD, or empty if not shown")
    var periodEnd: String
    var payFrequency: ModelPayFrequency
    @Guide(description: "Total gross pay for this pay period (the current column, not year-to-date)")
    var grossPay: Double
    @Guide(description: "Net pay (take-home pay) for this pay period")
    var netPay: Double
    @Guide(description: "Year-to-date gross pay, or 0 if not shown")
    var ytdGross: Double
    @Guide(description: "Year-to-date net pay, or 0 if not shown")
    var ytdNet: Double
    @Guide(description: "Every individual earning, tax, deduction and employer contribution line. Leave out total, subtotal, gross and net rows.")
    var lines: [ModelPayLine]

    func draft(fallback: PayslipDraft) -> PayslipDraft {
        func date(_ text: String) -> Date? { PayslipParser.dates(in: text).first }
        var draft = PayslipDraft(source: .appleIntelligence)
        draft.employer = employer.isEmpty ? fallback.employer : employer
        draft.payDate = date(payDate) ?? fallback.payDate
        draft.periodStart = date(periodStart) ?? fallback.periodStart
        draft.periodEnd = date(periodEnd) ?? fallback.periodEnd
        draft.frequency = payFrequency.frequency ?? fallback.frequency
        draft.grossPay = abs(grossPay)
        draft.netPay = abs(netPay)
        draft.ytdGross = ytdGross > 0 ? ytdGross : nil
        draft.ytdNet = ytdNet > 0 ? ytdNet : nil
        draft.lines = lines.compactMap { line in
            let name = line.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, line.amount != 0 else { return nil }
            // Known labels get the same category the rules would give them; the model decides only for unfamiliar ones.
            var kind = line.kind.kind
            switch PayslipParser.classify(name) {
            case .line(let known, _): kind = known
            case .gross, .net, .ignore: return nil
            case .unknown: break
            }
            return .init(name: name, kind: kind, amount: abs(line.amount), ytd: line.ytd > 0 ? line.ytd : nil,
                         isSavings: kind.reducesNet && PayslipParser.isSavings(name))
        }
        return draft
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
nonisolated struct ModelPayLine {
    @Guide(description: "The line's label exactly as printed, e.g. Federal Income Tax")
    var name: String
    var kind: ModelPayLineKind
    @Guide(description: "Amount for this pay period as a positive number")
    var amount: Double
    @Guide(description: "Year-to-date amount as a positive number, or 0 if not shown")
    var ytd: Double
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
nonisolated enum ModelPayLineKind {
    case earning, tax, preTaxDeduction, afterTaxDeduction, employerContribution

    var kind: PayLineKind {
        switch self {
        case .earning: .earning
        case .tax: .tax
        case .preTaxDeduction: .preTax
        case .afterTaxDeduction: .postTax
        case .employerContribution: .employer
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
nonisolated enum ModelPayFrequency {
    case weekly, biweekly, semimonthly, monthly, unknown

    var frequency: PayFrequency? {
        switch self {
        case .weekly: .weekly
        case .biweekly: .biweekly
        case .semimonthly: .semimonthly
        case .monthly: .monthly
        case .unknown: nil
        }
    }
}
#endif
