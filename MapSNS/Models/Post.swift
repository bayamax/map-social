import Foundation
import CoreLocation

/// APIから取得した投稿データ
struct Post: Identifiable, Decodable {
    // UserBrief は Models/UserBrief.swift で定義されたグローバル構造体を利用します
    
    struct Location: Decodable {
        let latitude: Double
        let longitude: Double
        let placeName: String?

        enum CodingKeys: String, CodingKey {
            case latitude
            case longitude
            case placeName = "place_name"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            // latitude / longitude はバックエンド側では Decimal → JSON 文字列になる場合があるため、
            // 数値・文字列どちらでも受け取れるようにする
            func decodeDouble(forKey key: CodingKeys) throws -> Double {
                if let doubleVal = try? container.decode(Double.self, forKey: key) {
                    return doubleVal
                }
                if let strVal = try? container.decode(String.self, forKey: key), let doubleVal = Double(strVal) {
                    return doubleVal
                }
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Expected Double or String convertible to Double")
            }

            latitude = try decodeDouble(forKey: .latitude)
            longitude = try decodeDouble(forKey: .longitude)
            placeName = try? container.decodeIfPresent(String.self, forKey: .placeName)
        }

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }
    
    // MARK: - Properties
    let id: Int
    let user: UserBrief
    let content: String
    let createdAt: Date
    let location: Location?
    /// 写真投稿の画像。文字だけの投稿・他アプリからの投稿では nil。
    var imageURL: URL? = nil
    /// 地図の吹き出し用の縮小版（480px）。原寸を並べると通信量が跳ねるので必ずこちらを使う。
    var imageThumbURL: URL? = nil
    // その他必要に応じて…
    
    enum CodingKeys: String, CodingKey {
        case id
        case user
        case content
        case createdAt = "created_at"
        case location
        case imageURL = "image_url"
        case imageThumbURL = "image_thumb_url"
    }
} 