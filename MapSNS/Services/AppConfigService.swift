import Foundation
import Combine

/// 表示まわりの数字をサーバーから受け取る（`GET /api/app-config/`）。
/// アプリに定数で持つと変更のたびに審査が要るので、投稿の表示期間や
/// 地図の写真の大きさはサーバー側で決める。取得できなければ既定値で動く。
@MainActor
final class AppConfigService: ObservableObject {
    static let shared = AppConfigService()

    struct PhotoConfig: Codable, Equatable {
        var maxWidth: Double = 132
        var minWidth: Double = 24
        var nearSpan: Double = 0.02
        var farSpan: Double = 40
        var aspect: Double = 0.75
        var cornerRatio: Double = 1.0 / 14
        var borderRatio: Double = 1.0 / 90
        var showDot: Bool = true

        enum CodingKeys: String, CodingKey {
            case maxWidth = "max_width"
            case minWidth = "min_width"
            case nearSpan = "near_span"
            case farSpan = "far_span"
            case aspect
            case cornerRatio = "corner_ratio"
            case borderRatio = "border_ratio"
            case showDot = "show_dot"
        }
    }

    struct Config: Codable, Equatable {
        var postDisplayHours: Double = 720
        var photo = PhotoConfig()

        enum CodingKeys: String, CodingKey {
            case postDisplayHours = "post_display_hours"
            case photo
        }
    }

    /// 直近に取れた設定。取得前は前回値（無ければ既定値）。
    @Published private(set) var config = Config()

    private static let cacheKey = "appConfigCache"
    private var cancellable: AnyCancellable?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(Config.self, from: data) {
            config = cached
        }
    }

    /// 起動時に一度だけ呼ぶ。失敗しても黙って前回値を使い続ける。
    func refresh() {
        guard let url = URL(string: "\(APIService.shared.publicBaseURL)/api/app-config/") else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadRevalidatingCacheData
        cancellable = URLSession.shared.dataTaskPublisher(for: req)
            .map(\.data)
            .decode(type: Config.self, decoder: JSONDecoder())
            .replaceError(with: config)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] new in
                guard let self else { return }
                self.config = new
                if let data = try? JSONEncoder().encode(new) {
                    UserDefaults.standard.set(data, forKey: Self.cacheKey)
                }
            }
    }

    /// 地図の写真の表示幅。寄れば大きく、引けば小さく（表示範囲の度数で対数補間）。
    func photoWidth(forSpan span: Double) -> CGFloat {
        let p = config.photo
        let s = max(span, 0.0001)
        let lo = max(p.nearSpan, 0.0001), hi = max(p.farSpan, lo * 10)
        let t = (log10(s) - log10(lo)) / (log10(hi) - log10(lo))
        return CGFloat(p.maxWidth - min(max(t, 0), 1) * (p.maxWidth - p.minWidth))
    }
}
