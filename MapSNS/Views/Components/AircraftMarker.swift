import SwiftUI
import CoreLocation

/// 飛行機マーカー（擬似3D）。バスと同じ「地面平面へ射影」の箱モデルで機体を組み、
/// 地下鉄が地面より下（負の標高）に沈むのと逆に、高度ぶんだけ地面から浮かせて描く。
/// 地面には影（z=0 の輪郭）を落とし、影と機体を細い線で結ぶので「浮いている高さ」が読める。
/// 地図を傾けるほど浮き上がり、真上から見ると影の上に重なる（実際の見え方と同じ）。
struct AircraftMarker: View {
    let aircraft: DisplayAircraft
    var mapHeading: Double = 0
    var mapPitch: Double = 0
    /// 便名ラベルを出すか（引きの表示ではクラッタになるので呼び出し側で制御）
    var showLabel = false
    /// 全体の縮尺（世界モードでは小さく描く）
    var scale: CGFloat = 1
    /// 浮かせる高さ（pt）を固定したいとき（世界モードでは高度差より一定の浮遊感を優先）
    var liftOverride: CGFloat? = nil
    /// 地球儀表示のカメラ。指定すると mapPitch の代わりに「視点直下は真上・縁ほど横から」の角度を
    /// 機体ごとに幾何から出す（中心角 θ とカメラ高度 d から視線と地面法線のなす角を求める）。
    var globe: MarkerProjection.GlobeCamera? = nil

    /// キャンバスの大きさと接地点（影の中心）の位置。Annotation の anchor と揃える。
    static let canvasSize = CGSize(width: 160, height: 150)
    static let groundY: CGFloat = 75
    static var anchor: UnitPoint { UnitPoint(x: 0.5, y: groundY / canvasSize.height) }

    var body: some View {
        // 浮かせる高さ（pt）：高度 0〜40,000ft → 0〜64pt。射影で sinP が掛かるので傾けたときだけ立ち上がる。
        let lift: CGFloat = liftOverride ?? (6 + CGFloat(min(max(aircraft.altitudeFt, 0), 40_000) / 40_000) * 58)

        // 配色（白い機体・明るい屋根・暗めの側面・濃紺の窓・尾翼にアクセント）
        let top = Color(white: 0.97)
        let side = Color(white: 0.80)
        let belly = Color(white: 0.68)
        let wingTop = Color(white: 0.90)
        let wingEdge = Color(white: 0.62)
        let glass = Color(red: 0.16, green: 0.22, blue: 0.32)
        let fin = Color(red: 0.13, green: 0.47, blue: 0.78)
        let engine = Color(white: 0.55)
        let outline = Color.black.opacity(0.28)

        Canvas { ctx, size in
            // 平面地図ではカメラの向き・傾きをそのまま、地球儀では機体ごとの角度を幾何から出す
            let origin = CGPoint(x: size.width / 2, y: Self.groundY)
            let P: MarkerProjection = globe.map {
                .globe(origin: origin, track: aircraft.track, mapHeading: mapHeading, camera: $0,
                       of: aircraft.coordinate, scale: scale)
            } ?? .flat(origin: origin, track: aircraft.track, mapHeading: mapHeading, mapPitch: mapPitch, scale: scale)
            func proj(_ dx: CGFloat, _ dy: CGFloat, _ z: CGFloat) -> CGPoint { P.point(dx, dy, z) }
            func poly(_ pts: [CGPoint]) -> Path { P.poly(pts) }
            func box(x0: CGFloat = 0, _ hw: CGFloat, _ dyF: CGFloat, _ dyR: CGFloat, _ zLo: CGFloat, _ zHi: CGFloat,
                     side sc: Color, top tc: Color) {
                P.box(ctx, x0: x0, hw, dyF, dyR, zLo, zHi, side: sc, top: tc)
            }

            // 機体寸法（pt）
            let hw: CGFloat = 2.6          // 胴体の幅半分
            let nose: CGFloat = -13        // 胴体前端
            let tip: CGFloat = -17         // 機首の先端
            let tail: CGFloat = 12         // 胴体後端
            let hgt: CGFloat = 5.0         // 胴体の高さ
            let L = lift

            // 主翼・水平尾翼の平面形（後退翼）
            let wingR: [(CGFloat, CGFloat)] = [(hw, -3), (14, 5.5), (14, 8), (hw, 3.5)]
            let wingL = wingR.map { (-$0.0, $0.1) }
            let stabR: [(CGFloat, CGFloat)] = [(hw, 7.5), (7.5, 10.5), (7.5, 12.5), (hw, 12)]
            let stabL = stabR.map { (-$0.0, $0.1) }

            // 1) 影（z=0 の輪郭。機体・主翼・尾翼を地面に落とす）
            let shadow = Color.black.opacity(0.24)
            ctx.fill(poly([proj(-hw, nose, 0), proj(0, tip, 0), proj(hw, nose, 0), proj(hw, tail, 0), proj(-hw, tail, 0)]), with: .color(shadow))
            for w in [wingR, wingL, stabR, stabL] { ctx.fill(poly(w.map { proj($0.0, $0.1, 0) }), with: .color(shadow)) }

            // 2) 高度の線（影の中心 → 機体の腹）。浮いている高さを読ませる補助線。
            P.altitudeLine(ctx, lift: L)

            // 3) エンジン（主翼の下に吊るす小箱）
            for sx: CGFloat in [-6.5, 6.5] {
                box(x0: sx, 1.4, 1.0, 6.0, L - 1.6, L + 1.2, side: engine, top: Color(white: 0.72))
            }

            // 4) 主翼（薄い板：縁を暗く、上面を明るく）
            for w in [wingR, wingL] {
                let lo = w.map { proj($0.0, $0.1, L + 1.0) }
                let hi = w.map { proj($0.0, $0.1, L + 1.9) }
                ctx.fill(poly(lo), with: .color(wingEdge))
                ctx.fill(poly(hi), with: .color(wingTop))
                ctx.stroke(poly(hi), with: .color(outline), lineWidth: 0.5)
            }

            // 5) 胴体（箱）＋機首（前面から先端へすぼめる）
            box(hw, nose, tail, L, L + hgt, side: side, top: top)
            // 機首：前面4隅から先端へ
            let n0 = proj(-hw, nose, L), n1 = proj(hw, nose, L), n2 = proj(hw, nose, L + hgt), n3 = proj(-hw, nose, L + hgt)
            let apex = proj(0, tip, L + hgt * 0.45)
            ctx.fill(poly([n0, n1, apex]), with: .color(belly))
            ctx.fill(poly([n1, n2, apex]), with: .color(side))
            ctx.fill(poly([n3, n0, apex]), with: .color(side))
            ctx.fill(poly([n2, n3, apex]), with: .color(top))
            // コクピット窓（上面前寄り）
            ctx.fill(poly([proj(-hw * 0.7, nose + 1.5, L + hgt), proj(hw * 0.7, nose + 1.5, L + hgt),
                           proj(hw * 0.5, nose - 1.2, L + hgt * 0.8), proj(-hw * 0.5, nose - 1.2, L + hgt * 0.8)]), with: .color(glass))
            // 客室窓（両側面に点列）
            for sx in [hw, -hw] {
                var y = nose + 4
                while y < tail - 3 {
                    let p = proj(sx, y, L + hgt * 0.62)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 0.55, y: p.y - 0.55, width: 1.1, height: 1.1)), with: .color(glass))
                    y += 1.9
                }
            }
            ctx.stroke(poly([proj(-hw, tail, L + hgt), proj(hw, tail, L + hgt), proj(hw, nose, L + hgt), proj(-hw, nose, L + hgt)]),
                       with: .color(outline), lineWidth: 0.5)

            // 6) 水平尾翼（胴体上端の高さ）
            for w in [stabR, stabL] {
                ctx.fill(poly(w.map { proj($0.0, $0.1, L + hgt * 0.7) }), with: .color(wingEdge))
                ctx.fill(poly(w.map { proj($0.0, $0.1, L + hgt * 0.7 + 0.8) }), with: .color(wingTop))
            }
            // 7) 垂直尾翼（x=0 の面に立つ板・アクセント色）。後退角つき。
            let finPts = [proj(0, 6.5, L + hgt), proj(0, tail, L + hgt), proj(0, tail, L + hgt + 7.5), proj(0, 9.5, L + hgt + 7.5)]
            ctx.fill(poly(finPts), with: .color(fin))
            ctx.stroke(poly(finPts), with: .color(outline), lineWidth: 0.5)

            // 8) 便名ラベル（機体の右横）
            if showLabel, let cs = aircraft.callsign {
                let text = ctx.resolve(Text(cs).font(.system(size: 8.5, weight: .bold, design: .monospaced)).foregroundColor(.white))
                let m = text.measure(in: CGSize(width: 80, height: 20))
                let at = proj(0, 0, L + hgt)
                let rect = CGRect(x: at.x + 14, y: at.y - m.height / 2 - 1.5, width: m.width + 8, height: m.height + 3)
                ctx.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(.black.opacity(0.55)))
                ctx.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
    }
}
