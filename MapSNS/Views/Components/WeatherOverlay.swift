import SwiftUI
import SpriteKit
import UIKit

/// 地図の上に重ねる天気エフェクト（雨/雪＝SpriteKitパーティクル、霧＝薄いトーン）。
/// allowsHitTesting(false) で地図操作は透過する。
struct WeatherOverlay: View {
    let effect: WeatherFX
    @State private var scene = WeatherScene()

    var body: some View {
        ZStack {
            if effect == .fog {
                Color(white: 0.82).opacity(0.28).ignoresSafeArea()
            }
            SpriteView(scene: scene, options: [.allowsTransparency])
                .ignoresSafeArea()
                .onAppear { scene.apply(effect) }
                .onChange(of: effect) { _, new in scene.apply(new) }
        }
        .allowsHitTesting(false)
    }
}

/// 雨・雪のエミッタを持つ透明シーン
final class WeatherScene: SKScene {
    private var emitter: SKEmitterNode?
    private var current: WeatherFX = .none

    override init() {
        super.init(size: CGSize(width: 400, height: 800))
        scaleMode = .resizeFill
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        view.allowsTransparency = true
        rebuild()
    }
    override func didChangeSize(_ oldSize: CGSize) { rebuild() }

    func apply(_ fx: WeatherFX) {
        guard fx != current else { return }
        current = fx
        rebuild()
    }

    private func rebuild() {
        emitter?.removeFromParent()
        emitter = nil
        guard size.width > 1 else { return }
        switch current {
        case .rain: emitter = Self.rain(width: size.width, height: size.height)
        case .snow: emitter = Self.snow(width: size.width, height: size.height)
        case .fog, .none: emitter = nil
        }
        if let e = emitter { addChild(e) }
    }

    // MARK: - エミッタ
    private static func rain(width: CGFloat, height: CGFloat) -> SKEmitterNode {
        let e = SKEmitterNode()
        e.particleTexture = lineTexture()
        e.particleBirthRate = max(120, width * 0.7)
        e.particleLifetime = 1.3
        e.particlePositionRange = CGVector(dx: width * 1.3, dy: 0)
        e.position = CGPoint(x: width / 2, y: height + 12)
        e.emissionAngle = -.pi / 2 - 0.12          // ほぼ真下＋わずかに風で傾く
        e.emissionAngleRange = 0.04
        e.particleSpeed = height * 1.5
        e.particleSpeedRange = 140
        e.particleAlpha = 0.5
        e.particleAlphaRange = 0.2
        e.particleScale = 1.0
        e.particleScaleRange = 0.4
        e.particleColor = UIColor(white: 0.88, alpha: 1)
        e.particleColorBlendFactor = 1
        e.particleBlendMode = .alpha
        return e
    }

    private static func snow(width: CGFloat, height: CGFloat) -> SKEmitterNode {
        let e = SKEmitterNode()
        e.particleTexture = dotTexture()
        e.particleBirthRate = max(40, width * 0.3)
        e.particleLifetime = 7
        e.particlePositionRange = CGVector(dx: width * 1.3, dy: 0)
        e.position = CGPoint(x: width / 2, y: height + 12)
        e.emissionAngle = -.pi / 2
        e.emissionAngleRange = 0.7
        e.particleSpeed = height * 0.22
        e.particleSpeedRange = 50
        e.xAcceleration = 6                          // ゆらゆら横ドリフト
        e.particleAlpha = 0.85
        e.particleAlphaRange = 0.2
        e.particleScale = 0.55
        e.particleScaleRange = 0.3
        e.particleColor = .white
        e.particleColorBlendFactor = 1
        e.particleBlendMode = .alpha
        return e
    }

    // MARK: - 粒テクスチャ（アセット不要・その場生成）
    private static func lineTexture() -> SKTexture {
        let size = CGSize(width: 3, height: 14)
        let img = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0.5, y: 0, width: 2, height: 14), cornerRadius: 1).fill()
        }
        return SKTexture(image: img)
    }
    private static func dotTexture() -> SKTexture {
        let size = CGSize(width: 8, height: 8)
        let img = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 6, height: 6)).fill()
        }
        return SKTexture(image: img)
    }
}
