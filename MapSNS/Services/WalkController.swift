import Foundation
import Combine
import CoreLocation
import MapKit

/// 散歩モード（フェーズ1・自分だけ）。実GPSは使わず、見ている地図中心に置いた
/// 仮想アバターをドラッグで歩かせる。30fps で位置を積分し、カメラ追従用に frame を更新。
@MainActor
final class WalkController: ObservableObject {
    @Published var isActive = false
    @Published var coordinate = CLLocationCoordinate2D(latitude: 35.681, longitude: 139.767)
    @Published var avatarHeading: Double = 0   // アバターの進行方向（度）
    @Published var viewHeading: Double = 0     // カメラの向き（度）
    @Published private(set) var frame: Int = 0 // カメラ追従トリガ（増えるたびに追従）

    let distance: Double = 320                 // 寄りのカメラ距離（通常より寄る）
    let pitch: Double = 72
    private let maxSpeed: Double = 14.0         // m/s（探索ペース・後で調整）

    private var moveVector: CGSize = .zero
    private var timer: AnyCancellable?

    func start(at center: CLLocationCoordinate2D, heading: Double) {
        coordinate = center
        viewHeading = heading
        avatarHeading = heading
        moveVector = .zero
        isActive = true
        timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.step() }
        frame &+= 1
    }

    func stop() {
        isActive = false
        moveVector = .zero
        timer?.cancel(); timer = nil
    }

    func setMove(_ v: CGSize) { moveVector = v }
    func clearMove() { moveVector = .zero }

    /// 上半分ドラッグ：視点（カメラの向き）を回す
    func rotateView(by deltaDeg: Double) {
        viewHeading = (viewHeading + deltaDeg).truncatingRemainder(dividingBy: 360)
        frame &+= 1
    }

    /// カメラを動かさない前方の扇＝首の回旋可動域（片側 約60°＝快適域の上限）。
    /// この範囲内は頭(アバター)だけ向き、超えると体(カメラ)が回って追う。
    private let deadZone: Double = 60.0
    /// 扇を外れた分をどれだけ回頭で追うか（大きいほどキビキビ）
    private let followGain: Double = 0.12

    private func step() {
        let mag = min(1.0, hypot(moveVector.width, moveVector.height) / 70.0)
        if mag > 0.06 {
            // 画面ドラッグ方向（度・0=前/上、±=左右）
            let screenAngle = atan2(moveVector.width, -moveVector.height) * 180 / .pi
            let bearing = viewHeading + screenAngle
            avatarHeading = bearing
            // 遊び：進行方向が前方±deadZone の扇を外れた分だけカメラを回頭
            if screenAngle > deadZone {
                viewHeading += (screenAngle - deadZone) * followGain
            } else if screenAngle < -deadZone {
                viewHeading += (screenAngle + deadZone) * followGain
            }
            let meters = mag * maxSpeed / 30.0
            coordinate = Self.move(coordinate, bearingDeg: bearing, meters: meters)
        }
        frame &+= 1
    }

    /// 角度を最短経路で a→b へ t 補間（度）
    static func lerpAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var diff = (b - a).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        return a + diff * t
    }

    /// 座標を方位 bearing に meters 進めた座標を返す
    static func move(_ c: CLLocationCoordinate2D, bearingDeg: Double, meters: Double) -> CLLocationCoordinate2D {
        let R = 6_378_137.0
        let br = bearingDeg * .pi / 180
        let latRad = c.latitude * .pi / 180
        let dLat = (meters * cos(br)) / R
        let dLon = (meters * sin(br)) / (R * cos(latRad))
        return CLLocationCoordinate2D(latitude: c.latitude + dLat * 180 / .pi,
                                      longitude: c.longitude + dLon * 180 / .pi)
    }
}
