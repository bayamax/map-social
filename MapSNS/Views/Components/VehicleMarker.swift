import SwiftUI
import UIKit

/// 押し出した3D箱の乗り物マーカー。
/// バス/トラム=1両（白＋都市色ライン）、鉄道/地下鉄=2連結（暗いグレー＋連結器）。
/// ヨー(進行方向−地図向き)で回転、ピッチで地面平面へ射影、地下鉄は地面下＋半透明。
struct VehicleMarker: View {
    let vehicle: DisplayVehicle
    var mapHeading: Double = 0
    var mapPitch: Double = 0

    var body: some View {
        let kind = vehicle.kind
        let isTrain = (kind == "rail" || kind == "metro")
        let isMetro = (kind == "metro")
        let accent = isTrain ? Color(white: 0.34) : Cities.color(vehicle.feed)
        let roofC = isTrain ? Color(white: 0.70) : Color(white: 0.93)
        let bodyC = isTrain ? Color(white: 0.55) : Color(white: 0.80)
        let glass = isTrain ? Color(red: 0.22, green: 0.28, blue: 0.34) : Color(red: 0.30, green: 0.40, blue: 0.48)
        let head = Color(red: 1.0, green: 0.92, blue: 0.55)
        let coupler = Color(white: 0.30)

        let w: CGFloat = 11
        let h: CGFloat = 9
        let depth: CGFloat = isMetro ? 8 : 0
        let carLen: CGFloat = isTrain ? 28 : (kind == "tram" ? 26 : 20)   // 1両の長さ
        let gap: CGFloat = 1.8                                            // 連結の隙間（詰める）
        let nCars = isTrain ? 2 : 1
        let total = CGFloat(nCars) * carLen + CGFloat(nCars - 1) * gap

        let rel = CGFloat(((vehicle.heading ?? 0) - mapHeading) * .pi / 180)
        let pitch = CGFloat(mapPitch * .pi / 180)
        let cosP = cos(pitch), sinP = sin(pitch)
        let canvas = max(w, total) + h + depth + 14

        Canvas { ctx, size in
            let cx = size.width / 2, cy = size.height / 2
            let hw = w / 2

            // 地面平面へ射影。zUp=高さ(上が正)。画面縦 cosP 圧縮・高さ sinP で起こす。
            func proj(_ dx: CGFloat, _ dy: CGFloat, _ zUp: CGFloat) -> CGPoint {
                let ox = dx * cos(rel) - dy * sin(rel)
                let oy = dx * sin(rel) + dy * cos(rel)
                return CGPoint(x: cx + ox, y: cy + oy * cosP - zUp * sinP)
            }
            let botZ: CGFloat = isMetro ? -(depth + h) : 0
            let topZ: CGFloat = isMetro ? -depth : h
            func g(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { proj(dx, dy, botZ) }
            func r(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { proj(dx, dy, topZ) }
            func quad(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Path {
                var p = Path(); p.move(to: a); p.addLine(to: b); p.addLine(to: c); p.addLine(to: d); p.closeSubpath(); return p
            }
            // 壁(接地→屋根)上の点 (t:端からの割合, v:高さ0..1)
            func wp(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ t: CGFloat, _ v: CGFloat) -> CGPoint {
                let gx = x0 + (x1 - x0) * t, gy = y0 + (y1 - y0) * t
                let gp = g(gx, gy), rp = r(gx, gy)
                return CGPoint(x: gp.x + (rp.x - gp.x) * v, y: gp.y + (rp.y - gp.y) * v)
            }
            func panel(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat,
                       _ t0: CGFloat, _ t1: CGFloat, _ v0: CGFloat, _ v1: CGFloat, _ color: Color) {
                ctx.fill(quad(wp(x0, y0, x1, y1, t0, v0), wp(x0, y0, x1, y1, t1, v0),
                              wp(x0, y0, x1, y1, t1, v1), wp(x0, y0, x1, y1, t0, v1)), with: .color(color))
            }

            // 1両を描く（dyF=前端, dyR=後端, isLead=先頭車）
            func drawCar(_ dyF: CGFloat, _ dyR: CGFloat, _ isLead: Bool) {
                // 4側面
                ctx.fill(quad(g(-hw, dyR), g(hw, dyR), r(hw, dyR), r(-hw, dyR)), with: .color(bodyC)) // 後
                ctx.fill(quad(g(hw, dyR), g(hw, dyF), r(hw, dyF), r(hw, dyR)), with: .color(bodyC))    // 右
                ctx.fill(quad(g(-hw, dyF), g(-hw, dyR), r(-hw, dyR), r(-hw, dyF)), with: .color(bodyC)) // 左
                ctx.fill(quad(g(-hw, dyF), g(hw, dyF), r(hw, dyF), r(-hw, dyF)), with: .color(bodyC))   // 前
                // 側面：色帯＋ガラス窓
                for sx in [hw, -hw] {
                    panel(sx, dyF, sx, dyR, 0.05, 0.95, 0.32, 0.46, accent)
                    for seg in [(0.12, 0.30), (0.36, 0.54), (0.60, 0.78), (0.82, 0.94)] {
                        panel(sx, dyF, sx, dyR, CGFloat(seg.0), CGFloat(seg.1), 0.50, 0.90, glass)
                    }
                }
                // 前面：色帯＋フロントガラス（先頭ならヘッドライト）
                panel(-hw, dyF, hw, dyF, 0.10, 0.90, 0.32, 0.46, accent)
                panel(-hw, dyF, hw, dyF, 0.14, 0.86, 0.52, 0.92, glass)
                if isLead {
                    for t in [0.24, 0.76] {
                        let p = wp(-hw, dyF, hw, dyF, CGFloat(t), 0.20)
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.1, y: p.y - 1.1, width: 2.2, height: 2.2)), with: .color(head))
                    }
                }
                // 後面：色帯＋リアガラス
                panel(-hw, dyR, hw, dyR, 0.10, 0.90, 0.32, 0.46, accent)
                panel(-hw, dyR, hw, dyR, 0.18, 0.82, 0.52, 0.90, glass)
                // 屋根
                ctx.fill(quad(r(-hw, dyR), r(hw, dyR), r(hw, dyF), r(-hw, dyF)), with: .color(roofC))
                ctx.stroke(quad(r(-hw, dyR), r(hw, dyR), r(hw, dyF), r(-hw, dyF)),
                           with: .color(.black.opacity(0.2)), lineWidth: 0.6)
            }

            // 影 / 地下印
            if isMetro {
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 3, y: cy - 2, width: 6, height: 4)), with: .color(.black.opacity(0.13)))
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: cx - hw, y: cy + (total / 2) * cosP - 2, width: w, height: 5)),
                         with: .color(.black.opacity(0.2)))
            }

            // 連結器（車両の間を橋渡し）。車両を後で上描きして両端を隠す。
            if nCars > 1 {
                let cw = w * 0.16
                ctx.fill(quad(g(-cw, -gap), g(cw, -gap), g(cw, gap), g(-cw, gap)), with: .color(coupler))
            }

            // 後ろの車両から描く（先頭を最後に上へ）
            for i in stride(from: nCars - 1, through: 0, by: -1) {
                let center = -(total / 2) + carLen / 2 + CGFloat(i) * (carLen + gap)
                drawCar(center - carLen / 2, center + carLen / 2, i == 0)
            }
        }
        .frame(width: canvas, height: canvas)
        // 地下鉄は半透明（地下にいる想定）
        .opacity(isMetro ? 0.45 : 1.0)
    }
}
