import SwiftUI
import WidgetKit

/// Total money across every account, on the Home Screen and Lock Screen.
struct BalanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FinManBalance", provider: SnapshotProvider()) { entry in
            BalanceWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Total balance")
        .description("All your accounts added up, plus what you've spent this month.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline])
    }
}

struct BalanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .accessoryInline:
                Text("💰 \(snapshot.totalBalance.widgetCurrency(compact: true))").privacySensitive()
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Label("Total balance", systemImage: "dollarsign.circle.fill").font(.caption2.weight(.semibold))
                    Text(snapshot.totalBalance.widgetCurrency()).font(.title3.weight(.bold)).privacySensitive()
                    Text("Spent \(snapshot.monthSpent.widgetCurrency(compact: true)) this month").font(.caption2).privacySensitive()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                small(snapshot)
            }
        } else {
            OpenAppPrompt()
        }
    }

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Total", systemImage: "dollarsign.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(WidgetStyle.brand)
            Spacer(minLength: 0)
            Text(snapshot.totalBalance.widgetCurrency(compact: true))
                .font(.title.weight(.bold))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .privacySensitive()
            Text("\(snapshot.accounts.count) account\(snapshot.accounts.count == 1 ? "" : "s")")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                Text("Spent this month").font(.caption2).foregroundStyle(.secondary)
                Text(snapshot.monthSpent.widgetCurrency(compact: true))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WidgetStyle.expense)
                    .privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

#Preview(as: .systemSmall) { BalanceWidget() } timeline: { SnapshotEntry(date: .now, snapshot: .preview) }
#Preview(as: .accessoryRectangular) { BalanceWidget() } timeline: { SnapshotEntry(date: .now, snapshot: .preview) }
