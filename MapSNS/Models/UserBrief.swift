import Foundation

/// 簡易ユーザ情報（タイムラインや認証レスポンスで使用）
struct UserBrief: Identifiable, Decodable {
    let id: Int
    let username: String
    let profileImageURL: String?
    let bio: String?
    let snsType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case profileImageURL = "profile_image_url"
        case bio
        case snsType = "sns_type"
    }
} 