import Foundation
import Combine
import CoreLocation
import QuartzCore
import MapKit

/// 散歩モードのマルチプレイ presence。
/// - 観測は常時（通常モードでも近くの「歩いてる人」を表示）
/// - 自分の位置を送る(post)のは散歩モード中だけ（仮想位置・匿名ID・サーバTTLで ephemeral）
@MainActor
final class PresenceService: ObservableObject {
    struct Person: Identifiable {
        let id: String
        var coordinate: CLLocationCoordinate2D
        var heading: Double
        let name: String
    }
    @Published private(set) var others: [Person] = []

    private struct Track {
        var fromLat, fromLon, toLat, toLon: Double
        var fromHdg, toHdg: Double
        var startAt: CFTimeInterval
        var lastSeen: CFTimeInterval
        let name: String
    }
    private var tracks: [String: Track] = [:]

    private weak var me: WalkController?          // 散歩中のみセット（=postする）
    private var observeRegion: MKCoordinateRegion?     // 観測範囲＝地図の表示範囲（世界ズームなら地球全体）
    private var myID = ""
    private var myName = "さんぽ"

    private let interval: TimeInterval = 3.5
    private let interp: Double = 3.5
    private let staleAfter: Double = 12

    private var cycleTimer: AnyCancellable?
    private var animTimer: AnyCancellable?

    static var deviceID: String {
        let key = "presenceDeviceID"
        if let s = UserDefaults.standard.string(forKey: key) { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: key)
        return s
    }
    private static var apiBase: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String) ?? ""
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    // MARK: - ライフサイクル（観測は常時）
    func start() {
        myID = Self.deviceID
        guard cycleTimer == nil else { return }
        cycleTimer = Timer.publish(every: interval, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.cycle() }
        animTimer = Timer.publish(every: 1.0 / 12.0, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
        cycle()
    }
    func stop() {
        cycleTimer?.cancel(); animTimer?.cancel()
        cycleTimer = nil; animTimer = nil
        tracks.removeAll()
        others = []
    }
    /// 観測範囲（＝地図の表示範囲）を更新。引いて見れば地球のどこで誰が歩いているかが見える。
    func updateFocus(_ r: MKCoordinateRegion) { observeRegion = r }

    /// 散歩開始：自分の位置送信を有効化
    func setWalking(me: WalkController, name: String) {
        self.me = me
        myID = Self.deviceID
        myName = name.isEmpty ? "さんぽ" : name
        post()
    }
    /// 散歩終了：送信は止めるが観測は続ける
    func endWalking() { me = nil }

    private func cycle() {
        if me != nil { post() }
        poll()
    }

    // MARK: - 送信
    private func post() {
        guard let me else { return }
        let c = me.coordinate
        let h = me.avatarHeading
        let base = Self.apiBase, id = myID, name = myName
        Task {
            guard let url = URL(string: "\(base)/api/presence/") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "id": id, "lat": c.latitude, "lon": c.longitude, "heading": h, "name": name
            ])
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    // MARK: - 受信
    private struct RawPerson: Decodable {
        let id: String; let lat: Double; let lon: Double; let heading: Double; let name: String
    }
    private struct PresenceResp: Decodable { let people: [RawPerson] }

    private func poll() {
        #if DEBUG
        if Self.mockEnabled {
            // 実サーバ同様、見えている範囲内の人だけ
            let people = Self.mockPeople().filter { p in
                guard let r = observeRegion else { return true }
                return abs(p.lat - r.center.latitude) <= r.span.latitudeDelta * 0.6
                    && abs(p.lon - r.center.longitude) <= r.span.longitudeDelta * 0.6
            }
            ingest(people); return
        }
        #endif
        // 見えている範囲（少し余白）を観測。範囲が無ければ自分のまわり。
        let bbox: String
        if let r = observeRegion {
            let dLat = min(r.span.latitudeDelta * 0.6, 90)
            let dLon = min(r.span.longitudeDelta * 0.6, 180)
            bbox = "\(max(-90, r.center.latitude - dLat)),\(max(-180, r.center.longitude - dLon)),\(min(90, r.center.latitude + dLat)),\(min(180, r.center.longitude + dLon))"
        } else if let c = me?.coordinate {
            bbox = "\(c.latitude - 0.02),\(c.longitude - 0.02),\(c.latitude + 0.02),\(c.longitude + 0.02)"
        } else { return }
        let base = Self.apiBase, id = myID
        Task { [weak self] in
            guard let url = URL(string: "\(base)/api/presence/nearby/?bbox=\(bbox)&exclude=\(id)") else { return }
            do {
                let (data, resp) = try await URLSession.shared.data(from: url)
                if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return }
                let people = (try? JSONDecoder().decode(PresenceResp.self, from: data))?.people ?? []
                self?.ingest(people)
            } catch {}
        }
    }

    private func ingest(_ people: [RawPerson]) {
        let now = CACurrentMediaTime()
        for p in people {
            if var tr = tracks[p.id] {
                let t = min(max((now - tr.startAt) / interp, 0), 1)
                tr.fromLat += (tr.toLat - tr.fromLat) * t
                tr.fromLon += (tr.toLon - tr.fromLon) * t
                tr.fromHdg += Self.angleDiff(tr.fromHdg, tr.toHdg) * t
                tr.toLat = p.lat; tr.toLon = p.lon; tr.toHdg = p.heading
                tr.startAt = now; tr.lastSeen = now
                tracks[p.id] = tr
            } else {
                tracks[p.id] = Track(fromLat: p.lat, fromLon: p.lon, toLat: p.lat, toLon: p.lon,
                                     fromHdg: p.heading, toHdg: p.heading,
                                     startAt: now, lastSeen: now, name: p.name)
            }
        }
    }

    // MARK: - 補間表示
    private func tick() {
        let now = CACurrentMediaTime()
        var out: [Person] = []
        var dead: [String] = []
        for (id, tr) in tracks {
            if now - tr.lastSeen > staleAfter { dead.append(id); continue }
            let t = min(max((now - tr.startAt) / interp, 0), 1)
            let lat = tr.fromLat + (tr.toLat - tr.fromLat) * t
            let lon = tr.fromLon + (tr.toLon - tr.fromLon) * t
            let hdg = tr.fromHdg + Self.angleDiff(tr.fromHdg, tr.toHdg) * t
            out.append(Person(id: id, coordinate: .init(latitude: lat, longitude: lon), heading: hdg, name: tr.name))
        }
        for id in dead { tracks.removeValue(forKey: id) }
        others = out
    }

    #if DEBUG
    // MARK: - デモ用モック（DEBUG ビルドで SCREENSHOT_MOCK_PRESENCE=1 のときだけ）
    // 実サーバへは何も送らない。世界各地を数人がゆっくり歩いている状態を再現する。
    private static let mockEnabled = ProcessInfo.processInfo.environment["SCREENSHOT_MOCK_PRESENCE"] == "1"
    private static let mockStart = CACurrentMediaTime()
    private static let mockSeeds: [(String, String, Double, Double, Double)] = [
        // id, name, lat, lon, heading
        ("mock-pp",  "Sokha",   11.5564,  104.9282, 40),
        ("mock-tas", "Aziz",    41.3111,  69.2797,  300),
        ("mock-tky", "ゆう",    35.6595,  139.7005, 120),
        ("mock-mnl", "Jasmine", 14.5547,  121.0244, 200),
        ("mock-alm", "Dana",    43.2389,  76.8897,  80),
    ]
    private static func mockPeople() -> [RawPerson] {
        let t = CACurrentMediaTime() - mockStart
        return mockSeeds.map { (id, name, lat, lon, hdg) in
            // 1.2m/s で heading 方向に歩く（緯度1度≈111km）
            let d = 1.2 * t / 111_000
            let rad = hdg * .pi / 180
            return RawPerson(id: id, lat: lat + d * cos(rad), lon: lon + d * sin(rad) / cos(lat * .pi / 180),
                             heading: hdg, name: name)
        }
    }
    #endif

    static func angleDiff(_ a: Double, _ b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}
