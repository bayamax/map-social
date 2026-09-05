import SwiftUI

/// 世界ライブカメラのマーカー。白円＋赤いカメラアイコン、下に LIVE バッジ。
/// 誰かが見ているときだけ右上に 👁+人数 のバッジが出る（「いま誰かがここを見てる」シグナル）。
struct WebcamMarker: View {
    let name: String
    var watchers: Int = 0
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 30, height: 30)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    Image(systemName: "video.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(red: 0.90, green: 0.15, blue: 0.20))
                }
                if watchers >= 1 {
                    HStack(spacing: 1.5) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 7, weight: .bold))
                        Text("\(watchers)")
                            .font(.system(size: 9, weight: .heavy))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .overlay(Capsule().stroke(.white.opacity(0.9), lineWidth: 1))
                    .offset(x: 10, y: -7)
                }
            }
            Text("LIVE")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color(red: 0.90, green: 0.15, blue: 0.20)))
                .opacity(pulse ? 1.0 : 0.55)
                // 明滅はこの opacity だけに限定する。withAnimation(.repeatForever) で包むと
                // Map がアノテーションを置き直すたびに位置の変化まで永久アニメーションに巻き込まれ、
                // 実機でピンが周期的に揺れる（既知の SwiftUI Map の挙動）。
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
        }
        .onAppear { pulse = true }
    }
}
