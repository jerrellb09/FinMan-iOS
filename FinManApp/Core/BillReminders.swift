import Foundation
import SwiftData
import UserNotifications

/// Local notifications for upcoming and due bills. Only the next occurrence of each bill is scheduled;
/// the schedule is rebuilt whenever the app opens or goes to the background, so it follows edits and payments.
enum BillReminders {
    static let enabledKey = "settings.billReminders"
    /// How many days before the due date to send the heads-up (0 = only on the due day).
    static let daysBeforeKey = "settings.billReminderDaysBefore"
    /// Time of day for reminders, in minutes after midnight.
    static let timeKey = "settings.billReminderTime"

    static let defaultDaysBefore = 2
    static let defaultTime = 9 * 60

    private static let idPrefix = "bill-reminder."
    private static var center: UNUserNotificationCenter { .current() }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Asks for permission the first time; returns whether notifications are allowed.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default: return false
        }
    }

    static func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    /// Replaces every pending bill reminder with a fresh schedule.
    static func reschedule(_ context: ModelContext) {
        let bills = (try? context.fetch(FetchDescriptor<Bill>())) ?? []
        reschedule(bills)
    }

    static func reschedule(_ bills: [Bill], now: Date = .now) {
        // Bill reminders are FinMan's only notifications, so clearing everything pending is safe,
        // and doing it synchronously means it can't race the requests added below.
        let center = center
        center.removeAllPendingNotificationRequests()
        guard isEnabled else { return }

        let defaults = UserDefaults.standard
        let daysBefore = defaults.object(forKey: daysBeforeKey) as? Int ?? defaultDaysBefore
        let minutes = defaults.object(forKey: timeKey) as? Int ?? defaultTime
        let calendar = Calendar.current

        for bill in bills {
            let schedule = BillSchedule(dueDay: bill.dueDay, isRecurring: bill.isRecurring, lastPaidDate: bill.lastPaidDate)
            guard let due = schedule.nextUnpaidDue(from: now) else { continue }
            let key = "\(Int(bill.createdAt.timeIntervalSince1970))-\(bill.name)"
            var offsets = [0]
            if daysBefore > 0 { offsets.append(daysBefore) }

            for offset in offsets {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: due)),
                      let fireDate = calendar.date(byAdding: .minute, value: minutes, to: day),
                      fireDate > now else { continue }
                let content = UNMutableNotificationContent()
                content.title = title(for: bill, daysBefore: offset)
                content.body = body(for: bill, due: due)
                content.sound = .default
                content.threadIdentifier = "bills"
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate), repeats: false)
                center.add(UNNotificationRequest(identifier: "\(idPrefix)\(key).\(offset)", content: content, trigger: trigger))
            }
        }
    }

    private static func title(for bill: Bill, daysBefore: Int) -> String {
        switch daysBefore {
        case 0: bill.autoPay ? "\(bill.name) autopays today" : "\(bill.name) is due today"
        case 1: "\(bill.name) is due tomorrow"
        case 7: "\(bill.name) is due in a week"
        default: "\(bill.name) is due in \(daysBefore) days"
        }
    }

    private static func body(for bill: Bill, due: Date) -> String {
        let when = due.formatted(.dateTime.weekday(.wide).month().day())
        return bill.autoPay
            ? "\(bill.amount.currency()) will be paid automatically on \(when)."
            : "\(bill.amount.currency()) due \(when). Mark it paid in FinMan once it's done."
    }
}
