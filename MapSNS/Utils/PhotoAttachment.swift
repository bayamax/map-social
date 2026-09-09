import SwiftUI
import UIKit
import CoreLocation
import Photos

/// 投稿に添付する写真。端末側で縮小・EXIF 除去してから送る。
/// - サーバのメモリが小さいので、原寸(数MB)を投げない
/// - EXIF はここで落とす（サーバでも再度落とすが、通信に載せない方が安全）
/// - ライブラリ写真は撮影場所・撮影日時を拾って「撮った場所に貼る」候補にする
struct PhotoAttachment {
    /// 送信用の JPEG（長辺 1600・品質 0.8）
    let jpeg: Data
    /// 画面プレビュー用
    let preview: UIImage
    /// その場でカメラ撮影したか（ライブラリから選んだ場合は false）
    let fromCamera: Bool
    /// 写真自体が持っている撮影位置（EXIF 由来。無ければ nil）
    var capturedAt: Date?
    var capturedCoordinate: CLLocationCoordinate2D?

    static let maxEdge: CGFloat = 1600
    static let quality: CGFloat = 0.8

    init?(image: UIImage, fromCamera: Bool) {
        let resized = Self.resize(image, maxEdge: Self.maxEdge)
        // jpegData は EXIF を持たないビットマップから作るので、位置情報は載らない
        guard let data = resized.jpegData(compressionQuality: Self.quality) else { return nil }
        self.jpeg = data
        self.preview = resized
        self.fromCamera = fromCamera
    }

    private static func resize(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let w = image.size.width, h = image.size.height
        let scale = min(1, maxEdge / max(w, h))
        if scale >= 1 { return image.normalizedOrientation() }
        let size = CGSize(width: floor(w * scale), height: floor(h * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

extension UIImage {
    /// 回転情報を画素に反映する（サーバ側でも exif_transpose するが、送る前に揃えておく）
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
