import Foundation
import Combine
import CoreLocation
import os

/// 認証リフレッシュの失敗種別。通信失敗ではログアウトせず、サーバ拒否時のみログアウトする。
enum AuthError: Error {
    case noRefreshToken    // 端末に refresh が無い → ログアウト相当
    case refreshRejected   // サーバが refresh を 401/403 で拒否 → ログアウト相当
    case transient         // 通信エラー / 5xx / タイムアウト → ログアウトしない（後で再試行）

    var isLogoutWorthy: Bool {
        switch self {
        case .noRefreshToken, .refreshRejected: return true
        case .transient: return false
        }
    }
}

/// MapSNS 用の簡易 API サービス
final class APIService {
    static let shared = APIService()
    private init() {}
    
    // TODO: Info.plist に API_BASE_URL キーを追加しておくこと
    private var baseURL: String {
        #if DEBUG
        // ローカル検証用（DEBUG のみ）。例: API_BASE_URL_OVERRIDE=http://127.0.0.1:8009
        if let override = ProcessInfo.processInfo.environment["API_BASE_URL_OVERRIDE"], !override.isEmpty {
            return override.hasSuffix("/") ? String(override.dropLast()) : override
        }
        #endif
        guard let urlString = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String else {
            fatalError("API_BASE_URL が Info.plist に設定されていません")
        }
        return urlString.hasSuffix("/") ? String(urlString.dropLast()) : urlString
    }
    
    private var apiURL: String { "\(baseURL)/api" }

    // 進行中のリフレッシュを共有し多重実行を防ぐ（複数の 401 が同時に来ても更新は1回だけ）
    private let refreshLock = NSLock()
    private var refreshInFlight: AnyPublisher<String, Error>?

    /// access トークンを付けて送信し、401（失効）なら refresh で更新して1度だけ再試行する。
    /// refresh も失効している場合のみ clearTokens（ログアウト）する。
    private func authorizedData(_ build: @escaping () -> URLRequest) -> AnyPublisher<(data: Data, response: URLResponse), Error> {
        func attempt(allowRefresh: Bool) -> AnyPublisher<(data: Data, response: URLResponse), Error> {
            var req = build()
            if let token = KeychainHelper.shared.readString(forKey: AuthManager.accessTokenKey) {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            return URLSession.shared.dataTaskPublisher(for: req)
                .mapError { $0 as Error }
                .flatMap { output -> AnyPublisher<(data: Data, response: URLResponse), Error> in
                    if allowRefresh, let http = output.response as? HTTPURLResponse, http.statusCode == 401 {
                        // access 失効 → refresh して1度だけ再試行
                        AuthLog.log.info("401 on \(req.url?.path ?? "?", privacy: .public) -> refresh + retry")
                        return self.refreshTokenSingleFlight()
                            .flatMap { _ in attempt(allowRefresh: false) }
                            .catch { err -> AnyPublisher<(data: Data, response: URLResponse), Error> in
                                // サーバが拒否/トークン無しのときだけログアウト。通信失敗ではセッション維持。
                                if (err as? AuthError)?.isLogoutWorthy ?? false {
                                    AuthLog.log.error("refresh-after-401 REJECTED -> clearTokens (\(String(describing: err), privacy: .public))")
                                    AuthManager.shared.clearTokens()
                                } else {
                                    AuthLog.log.error("refresh-after-401 transient(network) -> keep session (\(String(describing: err), privacy: .public))")
                                }
                                return Fail(error: err).eraseToAnyPublisher()
                            }
                            .eraseToAnyPublisher()
                    }
                    return Just((data: output.data, response: output.response))
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                .eraseToAnyPublisher()
        }
        return attempt(allowRefresh: true)
    }

    /// 同時に複数の 401 が来ても refresh は1回だけ実行し、新しい access を保存して結果を共有する。
    func refreshTokenSingleFlight() -> AnyPublisher<String, Error> {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        if let existing = refreshInFlight {
            AuthLog.log.info("refresh: joining in-flight")
            return existing
        }
        guard let refresh = KeychainHelper.shared.readString(forKey: AuthManager.refreshTokenKey),
              !refresh.isEmpty else {
            AuthLog.log.error("refresh: NO refresh token in Keychain -> fail (will logout)")
            return Fail(error: AuthError.noRefreshToken).eraseToAnyPublisher()
        }
        AuthLog.log.info("refresh: calling /auth/token/refresh/ (refreshLen=\(refresh.count, privacy: .public))")
        let pub = refreshAccessToken(refreshToken: refresh)
            .handleEvents(
                receiveOutput: { newToken in
                    AuthLog.log.info("refresh: SUCCESS, new access saved (len=\(newToken.count, privacy: .public))")
                    _ = KeychainHelper.shared.saveString(newToken, forKey: AuthManager.accessTokenKey)
                },
                receiveCompletion: { [weak self] completion in
                    if case .failure(let e) = completion {
                        AuthLog.log.error("refresh: network/decode FAILED: \(String(describing: e), privacy: .public)")
                    }
                    guard let self else { return }
                    self.refreshLock.lock()
                    self.refreshInFlight = nil
                    self.refreshLock.unlock()
                }
            )
            .share()
            .eraseToAnyPublisher()
        refreshInFlight = pub
        return pub
    }
    
    // MARK: - 投稿一覧取得（位置情報付き）
    func fetchTimeline() -> AnyPublisher<[Post], Error> {
        guard let url = URL(string: "\(apiURL)/posts/global/") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        func baseRequest() -> URLRequest {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            return req
        }

        func decodePosts(_ data: Data) -> AnyPublisher<[Post], Error> {
            Just(data)
                .setFailureType(to: Error.self)
                .decode(type: [Post].self, decoder: Self.jsonDecoder)
                .eraseToAnyPublisher()
        }

        // 未ログイン時に表示を続けるための匿名取得（認証ヘッダ無し）
        func anonymous() -> AnyPublisher<[Post], Error> {
            URLSession.shared.dataTaskPublisher(for: baseRequest())
                .mapError { $0 as Error }
                .flatMap { output -> AnyPublisher<[Post], Error> in
                    if let http = output.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        let msg = Self.parseErrorMessage(from: output.data) ?? "Server error (\(http.statusCode))"
                        return Fail(error: APIServiceError(message: msg)).eraseToAnyPublisher()
                    }
                    return decodePosts(output.data)
                }
                .eraseToAnyPublisher()
        }

        // トークンが無ければ匿名で取得
        guard KeychainHelper.shared.readString(forKey: AuthManager.accessTokenKey) != nil else {
            return anonymous().receive(on: DispatchQueue.main).eraseToAnyPublisher()
        }

        // 認証付き取得。401 なら authorizedData が自動で refresh して再試行する。
        // refresh も失効して最終的に失敗した場合のみ、ゲストとして匿名取得にフォールバック。
        return authorizedData { baseRequest() }
            .tryMap { output -> Data in
                if let http = output.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let msg = Self.parseErrorMessage(from: output.data) ?? "Server error (\(http.statusCode))"
                    throw APIServiceError(message: msg)
                }
                return output.data
            }
            .flatMap { decodePosts($0) }
            .catch { _ in anonymous() }
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
        return authorizedData { request }
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
    /// - Parameter imageData: 添付写真（JPEG）。nil なら従来どおり JSON で送る。
    ///   写真がある場合だけ multipart に切り替えるので、文字だけの投稿の経路は一切変わらない。
    func createPost(content: String, location: CLLocation?, parentPostID: Int? = nil,
                    imageData: Data? = nil) -> AnyPublisher<Post, Error> {
        guard let url = URL(string: "\(apiURL)/posts/") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var fields: [String: String] = ["content": content]
        if let parent = parentPostID {
            fields["parent_post"] = String(parent)
        }
        if let location {
            let lat = Double(round(location.coordinate.latitude * 1_000_000) / 1_000_000)
            let lon = Double(round(location.coordinate.longitude * 1_000_000) / 1_000_000)
            fields["latitude"] = String(lat)
            fields["longitude"] = String(lon)
        }

        if let imageData {
            let boundary = "MapSNS-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.multipartBody(boundary: boundary, fields: fields,
                                                  fileField: "image", fileName: "photo.jpg",
                                                  mimeType: "image/jpeg", fileData: imageData)
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["content": content]
            if let parent = parentPostID { body["parent_post"] = parent }
            if let lat = fields["latitude"], let lon = fields["longitude"] {
                body["latitude"] = Double(lat); body["longitude"] = Double(lon)
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        
        return authorizedData { request }
            .tryMap { output in
                if let http = output.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let msg = Self.parseErrorMessage(from: output.data) ?? "Server error (\(http.statusCode))"
                    throw APIServiceError(message: msg)
                }
                return output.data
            }
            .decode(type: Post.self, decoder: Self.jsonDecoder)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    /// multipart/form-data の本体を組み立てる（写真つき投稿用）
    private static func multipartBody(boundary: String, fields: [String: String],
                                      fileField: String, fileName: String,
                                      mimeType: String, fileData: Data) -> Data {
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        for (key, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")
        return body
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
        return authorizedData { req }
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
        return authorizedData { req }
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
        let refresh: String
        let user: UserBrief

        enum CodingKeys: String, CodingKey {
            case token, access, refresh
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
            // 自動ログイン維持のため refresh トークンも受け取る（無ければ空）
            refresh = (try? container.decodeIfPresent(String.self, forKey: .refresh)) ?? ""
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
            .tryMap { output in
                if let http = output.response as? HTTPURLResponse {
                    print("loginWithApple status: \(http.statusCode)")
                    if let bodyStr = String(data: output.data, encoding: .utf8) {
                        print("loginWithApple response: \(bodyStr.prefix(500))")
                    }
                    if !(200...299).contains(http.statusCode) {
                        let msg = Self.parseErrorMessage(from: output.data) ?? "Apple login failed (\(http.statusCode))"
                        throw APIServiceError(message: msg)
                    }
                }
                return output.data
            }
            .decode(type: AppleAuthResponse.self, decoder: Self.jsonDecoder)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    // Refresh access token
    // 失敗を「サーバ拒否(401/403)＝ログアウト相当」と「通信失敗/5xx＝transient(維持)」に分類する。
    func refreshAccessToken(refreshToken: String) -> AnyPublisher<String, Error> {
        guard let url = URL(string: "\(apiURL)/auth/token/refresh/") else {
            return Fail(error: AuthError.transient).eraseToAnyPublisher()
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh": refreshToken])
        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { output -> String in
                if let http = output.response as? HTTPURLResponse {
                    if http.statusCode == 401 || http.statusCode == 403 {
                        throw AuthError.refreshRejected      // refresh トークンが本当に失効
                    }
                    if !(200...299).contains(http.statusCode) {
                        throw AuthError.transient             // 5xx 等 → 維持
                    }
                }
                guard
                    let dict = try? Self.jsonDecoder.decode([String: String].self, from: output.data),
                    let token = dict["access"]
                else {
                    throw AuthError.transient                 // 想定外ボディ → 維持
                }
                return token
            }
            .mapError { err -> Error in
                (err is AuthError) ? err : AuthError.transient   // URLSession の通信エラー → 維持
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
        return authorizedData { req }
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
        return authorizedData { req }
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
        return authorizedData { req }
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