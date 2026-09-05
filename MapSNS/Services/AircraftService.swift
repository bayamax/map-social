import Foundation
import Combine
import CoreLocation
import MapKit
import QuartzCore

// MARK: - 表示用（推測航法で動かした1機）

struct DisplayAircraft: Identifiable {
    let id: String              // ICAO hex
    var coordinate: CLLocationCoordinate2D
    let track: Double           // 進行方向（度・北=0）
    let altitudeFt: Double      // 気圧高度（ft）。影のオフセットに使う
    let callsign: String?       // 便名（例: JAL123）
    let type: String?           // 機種コード（例: B789）
}

// MARK: - 調整ノブ

enum AircraftTuning {
    static let pollInterval: TimeInterval = 10        // adsb.lol 取得間隔（匿名は約1req/秒までなので余裕を持つ）
    static let animationInterval: TimeInterval = 1.0 / 10.0
    static let maxAircraft = 30                       // 表示上限（中心に近い順）。1機 = Canvas 1枚なので数がそのまま描画負荷
    static let staleAfter: Double = 60                // この秒数更新が無ければ消す
    static let hideAboveSpan: Double = 12             // 緯度デルタがこれ超（大陸規模）なら「世界モード」に切替
    static let maxRadiusNM: Double = 250              // API 上限

    // 世界モード（大陸〜地球）：機種ごとの全世界一覧から長距離ワイドボディだけを拾う
    // 機種が増えるほど初回表示が遅れる（1機種ずつ間隔を空けて叩く）ので、機数の多い3機種に絞る
    static let worldTypes = ["B77W", "B789", "A359"]
    static let worldPollInterval: TimeInterval = 60
    /// 世界モードの推測航法の更新間隔。大陸スケールでは 0.5 秒で 100m 強＝1pt 未満なので 10Hz は無駄
    static let worldAnimationInterval: TimeInterval = 0.5
    static let worldMinAltFt: Double = 25_000         // 巡航中だけ（離着陸中は除く）
    static let worldMaxAircraft = 40
    static let worldStaleAfter: Double = 200
}

// MARK: - サービス（adsb.lol → 推測航法（速度×経過時間）で滑らかに動かす）
//
// バスと違って飛行機は速い（〜250m/s）ので、2点間の直線補間ではなく
// 「最終観測位置から対地速度・進行方向で外挿」する。10秒ごとの再取得で位置を補正する。
// バックエンドを介さず端末から直接取得する（無料・キー不要）。

@MainActor
final class AircraftService: ObservableObject {
    @Published private(set) var displayAircraft: [DisplayAircraft] = []
    @Published private(set) var isEnabled = false

    private struct Track {
        var lat, lon: Double            // 最終観測位置（表示位置ではない）
        var fixAt: CFTimeInterval        // その観測の時刻（seen_pos 分だけ過去にずらす）
        var track: Double
        var speedMps: Double
        var altFt: Double
        let callsign: String?
        let type: String?
        var lastSeen: CFTimeInterval
    }
    private var tracks: [String: Track] = [:]          // ローカル（周辺）
    private var worldTracks: [String: Track] = [:]     // 世界（長距離便）。モードを行き来しても保持する
    private var region: MKCoordinateRegion?
    /// 世界モード（引きの表示）。表示側は機体を小さく・ラベル無しで描く
    @Published private(set) var isWorldMode = false
    private var lastWorldPoll: CFTimeInterval = 0
    private var lastLocalPoll: CFTimeInterval = 0
    private var pollTimer: AnyCancellable?
    private var animTimer: AnyCancellable?
    private var inflight = false          // ローカル取得中
    private var worldInflight = false     // 世界取得中（機種ぶんリクエストが連続するので長い）
    /// 地図操作のたびに叩かない：ローカル取得の最短間隔（秒）。adsb.lol 匿名は詰めると 429 になる
    private static let minLocalInterval: Double = 4

    // MARK: ライフサイクル
    func start(region: MKCoordinateRegion) {
        isEnabled = true
        self.region = region
        isWorldMode = region.span.latitudeDelta > AircraftTuning.hideAboveSpan
        startTimers()
        #if DEBUG
        if ProcessInfo.processInfo.environment["SCREENSHOT_MOCK_AIRCRAFT"] == "1" {
            seedMock(around: region.center)
            return
        }
        #endif
        poll()
    }

    #if DEBUG
    /// スクリーンショット用：カメラ中心の周りに高度違いの機体を配置（ネットワーク不要）
    private var mockEnabled = false
    private func seedMock(around c: CLLocationCoordinate2D) {
        mockEnabled = true
        let now = CACurrentMediaTime()
        // (dLat, dLon, track, 高度ft, 速度m/s, 便名, 機種)
        let seeds: [(Double, Double, Double, Double, Double, String, String)] = [
            // 速度は小さく（撮影中にフレームから出ないように）
            ( 0.0020,  0.0035,  25,  2_500, 3,  "ANA37",  "B78X"),
            (-0.0035, -0.0045, 205,  9_000, 3,  "JAL512", "A359"),
            ( 0.0075, -0.0070, 118, 20_000, 3,  "SKY008", "B738"),
            (-0.0070,  0.0090, 295, 31_000, 3,  "APJ304", "A320"),
            ( 0.0120,  0.0030, 350, 38_000, 3,  "UAL79",  "B77W"),
        ]
        for s in seeds {
            tracks[s.5] = Track(lat: c.latitude + s.0, lon: c.longitude + s.1, fixAt: now, track: s.2,
                                speedMps: s.4, altFt: s.3, callsign: s.5, type: s.6, lastSeen: now)
        }
        tick()
    }
    #endif
    func stop() {
        isEnabled = false
        cancelTimers()
        tracks.removeAll()
        worldTracks.removeAll()
        displayAircraft = []
    }
    func pause() { cancelTimers() }
    func resumeIfEnabled() {
        guard isEnabled, pollTimer == nil else { return }
        startTimers()
        poll()
    }
    func updateRegion(_ r: MKCoordinateRegion) {
        region = r
        let world = r.span.latitudeDelta > AircraftTuning.hideAboveSpan
        if world != isWorldMode {
            // モードが変わったら表示する母集団を切り替える（世界側のキャッシュは捨てない＝往復しても再取得しない）
            isWorldMode = world
            tick(force: true)
            if isEnabled { poll() }
        }
    }
    /// 地図の移動が終わった瞬間に呼ぶ（移動＝更新トリガー）
    func refreshNow(region r: MKCoordinateRegion) {
        region = r
        guard isEnabled else { return }
        poll()
    }

    private func startTimers() {
        pollTimer = Timer.publish(every: AircraftTuning.pollInterval, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.poll() }
        animTimer = Timer.publish(every: AircraftTuning.animationInterval, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }
    private func cancelTimers() {
        pollTimer?.cancel(); animTimer?.cancel()
        pollTimer = nil; animTimer = nil
    }

    // MARK: 取得
    private func poll() {
        #if DEBUG
        if mockEnabled { tick(); return }
        #endif
        guard let r = region else { return }
        let now = CACurrentMediaTime()
        if isWorldMode {
            // 世界一覧は重い（機種ごと ~100KB）ので、モードを何度切り替えても1分に1回まで
            guard !worldInflight, now - lastWorldPoll >= AircraftTuning.worldPollInterval - 1 else { return }
            lastWorldPoll = now
            worldInflight = true
            Task { [weak self] in
                var all: [RawAircraft] = []
                for (i, t) in AircraftTuning.worldTypes.enumerated() {
                    if i > 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }   // 匿名は詰めて叩くと429になる
                    var got = await Self.fetchType(t)
                    if got.isEmpty {                                                 // 429 等は少し待って1回だけ再試行
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        got = await Self.fetchType(t)
                    }
                    all += got
                    guard let self else { return }
                    // まだ何も出ていない初回だけ、1機種目が返った時点で先に出す（全機種待ちだと数秒〜十数秒遅れて
                    // ユーザーがその前に離れてしまう）。2回目以降は揃ってから差し替える（機体の入れ替わりを避ける）
                    if self.worldTracks.isEmpty { self.ingestWorld(all) }
                }
                guard let self else { return }
                self.worldInflight = false
                self.ingestWorld(all)
            }
            return
        }
        guard !inflight, now - lastLocalPoll >= Self.minLocalInterval else { return }
        lastLocalPoll = now
        // 表示範囲を覆う半径（海里）。画面対角の半分＋余白。
        let latNM = r.span.latitudeDelta * 60
        let lonNM = r.span.longitudeDelta * 60 * cos(r.center.latitude * .pi / 180)
        let radius = min(AircraftTuning.maxRadiusNM, max(15, hypot(latNM, lonNM) * 0.6))
        let center = r.center
        inflight = true
        Task { [weak self] in
            let raws = await Self.fetch(center: center, radiusNM: radius)
            guard let self else { return }
            self.inflight = false
            self.ingest(raws)
        }
    }

    private struct RawAircraft: Decodable {
        let hex: String
        let flight: String?
        let t: String?
        let lat: Double?
        let lon: Double?
        let track: Double?
        let gs: Double?          // 対地速度（ノット）
        let alt_baro: AltBaro?
        let seen_pos: Double?    // 位置を最後に受信してからの秒数

        /// alt_baro は数値または "ground" 文字列
        enum AltBaro: Decodable {
            case feet(Double), ground
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let d = try? c.decode(Double.self) { self = .feet(d) }
                else { self = .ground }
            }
        }
    }

    /// 世界モード：巡航中の長距離便だけを残し、上限まで間引く（hex で決定的に選ぶので毎回同じ機体が残る）
    private func ingestWorld(_ raws: [RawAircraft]) {
        let now = CACurrentMediaTime()
        var picked = raws.filter { a in
            guard a.lat != nil, a.lon != nil, a.track != nil, (a.seen_pos ?? 0) < 120 else { return false }
            if case .feet(let f)? = a.alt_baro { return f >= AircraftTuning.worldMinAltFt }
            return false
        }
        picked.sort { $0.hex < $1.hex }
        if picked.count > AircraftTuning.worldMaxAircraft {
            // 最遠点サンプリング：密集地（欧米の空）を間引き、洋上の孤立した便を優先的に残す
            picked = Self.farthestPointSample(picked, count: AircraftTuning.worldMaxAircraft)
        }
        var fresh: [String: Track] = [:]
        for a in picked {
            let alt: Double = { if case .feet(let f)? = a.alt_baro { return f }; return 0 }()
            let age = a.seen_pos ?? 0
            let cs = a.flight?.trimmingCharacters(in: .whitespaces)
            fresh[a.hex] = Track(lat: a.lat!, lon: a.lon!, fixAt: now - age, track: a.track!,
                                 speedMps: (a.gs ?? 0) * 0.514444, altFt: alt,
                                 callsign: (cs?.isEmpty == false) ? cs : nil, type: a.t, lastSeen: now)
        }
        worldTracks = fresh
        tick(force: true)
    }

    private func ingest(_ raws: [RawAircraft]) {
        let now = CACurrentMediaTime()
        for a in raws {
            guard let lat = a.lat, let lon = a.lon, let trk = a.track else { continue }
            // 地上滑走中は出さない（空港上に溜まってノイズになる）
            if case .ground? = a.alt_baro { continue }
            let alt: Double = { if case .feet(let f)? = a.alt_baro { return f }; return 0 }()
            let age = a.seen_pos ?? 0
            if age > 60 { continue }
            let mps = (a.gs ?? 0) * 0.514444
            let cs = a.flight?.trimmingCharacters(in: .whitespaces)
            tracks[a.hex] = Track(lat: lat, lon: lon, fixAt: now - age, track: trk, speedMps: mps, altFt: alt,
                                  callsign: (cs?.isEmpty == false) ? cs : nil, type: a.t, lastSeen: now)
        }
        tick()
    }

    // MARK: 毎フレーム推測航法
    private var lastTick: CFTimeInterval = 0
    private func tick(force: Bool = false) {
        let now = CACurrentMediaTime()
        // 世界モードでは動きが 1pt 未満なので間引く（引きの地球儀で数十機の Canvas を 10Hz で描き直さない）
        if isWorldMode, !force, now - lastTick < AircraftTuning.worldAnimationInterval { return }
        lastTick = now
        var out: [DisplayAircraft] = []
        out.reserveCapacity(tracks.count)
        var dead: [String] = []
        let active = isWorldMode ? worldTracks : tracks
        let stale = isWorldMode ? AircraftTuning.worldStaleAfter : AircraftTuning.staleAfter
        for (id, tr) in active {
            if now - tr.lastSeen > stale {
                #if DEBUG
                if mockEnabled { tracks[id]?.lastSeen = now } else { dead.append(id); continue }
                #else
                dead.append(id); continue
                #endif
            }
            let dt = max(0, now - tr.fixAt)
            let c = Self.advance(lat: tr.lat, lon: tr.lon, bearing: tr.track, meters: tr.speedMps * dt)
            out.append(DisplayAircraft(id: id, coordinate: c, track: tr.track, altitudeFt: tr.altFt,
                                       callsign: tr.callsign, type: tr.type))
        }
        for id in dead { if isWorldMode { worldTracks.removeValue(forKey: id) } else { tracks.removeValue(forKey: id) } }
        if !isWorldMode, out.count > AircraftTuning.maxAircraft, let c = region?.center {
            out.sort { sqFlat($0.coordinate, c) < sqFlat($1.coordinate, c) }
            out = Array(out.prefix(AircraftTuning.maxAircraft))
        }
        displayAircraft = out
    }

    /// 最遠点サンプリング（緯度経度の平面距離・経度は 180° で折り返し）
    private static func farthestPointSample(_ items: [RawAircraft], count: Int) -> [RawAircraft] {
        guard items.count > count, count > 0 else { return items }
        func d2(_ a: RawAircraft, _ b: RawAircraft) -> Double {
            let dLat = a.lat! - b.lat!
            var dLon = abs(a.lon! - b.lon!); if dLon > 180 { dLon = 360 - dLon }
            return dLat * dLat + dLon * dLon
        }
        var chosen: [RawAircraft] = [items[0]]
        var minD = items.map { d2($0, items[0]) }
        while chosen.count < count {
            var best = 0
            for i in 1..<items.count where minD[i] > minD[best] { best = i }
            chosen.append(items[best])
            for i in 0..<items.count { minD[i] = min(minD[i], d2(items[i], items[best])) }
        }
        return chosen
    }

    private func sqFlat(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = a.latitude - b.latitude
        let dLon = a.longitude - b.longitude
        return dLat * dLat + dLon * dLon
    }

    // MARK: helpers
    /// 方位 bearing に meters 進んだ座標（球面近似）
    private static func advance(lat: Double, lon: Double, bearing: Double, meters: Double) -> CLLocationCoordinate2D {
        let R = 6_371_000.0
        let d = meters / R
        let b = bearing * .pi / 180
        let la1 = lat * .pi / 180, lo1 = lon * .pi / 180
        let la2 = asin(sin(la1) * cos(d) + cos(la1) * sin(d) * cos(b))
        let lo2 = lo1 + atan2(sin(b) * sin(d) * cos(la1), cos(d) - sin(la1) * sin(la2))
        return .init(latitude: la2 * 180 / .pi, longitude: lo2 * 180 / .pi)
    }

    // 取得・デコードはメインアクター外で（世界一覧は 1 機種 ~100KB あるので main で decode すると描画が引っかかる）
    nonisolated private static func fetch(center: CLLocationCoordinate2D, radiusNM: Double) async -> [RawAircraft] {
        let lat = String(format: "%.3f", center.latitude), lon = String(format: "%.3f", center.longitude)
        return await fetchList("https://api.adsb.lol/v2/point/\(lat)/\(lon)/\(Int(radiusNM))")
    }
    /// 機種コードで全世界の機体一覧（例: A388）
    nonisolated private static func fetchType(_ type: String) async -> [RawAircraft] {
        await fetchList("https://api.adsb.lol/v2/type/\(type)")
    }
    nonisolated private static func fetchList(_ urlString: String) async -> [RawAircraft] {
        guard let url = URL(string: urlString) else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("MapSNS/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        struct Resp: Decodable { let ac: [RawAircraft] }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return [] }
            return (try? JSONDecoder().decode(Resp.self, from: data))?.ac ?? []
        } catch {
            return []
        }
    }
}
