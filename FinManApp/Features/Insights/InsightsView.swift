import Charts
import SwiftUI

struct InsightsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedSlice: String?
    @State private var rawSelection: Double?

    private var analytics: Analytics { Analytics(transactions: model.transactions) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    AICoachCard()
                    categoryDonut
                    monthlyBars
                    topMerchants
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .refreshable { await model.loadTransactions() }
            .navigationTitle("Insights")
        }
    }

    // MARK: Category donut

    private var categoryDonut: some View {
        let slices = analytics.byCategory()
        let total = slices.reduce(0) { $0 + $1.amount }
        let focused = slices.first { $0.name == selectedSlice }

        return VStack(alignment: .leading, spacing: 16) {
            Text("Where it went this month").font(.headline)
            if slices.isEmpty {
                Text("No spending this month yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("Amount", slice.amount),
                        innerRadius: .ratio(0.62),
                        outerRadius: .ratio(selectedSlice == slice.name ? 1.0 : 0.92),
                        angularInset: 2
                    )
                    .cornerRadius(6)
                    .foregroundStyle(CategoryStyle.forName(slice.name).color)
                    .opacity(selectedSlice == nil || selectedSlice == slice.name ? 1 : 0.35)
                }
                .chartAngleSelection(value: $rawSelection)
                .onChange(of: rawSelection) { _, value in
                    guard let value else { return }
                    var running = 0.0
                    let hit = slices.first { running += $0.amount; return value <= running }?.name
                    withAnimation(.snappy) { selectedSlice = selectedSlice == hit ? nil : hit }
                }
                .chartBackground { _ in
                    VStack(spacing: 2) {
                        Text(focused.map { CategoryStyle.forName($0.name).emoji } ?? "💸").font(.title)
                        Text((focused?.amount ?? total).currency(compact: true)).font(.title3.bold()).monospacedDigit()
                            .contentTransition(.numericText())
                        Text(focused?.name ?? "Total").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 230)
                .sensoryFeedback(.selection, trigger: selectedSlice)

                VStack(spacing: 10) {
                    ForEach(slices.prefix(6)) { slice in
                        Button {
                            withAnimation(.snappy) { selectedSlice = selectedSlice == slice.name ? nil : slice.name }
                        } label: {
                            HStack {
                                Circle().fill(CategoryStyle.forName(slice.name).color).frame(width: 10, height: 10)
                                Text(slice.name).font(.subheadline)
                                Spacer()
                                Text((slice.amount / max(total, 1)).formatted(.percent.precision(.fractionLength(0))))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(slice.amount.currency()).font(.subheadline.weight(.semibold)).monospacedDigit()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .card()
    }

    // MARK: Monthly bars

    private var monthlyBars: some View {
        let points = analytics.monthlyTrend()
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Income vs spending").font(.headline)
                Spacer()
                HStack(spacing: 10) {
                    legend("In", Theme.income)
                    legend("Out", Theme.expense)
                }
            }
            Chart {
                ForEach(points) { p in
                    BarMark(x: .value("Month", p.month, unit: .month), y: .value("Amount", p.income))
                        .foregroundStyle(Theme.income.gradient)
                        .position(by: .value("Kind", "Income"))
                        .cornerRadius(5)
                    BarMark(x: .value("Month", p.month, unit: .month), y: .value("Amount", p.spending))
                        .foregroundStyle(Theme.expense.gradient)
                        .position(by: .value("Kind", "Spending"))
                        .cornerRadius(5)
                }
            }
            .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(v.currency(compact: true)) } }
                }
            }
            .frame(height: 200)

            let saved = points.reduce(0) { $0 + $1.income - $1.spending }
            Text(saved >= 0 ? "🙌 You've kept \(saved.currency()) over the last 6 months."
                            : "📉 You've spent \(abs(saved).currency()) more than you earned over 6 months.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Merchants

    @ViewBuilder
    private var topMerchants: some View {
        let merchants = analytics.topMerchants()
        if !merchants.isEmpty {
            let maxAmount = merchants.first?.amount ?? 1
            VStack(alignment: .leading, spacing: 14) {
                Text("Top spots this month").font(.headline)
                ForEach(Array(merchants.enumerated()), id: \.element.id) { index, merchant in
                    HStack(spacing: 12) {
                        Text(["🥇", "🥈", "🥉", "4️⃣", "5️⃣"][min(index, 4)]).font(.title3)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(merchant.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Spacer()
                                Text(merchant.amount.currency()).font(.subheadline.weight(.semibold)).monospacedDigit()
                            }
                            GeometryReader { geo in
                                Capsule().fill(Theme.brandGradient)
                                    .frame(width: geo.size.width * merchant.amount / maxAmount, height: 6)
                            }
                            .frame(height: 6)
                            Text("\(merchant.count) visit\(merchant.count == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .card()
        }
    }
}

/// Pulls narrative advice from the backend's AI endpoints (Claude / Llama via AIService).
struct AICoachCard: View {
    @Environment(AppModel.self) private var model

    enum Mode: String, CaseIterable, Identifiable {
        case insights = "Insights", budgets = "Budget ideas", habits = "Habits"
        var id: Self { self }
        var path: String {
            switch self {
            case .insights: "/api/insights/ai/financial-insights"
            case .budgets: "/api/insights/ai/budget-suggestions"
            case .habits: "/api/insights/ai/spending-habits"
            }
        }
        var icon: String {
            switch self {
            case .insights: "lightbulb.fill"
            case .budgets: "target"
            case .habits: "brain.head.profile"
            }
        }
    }

    @State private var mode: Mode = .insights
    @State private var results: [Mode: String] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("AI money coach", systemImage: "sparkles")
                    .font(.headline)
                    .symbolEffect(.pulse, isActive: loading)
                Spacer()
            }
            .foregroundStyle(.white)

            HStack(spacing: 8) {
                ForEach(Mode.allCases) { m in
                    Button {
                        withAnimation(.snappy) { mode = m; expanded = false }
                    } label: {
                        Label(m.rawValue, systemImage: m.icon)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(.white.opacity(mode == m ? 0.95 : 0.18), in: .capsule)
                            .foregroundStyle(mode == m ? Theme.brand : .white)
                    }
                    .buttonStyle(.plain)
                }
            }

            Group {
                if loading {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Crunching your numbers…").font(.subheadline)
                    }
                    .padding(.vertical, 8)
                } else if let text = results[mode] {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text)
                            .font(.subheadline)
                            .lineLimit(expanded ? nil : 6)
                            .textSelection(.enabled)
                        Button(expanded ? "Show less" : "Read more") { withAnimation(.snappy) { expanded.toggle() } }
                            .font(.caption.bold())
                    }
                } else if let error {
                    Text(error).font(.footnote)
                } else {
                    Text("Get personalised tips based on your spending, bills and budgets.").font(.subheadline).opacity(0.9)
                }
            }
            .foregroundStyle(.white)
            .transition(.opacity)

            Button {
                Task { await fetch() }
            } label: {
                Label(results[mode] == nil ? "Ask the coach" : "Ask again", systemImage: "wand.and.stars")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.white, in: .rect(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(Theme.brand)
            }
            .buttonStyle(PressableStyle())
            .disabled(loading)
        }
        .padding(18)
        .background(Theme.brandGradient, in: .rect(cornerRadius: 26, style: .continuous))
        .shadow(color: Theme.brand.opacity(0.3), radius: 16, y: 8)
        .sensoryFeedback(.success, trigger: results.count)
    }

    private func fetch() async {
        let current = mode
        loading = true
        error = nil
        defer { loading = false }
        do {
            let response: AIText = try await model.api.get(current.path)
            withAnimation(.snappy) {
                results[current] = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "The coach didn't have anything to say this time."
            }
        } catch {
            self.error = "The AI coach is unavailable right now. \(error.localizedDescription)"
        }
    }
}
