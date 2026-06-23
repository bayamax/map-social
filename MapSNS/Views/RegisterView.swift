import SwiftUI

struct RegisterView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isRegistering = false
    @State private var errorMessage: String?
    @State private var termsAccepted = false

    // ボタン活性条件
    private var isRegisterButtonDisabled: Bool {
        username.isEmpty || password.isEmpty || password != confirmPassword || !termsAccepted || isRegistering
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("新規アカウント登録")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .padding(.bottom, 20)

                    TextField("ユーザー名", text: $username)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)

                    TextField("メールアドレス (任意)", text: $email)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                        .keyboardType(.emailAddress)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)

                    SecureField("パスワード", text: $password)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(8)

                    SecureField("パスワード (確認)", text: $confirmPassword)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(8)

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(alignment: .top) {
                        Image(systemName: termsAccepted ? "checkmark.square.fill" : "square")
                            .foregroundColor(termsAccepted ? .blue : .gray)
                            .font(.title3)
                            .onTapGesture { termsAccepted.toggle() }

                        Text("[利用規約](https://sites.google.com/view/mapsns/%E3%83%9B%E3%83%BC%E3%83%A0)および[プライバシーポリシー](https://sites.google.com/view/map-social-privacy/%E3%83%9B%E3%83%BC%E3%83%A0)に同意します。")
                            .font(.footnote)
                            .environment(\.openURL, OpenURLAction { url in
                                .systemAction
                            })
                    }
                    .padding(.bottom, 10)

                    Button(action: register) {
                        if isRegistering {
                            ProgressView()
                        } else {
                            Text("登録")
                                .fontWeight(.semibold)
                                .foregroundColor(isRegisterButtonDisabled ? .gray : .white)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding()
                    .background(isRegisterButtonDisabled ? Color.gray.opacity(0.5) : Color.green)
                    .cornerRadius(8)
                    .disabled(isRegisterButtonDisabled)
                }
                .padding()
            }
            .navigationBarItems(trailing: Button("閉じる") { dismiss() })
        }
    }

    private func register() {
        guard password == confirmPassword else {
            errorMessage = "パスワードが一致しません"
            return
        }

        isRegistering = true
        errorMessage = nil

        AuthManager.shared.register(username: username, email: email, password: password) { result in
            DispatchQueue.main.async {
                isRegistering = false
                switch result {
                case .success:
                    dismiss()
                case .failure(let error):
                    let fullErrorMessage = error.localizedDescription
                    let firstError = fullErrorMessage.components(separatedBy: ", ").first ?? fullErrorMessage
                    errorMessage = firstError
                }
            }
        }
    }
}

#Preview {
    RegisterView()
} 