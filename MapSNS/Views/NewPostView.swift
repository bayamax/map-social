import SwiftUI
import CoreLocation

struct NewPostView: View {
    @EnvironmentObject var locationManager: LocationManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: TimelineViewModel
    
    @State private var content: String = ""
    @AppStorage("defaultIncludeLocation") private var defaultIncludeLocation = true
    @State private var includeLocation: Bool
    @State private var isPosting = false

    // ゲスト投稿: 書き終えて「投稿」を押した時点で初めて登録を促す。
    // 入力内容は content に残したままなので、登録後そのまま投稿できる。
    @ObservedObject private var auth = AuthManager.shared
    @State private var isShowingAuth = false

    /// 地図上で選択した投稿地点。指定された場合は常にこの座標を添付する。
    let presetCoordinate: CLLocationCoordinate2D?

    init(viewModel: TimelineViewModel, presetCoordinate: CLLocationCoordinate2D? = nil) {
        self.viewModel = viewModel
        self.presetCoordinate = presetCoordinate
        // 地図SNSなので既定は「位置つき」。位置が無い投稿は地図に出ないため、
        // 既定 false だと「投稿したのに何も起きない」体験になってしまう。
        _includeLocation = State(initialValue: UserDefaults.standard.object(forKey: "defaultIncludeLocation") as? Bool ?? true)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextEditor(text: $content)
                    .frame(minHeight: 150)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                
                if let coord = presetCoordinate {
                    // 地図でドラッグして選んだ地点に投稿
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundColor(.red)
                        Text("選択した地点に投稿します")
                    }
                    .font(.subheadline)
                    Text(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Toggle(isOn: $includeLocation) {
                        Text("現在地を添付する")
                    }
                    .onChange(of: includeLocation) { newValue in
                        if newValue {
                            locationManager.requestPermission()
                        }
                        // 保存: ユーザーの選択を次回デフォルトにする
                        defaultIncludeLocation = newValue
                    }

                    if includeLocation, let loc = locationManager.lastLocation {
                        Text("位置情報取得済み: \(String(format: "%.4f", loc.coordinate.latitude)), \(String(format: "%.4f", loc.coordinate.longitude))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if includeLocation {
                        Text("位置情報取得中…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("新規投稿")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("投稿") {
                        handlePostButton()
                    }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPosting || (presetCoordinate == nil && includeLocation && locationManager.lastLocation == nil))
                }
            }
        }
        // 場所の選択は非破壊にする。以前は「いいえ」で書いた内容ごと破棄していた。
        .alert("この投稿をどこに置きますか？", isPresented: $isShowingLocationPrompt) {
            Button("現在地に置く") {
                includeLocation = true
                defaultIncludeLocation = true
                locationManager.requestPermission()
                submitPost()
            }
            Button("場所を付けずに投稿") {
                // 位置なし投稿はそのまま送るが、地図には出ないことを message で伝えてある
                submitPost()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("場所を付けない投稿は、地図の吹き出しには表示されません。")
        }
        .onAppear {
            if includeLocation {
                locationManager.requestPermission()
            }
        }
        .sheet(isPresented: $isShowingAuth) {
            AuthPromptView(message: "登録すると、いま書いた内容がこの場所に置かれます。")
        }
        .onChange(of: auth.isLoggedIn) { loggedIn in
            // 登録/ログイン成功 → 中断していた投稿をそのまま続行する
            if loggedIn && isShowingAuth {
                isShowingAuth = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    submitPost()
                }
            }
        }
    }
    
    private func submitPost() {
        // ゲストはここで登録へ。content は保持されるので、登録成功後に自動で続行する。
        guard auth.isLoggedIn else {
            isShowingAuth = true
            return
        }
        isPosting = true
        let location: CLLocation?
        if let coord = presetCoordinate {
            location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        } else {
            location = includeLocation ? locationManager.lastLocation : nil
        }
        viewModel.createPost(content: content, location: location)
        // 投稿完了後に閉じる
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            isPosting = false
            dismiss()
        }
    }

    // MARK: - 新しいロジック
    @State private var isShowingLocationPrompt = false

    private func handlePostButton() {
        if presetCoordinate == nil && !includeLocation && !defaultIncludeLocation {
            // 位置情報がオフなので確認プロンプト
            isShowingLocationPrompt = true
        } else {
            // 地点が選択済み、または現在地添付がオンなのでそのまま投稿
            submitPost()
        }
    }
}
#Preview {
    NewPostView(viewModel: TimelineViewModel())
        .environmentObject(LocationManager())
} 