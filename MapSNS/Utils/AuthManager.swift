import Foundation
import Combine
import UIKit
import os

/// 認証フローの診断ログ（Console.app / コンソールで subsystem=…, category="auth" で絞り込み）。
/// トークンの中身は出さない（有無・長さ・ステータスのみ）。
enum AuthLog {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MapSNS", category: "auth")
}

final class AuthManager: ObservableObject {
    static let shared = AuthManager()
    private init() {
        // Keychain にトークンが残っていればログイン済みとみなす
        let hasAccess = KeychainHelper.shared.readString(forKey: Self.accessTokenKey) != nil
        let hasRefresh = KeychainHelper.shared.readString(forKey: Self.refreshTokenKey) != nil
        self.isLoggedIn = hasAccess
        AuthLog.log.info("init: hasAccess=\(hasAccess, privacy: .public) hasRefresh=\(hasRefresh, privacy: .public)")
        // 起動時に refresh トークンでアクセストークンを更新し、自動ログインを維持
        restoreSession()
        // フォアグラウンド復帰時にも先回りで更新（30分以上バックグラウンドにいて
        // access が切れていても、ログイン画面に飛ばされないようにする）
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.restoreSession()
        }
    }

    /// リフレッシュトークンでアクセストークンを更新し、自動ログインを維持する。
    /// 起動時・フォアグラウンド復帰時に呼ぶ。refresh も失効していた場合のみログアウト。
    func restoreSession() {
        guard let refresh = KeychainHelper.shared.readString(forKey: Self.refreshTokenKey),
              !refresh.isEmpty else {
            AuthLog.log.info("restoreSession: NO refresh token -> skip")
            return
        }
        AuthLog.log.info("restoreSession: refreshing...")
        // 401 リトライと共通のシングルフライト更新を使う（新しい access は内部で保存される）
        APIService.shared.refreshTokenSingleFlight()
            .sink(receiveCompletion: { [weak self] result in
                if case .failure(let e) = result {
                    // サーバ拒否/トークン無しのときだけログアウト。通信失敗ではセッション維持して後で再試行。
                    if (e as? AuthError)?.isLogoutWorthy ?? false {
                        AuthLog.log.error("restoreSession: refresh REJECTED -> clearTokens (\(String(describing: e), privacy: .public))")
                        self?.clearTokens()
                    } else {
                        AuthLog.log.info("restoreSession: refresh transient(network) -> keep session (\(String(describing: e), privacy: .public))")
                    }
                }
            }, receiveValue: { [weak self] _ in
                AuthLog.log.info("restoreSession: refresh OK")
                self?.isLoggedIn = true
                self?.refreshBlockedList()
            })
            .store(in: &cancellables)
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
#if DEBUG
    /// 検証用：擬似失効テストの結果をUIに出すためのメッセージ
    @Published var debugMessage: String?
#endif

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
        let hadRefresh = KeychainHelper.shared.readString(forKey: Self.refreshTokenKey) != nil
        AuthLog.log.error("clearTokens CALLED (-> login screen). hadRefresh=\(hadRefresh, privacy: .public)")
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
                AuthLog.log.info("appleLogin OK: accessLen=\(auth.token.count, privacy: .public) refreshSaved=\(!auth.refresh.isEmpty, privacy: .public) refreshLen=\(auth.refresh.count, privacy: .public)")
                _ = KeychainHelper.shared.saveString(auth.token, forKey: Self.accessTokenKey)
                // 自動ログイン維持のため refresh トークンも保存
                if !auth.refresh.isEmpty {
                    _ = KeychainHelper.shared.saveString(auth.refresh, forKey: Self.refreshTokenKey)
                }
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

#if DEBUG
    /// 検証用：アクセストークンだけ壊して（refreshトークンは残す）、認証付きリクエストを1発投げる。
    /// → サーバが401 → 本物の「401→refresh→再試行」経路が発火。結果を debugMessage でUIに出す。
    func debugForceTokenExpiry() {
        guard isLoggedIn else {
            debugMessage = "先に Apple サインインしてから押してください（今ログインしていません）"
            return
        }
        let hadRefresh = KeychainHelper.shared.readString(forKey: Self.refreshTokenKey) != nil
        AuthLog.log.info("DEBUG: forcing access-token expiry. hadRefresh=\(hadRefresh, privacy: .public)")
        _ = KeychainHelper.shared.saveString("expired.invalid.access.token", forKey: Self.accessTokenKey)

        if !hadRefresh {
            // refreshトークンが無い＝この時点で原因確定（保存されていない）
            debugMessage = "❌ 原因確定：refreshトークンが端末に無い（hadRefresh=false）。\nApple ログイン時に保存できていない／古いセッション引き継ぎ。"
        }

        // 認証付き呼び出しで 401 を誘発し、結果を観測
        APIService.shared.fetchBlockedUsers()
            .sink(receiveCompletion: { [weak self] completion in
                guard let self else { return }
                switch completion {
                case .finished:
                    self.debugMessage = "✅ 成功：401→refresh→再試行が機能し、ログイン維持できた。\n（30分問題は解消されているはず）"
                case .failure:
                    if self.isLoggedIn == false {
                        self.debugMessage = "❌ ログアウトされた：refreshが失敗。hadRefresh=\(hadRefresh)\n→ \(hadRefresh ? "refreshトークンはあるがサーバに拒否された" : "refreshトークンが端末に無い")"
                    } else {
                        self.debugMessage = "⚠️ リクエスト失敗だがログインは維持。hadRefresh=\(hadRefresh)"
                    }
                }
            }, receiveValue: { _ in })
            .store(in: &cancellables)
    }
#endif
} 