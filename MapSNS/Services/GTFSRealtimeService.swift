import Foundation
import Combine
import CoreLocation
import MapKit
import SwiftUI

// MARK: - 表示用（補間後の1台）

struct DisplayVehicle: Identifiable {
    let id: String
    var coordinate: CLLocationCoordinate2D
    var heading: Double?
    let kind: String
    let feed: String
    let route: String?
}

// MARK: - 都市レジストリ＆見た目（フロントの調整ポイント）
// バックエンドの feed id と一致させる。色・アイコンはここで自由に変えられる。

struct CityInfo {
    let id: String
    let name: String
    let home: CLLocationCoordinate2D
    let color: Color
}

enum Cities {
    static let all: [CityInfo] = [
        CityInfo(id: "tokyo",     name: "東京 都営バス",     home: .init(latitude: 35.685,   longitude: 139.760),  color: Color(red: 0.15, green: 0.50, blue: 0.95)),
        CityInfo(id: "boston",    name: "Boston MBTA",      home: .init(latitude: 42.3601,  longitude: -71.0589), color: Color(red: 0.85, green: 0.20, blue: 0.25)),
        CityInfo(id: "amsterdam", name: "Amsterdam OV",     home: .init(latitude: 52.3676,  longitude: 4.9041),   color: Color(red: 0.95, green: 0.55, blue: 0.10)),
        CityInfo(id: "oslo",      name: "Oslo Entur",       home: .init(latitude: 59.9139,  longitude: 10.7522),  color: Color(red: 0.55, green: 0.30, blue: 0.85)),
        CityInfo(id: "warsaw",    name: "Warszawa",         home: .init(latitude: 52.2297,  longitude: 21.0122),  color: Color(red: 0.10, green: 0.65, blue: 0.65)),
        CityInfo(id: "adelaide",  name: "Adelaide Metro",   home: .init(latitude: -34.9285, longitude: 138.6007), color: Color(red: 0.90, green: 0.30, blue: 0.65)),
        CityInfo(id: "kl",        name: "Kuala Lumpur",     home: .init(latitude: 3.139,    longitude: 101.6869), color: Color(red: 0.20, green: 0.70, blue: 0.35)),
        CityInfo(id: "brisbane",  name: "Brisbane",         home: .init(latitude: -27.4698, longitude: 153.0251), color: Color(red: 0.60, green: 0.10, blue: 0.25)),
        CityInfo(id: "minneapolis", name: "Minneapolis",    home: .init(latitude: 44.9778,  longitude: -93.2650), color: Color(red: 0.15, green: 0.40, blue: 0.70)),
        CityInfo(id: "penang",    name: "Penang",           home: .init(latitude: 5.4141,   longitude: 100.3288), color: Color(red: 0.90, green: 0.60, blue: 0.10)),
        CityInfo(id: "johor",     name: "Johor",            home: .init(latitude: 1.4927,   longitude: 103.7414), color: Color(red: 0.20, green: 0.55, blue: 0.65)),
        CityInfo(id: "hiroshima", name: "Hiroshima",        home: .init(latitude: 34.3853,  longitude: 132.4553), color: Color(red: 0.20, green: 0.55, blue: 0.30)),
    ]
    static let byID: [String: CityInfo] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func color(_ feed: String) -> Color { byID[feed]?.color ?? .gray }

    static func nearest(to c: CLLocationCoordinate2D) -> CityInfo? {
        all.min { sq(c, $0.home) < sq(c, $1.home) }
    }
    static func anyNear(_ c: CLLocationCoordinate2D, deg: Double = 2.0) -> Bool {
        all.contains { sq(c, $0.home) <= deg * deg }
    }
    static func icon(kind: String) -> String {
        switch kind {
        case "rail":  return "tram.fill"
        case "tram":  return "cablecar.fill"
        case "ferry": return "ferry.fill"
        default:      return "bus.fill"
        }
    }
    private static func sq(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = a.latitude - b.latitude
        let dLon = (a.longitude - b.longitude) * cos(a.latitude * .pi / 180)
        return dLat * dLat + dLon * dLon
    }
}

// MARK: - 調整ノブ（使用感はここをいじって再ビルドで詰める）

enum VehicleTuning {
    static let pollInterval: TimeInterval = 12        // バックエンド取得間隔
    static let animationInterval: TimeInterval = 1.0 / 10.0  // 補間アニメfps（発熱対策で控えめ）
    static let interpDuration: Double = 12            // 2点間を何秒かけて動かすか（≈取得間隔）
    static let maxVehicles = 80                       // 表示上限（中心に近い順・負荷対策）
    static let staleAfter: Double = 90                // この秒数見えなければ消す
    static let teleportMps: Double = 60               // 見かけ速度がこれ超ならスライドせず瞬間移動
    static let hideAboveSpan: Double = 0.3            // 緯度デルタがこれ超（引きすぎ）なら取得停止＆非表示（寄った時だけ描く＝軽量）
}

// MARK: - サービス（バックエンド取得 → T2直線補間 → 表示）

@MainActor
final class VehicleService: ObservableObject {
    @Published private(set) var displayVehicles: [DisplayVehicle] = []
    @Published private(set) var isEnabled = false

    private struct Track {
        var fromLat, fromLon, toLat, toLon: Double
        var startAt: CFTimeInterval
        var heading: Double?
        let kind: String
        let feed: String
        let route: String?
        var lastSeen: CFTimeInterval
    }
    private var tracks: [String: Track] = [:]
    private var region: MKCoordinateRegion?
    private var pollTimer: AnyCancellable?
    private var animTimer: AnyCancellable?

    private static var apiBase: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String) ?? ""
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    // MARK: ライフサイクル
    func start(region: MKCoordinateRegion) {
        isEnabled = true
        self.region = region
        startTimers()
        poll()
        // バックエンドのコールドスタート対策：起動直後は素早く追加取得して数秒で車両を出す
        for delay in [3.0, 6.0, 9.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isEnabled else { return }
                self.poll()
            }
        }
    }
    func stop() {
        isEnabled = false
        cancelTimers()
        tracks.removeAll()
        displayVehicles = []
    }
    func pause() { cancelTimers() }
    func resumeIfEnabled() {
        guard isEnabled, pollTimer == nil else { return }
        startTimers()
        poll()
    }
    func updateRegion(_ r: MKCoordinateRegion) {
        region = r
        // 引きすぎたら即・非表示にする（取得も次の poll で止まる）
        if r.span.latitudeDelta > VehicleTuning.hideAboveSpan, !displayVehicles.isEmpty {
            tracks.removeAll()
            displayVehicles = []
        }
    }

    /// 地図の移動が終わった瞬間に呼ぶ。表示範囲を更新して即取得（＝移動が更新トリガー）。
    func refreshNow(region r: MKCoordinateRegion) {
        region = r
        guard isEnabled else { return }
        if r.span.latitudeDelta > VehicleTuning.hideAboveSpan {
            if !tracks.isEmpty || !displayVehicles.isEmpty {
                tracks.removeAll()
                displayVehicles = []
            }
            return
        }
        poll()
    }

    private func startTimers() {
        pollTimer = Timer.publish(every: VehicleTuning.pollInterval, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.poll() }
        animTimer = Timer.publish(every: VehicleTuning.animationInterval, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }
    private func cancelTimers() {
        pollTimer?.cancel(); animTimer?.cancel()
        pollTimer = nil; animTimer = nil
    }

    // MARK: 取得
    private func poll() {
        guard let r = region else { return }
        // 引きすぎている間は API を叩かない（垂れ流し防止）＆表示クリア
        if r.span.latitudeDelta > VehicleTuning.hideAboveSpan {
            if !tracks.isEmpty || !displayVehicles.isEmpty {
                tracks.removeAll()
                displayVehicles = []
            }
            return
        }
        let bbox = Self.bbox(r)
        let base = Self.apiBase
        Task { [weak self] in
            let raws = await Self.fetch(base: base, bbox: bbox)
            guard let self else { return }
            self.ingest(raws)
        }
    }

    private func ingest(_ raws: [Vehicle]) {
        let now = CACurrentMediaTime()
        for rv in raws {
            if var tr = tracks[rv.id] {
                let t = min(max((now - tr.startAt) / VehicleTuning.interpDuration, 0), 1)
                let curLat = tr.fromLat + (tr.toLat - tr.fromLat) * t
                let curLon = tr.fromLon + (tr.toLon - tr.fromLon) * t
                let meters = Self.dist(curLat, curLon, rv.lat, rv.lon)
                if meters > VehicleTuning.teleportMps * VehicleTuning.interpDuration {
                    tr.fromLat = rv.lat; tr.fromLon = rv.lon          // ワープはスライドさせない
                } else {
                    tr.fromLat = curLat; tr.fromLon = curLon          // 今いる位置から次へ
                }
                tr.toLat = rv.lat; tr.toLon = rv.lon
                tr.startAt = now
                tr.heading = rv.hdg ?? Self.heading(tr.fromLat, tr.fromLon, rv.lat, rv.lon) ?? tr.heading
                tr.lastSeen = now
                tracks[rv.id] = tr
            } else {
                tracks[rv.id] = Track(fromLat: rv.lat, fromLon: rv.lon, toLat: rv.lat, toLon: rv.lon,
                                      startAt: now, heading: rv.hdg, kind: rv.kind, feed: rv.feed,
                                      route: rv.route, lastSeen: now)
            }
        }
        tick()
    }

    // MARK: 毎フレーム補間
    private func tick() {
        let now = CACurrentMediaTime()
        var out: [DisplayVehicle] = []
        out.reserveCapacity(tracks.count)
        var dead: [String] = []
        for (id, tr) in tracks {
            if now - tr.lastSeen > VehicleTuning.staleAfter { dead.append(id); continue }
            let t = min(max((now - tr.startAt) / VehicleTuning.interpDuration, 0), 1)
            let lat = tr.fromLat + (tr.toLat - tr.fromLat) * t
            let lon = tr.fromLon + (tr.toLon - tr.fromLon) * t
            out.append(DisplayVehicle(id: id, coordinate: .init(latitude: lat, longitude: lon),
                                      heading: tr.heading, kind: tr.kind, feed: tr.feed, route: tr.route))
        }
        for id in dead { tracks.removeValue(forKey: id) }

        if out.count > VehicleTuning.maxVehicles, let c = region?.center {
            out.sort { sqFlat($0.coordinate, c) < sqFlat($1.coordinate, c) }
            out = Array(out.prefix(VehicleTuning.maxVehicles))
        }
        displayVehicles = out
    }

    private func sqFlat(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = a.latitude - b.latitude
        let dLon = a.longitude - b.longitude
        return dLat * dLat + dLon * dLon
    }

    // MARK: helpers
    private static func bbox(_ r: MKCoordinateRegion) -> String {
        let latM = max(r.span.latitudeDelta * 0.6, 0.02)
        let lonM = max(r.span.longitudeDelta * 0.6, 0.02)
        let minLat = r.center.latitude - latM, maxLat = r.center.latitude + latM
        let minLon = r.center.longitude - lonM, maxLon = r.center.longitude + lonM
        return "\(minLat),\(minLon),\(maxLat),\(maxLon)"
    }

    private static func dist(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
        let R = 6_371_000.0
        let dLat = (bLat - aLat) * .pi / 180, dLon = (bLon - aLon) * .pi / 180
        let la1 = aLat * .pi / 180, la2 = bLat * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * R * asin(min(1, sqrt(h)))
    }

    private static func heading(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double? {
        if dist(aLat, aLon, bLat, bLon) < 3 { return nil }      // ほぼ動いてない → 向き更新しない
        let dLon = (bLon - aLon) * .pi / 180
        let la1 = aLat * .pi / 180, la2 = bLat * .pi / 180
        let y = sin(dLon) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLon)
        var deg = atan2(y, x) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }

    private static func fetch(base: String, bbox: String) async -> [Vehicle] {
        guard let url = URL(string: "\(base)/api/vehicles/?bbox=\(bbox)") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        struct Resp: Decodable { let vehicles: [Vehicle] }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return [] }
            return (try? JSONDecoder().decode(Resp.self, from: data))?.vehicles ?? []
        } catch {
            return []
        }
    }
}
