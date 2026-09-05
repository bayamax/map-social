import SwiftUI
import Combine

struct SettingsView: View {
    @EnvironmentObject var locationManager: LocationManager
    @AppStorage("defaultIncludeLocation") private var defaultIncludeLocation = true

    var body: some View {
        Form {
            Section(header: Text("表示設定")) {
                // ブロック一覧機能を一時的に非表示にする
                // NavigationLink("ブロック中のユーザー") {
                //     BlockedUsersView()
                // }
            }
            Section(header: Text("位置情報")) {
                HStack {
                    Text("位置情報の利用")
                    Spacer()
                    Text(statusText)
                        .foregroundColor(.secondary)
                }
                Toggle(isOn: $defaultIncludeLocation) {
                    Text("投稿時に位置情報を添付(デフォルト)")
                }
            }
            Section {
                Link("利用規約", destination: URL(string: "https://sites.google.com/view/mapsns/%E3%83%9B%E3%83%BC%E3%83%A0")!)
                Link("プライバシーポリシー", destination: URL(string: "https://sites.google.com/view/map-social-privacy/%E3%83%9B%E3%83%BC%E3%83%A0")!)
                Link("サポート", destination: URL(string: "https://sites.google.com/view/mapsosial/%E3%83%9B%E3%83%BC%E3%83%A0")!)
                // ゲスト中はアカウント系の項目に意味がないので出さない。
                // 代わりに、ここからでも登録できる導線を置く。
                if auth.isLoggedIn {
                    Button("ログアウト", role: .destructive) {
                        AuthManager.shared.logout()
                    }
                    Button("ログイン情報を削除", role: .destructive) {
                        AuthManager.shared.logoutAndForgetCredentials()
                    }
                    Button("アカウント削除", role: .destructive) {
                        isShowingDeleteAlert = true
                    }
                }
            }
            if !auth.isLoggedIn {
                Section(footer: Text("いまはゲストとして閲覧中です。登録すると、地図に書き込めるようになります。")) {
                    Button("ログイン / 新規登録") {
                        isShowingAuth = true
                    }
                }
            }
#if DEBUG
            Section(header: Text("デバッグ（検証用）"),
                    footer: Text("アクセストークンを壊して 401→refresh 経路を即発火させます。Consoleで category=auth を確認。")) {
                Button("🔧 トークンを失効させて検証") {
                    AuthManager.shared.debugForceTokenExpiry()
                }
            }
#endif
        }
        .navigationTitle("設定")
        .sheet(isPresented: $isShowingAuth) {
            AuthPromptView(message: "登録すると、地図に自分の書き込みを置けるようになります。")
        }
        .alert("本当にアカウントを削除しますか？", isPresented: $isShowingDeleteAlert) {
            Button("キャンセル", role: .cancel) {}
            Button("削除", role: .destructive) {
                deleteAccount()
            }
        } message: {
            Text("この操作は取り消せません")
        }
#if DEBUG
        .alert("ログイン検証結果", isPresented: Binding(
            get: { auth.debugMessage != nil },
            set: { if !$0 { auth.debugMessage = nil } }
        )) {
            Button("OK") { auth.debugMessage = nil }
        } message: {
            Text(auth.debugMessage ?? "")
        }
#endif
    }

    @ObservedObject private var auth = AuthManager.shared

    @State private var isShowingDeleteAlert = false
    @State private var isShowingAuth = false

    private func deleteAccount() {
        APIService.shared.deleteAccount()
            .sink(receiveCompletion: { comp in
                if case .failure(let err) = comp {
                    print("Delete account failed: \(err.localizedDescription)")
                }
            }, receiveValue: {
                AuthManager.shared.logout()
            })
            .store(in: &Self.cancellables)
    }
    
    private static var cancellables = Set<AnyCancellable>()
    
    private var statusText: String {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return "許可済み"
        case .denied, .restricted:
            return "拒否"
        case .notDetermined:
            return "未確認"
        @unknown default:
            return "不明"
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(LocationManager())
} 