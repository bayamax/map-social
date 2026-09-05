import SwiftUI
import UIKit

/// 散歩モードのアバター：マイクラ風のカクカク人型（縦長の体＋頭の立方体）。
/// バスと同じ擬似3D箱の射影で、向き(heading)と地図の傾き(pitch)に追従して立つ。
struct AvatarMarker: View {
    var heading: Double = 0       // 進行方向（度）
    var mapHeading: Double = 0    // カメラの向き（度）
    var mapPitch: Double = 72     // カメラのピッチ（度）
    var shirt: Color = Color(red: 0.20, green: 0.48, blue: 0.86)  // 体の色（自分=青/他者=色分け）
    var name: String? = nil       // 他者の名前（自分は nil）

    var body: some View {
        let shirtSide = Self.darker(shirt, 0.13)
        let skin = Color(red: 0.96, green: 0.80, blue: 0.62)
        let skinSide = Self.darker(skin, 0.10)
        let eye = Color(white: 0.15)

        let rel = CGFloat((heading - mapHeading) * .pi / 180)
        let pitch = CGFloat(mapPitch * .pi / 180)
        let cosP = cos(pitch), sinP = sin(pitch)

        Canvas { ctx, size in
            let cx = size.width / 2, cy = size.height / 2 + 8   // 足元を少し下に置く
            // 局所(dx:左右, dy:前後[-=前], z:高さ) → 画面。ヨー回転＋ピッチ射影。
            func proj(_ dx: CGFloat, _ dy: CGFloat, _ z: CGFloat) -> CGPoint {
                let ox = dx * cos(rel) - dy * sin(rel)
                let oy = dx * sin(rel) + dy * cos(rel)
                return CGPoint(x: cx + ox, y: cy + oy * cosP - z * sinP)
            }
            func quad(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Path {
                var p = Path(); p.move(to: a); p.addLine(to: b); p.addLine(to: c); p.addLine(to: d); p.closeSubpath(); return p
            }
            // 直方体を描く（hwx:幅半分, hdy:奥行半分, z下〜z上, 側面色, 上面色）
            func box(_ hwx: CGFloat, _ hdy: CGFloat, _ zLo: CGFloat, _ zHi: CGFloat, _ side: Color, _ top: Color) {
                func c(_ sx: CGFloat, _ sy: CGFloat, _ z: CGFloat) -> CGPoint { proj(sx * hwx, sy * hdy, z) }
                // 4側面（前=-dy, 右=+dx, 後=+dy, 左=-dx）
                ctx.fill(quad(c(-1,-1,zLo), c(1,-1,zLo), c(1,-1,zHi), c(-1,-1,zHi)), with: .color(side))   // 前
                ctx.fill(quad(c(1,-1,zLo), c(1,1,zLo), c(1,1,zHi), c(1,-1,zHi)), with: .color(side))        // 右
                ctx.fill(quad(c(1,1,zLo), c(-1,1,zLo), c(-1,1,zHi), c(1,1,zHi)), with: .color(side))        // 後
                ctx.fill(quad(c(-1,1,zLo), c(-1,-1,zLo), c(-1,-1,zHi), c(-1,1,zHi)), with: .color(side))    // 左
                // 上面
                ctx.fill(quad(c(-1,-1,zHi), c(1,-1,zHi), c(1,1,zHi), c(-1,1,zHi)), with: .color(top))
            }

            // 接地影
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 6, y: cy - 2, width: 12, height: 5)), with: .color(.black.opacity(0.28)))

            // 体（縦長の直方体）
            box(4.5, 3.0, 0, 15, shirtSide, shirt)
            // 頭（立方体）
            box(4.0, 4.0, 15, 23, skinSide, skin)

            // 顔（前面に目2つ）
            for sx in [CGFloat(-1.9), CGFloat(1.9)] {
                let p = proj(sx, -4.0, 19.5)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.0, y: p.y - 1.0, width: 2.0, height: 2.0)), with: .color(eye))
            }
        }
        .frame(width: 64, height: 64)
        .overlay(alignment: .top) {
            if let name {
                Text(name)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.5)))
            }
        }
    }

    private static func darker(_ color: Color, _ amount: CGFloat) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: s, brightness: max(0, b - amount), opacity: a)
    }
}
