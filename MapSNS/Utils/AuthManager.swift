import Foundation
import Combine

final class AuthManager: ObservableObject {
    static let shared = AuthManager()
    private init() {
        // Keychain にトークンが残っていればログイン済みとみなす
        self.isLoggedIn = KeychainHelper.shared.readString(forKey: Self.accessTokenKey) != nil
    }

    // Keychain keys
    static let accessTokenKey = "accessToken"
    static let refreshTokenKey = "refreshToken"
    static let currentUserKey = "currentUser"
    // 保存する資格情報（ユーザー／パスワード）およびログイン方式
    static let keychainUsernameKey = "savedUsername"
    static let keychainPasswordKey = "savedPassword"
    static let loginMethodKey = "loginMethod"

    // 現在のユーザーとログイン状態をアプリ全体に通知
    @Published private(set) var currentUser: UserBrief?
    @Published private(set) var isLoggedIn: Bool
    @Published var blockedUserIDs: Set<Int> = []

    var accessToken: String? {
        KeychainHelper.shared.readString(forKey: Self.accessTokenKey)
    }

    // 初期化時に Keychain を確認してログイン状態を設定
    // ※ ここで改めて public init を宣言する必要はない

    // MARK: - Login / Register
    func login(username: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        APIService.shared.login(username: username, password: password)
            .sink(receiveCompletion: { result in
                if case let .failure(err) = result { completion(.failure(err)) }
            }, receiveValue: { [weak self] auth in
                // ブロックリスト取得
                self?.refreshBlockedList()
                _ = KeychainHelper.shared.saveString(auth.access, forKey: Self.accessTokenKey)
                _ = KeychainHelper.shared.saveString(auth.refresh, forKey: Self.refreshTokenKey)
                // 資格情報を記憶（任意）
                _ = KeychainHelper.shared.saveString(username, forKey: Self.keychainUsernameKey)
                _ = KeychainHelper.shared.saveString(password, forKey: Self.keychainPasswordKey)
                // ログイン方式を保存
                UserDefaults.standard.set("password", forKey: Self.loginMethodKey)

                self?.currentUser = auth.user
                self?.isLoggedIn = true
                completion(.success(()))
            })
            .store(in: &cancellables)
    }

    func register(username: String, email: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        APIService.shared.register(username: username, email: email, password: password)
            .sink(receiveCompletion: { result in
                if case let .failure(err) = result { completion(.failure(err)) }
            }, receiveValue: { [weak self] _ in
                // auto login
                self?.login(username: username, password: password, completion: completion)
            })
            .store(in: &cancellables)
    }

    /// トークンのみ削除し、ユーザー名・パスワードは保持する（自動入力用）
    func logout() {
        clearTokens()
    }

    /// トークンと保存資格情報をすべて削除したい場合に呼ぶ
    func logoutAndForgetCredentials() {
        clearTokens()
        KeychainHelper.shared.delete(forKey: Self.keychainUsernameKey)
        KeychainHelper.shared.delete(forKey: Self.keychainPasswordKey)
    }

    /// アクセス・リフレッシュトークンのみを削除し、資格情報は保持する
    func clearTokens() {
        KeychainHelper.shared.delete(forKey: Self.accessTokenKey)
        KeychainHelper.shared.delete(forKey: Self.refreshTokenKey)
        currentUser = nil
        isLoggedIn = false
        // ログアウト時にブロックリストも初期化
        blockedUserIDs.removeAll()
    }

    // MARK: - Apple Login
    func loginWithApple(idToken: String, completion: @escaping (Result<Void, Error>) -> Void) {
        APIService.shared.loginWithApple(idToken: idToken)
            .sink(receiveCompletion: { result in
                if case let .failure(err) = result { completion(.failure(err)) }
            }, receiveValue: { [weak self] auth in
                _ = KeychainHelper.shared.saveString(auth.token, forKey: Self.accessTokenKey)
                UserDefaults.standard.set("apple", forKey: Self.loginMethodKey)

                self?.currentUser = auth.user
                self?.isLoggedIn = true
                // Apple ログインでもブロックリストを更新
                self?.refreshBlockedList()
                completion(.success(()))
            })
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Block Helpers
    func refreshBlockedList() {
        APIService.shared.fetchBlockedUsers()
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] ids in
                self?.blockedUserIDs = Set(ids)
            })
            .store(in: &cancellables)
    }

    func block(userID: Int) {
        APIService.shared.block(userID: userID)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] in
                self?.blockedUserIDs.insert(userID)
                NotificationCenter.default.post(name: .init("BlockStatusChanged"), object: nil)
            })
            .store(in: &cancellables)
    }

    func unblock(userID: Int) {
        APIService.shared.unblock(userID: userID)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] in
                self?.blockedUserIDs.remove(userID)
                NotificationCenter.default.post(name: .init("BlockStatusChanged"), object: nil)
            })
            .store(in: &cancellables)
    }
} 