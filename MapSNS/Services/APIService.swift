import Foundation
import Combine
import CoreLocation

/// MapSNS 用の簡易 API サービス
final class APIService {
    static let shared = APIService()
    private init() {}
    
    // TODO: Info.plist に API_BASE_URL キーを追加しておくこと
    private var baseURL: String {
        guard let urlString = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String else {
            fatalError("API_BASE_URL が Info.plist に設定されていません")
        }
        return urlString.hasSuffix("/") ? String(urlString.dropLast()) : urlString
    }
    
    private var apiURL: String { "\(baseURL)/api" }

    private func authorizedRequest(_ request: URLRequest) -> URLRequest {
        var req = request
        if let token = KeychainHelper.shared.readString(forKey: AuthManager.accessTokenKey) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }
    
    // MARK: - 投稿一覧取得（位置情報付き）
    func fetchTimeline() -> AnyPublisher<[Post], Error> {
        guard let url = URL(string: "\(apiURL)/posts/global/") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        func publisher(_ request: URLRequest) -> AnyPublisher<[Post], Error> {
            return URLSession.shared.dataTaskPublisher(for: request)
                .tryMap { output in
                    if let http = output.response as? HTTPURLResponse {
                        print("fetchTimeline status: \(http.statusCode) bytes: \(output.data.count)")
                        if !(200...299).contains(http.statusCode) {
                            let msg = Self.parseErrorMessage(from: output.data) ?? "Server error (\(http.statusCode))"
                            throw APIServiceError(message: msg)
                        }
                    }
                    #if DEBUG
                    if let jsonStr = String(data: output.data, encoding: .utf8) {
                        print("Timeline raw JSON: \n\(jsonStr.prefix(1000))...")
                    }
                    #endif
                    return output.data
                }
                .decode(type: [Post].self, decoder: Self.jsonDecoder)
                .eraseToAnyPublisher()
        }

        // まずは匿名リクエストで取得
        let token = KeychainHelper.shared.readString(forKey: AuthManager.accessTokenKey)

        func makeRequest(useAuth: Bool) -> URLRequest {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if useAuth, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            return req
        }

        let firstReqAuth = token != nil

        return publisher(makeRequest(useAuth: firstReqAuth))
            .catch { [weak self] err -> AnyPublisher<[Post], Error> in
                guard let self = self else { return Fail(error: err).eraseToAnyPublisher() }
                // 認証付きで失敗した場合にトークンをクリアして匿名で再取得
                if firstReqAuth {
                    AuthManager.shared.clearTokens()
                    return publisher(makeRequest(useAuth: false))
                }
                return Fail(error: err).eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    // MARK: - 返信一覧取得
    func fetchReplies(parentID: Int) -> AnyPublisher<[Post], Error> {
        guard let url = URL(string: "\(apiURL)/posts/\(parentID)/comments/") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return URLSession.shared.dataTaskPublisher(for: authorizedRequest(request))
            .tryMap { output in
                if let http = output.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    if http.statusCode == 401 {
                        // 認証必須の場合は空配列で返す（未ログインでも UI 表示を続行）
                        return Data("[]".utf8)
                    }
                    let msg = Self.parseErrorMessage(from: output.data) ?? "Server error (\(http.statusCode))"
                    throw APIServiceError(message: msg)
                }
                return output.data
            }
            .decode(type: [Post].self, decoder: Self.jsonDecoder)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    // MARK: - 投稿作成
    func createPost(content: String, location: CLLocation?, parentPostID: Int? = nil) -> AnyPublisher<Post, Error> {
        guard let url = URL(string: "\(apiURL)/posts/") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        var body: [String: Any] = ["content": content]
        if let parent = parentPostID {
            body["parent_post"] = parent
        }
        if let location {
            let lat = Double(round(location.coordinate.latitude * 1_000_000) / 1_000_000)
            let lon = Double(round(location.coordinate.longitude * 1_000_000) / 1_000_000)
            body["latitude"] = lat
            body["longitude"] = lon
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        return URLSession.shared.dataTaskPublisher(for: authorizedRequest(request))
            .tryMap { output in
                if let http = output.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    // 401 ならログアウト
                    if http.statusCode == 401 {
                        AuthManager.shared.clearTokens()
                    }
                    let msg = Self.parseErrorMessage(from: output.data) ?? "Server error (\(http.statusCode))"
                    throw APIServiceError(message: msg)
                }
                return output.data
            }
            .decode(type: Post.self, decoder: Self.jsonDecoder)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    // MARK: - 投稿通報
    func reportPost(postID: Int, reason: String?) -> AnyPublisher<Void, Error> {
        guard let url = URL(string: "\(apiURL)/posts/\(postID)/report/") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [:]
        if let reason { body["reason"] = reason }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return URLSession.shared.dataTaskPublisher(for: authorizedRequest(req))
            .tryMap { output in
                if let http = output.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let msg = Self.parseErrorMessage(from: output.data) ?? "Server error (\(http.statusCode))"
                    throw APIServiceError(message: msg)
                }
                return ()
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    // MARK: - アカウント削除
    func deleteAccount() -> AnyPublisher<Void, Error> {
        guard let url = URL(string: "\(apiURL)/auth/me/delete/") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        return URLSession.shared.dataTaskPublisher(for: authorizedRequest(req))
            .tryMap { output in
                if let http = output.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let msg = Self.parseErrorMessage(from: output.data) ?? "Server error (\(http.statusCode))"
                    throw APIServiceError(message: msg)
                }
                return ()
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    // MARK: - JSONDecoder
    private static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        // バックエンドの日時フォーマットは `2024-07-19T14:23:45.123456Z` のようにマイクロ秒付きの ISO8601 形式
        // 標準の .iso8601 전략ではマイクロ秒を含む文字列をパースできずデコードエラーになるため、
        // フラクショナルセカンド対応の ISO8601DateFormatter を用いたカスタム戦略を設定する。

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let noTZFormatter: DateFormatter = {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone.current // サーバーはタイムゾーン無しで端末ローカル時刻を返す想定
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS" // 例: 2025-07-21T22:34:53.071370
            return fmt
        }()

        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            // 1) ISO8601 (Z / オフセット付き)
            if let date = isoFormatter.date(from: dateString) {
                return date
            }
            // 2) マイクロ秒あり・タイムゾーン無し
            if let date = noTZFormatter.date(from: dateString) {
                return date
            }
            // 3) ミリ秒なし (ISO8601)
            let isoNoFrac = ISO8601DateFormatter()
            isoNoFrac.formatOptions = [.withInternetDateTime]
            if let date = isoNoFrac.date(from: dateString) {
                return date
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(dateString)")
        }
        return decoder
    }

    // MARK: - Auth Models
    struct AuthResponse: Decodable {
        let access: String
        let refresh: String
        let user: UserBrief

        // Backend は user 情報をルート階層にフラットで返すため custom init
        enum CodingKeys: String, CodingKey {
            case access, refresh, token
            case id, username
            case profileImageURL = "profile_image_url"
            case bio
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // access と token のどちらかを許容
            if let acc = try? container.decodeIfPresent(String.self, forKey: .access) {
                access = acc
            } else if let tok = try? container.decode(String.self, forKey: .token) {
                access = tok
            } else {
                throw DecodingError.keyNotFound(CodingKeys.access, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Neither 'access' nor 'token' found in response"))
            }
            // refresh は無い場合もあるためオプショナルで受け取り、デフォルト空文字
            refresh = (try? container.decodeIfPresent(String.self, forKey: .refresh)) ?? ""
            let id = try container.decode(Int.self, forKey: .id)
            let username = try container.decode(String.self, forKey: .username)
            let profile = try container.decodeIfPresent(String.self, forKey: .profileImageURL)
            let bio = try container.decodeIfPresent(String.self, forKey: .bio)
            user = UserBrief(id: id, username: username, profileImageURL: profile, bio: bio, snsType: nil)
        }
    }

    struct AppleAuthResponse: Decodable {
        let token: String
        let user: UserBrief

        enum CodingKeys: String, CodingKey {
            case token, access
            case id, username
            case profileImageURL = "profile_image_url"
            case bio
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // token または access のどちらかでデコード
            if let tok = try? container.decodeIfPresent(String.self, forKey: .token) {
                token = tok
            } else if let acc = try? container.decode(String.self, forKey: .access) {
                token = acc
            } else {
                throw DecodingError.keyNotFound(CodingKeys.token, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Neither 'token' nor 'access' found in response"))
            }
            let id = try container.decode(Int.self, forKey: .id)
            let username = try container.decode(String.self, forKey: .username)
            let profile = try container.decodeIfPresent(String.self, forKey: .profileImageURL)
            let bio = try container.decodeIfPresent(String.self, forKey: .bio)
            user = UserBrief(id: id, username: username, profileImageURL: profile, bio: bio, snsType: nil)
        }
    }

    // MARK: - 共通エラーハンドリング
    struct APIServiceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func parseErrorMessage(from data: Data) -> String? {
        // 可能なフォーマット: {"detail": "..."} または {"non_field_errors": ["..."]} etc.
        if
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let detail = json["detail"] as? String { return detail }
            if let nonField = json["non_field_errors"] as? [String], let first = nonField.first { return first }
            // 先頭のvalueがStringのものを返す
            if let firstValue = json.values.first as? String { return firstValue }
            if let firstArray = json.values.first as? [String], let first = firstArray.first { return first }
        }
        return nil
    }

    // MARK: - Auth APIs
    func login(username: String, password: String) -> AnyPublisher<AuthResponse, Error> {
        guard let url = URL(string: "\(apiURL)/auth/login/") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // MapSNS ユーザーは必ず sns_type="map" を明示的に送る
        let body: [String: Any] = [
            "username": username,
            "password": password,
            "sns_type": "map"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { output in
                if let http = output.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let msg = Self.parseErrorMessage(from: output.data) ?? "Server error (\(http.statusCode))"
                    throw APIServiceError(message: msg)
                }
                return output.data
            }
            .decode(type: AuthResponse.self, decoder: Self.jsonDecoder)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    // Apple Login
    func loginWithApple(idToken: String) -> AnyPublisher<AppleAuthResponse, Error> {
        guard let url = URL(string: "\(apiURL)/auth/apple/login/") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // identity_token はバックエンドで期待されているキー名
        let body: [String: Any] = ["identity_token": idToken, "sns_type": "map"]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return URLSession.shared.dataTaskPublisher(for: req)
            .mapError { $0 as Error }
            .map(\.data)
            .decode(type: AppleAuthResponse.self, decoder: Self.jsonDecoder)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    // Refresh access token
    func refreshAccessToken(refreshToken: String) -> AnyPublisher<String, Error> {
        guard let url = URL(string: "\(apiURL)/auth/token/refresh/") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh": refreshToken])
        return URLSession.shared.dataTaskPublisher(for: req)
            .mapError { $0 as Error }
            .map(\.data)
            .decode(type: [String: String].self, decoder: Self.jsonDecoder)
            .tryMap { dict in
                guard let token = dict["access"] else { throw URLError(.badServerResponse) }
                return token
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    func register(username: String, email: String, password: String) -> AnyPublisher<Void, Error> {
        guard let url = URL(string: "\(apiURL)/auth/register/") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "username": username,
            "email": email,
            "password": password,
            "password2": password,  // 確認用も同じ値を送信（UI で2入力に分けていないため）
            "sns_type": "map"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { output in
                if let http = output.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let msg = Self.parseErrorMessage(from: output.data) ?? "Server error (\(http.statusCode))"
                    throw APIServiceError(message: msg)
                }
                return output.data
            }
            .map { _ in () }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    // MARK: - Block APIs
    func fetchBlockedUsers() -> AnyPublisher<[Int], Error> {
        guard let url = URL(string: "\(apiURL)/accounts/me/blocked/") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        let req = URLRequest(url: url)
        struct Resp: Decodable { let id: Int }
        return URLSession.shared.dataTaskPublisher(for: authorizedRequest(req))
            .tryMap { output in
                if let http = output.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let msg = Self.parseErrorMessage(from: output.data) ?? "Server error (\(http.statusCode))"
                    throw APIServiceError(message: msg)
                }
                return output.data
            }
            .decode(type: [Resp].self, decoder: Self.jsonDecoder)
            .map { $0.map { $0.id } }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    func block(userID: Int) -> AnyPublisher<Void, Error> {
        guard let url = URL(string: "\(apiURL)/accounts/\(userID)/block/") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        return URLSession.shared.dataTaskPublisher(for: authorizedRequest(req))
            .tryMap { output in
                if let http = output.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let msg = Self.parseErrorMessage(from: output.data) ?? "Server error (\(http.statusCode))"
                    throw APIServiceError(message: msg)
                }
                return ()
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    func unblock(userID: Int) -> AnyPublisher<Void, Error> {
        guard let url = URL(string: "\(apiURL)/accounts/\(userID)/block/") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        return URLSession.shared.dataTaskPublisher(for: authorizedRequest(req))
            .tryMap { output in
                if let http = output.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let msg = Self.parseErrorMessage(from: output.data) ?? "Server error (\(http.statusCode))"
                    throw APIServiceError(message: msg)
                }
                return ()
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
} 