import SwiftUI
import WidgetKit

/// Balance, this month's spending against income, and the next bill, side by side.
struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FinManOverview", provider: SnapshotProvider()) { entry in
            OverviewWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("This month")
        .description("Your balance, spending against income, and the next bill.")
        .supportedFamilies([.systemMedium])
    }
}

struct OverviewWidgetView: View {
    let entry: SnapshotEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            HStack(alignment: .top, spacing: 16) {
                balance(snapshot)
                Divider()
                month(snapshot)
            }
        } else {
            OpenAppPrompt()
        }
    }

    private func balance(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Total", systemImage: "dollarsign.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(WidgetStyle.brand)
            Text(snapshot.totalBalance.widgetCurrency(compact: true))
                .font(.title2.weight(.bold))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .privacySensitive()
            Spacer(minLength: 0)
            if let next = snapshot.upcomingBills(at: entry.date).first {
                let days = BillSchedule.daysUntil(next.due, from: entry.date)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Next: \(next.bill.name)").font(.caption.weight(.semibold)).lineLimit(1)
                    Text(BillSchedule.dueText(next.due, from: entry.date))
                        .font(.caption2)
                        .foregroundStyle(WidgetStyle.color(forDays: days))
                }
            } else {
                Text("No bills due").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func month(_ snapshot: WidgetSnapshot) -> some View {
        // Fall back to the profile income when nothing has been logged as income yet this month.
        let income = max(snapshot.monthIncome, snapshot.monthlyIncome)
        let progress = income > 0 ? min(snapshot.monthSpent / income, 1) : 0
        let left = income - snapshot.monthSpent
        let isCurrentMonth = Calendar.current.isDate(snapshot.updatedAt, equalTo: entry.date, toGranularity: .month)
        return VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.updatedAt.formatted(.dateTime.month(.wide)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("Spent").font(.caption2).foregroundStyle(.secondary)
                Text(snapshot.monthSpent.widgetCurrency(compact: true))
                    .font(.headline)
                    .foregroundStyle(WidgetStyle.expense)
                    .privacySensitive()
            }
            ProgressView(value: progress)
                .tint(progress > 0.9 ? WidgetStyle.expense : WidgetStyle.brand)
            Text(left >= 0 ? "\(left.widgetCurrency(compact: true)) left of \(income.widgetCurrency(compact: true))"
                           : "\((-left).widgetCurrency(compact: true)) over \(income.widgetCurrency(compact: true))")
                .font(.caption2)
                .foregroundStyle(left >= 0 ? Color.secondary : WidgetStyle.expense)
                .privacySensitive()
            if !isCurrentMonth {
                Text("Open FinMan to update").font(.caption2).foregroundStyle(WidgetStyle.warning)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

#Preview(as: .systemMedium) { OverviewWidget() } timeline: { SnapshotEntry(date: .now, snapshot: .preview) }
