import Foundation
import Combine
import CoreLocation
import QuartzCore

// MARK: - 国際宇宙ステーションの実位置（wheretheiss.at・キー不要）
//
// 10秒ごとに位置を取り、取得の合間は直前2点から求めた進行方向と速度（約7.66 km/s）で外挿する。
// 1周 約92分・地表上の軌跡が毎周ずれるので、ライブカメラ "iss" のピンをこの位置に置くと
// 「地球儀の上をゆっくり回っている」ように見える。

@MainActor
final class ISSService: ObservableObject {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var altitudeKm: Double = 420
    @Published private(set) var heading: Double = 45      // 進行方向（度）
    @Published private(set) var isDaylight = true

    private struct Fix { let lat, lon, speedMps: Double; let at: CFTimeInterval }
    private var last: Fix?
    private var pollTimer: AnyCancellable?
    private var animTimer: AnyCancellable?

    static let pollInterval: TimeInterval = 10
    static let animationInterval: TimeInterval = 1.0

    func start() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.publish(every: Self.pollInterval, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.poll() }
        animTimer = Timer.publish(every: Self.animationInterval, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
        poll()
    }
    func stop() {
        pollTimer?.cancel(); animTimer?.cancel()
        pollTimer = nil; animTimer = nil
    }

    private struct Resp: Decodable {
        let latitude, longitude, altitude, velocity: Double   // km, km/h
        let visibility: String?
    }

    private func poll() {
        Task { [weak self] in
            guard let url = URL(string: "https://api.wheretheiss.at/v1/satellites/25544") else { return }
            var req = URLRequest(url: url); req.timeoutInterval = 8
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false,
                  let r = try? JSONDecoder().decode(Resp.self, from: data) else { return }
            guard let self else { return }
            let now = CACurrentMediaTime()
            let fix = Fix(lat: r.latitude, lon: r.longitude, speedMps: r.velocity / 3.6, at: now)
            if let prev = self.last {
                // 直前の観測点からの方位＝進行方向
                self.heading = Self.bearing(from: prev, to: fix)
            }
            self.last = fix
            self.altitudeKm = r.altitude
            self.isDaylight = r.visibility != "eclipsed"
            self.tick()
        }
    }

    private func tick() {
        guard let f = last else { return }
        let dt = CACurrentMediaTime() - f.at
        coordinate = Self.advance(lat: f.lat, lon: f.lon, bearing: heading, meters: f.speedMps * dt)
    }

    private static func bearing(from a: Fix, to b: Fix) -> Double {
        let la1 = a.lat * .pi / 180, la2 = b.lat * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let y = sin(dLon) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }
    private static func advance(lat: Double, lon: Double, bearing: Double, meters: Double) -> CLLocationCoordinate2D {
        let R = 6_371_000.0 + 420_000.0   // 軌道半径で進めると地表投影の角速度が合う
        let d = meters / R
        let b = bearing * .pi / 180
        let la1 = lat * .pi / 180, lo1 = lon * .pi / 180
        let la2 = asin(sin(la1) * cos(d) + cos(la1) * sin(d) * cos(b))
        let lo2 = lo1 + atan2(sin(b) * sin(d) * cos(la1), cos(d) - sin(la1) * sin(la2))
        var lonDeg = lo2 * 180 / .pi
        if lonDeg > 180 { lonDeg -= 360 } else if lonDeg < -180 { lonDeg += 360 }
        return .init(latitude: la2 * 180 / .pi, longitude: lonDeg)
    }
}
