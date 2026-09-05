import Foundation
import CoreLocation

// MARK: - モデル（バックエンド /api/webcams/ の1件）

struct Webcam: Identifiable, Decodable, Equatable {
    let id: String
    let name: String        // 日本語名
    let name_en: String?    // 英語名（旧サーバ互換で optional）
    let lat: Double
    let lon: Double
    let video: String       // 検証済みの YouTube ライブ動画ID
    let channel: String?    // 配信チャンネルID（IDが入れ替わったときのフォールバック用）
    let post: Int?          // コメントスレッドのアンカー投稿ID（返信=このカメラのコメント）

    /// 端末言語に合わせた表示名
    var displayName: String {
        Locale.preferredLanguages.first?.hasPrefix("ja") == true ? name : (name_en ?? name)
    }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var watchURL: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(video)")
    }
}

// MARK: - サービス（起動時に一覧を1回取得。静的に近いデータなので再取得は1時間ごと）

@MainActor
final class WebcamService: ObservableObject {
    @Published private(set) var cams: [Webcam] = []
    /// カメラごとの「いま見ている人数」（アプリ内・視聴者ゼロのカメラはキー無し）
    @Published private(set) var counts: [String: Int] = [:]
    private var lastFetch: Date?
    private var countsTask: Task<Void, Never>?

    private static var apiBase: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String) ?? ""
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    // MARK: 視聴者数

    /// アプリ内視聴者のハートビート用・匿名トークン（起動ごとに変わる）
    private static let watcherToken = UUID().uuidString

    /// 在席を申告しつつ「このアプリから何人見ているか」を返す（60秒で自動退室）
    static func heartbeatAppWatchers(camID: String) async -> Int? {
        guard let url = URL(string: "\(apiBase)/api/webcams/\(camID)/watching/?t=\(watcherToken)") else { return nil }
        struct P: Decodable { let watchers: Int }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let p = try? JSONDecoder().decode(P.self, from: data) else { return nil }
        return p.watchers
    }

    // MARK: ピンのバッジ用・人数一括ポーリング（マップ表示中のみ）

    func startCountsPolling() {
        guard countsTask == nil else { return }
        countsTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, let counts = await Self.fetchAllCounts() {
                    self.counts = counts
                }
                try? await Task.sleep(nanoseconds: 25_000_000_000)
            }
        }
    }

    func stopCountsPolling() {
        countsTask?.cancel()
        countsTask = nil
    }

    private static func fetchAllCounts() async -> [String: Int]? {
        guard let url = URL(string: "\(apiBase)/api/webcams/watching/") else { return nil }
        struct P: Decodable { let counts: [String: Int] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let p = try? JSONDecoder().decode(P.self, from: data) else { return nil }
        return p.counts
    }

    func loadIfNeeded() {
        if let t = lastFetch, Date().timeIntervalSince(t) < 3600, !cams.isEmpty { return }
        guard let url = URL(string: "\(Self.apiBase)/api/webcams/") else { return }
        Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                struct Payload: Decodable { let webcams: [Webcam] }
                let payload = try JSONDecoder().decode(Payload.self, from: data)
                guard let self else { return }
                self.cams = payload.webcams
                self.lastFetch = Date()
            } catch {
                print("[WebcamService] fetch failed: \(error)")
            }
        }
    }
}
