import SwiftUI

/// A simple speech bubble shape with a rounded rectangle body and a small triangular tail at the bottom centre.
struct SpeechBubbleShape: Shape {
    var cornerRadius: CGFloat = 10
    var tailSize: CGSize = CGSize(width: 14, height: 8)

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Define body rect (leave room for tail)
        let bodyHeight = rect.height - tailSize.height
        let bodyRect = CGRect(x: 0, y: 0, width: rect.width, height: bodyHeight)
        path.addRoundedRect(in: bodyRect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))

        // Draw triangular tail centred at bottom
        let midX = rect.midX
        path.move(to: CGPoint(x: midX - tailSize.width / 2, y: bodyHeight))
        path.addLine(to: CGPoint(x: midX, y: bodyHeight + tailSize.height))
        path.addLine(to: CGPoint(x: midX + tailSize.width / 2, y: bodyHeight))
        path.closeSubpath()

        return path
    }
} 