import Foundation
import SwiftData

// Kept beside RailTicket (Features/Tickets), not in Core: Core is also compiled into the widget extension,
// which does not have the ticket model.
extension ShareTripService {
    // MARK: A ticket from the 車票 page

    /// One vehicle leg from a saved ticket: train, from/to station and the times. The seat, car number, notes and
    /// the ticket holder's anything else are NOT part of it — a link shows the service, not the passenger.
    static func segment(for ticket: RailTicket) -> SegmentBody? {
        guard let dep = ticket.departureDate, let arr = ticket.arrivalDate else { return nil }
        let iso = ISO8601DateFormatter()
        let tra = ticket.system == .tra
        let day: String = {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = TimeZone(identifier: "Asia/Taipei")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: ticket.serviceDate)
        }()
        return SegmentBody(
            mode: tra ? "TRA" : "HSR", routeId: tra ? "TRA" : "HSR", line: ticket.trainLabel,
            // The realtime overlay looks a train up by "TRA_{車次}_{日期}" at the boarding station.
            from: tra ? "TRA:\(ticket.fromStationID)" : nil, to: tra ? "TRA:\(ticket.toStationID)" : nil,
            tripId: tra ? "TRA_\(ticket.trainNo)_\(day)" : nil,
            fromName: ticket.fromName, toName: ticket.toName,
            departureTime: iso.string(from: dep), arrivalTime: iso.string(from: arr)
        )
    }

    static func requestBody(ticket: RailTicket, ttlHours: Int = 12) throws -> Data? {
        guard let seg = segment(for: ticket) else { return nil }
        return try JSONEncoder().encode(Body(title: "\(ticket.fromName) → \(ticket.toName)・\(ticket.trainLabel)", ttlHours: ttlHours, segments: [seg]))
    }

    static func prepare(ticket: RailTicket) -> Result<Prepared, Failure> {
        guard let body = (try? requestBody(ticket: ticket)) ?? nil else { return .failure(.nothingToFollow) }
        return prepare(body: body)
    }
}
