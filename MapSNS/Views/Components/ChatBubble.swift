import SwiftUI

struct ChatBubble: View {
    let text: String
    /// 写真投稿のサムネイル（480px）。地図では原寸を絶対に使わない。
    var imageURL: URL? = nil
    /// 写真の表示幅（地図のズームに応じて呼び出し側が決める）
    var imageWidth: CGFloat = 132
    private let tailLength: CGFloat = 13

    var body: some View {
        // 書き込み中の吹き出し（TypingBubble）と同じ、なめらか一体型しっぽの形状
        let shape = SmoothTailBubble(cornerRadius: 16, tailWidth: 8, tailLength: tailLength)
        VStack(alignment: .leading, spacing: 6) {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "photo")
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    default:
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: imageWidth, height: imageWidth * 0.75)
                .clipShape(RoundedRectangle(cornerRadius: max(4, imageWidth / 17)))
            }
            if !text.isEmpty, imageURL == nil {
                Text(text)
                    .font(.caption)
                    // 白い吹き出しなので、ダークマップ時でも読めるよう常に濃色
                    .foregroundColor(.black)
            }
        }
        .padding(.horizontal, imageURL == nil ? 12 : 5)
        .padding(.top, imageURL == nil ? 9 : 5)
        .padding(.bottom, (imageURL == nil ? 9 : 5) + tailLength) // 本文余白 + しっぽの長さ
        .background(
            shape
                .fill(Color.white)
                .overlay(shape.stroke(Color.gray.opacity(0.35), lineWidth: 0.5))
        )
    }
}

#Preview {
    ChatBubble(text: "Hello")
        .padding()
        .previewLayout(.sizeThatFits)
} 