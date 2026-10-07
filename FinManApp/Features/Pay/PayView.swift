import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Your latest paycheck broken down: taxes, deductions, savings and take-home, plus past payslips.
struct PayView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Payslip.payDate, order: .reverse) private var payslips: [Payslip]

    @State private var review: ReviewItem?
    @State private var showScanner = false
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var reading = false
    @State private var error: String?

    struct ReviewItem: Identifiable {
        let id = UUID()
        let draft: PayslipDraft
        var payslip: Payslip?
        let isLatest: Bool
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let latest = payslips.first {
                    PaycheckHero(payslip: latest)
                    PayBreakdownCard(payslip: latest)
                    monthlyCard(latest)
                    if let previous = payslips.dropFirst().first {
                        PayChangesCard(current: latest, previous: previous)
                    }
                    ForEach(PayLineKind.allCases) { kind in
                        if !latest.lines(kind).isEmpty { linesCard(latest, kind: kind) }
                    }
                    yearToDate(latest)
                    history
                } else {
                    emptyState
                }
                Label("Payslips are read on this iPhone. Only the numbers are kept, never the document.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Paycheck")
        .toolbar {
            if !payslips.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu { importOptions } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add payslip")
                }
            }
        }
        .overlay { if reading { readingOverlay } }
        .sheet(item: $review) { item in
            PayslipReviewView(draft: item.draft, payslip: item.payslip, isLatest: item.isLatest)
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScanner { images in
                showScanner = false
                let pages = images.compactMap { $0.jpegData(compressionQuality: 0.9) }
                read { try await PayslipReader.read(images: pages) }
            } onCancel: {
                showScanner = false
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 3, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            reading = true
            Task {
                var pages: [Data] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { pages.append(data) }
                }
                read { try await PayslipReader.read(images: pages) }
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                error = PayslipReader.ReadError.unreadable.localizedDescription
                return
            }
            let isPDF = UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) ?? false
            read { isPDF ? try await PayslipReader.read(pdf: data) : try await PayslipReader.read(images: [data]) }
        }
        .alert("Couldn't read that payslip", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Enter by hand") { startManual() }
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        #if DEBUG
        // `-pay <file>` imports that PDF or image on launch.
        .task {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-pay"), i + 1 < args.count, !args[i + 1].hasPrefix("-"),
                  let data = FileManager.default.contents(atPath: args[i + 1]) else { return }
            let isPDF = args[i + 1].lowercased().hasSuffix(".pdf")
            read { isPDF ? try await PayslipReader.read(pdf: data) : try await PayslipReader.read(images: [data]) }
        }
        #endif
    }

    // MARK: Importing

    @ViewBuilder
    private var importOptions: some View {
        if DocumentScanner.isAvailable {
            Button { showScanner = true } label: { Label("Scan with camera", systemImage: "doc.viewfinder") }
        }
        Button { showPhotos = true } label: { Label("Choose photo", systemImage: "photo") }
        Button { showFiles = true } label: { Label("Import PDF or image", systemImage: "folder") }
        Button { startManual() } label: { Label("Enter by hand", systemImage: "square.and.pencil") }
    }

    private func read(_ work: @escaping @Sendable () async throws -> PayslipDraft) {
        reading = true
        Task {
            defer { reading = false }
            do {
                let draft = try await work()
                review = ReviewItem(draft: draft, isLatest: draft.payDate >= (payslips.first?.payDate ?? .distantPast))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func startManual() {
        var draft = PayslipDraft(source: .manual)
        draft.frequency = payslips.first?.frequency ?? .biweekly
        draft.employer = payslips.first?.employer ?? ""
        review = ReviewItem(draft: draft, isLatest: true)
    }

    private var readingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Reading your payslip…").font(.headline)
            Text(PayslipReader.isModelAvailable ? "On this iPhone, with Apple Intelligence if needed" : "On this iPhone")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .background(.regularMaterial, in: .rect(cornerRadius: 24, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.15))
        .transition(.opacity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            EmptyStateView(emoji: "🧾", title: "See where your paycheck goes",
                           message: "Add a payslip and FinMan works out your taxes, deductions, savings and real take-home pay.")
            VStack(spacing: 10) {
                if DocumentScanner.isAvailable {
                    Button { showScanner = true } label: { Label("Scan payslip", systemImage: "doc.viewfinder") }
                        .buttonStyle(PrimaryButtonStyle())
                }
                HStack(spacing: 10) {
                    Button { showPhotos = true } label: { Label("Photo", systemImage: "photo").frame(maxWidth: .infinity) }
                    Button { showFiles = true } label: { Label("PDF", systemImage: "folder").frame(maxWidth: .infinity) }
                    Button { startManual() } label: { Label("By hand", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .card()
    }

    // MARK: Cards

    private func monthlyCard(_ payslip: Payslip) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Every month").font(.headline)
            row("Gross pay", payslip.monthly(payslip.grossPay))
            row("Taxes", -payslip.monthly(payslip.taxes))
            if payslip.savingsContributions > 0 { row("Saved through payroll", -payslip.monthlySavings) }
            if payslip.deductions - payslip.savingsContributions > 0.005 {
                row("Benefits and other deductions", -payslip.monthly(payslip.deductions - payslip.savingsContributions))
            }
            Divider()
            row("Take-home", payslip.monthlyNet, bold: true)
            Text("Based on \(Int(payslip.frequency.periodsPerYear)) paychecks a year.").font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    private func linesCard(_ payslip: Payslip, kind: PayLineKind) -> some View {
        let lines = payslip.lines(kind)
        let showYTD = lines.contains { $0.ytd != nil }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(kind.title, systemImage: kind.symbol).font(.headline)
                Spacer()
                if showYTD { Text("This year").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline) {
                    Text(line.name).font(.subheadline)
                    if line.isSavings {
                        Text("Savings")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.14), in: .capsule)
                    }
                    Spacer()
                    Text(line.amount.currency()).font(.subheadline.weight(.semibold)).monospacedDigit()
                    if showYTD {
                        Text(line.ytd?.currency(compact: true) ?? "–")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .frame(minWidth: 64, alignment: .trailing)
                    }
                }
            }
            if lines.count > 1 {
                Divider()
                HStack {
                    Text("Total").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(payslip.total(kind).currency()).font(.subheadline.weight(.bold)).monospacedDigit()
                }
            }
            if kind == .tax, payslip.grossPay > 0 {
                Text("\(payslip.effectiveTaxRate.formatted(.percent.precision(.fractionLength(1)))) of your gross pay goes to taxes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    @ViewBuilder
    private func yearToDate(_ payslip: Payslip) -> some View {
        if let ytdGross = payslip.ytdGross {
            let taxLines = payslip.lines(.tax)
            let ytdTaxes = taxLines.allSatisfy { $0.ytd != nil } ? taxLines.reduce(0) { $0 + ($1.ytd ?? 0) } : nil
            VStack(alignment: .leading, spacing: 12) {
                Text("This year so far").font(.headline)
                row("Earned", ytdGross)
                if let ytdTaxes, ytdTaxes > 0 { row("Paid in taxes", -ytdTaxes) }
                if let ytdNet = payslip.ytdNet { row("Took home", ytdNet, bold: true) }
            }
            .card()
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Payslips")
            VStack(spacing: 0) {
                ForEach(payslips) { payslip in
                    Button {
                        review = ReviewItem(draft: payslip.draft, payslip: payslip, isLatest: payslip.id == payslips.first?.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(payslip.payDate.formatted(date: .abbreviated, time: .omitted)).font(.subheadline.weight(.semibold))
                                if !payslip.employer.isEmpty { Text(payslip.employer).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text(payslip.netPay.currency()).font(.subheadline.weight(.semibold)).monospacedDigit()
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 10)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            context.delete(payslip)
                            try? context.save()
                        } label: {
                            Label("Delete payslip", systemImage: "trash")
                        }
                    }
                    if payslip.id != payslips.last?.id { Divider() }
                }
            }
            .card(padding: 14)
        }
    }

    private func row(_ title: String, _ amount: Double, bold: Bool = false) -> some View {
        HStack {
            Text(title).font(bold ? .subheadline.weight(.semibold) : .subheadline)
            Spacer()
            Text(amount < 0 ? "−\(abs(amount).currency())" : amount.currency())
                .font(bold ? .headline : .subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(bold ? Theme.income : Color.primary)
        }
    }
}

// MARK: - Components

private struct PaycheckHero: View {
    let payslip: Payslip

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Take-home pay").font(.subheadline.weight(.medium)).opacity(0.85)
                Text(payslip.netPay.currency())
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text([payslip.employer, "Paid \(payslip.payDate.formatted(date: .abbreviated, time: .omitted))", payslip.frequency.label]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.footnote).opacity(0.85)
            }
            HStack(spacing: 12) {
                stat("Per month", payslip.monthlyNet.currency(compact: true))
                stat("Gross", payslip.grossPay.currency(compact: true))
                stat("Tax rate", payslip.effectiveTaxRate.formatted(.percent.precision(.fractionLength(0))))
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.brandGradient, in: .rect(cornerRadius: 28, style: .continuous))
        .shadow(color: Theme.brand.opacity(0.35), radius: 20, y: 10)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).opacity(0.85)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.15), in: .rect(cornerRadius: 16, style: .continuous))
    }
}

/// Gross pay split into take-home, taxes, payroll savings and other deductions.
/// `compact` draws just the bar, for embedding in other cards.
struct PayBreakdownCard: View {
    let payslip: Payslip
    var compact = false

    struct Segment: Identifiable {
        var id: String { title }
        let title: String
        let amount: Double
        let color: Color
    }

    var segments: [Segment] {
        [
            Segment(title: "Take-home", amount: payslip.netPay, color: Theme.income),
            Segment(title: "Taxes", amount: payslip.taxes, color: Theme.expense),
            Segment(title: "Savings", amount: payslip.savingsContributions, color: .purple),
            Segment(title: "Benefits & other", amount: max(0, payslip.deductions - payslip.savingsContributions), color: Theme.warning),
        ].filter { $0.amount > 0.005 }
    }

    var body: some View {
        if compact { content } else { content.card() }
    }

    private var content: some View {
        let total = max(segments.reduce(0) { $0 + $1.amount }, 0.01)
        return VStack(alignment: .leading, spacing: 14) {
            if !compact { Text("Where your pay goes").font(.headline) }
            GeometryReader { geo in
                HStack(spacing: 3) {
                    ForEach(segments) { segment in
                        segment.color.frame(width: max(4, (geo.size.width - CGFloat(segments.count - 1) * 3) * segment.amount / total))
                    }
                }
                .clipShape(.capsule)
            }
            .frame(height: compact ? 10 : 16)
            if !compact {
                ForEach(segments) { segment in
                    HStack {
                        Circle().fill(segment.color).frame(width: 10, height: 10)
                        Text(segment.title).font(.subheadline)
                        Spacer()
                        Text(segment.amount.currency()).font(.subheadline.weight(.semibold)).monospacedDigit()
                        Text((segment.amount / total).formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
    }
}

/// What changed between the two most recent payslips: raises, new or dropped deductions, tax changes.
private struct PayChangesCard: View {
    let current: Payslip
    let previous: Payslip

    private var changes: [(String, String)] {
        let old = Dictionary(previous.lines.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(current.lines.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var result: [(String, String)] = []
        for line in current.lines {
            if let before = old[line.name.lowercased()] {
                if abs(before.amount - line.amount) >= 0.5 { result.append((line.name, "\(before.amount.currency()) → \(line.amount.currency())")) }
            } else {
                result.append((line.name, "New · \(line.amount.currency())"))
            }
        }
        for line in previous.lines where new[line.name.lowercased()] == nil {
            result.append((line.name, "Gone · was \(line.amount.currency())"))
        }
        return result
    }

    var body: some View {
        let netChange = current.netPay - previous.netPay
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Since your last payslip").font(.headline)
                Spacer()
                Text(abs(netChange) < 0.005 ? "No change" : "\(netChange.currency(showSign: true)) take-home")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(netChange >= 0 ? Theme.income : Theme.expense)
            }
            let list = changes
            if list.isEmpty {
                Text("Same pay, taxes and deductions as \(previous.payDate.formatted(date: .abbreviated, time: .omitted)).")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(list.prefix(6), id: \.0) { name, detail in
                    HStack {
                        Text(name).font(.subheadline)
                        Spacer()
                        Text(detail).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .card()
    }
}
