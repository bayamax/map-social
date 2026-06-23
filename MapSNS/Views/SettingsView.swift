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
        .navigationTitle("設定")
        .alert("本当にアカウントを削除しますか？", isPresented: $isShowingDeleteAlert) {
            Button("キャンセル", role: .cancel) {}
            Button("削除", role: .destructive) {
                deleteAccount()
            }
        } message: {
            Text("この操作は取り消せません")
        }
    }

    @State private var isShowingDeleteAlert = false

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