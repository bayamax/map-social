import Foundation

/// バックエンド /api/vehicles/ から受け取る「生の1台」（正規化済みJSON）。
/// 補間前の素データ。表示用の補間後は DisplayVehicle（VehicleService）を使う。
struct Vehicle: Decodable, Sendable {
    let id: String
    let lat: Double
    let lon: Double
    let hdg: Double?    // 進行方向（度・北=0）。無いフィードでは nil → 移動ベクトルから算出
    let spd: Double?
    let ts: Double?
    let route: String?
    let feed: String
    let kind: String    // bus / tram / rail / ferry ...
}
