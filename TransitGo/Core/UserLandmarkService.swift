import Foundation
import CoreLocation
import SwiftUI
import MapKit

/// Fixed 12-group taxonomy (plus "other") for landmark categorization — real-world
/// categories a map app actually distinguishes with icon/color, matching
/// transitgo-server's LANDMARK_CATEGORIES exactly (same raw values).
enum LandmarkCategory: String, CaseIterable, Identifiable, Codable {
    case foodDrink, medical, shopping, transportation, education, finance
    case government, recreation, sports, lodging, religion, personalServices, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .foodDrink: return "餐飲與美食"
        case .medical: return "醫療與健康"
        case .shopping: return "購物與零售"
        case .transportation: return "交通與基礎設施"
        case .education: return "教育與學術"
        case .finance: return "金融與商務"
        case .government: return "公共服務與政府機構"
        case .recreation: return "休閒、娛樂與觀光"
        case .sports: return "運動與健身"
        case .lodging: return "住宿"
        case .religion: return "宗教與信仰"
        case .personalServices: return "生活服務"
        case .other: return "其他"
        }
    }

    var icon: String {
        switch self {
        case .foodDrink: return "fork.knife"
        case .medical: return "cross.case.fill"
        case .shopping: return "bag.fill"
        case .transportation: return "car.fill"
        case .education: return "graduationcap.fill"
        case .finance: return "banknote.fill"
        case .government: return "building.columns.fill"
        case .recreation: return "camera.fill"
        case .sports: return "figure.run"
        case .lodging: return "bed.double.fill"
        case .religion: return "building.2.fill"
        case .personalServices: return "scissors"
        case .other: return "mappin"
        }
    }

    var color: Color {
        switch self {
        case .foodDrink: return .orange
        case .medical: return .red
        case .shopping: return .pink
        case .transportation: return .blue
        case .education: return .indigo
        case .finance: return .green
        case .government: return .brown
        case .recreation: return .purple
        case .sports: return .mint
        case .lodging: return .teal
        case .religion: return .yellow
        case .personalServices: return .cyan
        case .other: return .gray
        }
    }

    /// Best-effort mapping from Apple's own POI category (real data MapKit already
    /// gives us) to the same taxonomy, so Apple-sourced landmarks get a matching
    /// icon/color instead of only our own user submissions being categorized.
    init(appleCategory: MKPointOfInterestCategory?) {
        // Deliberately only categories confirmed available on this project's deployment
        // target (iOS 17) — several newer MKPointOfInterestCategory cases (spa, golf,
        // church, etc.) only ship from iOS 18 and aren't real symbols here yet.
        switch appleCategory {
        case .restaurant, .cafe, .bakery, .brewery, .winery, .nightlife, .foodMarket:
            self = .foodDrink
        case .hospital, .pharmacy:
            self = .medical
        case .store, .marina:
            self = .shopping
        case .publicTransport, .airport, .parking, .gasStation, .evCharger, .carRental:
            self = .transportation
        case .school, .university, .library:
            self = .education
        case .bank, .atm:
            self = .finance
        case .police, .fireStation, .postOffice:
            self = .government
        case .museum, .park, .nationalPark, .theater, .movieTheater, .amusementPark, .aquarium, .zoo, .campground, .beach:
            self = .recreation
        case .fitnessCenter, .stadium:
            self = .sports
        case .hotel:
            self = .lodging
        case .laundry:
            self = .personalServices
        default:
            self = .other
        }
    }
}

/// A real, admin-approved user-submitted landmark from our own backend — see
/// transitgo-server's /v1/landmarks. Only approved ones are ever returned by the public
/// GET endpoint, so anything the app shows here has already passed moderation.
struct UserLandmark: Decodable, Identifiable {
    let id: Int
    let name: String
    let description: String
    let category: LandmarkCategory
    let lat: Double
    let lon: Double
    let photo: String?
    /// Only non-nil once an admin has verified the submitter really is the business —
    /// never shown to other users before that (see server's business_verified gate).
    let businessHours: String?
    let businessVerified: Bool

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

/// User-submitted landmarks (real content, e.g. a small shop/spot Apple's POI index
/// doesn't have) — held for admin approval before anyone else sees them, same principle
/// as this app's other user-generated content (place reviews).
enum UserLandmarkService {
    static func nearby(_ coordinate: CLLocationCoordinate2D, radiusMeters: Double = 1000) async -> [UserLandmark] {
        guard let base = BackendConfig.baseURL else { return [] }
        var comps = URLComponents(url: base.appendingPathComponent("v1/landmarks"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "lat", value: String(coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(coordinate.longitude)),
            URLQueryItem(name: "radius", value: String(radiusMeters)),
        ]
        struct Response: Decodable { let landmarks: [UserLandmark] }
        guard let url = comps?.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return decoded.landmarks
    }

    static func submit(
        name: String, description: String, category: LandmarkCategory, coordinate: CLLocationCoordinate2D,
        photo: String?, isBusinessClaim: Bool = false, businessHours: String? = nil
    ) {
        guard let base = BackendConfig.baseURL else { return }
        var payload: [String: Any] = [
            "name": name,
            "description": description,
            "category": category.rawValue,
            "lat": coordinate.latitude,
            "lon": coordinate.longitude,
            "appVersion": BackendConfig.appVersion,
            "device": BackendConfig.deviceID,
            "isBusinessClaim": isBusinessClaim,
        ]
        if let photo { payload["photo"] = photo }
        if let businessHours, !businessHours.isEmpty { payload["businessHours"] = businessHours }
        Task {
            var req = URLRequest(url: base.appendingPathComponent("v1/landmarks"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            _ = try? await URLSession.shared.data(for: req)
        }
    }
}
