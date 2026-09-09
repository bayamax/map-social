import Foundation
import CoreLocation
import ImageIO

/// ライブラリから選んだ写真の EXIF から「いつ・どこで撮ったか」を読む。
/// 写真ライブラリの許可は不要（PhotosPicker が渡してくれたデータを読むだけ）。
/// 読んだあとの送信用 JPEG には EXIF を載せない（PhotoAttachment 側で再エンコード）。
enum ImageMetadata {
    static func read(from data: Data) -> (date: Date?, coordinate: CLLocationCoordinate2D?) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return (nil, nil)
        }
        var date: Date?
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
            date = fmt.date(from: s)
        }
        var coordinate: CLLocationCoordinate2D?
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            coordinate = CLLocationCoordinate2D(latitude: latRef == "S" ? -lat : lat,
                                                longitude: lonRef == "W" ? -lon : lon)
        }
        return (date, coordinate)
    }
}
