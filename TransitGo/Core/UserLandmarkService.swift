import Foundation
import CoreLocation
import SwiftUI
import MapKit

/// The original 12-group taxonomy (plus "other") — still used for icon/color and for
/// grouping the fine-grained categories below in pickers, Google-Maps style (a specific
/// "餐廳"/"咖啡廳"/"早餐店" pick, grouped visually under 餐飲與美食).
enum LandmarkCategoryGroup: String, CaseIterable, Identifiable {
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
}

/// Google-Maps-style fine-grained category — matching transitgo-server's
/// LANDMARK_CATEGORIES exactly (same raw values). Icon/color come from `group`, so adding
/// a new fine case only ever needs a label + which group it belongs to.
enum LandmarkCategory: String, CaseIterable, Identifiable, Codable {
    /// Falls back to `.other` for anything unrecognized — most importantly the old, coarser
    /// category strings ("foodDrink", "medical"…) a landmark saved before this fine-grained
    /// taxonomy existed may still carry. One unrecognized row failing to decode used to fail
    /// the *whole* landmarks list for everyone; this keeps a single odd value from doing that.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LandmarkCategory(rawValue: raw) ?? .other
    }

    // 餐飲與美食
    case restaurant, cafe, teaShop, bakery, dessertShop, bar, breakfastShop, nightMarketStall, buffet, fastFood
    // 購物與零售
    case groceryStore, convenienceStore, supermarket, clothingStore, bookstore, electronicsStore, giftShop, marketplace
    // 醫療與健康
    case hospital, clinic, dentist, pharmacy, veterinary
    // 交通與基礎設施
    case gasStation, evCharging, parkingLot, carRepair, bikeShop
    // 教育與學術
    case school, kindergarten, cramSchool, library
    // 金融與商務
    case bank, atm, insurance
    // 公共服務與政府機構
    case policeStation, fireStation, postOffice, cityHall
    // 休閒、娛樂與觀光
    case park, cinema, museum, artGallery, karaoke, arcade
    // 運動與健身
    case gym, swimmingPool, sportsField, yogaStudio
    // 住宿
    case hotel, hostel, bnb, campground
    // 宗教與信仰
    case temple, church
    // 生活服務
    case hairSalon, laundry, petGrooming, repairShop
    case other

    var id: String { rawValue }

    var group: LandmarkCategoryGroup {
        switch self {
        case .restaurant, .cafe, .teaShop, .bakery, .dessertShop, .bar, .breakfastShop, .nightMarketStall, .buffet, .fastFood:
            return .foodDrink
        case .groceryStore, .convenienceStore, .supermarket, .clothingStore, .bookstore, .electronicsStore, .giftShop, .marketplace:
            return .shopping
        case .hospital, .clinic, .dentist, .pharmacy, .veterinary:
            return .medical
        case .gasStation, .evCharging, .parkingLot, .carRepair, .bikeShop:
            return .transportation
        case .school, .kindergarten, .cramSchool, .library:
            return .education
        case .bank, .atm, .insurance:
            return .finance
        case .policeStation, .fireStation, .postOffice, .cityHall:
            return .government
        case .park, .cinema, .museum, .artGallery, .karaoke, .arcade:
            return .recreation
        case .gym, .swimmingPool, .sportsField, .yogaStudio:
            return .sports
        case .hotel, .hostel, .bnb, .campground:
            return .lodging
        case .temple, .church:
            return .religion
        case .hairSalon, .laundry, .petGrooming, .repairShop:
            return .personalServices
        case .other:
            return .other
        }
    }

    var icon: String { group.icon }
    var color: Color { group.color }

    var label: String {
        switch self {
        case .restaurant: return "餐廳"
        case .cafe: return "咖啡廳"
        case .teaShop: return "飲料店"
        case .bakery: return "麵包店"
        case .dessertShop: return "甜點店"
        case .bar: return "酒吧"
        case .breakfastShop: return "早餐店"
        case .nightMarketStall: return "夜市小吃"
        case .buffet: return "自助餐"
        case .fastFood: return "速食店"
        case .groceryStore: return "雜貨店"
        case .convenienceStore: return "便利商店"
        case .supermarket: return "超市"
        case .clothingStore: return "服飾店"
        case .bookstore: return "書店"
        case .electronicsStore: return "3C／電器行"
        case .giftShop: return "禮品店"
        case .marketplace: return "市場"
        case .hospital: return "醫院"
        case .clinic: return "診所"
        case .dentist: return "牙醫"
        case .pharmacy: return "藥局"
        case .veterinary: return "獸醫院"
        case .gasStation: return "加油站"
        case .evCharging: return "電動車充電站"
        case .parkingLot: return "停車場"
        case .carRepair: return "汽機車保養廠"
        case .bikeShop: return "自行車行"
        case .school: return "學校"
        case .kindergarten: return "幼兒園"
        case .cramSchool: return "補習班"
        case .library: return "圖書館"
        case .bank: return "銀行"
        case .atm: return "ATM"
        case .insurance: return "保險"
        case .policeStation: return "警察局"
        case .fireStation: return "消防局"
        case .postOffice: return "郵局"
        case .cityHall: return "行政機關"
        case .park: return "公園"
        case .cinema: return "電影院"
        case .museum: return "博物館"
        case .artGallery: return "藝廊"
        case .karaoke: return "KTV"
        case .arcade: return "遊藝場"
        case .gym: return "健身房"
        case .swimmingPool: return "游泳池"
        case .sportsField: return "運動場"
        case .yogaStudio: return "瑜伽教室"
        case .hotel: return "飯店"
        case .hostel: return "青年旅館"
        case .bnb: return "民宿"
        case .campground: return "露營地"
        case .temple: return "廟宇"
        case .church: return "教堂"
        case .hairSalon: return "美髮沙龍"
        case .laundry: return "洗衣店"
        case .petGrooming: return "寵物美容"
        case .repairShop: return "維修行"
        case .other: return "其他"
        }
    }

    /// Best-effort mapping from Apple's own POI category (real data MapKit already
    /// gives us) to the same taxonomy, so Apple-sourced landmarks get a matching
    /// category instead of only our own user submissions being categorized.
    init(appleCategory: MKPointOfInterestCategory?) {
        // Deliberately only categories confirmed available on this project's deployment
        // target (iOS 17) — several newer MKPointOfInterestCategory cases (spa, golf,
        // church, etc.) only ship from iOS 18 and aren't real symbols here yet.
        switch appleCategory {
        case .restaurant: self = .restaurant
        case .cafe: self = .cafe
        case .bakery: self = .bakery
        case .brewery, .winery, .nightlife: self = .bar
        case .foodMarket: self = .marketplace
        case .hospital: self = .hospital
        case .pharmacy: self = .pharmacy
        case .store, .marina: self = .other
        case .publicTransport, .airport, .carRental: self = .other
        case .parking: self = .parkingLot
        case .gasStation: self = .gasStation
        case .evCharger: self = .evCharging
        case .school: self = .school
        case .university, .library: self = .library
        case .bank: self = .bank
        case .atm: self = .atm
        case .police: self = .policeStation
        case .fireStation: self = .fireStation
        case .postOffice: self = .postOffice
        case .museum: self = .museum
        case .park, .nationalPark, .beach: self = .park
        case .theater, .movieTheater: self = .cinema
        case .amusementPark: self = .arcade
        case .aquarium, .zoo: self = .other
        case .campground: self = .campground
        case .fitnessCenter: self = .gym
        case .stadium: self = .sportsField
        case .hotel: self = .hotel
        case .laundry: self = .laundry
        default: self = .other
        }
    }
}

/// A real, admin-approved user-submitted landmark from our own backend — see
/// transitgo-server's /v1/landmarks. Only approved ones are ever returned by the public
/// GET endpoint, so anything the app shows here has already passed moderation.
/// 'open' | 'temporarily_closed' | 'permanently_closed' — Google-Maps style: a closed place
/// stays visible with this flag rather than vanishing from listings.
enum BusinessStatus: String, CaseIterable, Identifiable, Codable {
    case open, temporarilyClosed = "temporarily_closed", permanentlyClosed = "permanently_closed"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .open: return "營業中"
        case .temporarilyClosed: return "暫停營業"
        case .permanentlyClosed: return "已停業"
        }
    }
}

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
    let phone: String?
    let businessVerified: Bool
    /// Missing (rather than defaulted) only protects against an older cached response never
    /// having this field at all — treat absence the same as "open".
    let businessStatus: BusinessStatus?
    var effectiveBusinessStatus: BusinessStatus { businessStatus ?? .open }
    /// Only present from GET /v1/landmarks/mine (this device's own submissions) — nil
    /// when decoded from the public nearby-landmarks endpoint, which only ever returns
    /// already-approved, non-business-claim-specific entries.
    let approved: Bool?
    let isBusinessClaim: Bool?

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

    /// Flags a landmark as inappropriate — same categorized-report pattern as place reviews.
    static func report(id: Int, reason: ReportReason) {
        guard let base = BackendConfig.baseURL else { return }
        Task {
            var req = URLRequest(url: base.appendingPathComponent("v1/landmarks/\(id)/report"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["reason": reason.rawValue])
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    /// This device's own submitted landmarks — lets the app show submission status and,
    /// for a verified business, offer editing.
    static func mine() async -> [UserLandmark] {
        guard let base = BackendConfig.baseURL else { return [] }
        var comps = URLComponents(url: base.appendingPathComponent("v1/landmarks/mine"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "device", value: BackendConfig.deviceID)]
        struct Response: Decodable { let landmarks: [UserLandmark] }
        guard let url = comps?.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return decoded.landmarks
    }

    /// Editing only actually succeeds server-side for a verified business owner's own
    /// listing — the server checks device + business_verified itself (see
    /// updateMyUserLandmark), this call can't bypass that from the client.
    /// `email`/`code` let a verified owner edit from a phone OTHER than the one that
    /// originally submitted the claim — omit them to edit as this device (the normal case).
    static func update(
        id: Int, description: String?, businessHours: String?, phone: String? = nil,
        businessStatus: BusinessStatus? = nil, photo: String?, coordinate: CLLocationCoordinate2D? = nil,
        email: String? = nil, code: String? = nil
    ) async -> Bool {
        guard let base = BackendConfig.baseURL else { return false }
        var payload: [String: Any] = [:]
        if let email, let code {
            payload["email"] = email
            payload["code"] = code
        } else {
            payload["device"] = BackendConfig.deviceID
        }
        if let description { payload["description"] = description }
        if let businessHours { payload["businessHours"] = businessHours }
        if let phone { payload["phone"] = phone }
        if let businessStatus { payload["businessStatus"] = businessStatus.rawValue }
        if let photo { payload["photo"] = photo }
        if let coordinate { payload["lat"] = coordinate.latitude; payload["lon"] = coordinate.longitude }
        var req = URLRequest(url: base.appendingPathComponent("v1/landmarks/\(id)"))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// This device's own submitted landmarks, cross-device: needs a code freshly verified
    /// with `EmailVerificationService.requestCode(email:)` — same idea as
    /// `PlaceReviewService.mine()` via email.
    static func mine(email: String, code: String) async -> [UserLandmark] {
        guard let base = BackendConfig.baseURL else { return [] }
        var req = URLRequest(url: base.appendingPathComponent("v1/landmarks/mine"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email, "code": code])
        struct Response: Decodable { let landmarks: [UserLandmark] }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return decoded.landmarks
    }

    enum SubmitResult { case ok, invalidCode, failed }

    /// `email`/`code` only matter (and are only required server-side) when `isBusinessClaim` is
    /// true — a plain community landmark suggestion needs no verification. Get a code first with
    /// `EmailVerificationService.requestCode(email:)`.
    static func submit(
        name: String, description: String, category: LandmarkCategory, coordinate: CLLocationCoordinate2D,
        photo: String?, isBusinessClaim: Bool = false, businessHours: String? = nil, phone: String? = nil,
        email: String? = nil, code: String? = nil
    ) async -> SubmitResult {
        guard let base = BackendConfig.baseURL else { return .failed }
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
        if let phone, !phone.isEmpty { payload["phone"] = phone }
        if let email { payload["email"] = email }
        if let code { payload["code"] = code }
        var req = URLRequest(url: base.appendingPathComponent("v1/landmarks"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let status = (resp as? HTTPURLResponse)?.statusCode else { return .failed }
        if status == 200 { return .ok }
        return status == 400 ? .invalidCode : .failed
    }
}
