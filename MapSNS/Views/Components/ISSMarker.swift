import SwiftUI
import CoreLocation

/// 国際宇宙ステーションのマーカー（擬似3D）。飛行機と同じ射影で、トラス・太陽電池パネル・
/// 与圧モジュールを箱で組み、地表に影を落として上空に浮かせる。地球儀では視点からの角度で
/// 「直下は真上・縁ほど横から」に見える。タップでライブカメラ（地球の眺め）が開く。
struct ISSMarker: View {
    var coordinate: CLLocationCoordinate2D
    var heading: Double = 0
    var mapHeading: Double = 0
    var mapPitch: Double = 0
    var watchers: Int = 0
    var isDaylight = true
    var scale: CGFloat = 1
    /// 浮かせる高さ（pt）。飛行機より高い軌道なのでやや高め。
    var lift: CGFloat = 26
    var globe: MarkerProjection.GlobeCamera? = nil
    @State private var glow = false

    static let canvasSize = CGSize(width: 160, height: 150)
    static let groundY: CGFloat = 75
    static var anchor: UnitPoint { UnitPoint(x: 0.5, y: groundY / canvasSize.height) }

    var body: some View {
        let panel = Color(red: 0.86, green: 0.62, blue: 0.20)
        let panelDark = Color(red: 0.55, green: 0.36, blue: 0.10)
        let panelEdge = Color(red: 0.42, green: 0.27, blue: 0.08)
        let truss = Color(white: 0.62)
        let trussTop = Color(white: 0.82)
        let body = Color(white: 0.80)
        let bodyTop = Color(white: 0.97)
        let radiator = Color(white: 0.92)
        let glass = Color(red: 0.16, green: 0.22, blue: 0.32)
        let outline = Color.black.opacity(0.28)

        Canvas { ctx, size in
            let origin = CGPoint(x: size.width / 2, y: Self.groundY)
            let P: MarkerProjection = globe.map {
                .globe(origin: origin, track: heading, mapHeading: mapHeading, camera: $0, of: coordinate, scale: scale)
            } ?? .flat(origin: origin, track: heading, mapHeading: mapHeading, mapPitch: mapPitch, scale: scale)
            let L = lift

            // 平面形（dx:右, dy:後ろ）。トラスは左右に長く、パネルはトラス両端から前後に張り出す。
            let trussHW: CGFloat = 21, trussHD: CGFloat = 1.2, trussH: CGFloat = 2.2
            let panels: [[(CGFloat, CGFloat)]] = [
                [(8, -12), (20, -12), (20, -2), (8, -2)], [(8, 2), (20, 2), (20, 12), (8, 12)],
                [(-20, -12), (-8, -12), (-8, -2), (-20, -2)], [(-20, 2), (-8, 2), (-8, 12), (-20, 12)],
            ]
            let modHW: CGFloat = 2.2, modF: CGFloat = -13, modR: CGFloat = 11, modH: CGFloat = 4.4
            let radiators: [[(CGFloat, CGFloat)]] = [
                [(-6.5, 3), (-3, 3), (-3, 9.5), (-6.5, 9.5)], [(3, 3), (6.5, 3), (6.5, 9.5), (3, 9.5)],
            ]

            // 1) 影（z=0）
            let shadow = Color.black.opacity(0.22)
            ctx.fill(P.poly([(-trussHW, -trussHD), (trussHW, -trussHD), (trussHW, trussHD), (-trussHW, trussHD)], z: 0), with: .color(shadow))
            for q in panels { ctx.fill(P.poly(q, z: 0), with: .color(shadow)) }
            ctx.fill(P.poly([(-modHW, modF), (modHW, modF), (modHW, modR), (-modHW, modR)], z: 0), with: .color(shadow))

            // 2) 高度の補助線
            P.altitudeLine(ctx, lift: L)

            // 3) 太陽電池パネル（薄い板：縁を暗く・上面に縞）
            for q in panels {
                ctx.fill(P.poly(q, z: L + 0.6), with: .color(panelEdge))
                ctx.fill(P.poly(q, z: L + 1.3), with: .color(panel))
                let x0 = min(q[0].0, q[1].0), x1 = max(q[0].0, q[1].0)
                let y0 = q[0].1, y1 = q[2].1
                var x = x0 + 2
                while x < x1 - 0.5 {
                    var l = Path(); l.move(to: P.point(x, y0, L + 1.3)); l.addLine(to: P.point(x, y1, L + 1.3))
                    ctx.stroke(l, with: .color(panelDark), lineWidth: 0.7)
                    x += 2.4
                }
                ctx.stroke(P.poly(q, z: L + 1.3), with: .color(outline), lineWidth: 0.5)
            }

            // 4) トラス（横長の桁）
            P.box(ctx, trussHW, -trussHD, trussHD, L, L + trussH, side: truss, top: trussTop)
            // 桁の節（上面に短い線）
            var x: CGFloat = -trussHW + 3
            while x < trussHW - 1 {
                var l = Path(); l.move(to: P.point(x, -trussHD, L + trussH)); l.addLine(to: P.point(x, trussHD, L + trussH))
                ctx.stroke(l, with: .color(truss), lineWidth: 0.6)
                x += 3
            }

            // 5) ラジエーター（白い板・トラス後方）
            for q in radiators {
                ctx.fill(P.poly(q, z: L + 0.8), with: .color(Color(white: 0.7)))
                ctx.fill(P.poly(q, z: L + 1.4), with: .color(radiator))
            }

            // 6) 与圧モジュール（トラスと直交する白い円筒＝箱）＋前方のキューポラ
            P.box(ctx, modHW, modF, modR, L, L + modH, side: body, top: bodyTop)
            ctx.stroke(P.poly([(-modHW, modF), (modHW, modF), (modHW, modR), (-modHW, modR)], z: L + modH),
                       with: .color(outline), lineWidth: 0.5)
            // 節（モジュールの継ぎ目）
            for y: CGFloat in [-6, -1, 5] {
                var l = Path(); l.move(to: P.point(-modHW, y, L + modH)); l.addLine(to: P.point(modHW, y, L + modH))
                ctx.stroke(l, with: .color(Color(white: 0.7)), lineWidth: 0.6)
            }
            let cup = P.point(0, modF + 2.5, L + modH)
            ctx.fill(Path(ellipseIn: CGRect(x: cup.x - 1.4 * scale, y: cup.y - 1.4 * scale, width: 2.8 * scale, height: 2.8 * scale)), with: .color(glass))

            // 7) ラベル（本体の右横）：ISS LIVE ＋ 視聴者数
            let label = watchers >= 1 ? "ISS  LIVE  👁 \(watchers)" : "ISS  LIVE"
            let text = ctx.resolve(Text(label).font(.system(size: 8.5, weight: .heavy)).foregroundColor(.white))
            let m = text.measure(in: CGSize(width: 120, height: 20))
            let at = P.point(0, 0, L + modH)
            let rect = CGRect(x: at.x + 24 * scale, y: at.y - m.height / 2 - 1.5, width: m.width + 10, height: m.height + 3)
            ctx.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(.black.opacity(0.72)))
            // 「LIVE」部分の赤い下地
            let live = ctx.resolve(Text("LIVE").font(.system(size: 8.5, weight: .heavy)).foregroundColor(.white))
            let pre = ctx.resolve(Text("ISS  ").font(.system(size: 8.5, weight: .heavy)))
            let preW = pre.measure(in: CGSize(width: 60, height: 20)).width
            let liveW = live.measure(in: CGSize(width: 60, height: 20)).width
            let liveRect = CGRect(x: rect.minX + 5 + preW - 2, y: rect.minY + 1.5, width: liveW + 4, height: rect.height - 3)
            ctx.fill(Path(roundedRect: liveRect, cornerRadius: liveRect.height / 2),
                     with: .color(Color(red: 0.90, green: 0.15, blue: 0.20)))
            ctx.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
        }
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
        .shadow(color: .white.opacity(glow ? 0.8 : 0.25), radius: glow ? 5 : 1.5)
        // 発光の明滅だけをアニメーションする（withAnimation で包まない：位置更新が巻き込まれて揺れる）
        .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: glow)
        .onAppear { glow = true }
    }
}
