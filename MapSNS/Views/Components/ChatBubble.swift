import SwiftUI

struct ChatBubble: View {
    let text: String
    /// 写真投稿のサムネイル（480px）。地図では原寸を絶対に使わない。
    var imageURL: URL? = nil
    /// 写真の表示幅（地図のズームに応じて呼び出し側が決める）
    var imageWidth: CGFloat = 132
    private let tailLength: CGFloat = 13

    var body: some View {
        if let imageURL {
            // 写真は吹き出しの枠に入れず、写真そのものを地図に置く。
            // 白い縁を細く残すのは、暗い地図・空撮の上でも輪郭が消えないため。
            VStack(spacing: 3) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "photo").foregroundColor(.gray)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white.opacity(0.85))
                    default:
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white.opacity(0.85))
                    }
                }
                .frame(width: imageWidth, height: imageWidth * 0.75)
                .clipShape(RoundedRectangle(cornerRadius: max(5, imageWidth / 14)))
                .overlay(
                    RoundedRectangle(cornerRadius: max(5, imageWidth / 14))
                        .stroke(Color.white.opacity(0.9), lineWidth: max(1, imageWidth / 90))
                )
                // 撮られた地点を示す小さな点（しっぽの代わり）
                Circle()
                    .fill(Color.white)
                    .frame(width: 5, height: 5)
                    .shadow(color: .black.opacity(0.35), radius: 1)
            }
        } else {
            // 書き込み中の吹き出し（TypingBubble）と同じ、なめらか一体型しっぽの形状
            let shape = SmoothTailBubble(cornerRadius: 16, tailWidth: 8, tailLength: tailLength)
            Text(text)
                .font(.caption)
                // 白い吹き出しなので、ダークマップ時でも読めるよう常に濃色
                .foregroundColor(.black)
                .padding(.horizontal, 12)
                .padding(.top, 9)
                .padding(.bottom, 9 + tailLength) // 本文余白 + しっぽの長さ
                .background(
                    shape
                        .fill(Color.white)
                        .overlay(shape.stroke(Color.gray.opacity(0.35), lineWidth: 0.5))
                )
        }
    }
}

#Preview {
    ChatBubble(text: "Hello")
        .padding()
        .previewLayout(.sizeThatFits)
}
