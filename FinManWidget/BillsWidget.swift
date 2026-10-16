import SwiftUI
import WidgetKit

/// The next bills to pay, with how many days are left.
struct BillsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FinManBills", provider: SnapshotProvider()) { entry in
            BillsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Upcoming bills")
        .description("What's due next and how many days you have left.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct BillsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            let upcoming = snapshot.upcomingBills(at: entry.date)
            if upcoming.isEmpty {
                allPaid
            } else {
                switch family {
                case .accessoryRectangular: lockScreen(upcoming[0])
                case .systemSmall: small(upcoming)
                case .systemLarge: list(upcoming, limit: 7, snapshot: snapshot)
                default: list(upcoming, limit: 3, snapshot: snapshot)
                }
            }
        } else {
            OpenAppPrompt()
        }
    }

    private var allPaid: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(WidgetStyle.income)
            Text("No bills due").font(.caption.weight(.semibold))
        }
    }

    private func lockScreen(_ next: (bill: WidgetSnapshot.Bill, due: Date)) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Next bill", systemImage: "calendar.badge.clock").font(.caption2.weight(.semibold))
            Text(next.bill.name).font(.headline).lineLimit(1)
            Text("\(next.bill.amount.widgetCurrency()) · \(BillSchedule.dueText(next.due, from: entry.date))")
                .font(.caption2).privacySensitive()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func small(_ upcoming: [(bill: WidgetSnapshot.Bill, due: Date)]) -> some View {
        let next = upcoming[0]
        let days = BillSchedule.daysUntil(next.due, from: entry.date)
        return VStack(alignment: .leading, spacing: 3) {
            Label("Next bill", systemImage: "calendar.badge.clock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(WidgetStyle.brand)
            Spacer(minLength: 0)
            Text(next.bill.name).font(.headline).lineLimit(2)
            Text(next.bill.amount.widgetCurrency()).font(.title2.weight(.bold)).minimumScaleFactor(0.6).privacySensitive()
            Text(BillSchedule.dueText(next.due, from: entry.date))
                .font(.caption.weight(.semibold))
                .foregroundStyle(WidgetStyle.color(forDays: days))
            Spacer(minLength: 0)
            if upcoming.count > 1 {
                Text("+\(upcoming.count - 1) more").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func list(_ upcoming: [(bill: WidgetSnapshot.Bill, due: Date)], limit: Int, snapshot: WidgetSnapshot) -> some View {
        let calendar = Calendar.current
        let dueThisMonth = upcoming.filter { calendar.isDate($0.due, equalTo: entry.date, toGranularity: .month) }
        return VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 6) {
            HStack {
                Label("Upcoming bills", systemImage: "calendar.badge.clock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WidgetStyle.brand)
                Spacer()
                Text("\(dueThisMonth.reduce(0) { $0 + $1.bill.amount }.widgetCurrency(compact: true)) left this month")
                    .font(.caption2).foregroundStyle(.secondary).privacySensitive()
            }
            ForEach(upcoming.prefix(limit), id: \.bill.id) { item in
                let days = BillSchedule.daysUntil(item.due, from: entry.date)
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(WidgetStyle.color(forDays: days, normal: WidgetStyle.brand))
                        .frame(width: 4)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.bill.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(item.bill.autoPay ? "\(BillSchedule.dueText(item.due, from: entry.date)) · Autopay" : BillSchedule.dueText(item.due, from: entry.date))
                            .font(.caption2)
                            .foregroundStyle(WidgetStyle.color(forDays: days))
                    }
                    Spacer()
                    Text(item.bill.amount.widgetCurrency()).font(.subheadline.weight(.semibold)).monospacedDigit().privacySensitive()
                }
                .frame(maxHeight: family == .systemLarge ? 34 : 28)
            }
            if family == .systemLarge { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview(as: .systemSmall) { BillsWidget() } timeline: { SnapshotEntry(date: .now, snapshot: .preview) }
#Preview(as: .systemMedium) { BillsWidget() } timeline: { SnapshotEntry(date: .now, snapshot: .preview) }
#Preview(as: .systemLarge) { BillsWidget() } timeline: { SnapshotEntry(date: .now, snapshot: .preview) }
