import SwiftUI
import CoreLocation

/// マーカー用の擬似3D射影（飛行機・ISS 共通）。
/// 局所座標 (dx:右, dy:後ろ[-=前], z:上) を、ヨー rel → ピッチ pitch で地面平面へ射影し、
/// 最後に画面上で roll だけ回す。平面地図では roll=0・pitch=カメラの傾き。
/// 地球儀では機体ごとに「視点直下は真上・縁ほど横から」の角度を幾何から出す（`globe(...)`）。
struct MarkerProjection {
    var origin: CGPoint
    var rel: CGFloat
    var pitch: CGFloat
    var roll: CGFloat = 0
    var scale: CGFloat = 1

    var sinP: CGFloat { sin(pitch) }

    /// 地球儀のカメラ（中心座標とカメラ高度 m）
    struct GlobeCamera {
        var center: CLLocationCoordinate2D
        var distance: Double
    }

    /// 平面地図（カメラの heading / pitch をそのまま使う）
    static func flat(origin: CGPoint, track: Double, mapHeading: Double, mapPitch: Double, scale: CGFloat) -> MarkerProjection {
        MarkerProjection(origin: origin, rel: CGFloat((track - mapHeading) * .pi / 180),
                         pitch: CGFloat(mapPitch * .pi / 180), roll: 0, scale: scale)
    }

    /// 地球儀：中心角 θ とカメラ高度 d から、地点の地面法線と視線のなす角（tilt）を出し、
    /// 射影軸を「視点から遠ざかる方向」（画面では中心→地点の放射方向）に取る。
    static func globe(origin: CGPoint, track: Double, mapHeading: Double, camera g: GlobeCamera,
                      of p: CLLocationCoordinate2D, scale: CGFloat) -> MarkerProjection {
        let v = globeView(center: g.center, distance: g.distance, of: p)
        return MarkerProjection(origin: origin,
                                rel: CGFloat((track - (v.bearingToCenter + 180)) * .pi / 180),
                                pitch: CGFloat(v.tilt * .pi / 180),
                                roll: CGFloat((v.bearingFromCenter - mapHeading) * .pi / 180),
                                scale: scale)
    }

    /// tilt = P の地面法線と P→カメラの視線のなす角（度）。中心で 0、地平線で 90。
    static func globeView(center c: CLLocationCoordinate2D, distance d: Double, of p: CLLocationCoordinate2D)
        -> (tilt: Double, bearingFromCenter: Double, bearingToCenter: Double) {
        let R = 6_371_000.0
        let φ1 = c.latitude * .pi / 180, φ2 = p.latitude * .pi / 180
        let dλ = (p.longitude - c.longitude) * .pi / 180
        let cosθ = min(1, max(-1, sin(φ1) * sin(φ2) + cos(φ1) * cos(φ2) * cos(dλ)))
        let num = (R + d) * cosθ - R
        let len = sqrt(max(1, R * R + (R + d) * (R + d) - 2 * R * (R + d) * cosθ))
        let tilt = num <= 0 ? 90.0 : acos(min(1, num / len)) * 180 / .pi
        func bearing(_ a1: Double, _ a2: Double, _ dl: Double) -> Double {
            let y = sin(dl) * cos(a2), x = cos(a1) * sin(a2) - sin(a1) * cos(a2) * cos(dl)
            return atan2(y, x) * 180 / .pi
        }
        return (tilt, bearing(φ1, φ2, dλ), bearing(φ2, φ1, -dλ))
    }

    func point(_ dx: CGFloat, _ dy: CGFloat, _ z: CGFloat) -> CGPoint {
        let ox = (dx * cos(rel) - dy * sin(rel)) * scale
        let oy = (dx * sin(rel) + dy * cos(rel)) * scale
        let sx = ox, sy = oy * cos(pitch) - z * scale * sin(pitch)
        return CGPoint(x: origin.x + sx * cos(roll) - sy * sin(roll), y: origin.y + sx * sin(roll) + sy * cos(roll))
    }

    func poly(_ pts: [CGPoint]) -> Path {
        var p = Path()
        for (i, q) in pts.enumerated() { i == 0 ? p.move(to: q) : p.addLine(to: q) }
        p.closeSubpath()
        return p
    }

    /// 局所 (dx, dy) の頂点列を高さ z に置いた多角形
    func poly(_ pts: [(CGFloat, CGFloat)], z: CGFloat) -> Path {
        poly(pts.map { point($0.0, $0.1, z) })
    }

    /// 直方体（x0:中心の横位置, hw:幅半分, dyF..dyR:前後, zLo..zHi:高さ）。側面→上面の順で描く。
    func box(_ ctx: GraphicsContext, x0: CGFloat = 0, _ hw: CGFloat, _ dyF: CGFloat, _ dyR: CGFloat,
             _ zLo: CGFloat, _ zHi: CGFloat, side sc: Color, top tc: Color) {
        let l = x0 - hw, r = x0 + hw
        ctx.fill(poly([point(l, dyR, zLo), point(r, dyR, zLo), point(r, dyR, zHi), point(l, dyR, zHi)]), with: .color(sc))
        ctx.fill(poly([point(r, dyR, zLo), point(r, dyF, zLo), point(r, dyF, zHi), point(r, dyR, zHi)]), with: .color(sc))
        ctx.fill(poly([point(l, dyF, zLo), point(l, dyR, zLo), point(l, dyR, zHi), point(l, dyF, zHi)]), with: .color(sc))
        ctx.fill(poly([point(l, dyF, zLo), point(r, dyF, zLo), point(r, dyF, zHi), point(l, dyF, zHi)]), with: .color(sc))
        ctx.fill(poly([point(l, dyR, zHi), point(r, dyR, zHi), point(r, dyF, zHi), point(l, dyF, zHi)]), with: .color(tc))
    }

    /// 高度の補助線（影の中心 → 浮いている高さ）。傾きが小さいときは出さない。
    func altitudeLine(_ ctx: GraphicsContext, lift: CGFloat) {
        guard lift * sinP > 8 else { return }
        var line = Path()
        line.move(to: point(0, 0, 0)); line.addLine(to: point(0, 0, lift))
        ctx.stroke(line, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        ctx.stroke(line, with: .color(.black.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [2, 3], dashPhase: 2.5))
    }
}
