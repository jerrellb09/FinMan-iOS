import Charts
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedTab: AppTab

    @State private var showSettings = false
    @State private var quickAdd: QuickAddKind?

    private var analytics: Analytics { Analytics(transactions: model.transactions) }
    private var totalBalance: Double { model.accounts.reduce(0) { $0 + $1.balance.doubleValue } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    heroCard
                    quickActions
                    healthCard
                    spendingPaceCard
                    upcomingBills
                    budgetsSnapshot
                    recentActivity
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .refreshable { await model.refreshAll() }
            .navigationTitle(greeting)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Text(model.user?.initials ?? "?")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Theme.brandGradient, in: .circle)
                    }
                    .accessibilityLabel("Profile and settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(item: $quickAdd) { kind in
                TransactionEditor(transaction: nil, startAsIncome: kind == .income)
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return "\(part), \(model.user?.displayName ?? "friend")"
    }

    // MARK: Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total balance").font(.subheadline.weight(.medium)).opacity(0.85)
                    Text(totalBalance.currency())
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: totalBalance))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
                Spacer()
                if model.user?.isDemo == true {
                    Text("DEMO").font(.caption2.weight(.heavy)).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.white.opacity(0.2), in: .capsule)
                }
            }

            HStack(spacing: 12) {
                heroStat(title: "Spent this month", value: analytics.spentThisMonth.currency(), icon: "arrow.up.right")
                heroStat(title: "Income this month", value: analytics.incomeThisMonth.currency(), icon: "arrow.down.left")
            }

            if let change = analytics.spendingChange {
                HStack(spacing: 6) {
                    Image(systemName: change <= 0 ? "hand.thumbsup.fill" : "flame.fill")
                    Text(change <= 0
                         ? "You're spending \(abs(change).formatted(.percent.precision(.fractionLength(0)))) less than this time last month. Nice!"
                         : "Spending is up \(change.formatted(.percent.precision(.fractionLength(0)))) vs this time last month.")
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.white.opacity(0.18), in: .capsule)
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .background {
            ZStack {
                Theme.brandGradient
                Circle().fill(.white.opacity(0.12)).frame(width: 220).offset(x: 140, y: -90)
                Circle().fill(.white.opacity(0.08)).frame(width: 160).offset(x: -150, y: 90)
            }
        }
        .clipShape(.rect(cornerRadius: 28, style: .continuous))
        .shadow(color: Theme.brand.opacity(0.35), radius: 20, y: 10)
    }

    private func heroStat(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption.weight(.medium)).opacity(0.85)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.15), in: .rect(cornerRadius: 16, style: .continuous))
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 12) {
            quickAction("Expense", icon: "minus", color: Theme.expense) { quickAdd = .expense }
            quickAction("Income", icon: "plus", color: Theme.income) { quickAdd = .income }
            quickAction("Bills", icon: "checkmark", color: .blue) { selectedTab = .bills }
            quickAction("Ask AI", icon: "sparkles", color: .purple) { selectedTab = .insights }
        }
    }

    private func quickAction(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3.bold())
                    .foregroundStyle(color)
                    .frame(width: 52, height: 52)
                    .background(color.opacity(0.14), in: .circle)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: quickAdd)
    }

    // MARK: Health

    private var healthCard: some View {
        let score = Analytics.healthScore(
            analytics: analytics, budgets: model.budgets, spending: model.budgetSpending,
            bills: model.bills, monthlyIncome: model.user?.monthlyIncome?.doubleValue ?? 0
        )
        let mood = score >= 80 ? ("🤩", "Crushing it") : score >= 60 ? ("😊", "Looking good") : score >= 40 ? ("😐", "Room to grow") : ("😬", "Let's regroup")
        let streak = analytics.noSpendStreak

        return HStack(spacing: 18) {
            RingGauge(progress: Double(score) / 100, lineWidth: 12, tint: score >= 60 ? Theme.income : score >= 40 ? Theme.warning : Theme.expense) {
                VStack(spacing: 0) {
                    Text("\(score)").font(.title.bold()).monospacedDigit().contentTransition(.numericText(value: Double(score)))
                    Text("score").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 92, height: 92)

            VStack(alignment: .leading, spacing: 8) {
                Text("\(mood.0) \(mood.1)").font(.headline)
                Text("Your money health blends savings, budgets and bills.")
                    .font(.footnote).foregroundStyle(.secondary)
                if streak > 0 {
                    Label("\(streak)-day no-spend streak", systemImage: "flame.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.orange.opacity(0.14), in: .capsule)
                }
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    // MARK: Spending pace

    private var spendingPaceCard: some View {
        let points = analytics.cumulativeThisMonth
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spending pace").font(.headline)
                Spacer()
                Text(Date.now.formatted(.dateTime.month(.wide))).font(.subheadline).foregroundStyle(.secondary)
            }
            if points.allSatisfy({ $0.cumulative == 0 }) {
                Text("No spending yet this month 🎉").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Chart(points) { point in
                    AreaMark(x: .value("Day", point.day, unit: .day), y: .value("Spent", point.cumulative))
                        .foregroundStyle(Theme.brandGradient.opacity(0.25))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Day", point.day, unit: .day), y: .value("Spent", point.cumulative))
                        .foregroundStyle(Theme.brand)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Double.self) { Text(v.currency(compact: true)) } }
                    }
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.day()) } }
                .frame(height: 140)
            }
        }
        .card()
    }

    // MARK: Bills

    @ViewBuilder
    private var upcomingBills: some View {
        let upcoming = model.bills.filter { !$0.isPaid }.prefix(6)
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Up next", action: ("See all", { selectedTab = .bills }))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(upcoming)) { bill in
                            BillChip(bill: bill)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollClipDisabled()
            }
        }
    }

    // MARK: Budgets

    @ViewBuilder
    private var budgetsSnapshot: some View {
        if !model.budgets.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Budgets", action: ("See all", { selectedTab = .budgets }))
                VStack(spacing: 14) {
                    ForEach(model.budgets.prefix(3)) { budget in
                        let spending = model.budgetSpending[budget.id]
                        let progress = (spending?.percentageUsed.doubleValue ?? 0) / 100
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(CategoryStyle.forName(budget.category?.name).emoji)
                                Text(budget.name).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\((spending?.currentSpending ?? 0).currency(compact: true)) / \(budget.amount.currency(compact: true))")
                                    .font(.caption.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            ProgressCapsule(progress: progress, warning: budget.warningThreshold.doubleValue / 100)
                        }
                    }
                }
                .card()
            }
        }
    }

    // MARK: Recent

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Recent activity", action: ("See all", { selectedTab = .activity }))
            if model.transactions.isEmpty {
                EmptyStateView(emoji: "🧾", title: "No transactions yet", message: "Add your first expense or income to get the party started.",
                               actionTitle: "Add transaction") { quickAdd = .expense }
                    .card()
            } else {
                VStack(spacing: 0) {
                    ForEach(model.transactions.prefix(5)) { tx in
                        TransactionRow(transaction: tx)
                            .padding(.vertical, 10)
                        if tx.id != model.transactions.prefix(5).last?.id { Divider().padding(.leading, 52) }
                    }
                }
                .card(padding: 14)
            }
        }
    }
}

enum QuickAddKind: Identifiable { case expense, income; var id: Self { self } }

struct BillChip: View {
    let bill: Bill

    var body: some View {
        let days = bill.daysUntilDue()
        let (label, color): (String, Color) = days < 0 ? ("Overdue", Theme.expense)
            : days == 0 ? ("Due today", Theme.warning)
            : days == 1 ? ("Tomorrow", Theme.warning)
            : ("In \(days) days", .secondary)

        VStack(alignment: .leading, spacing: 10) {
            CategoryIcon(name: bill.categoryName ?? bill.name, size: 36)
            Text(bill.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(bill.amount.currency()).font(.headline).monospacedDigit()
            Text(label).font(.caption.weight(.bold)).foregroundStyle(color)
        }
        .padding(14)
        .frame(width: 140, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
    }
}
