import Foundation
import Combine
import CoreLocation
import MapKit

/// 地図に重ねる天気エフェクトの種類
enum WeatherFX: Equatable {
    case none, rain, snow, fog
}

/// 地図中心の「今の天気」を Open-Meteo（無料・キー不要）で取得する。
/// 演出（雨/雪オーバーレイ）のトグルと連動。
@MainActor
final class WeatherService: ObservableObject {
    @Published private(set) var effect: WeatherFX = .none
    @Published private(set) var isEnabled = false
    @Published private(set) var label: String?      // 例: "12°"（任意表示用）

    private var region: MKCoordinateRegion?
    private var lastCenter: CLLocationCoordinate2D?
    private var timer: AnyCancellable?

    func start(region r: MKCoordinateRegion) {
        isEnabled = true
        region = r
        startTimer()
        fetch()
    }
    func stop() {
        isEnabled = false
        timer?.cancel(); timer = nil
        effect = .none
        label = nil
    }
    func pause() { timer?.cancel(); timer = nil }
    func resumeIfEnabled() {
        guard isEnabled, timer == nil else { return }
        startTimer(); fetch()
    }

    /// 地図移動時に呼ぶ。中心が十分動いたら取り直す。
    func updateRegion(_ r: MKCoordinateRegion) {
        region = r
        guard isEnabled else { return }
        if let last = lastCenter {
            let d = abs(r.center.latitude - last.latitude) + abs(r.center.longitude - last.longitude)
            if d > 0.25 { fetch() }
        } else {
            fetch()
        }
    }

    private func startTimer() {
        // 天気は変化が遅いので10分ごと
        timer = Timer.publish(every: 600, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.fetch() }
    }

    private func fetch() {
        guard let c = region?.center else { return }
        lastCenter = c
        Task { [weak self] in
            guard let res = await Self.load(lat: c.latitude, lon: c.longitude) else { return }
            guard let self else { return }
            self.effect = res.fx
            self.label = res.label
        }
    }

    private static func load(lat: Double, lon: Double) async -> (fx: WeatherFX, label: String)? {
        let s = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code,is_day"
        guard let url = URL(string: s) else { return nil }
        struct Resp: Decodable {
            struct Cur: Decodable { let temperature_2m: Double; let weather_code: Int }
            let current: Cur
        }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            let r = try JSONDecoder().decode(Resp.self, from: data)
            return (fx(for: r.current.weather_code), "\(Int(r.current.temperature_2m.rounded()))°")
        } catch {
            return nil
        }
    }

    /// WMO weather code → エフェクト
    static func fx(for code: Int) -> WeatherFX {
        switch code {
        case 71, 73, 75, 77, 85, 86:                                   return .snow
        case 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 99: return .rain
        case 45, 48:                                                   return .fog
        default:                                                       return .none
        }
    }
}
