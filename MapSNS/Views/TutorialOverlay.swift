import SwiftUI

/// 初回起動時に一度だけ地図の上に重ねる3枚のチュートリアル。
///
/// 設計意図: 文章で説明するより「地図が後ろに見えている状態」で操作を教えたいので、
/// 別画面には遷移せずオーバーレイにしている。実際の UI 部品（緑の投稿ボタン・赤い
/// カメラピン・白い吹き出し）をそのまま縮小して見せ、指で探す手間を無くす。
struct TutorialOverlay: View {
    @Binding var isPresented: Bool
    @State private var page = 0

    /// 撮影/確認用: 指定ページから開く（DEBUGビルドで環境変数があるときだけ効く）
    private static var initialPage: Int {
        #if DEBUG
        if let v = ProcessInfo.processInfo.environment["TUTORIAL_PAGE"], let i = Int(v) { return max(0, min(2, i)) }
        #endif
        return 0
    }

    private let pageCount = 3

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: 22) {
                    illustration
                        .frame(height: 92)

                    VStack(spacing: 10) {
                        Text(title)
                            .font(.title3)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                        Text(message)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 8)

                    // ページ位置
                    HStack(spacing: 7) {
                        ForEach(0..<pageCount, id: \.self) { i in
                            Circle()
                                .fill(i == page ? Color.green : Color.secondary.opacity(0.28))
                                .frame(width: 7, height: 7)
                        }
                    }

                    Button {
                        if page < pageCount - 1 {
                            withAnimation(.easeInOut(duration: 0.22)) { page += 1 }
                        } else {
                            finish()
                        }
                    } label: {
                        Text(page < pageCount - 1 ? "次へ" : "はじめる")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(24)
                .frame(maxWidth: 340)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(.systemBackground))
                )
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)

                Button("スキップ") { finish() }
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    // 明るい衛星写真の上でも読めるよう、薄い下地を敷く
                    .background(Capsule().fill(Color.black.opacity(0.35)))
                    .padding(.top, 18)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
        }
        .transition(.opacity)
        .onAppear { page = Self.initialPage }
    }

    private func finish() {
        withAnimation(.easeInOut(duration: 0.25)) { isPresented = false }
    }

    // MARK: - ページ内容

    // Text(String) は辞書を引かない。LocalizedStringKey で返して多言語を効かせる。
    private var title: LocalizedStringKey {
        switch page {
        case 0:  return "地図に、いまを書き込む"
        case 1:  return "世界のライブカメラ"
        default: return "誰かの声をのぞく"
        }
    }

    private var message: LocalizedStringKey {
        switch page {
        case 0:  return "緑のボタンを押したまま指をすべらせて、置きたい場所で離すだけ。あなたの言葉がその場所に残ります。"
        case 1:  return "赤いピンをタップすると、その街のいまが映像で流れます。見ながらコメントもできます。"
        default: return "白い吹き出しをタップすると、そこで誰かが書いたことが読めます。返信もできます。"
        }
    }

    /// 実際の UI 部品をそのまま縮小して見せる
    @ViewBuilder
    private var illustration: some View {
        switch page {
        case 0:
            ZStack {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.white)
                    .padding(22)
                    .background(Circle().fill(Color.green))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.primary)
                    .offset(x: 30, y: 30)
            }
        case 1:
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: 74, height: 74)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                Image(systemName: "video.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.red)
                Text("LIVE")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.red))
                    .offset(x: 30, y: -30)
            }
        default:
            VStack(spacing: -2) {
                Text("ここ、すごい人")
                    .font(.caption)
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white)
                            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    )
                Triangle()
                    .fill(Color.white)
                    .frame(width: 12, height: 10)
            }
        }
    }
}

/// 吹き出しのしっぽ
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX - rect.width / 2, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX + rect.width / 2, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
