import Foundation
import UserNotifications

/// Schedules / cancels the "即將發車" local reminder for a saved ticket.
/// Fires even when the app isn't running and the Live Activity isn't started.
enum TicketReminders {

    static let leadChoices = [0, 5, 10, 15, 30, 60]

    static func label(forLead minutes: Int) -> String {
        minutes == 0 ? "不提醒" : "提前 \(minutes) 分鐘"
    }

    private static func id(_ ticket: RailTicket) -> String { "ticket-reminder-\(ticket.uuid)" }

    /// Cancel any existing reminder, then schedule a fresh one if still in the future.
    static func reschedule(for ticket: RailTicket) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id(ticket)])

        guard ticket.reminderLeadMinutes > 0, let dep = ticket.departureDate else { return }
        let fire = dep.addingTimeInterval(TimeInterval(-ticket.reminderLeadMinutes * 60))
        guard fire > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(ticket.trainLabel) 即將發車"
        var body = "\(ticket.fromName) → \(ticket.toName)　\(ticket.depTime) 開車"
        if !ticket.seatLabel.isEmpty { body += "　\(ticket.seatLabel)" }
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id(ticket), content: content, trigger: trigger))
    }

    static func cancel(for ticket: RailTicket) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id(ticket)])
    }

    static func requestAuthIfNeeded() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }
}
