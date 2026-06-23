import SwiftUI

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    // 入力状態
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isLoggingIn: Bool = false
    @State private var errorMessage: String?
    @State private var showRegistration: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("MapSNS")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding(.bottom, 30)

                TextField("ユーザー名", text: $username)
                    .autocapitalization(.none)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)

                SecureField("パスワード", text: $password)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)

                // エラー
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

                Divider().padding(.vertical, 8)

                Button("アカウントをお持ちでない方はこちら") {
                    showRegistration = true
                }
                .foregroundColor(.blue)
                .padding(.top, 10)
            }
            .padding()
            .navigationBarHidden(true)
            .sheet(isPresented: $showRegistration) {
                RegisterView()
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
    }

    private func login() {
        isLoggingIn = true
        errorMessage = nil
        AuthManager.shared.login(username: username, password: password) { result in
            DispatchQueue.main.async {
                isLoggingIn = false
                switch result {
                case .success:
                    // 成功時は AuthManager が通知を出すので UI 遷移は ContentView に任せる
                    break
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    // AppleID ログインは未実装のため削除
}

#Preview {
    LoginView()
} 