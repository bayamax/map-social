import SwiftUI
import AuthenticationServices

struct LoginView: View {
    /// アプリ名の見出しを出すか。AuthPromptView の中では見出しが重複するので false にする。
    var showsTitle: Bool = true

    @State private var showRegistration: Bool = false
    @State private var showPasswordLogin: Bool = false
    @State private var isLoggingIn: Bool = false
    @State private var errorMessage: String?

    /// 直近のログイン方式が Apple なら、Apple を主役にした画面にする
    private var preferApple: Bool {
        UserDefaults.standard.string(forKey: AuthManager.loginMethodKey) == "apple"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if showsTitle {
                    // ストア表記と揃える（ホーム画面のアイコン名も "Map Social"）
                    Text("Map Social")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .padding(.bottom, 30)
                }

                // Sign in with Apple（常に表示）
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    handleApple(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 48)
                .cornerRadius(8)
                .disabled(isLoggingIn)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                // Apple をまだ使っていない場合は、従来のID/パスワード欄をそのまま表示
                if !preferApple {
                    PasswordLoginForm()
                }

                Divider().padding(.vertical, 8)

                Button("アカウントをお持ちでない方はこちら") {
                    showRegistration = true
                }
                .foregroundColor(.blue)

                // Apple 利用者には「ユーザー名でログイン」をリンクとして提供
                if preferApple {
                    Button("ユーザー名でログイン") {
                        showPasswordLogin = true
                    }
                    .foregroundColor(.blue)
                }
            }
            .padding()
            .navigationBarHidden(true)
            .sheet(isPresented: $showRegistration) {
                RegisterView()
            }
            // 「ユーザー名でログイン」→ 従来のログイン画面へ遷移
            .navigationDestination(isPresented: $showPasswordLogin) {
                ScrollView {
                    PasswordLoginForm()
                        .padding()
                }
                .navigationTitle("ログイン")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    // MARK: - Apple Sign-In
    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Apple 認証情報の取得に失敗しました"
                return
            }
            isLoggingIn = true
            errorMessage = nil
            AuthManager.shared.loginWithApple(idToken: idToken) { res in
                DispatchQueue.main.async {
                    isLoggingIn = false
                    // 成功時は AuthManager の状態変化で ContentView が自動遷移する
                    if case .failure(let error) = res {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        case .failure(let error):
            // ユーザーがキャンセルした場合はエラー表示しない
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return
            }
            errorMessage = error.localizedDescription
        }
    }
}

/// ユーザー名／パスワードのログインフォーム（インライン表示にも遷移先にも使う）
struct PasswordLoginForm: View {
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isLoggingIn: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            TextField("ユーザー名", text: $username)
                .autocapitalization(.none)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(8)

            SecureField("パスワード", text: $password)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(8)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Button(action: login) {
                if isLoggingIn {
                    ProgressView()
                } else {
                    Text("ログイン")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(8)
            .disabled(username.isEmpty || password.isEmpty || isLoggingIn)
        }
        .onAppear {
            // キーチェーンから記憶済み資格情報を取得
            if let savedUsername = KeychainHelper.shared.readString(forKey: AuthManager.keychainUsernameKey) {
                username = savedUsername
            }
            if let savedPassword = KeychainHelper.shared.readString(forKey: AuthManager.keychainPasswordKey) {
                password = savedPassword
            }
        }
    }

    private func login() {
        isLoggingIn = true
        errorMessage = nil
        AuthManager.shared.login(username: username, password: password) { result in
            DispatchQueue.main.async {
                isLoggingIn = false
                // 成功時は AuthManager の状態変化で ContentView が自動遷移する
                if case .failure(let error) = result {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    LoginView()
}
