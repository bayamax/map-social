import SwiftUI
import CoreLocation

struct NewPostView: View {
    @EnvironmentObject var locationManager: LocationManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: TimelineViewModel
    
    @State private var content: String = ""
    @AppStorage("defaultIncludeLocation") private var defaultIncludeLocation = false
    @State private var includeLocation: Bool
    @State private var isPosting = false

    /// 地図上で選択した投稿地点。指定された場合は常にこの座標を添付する。
    let presetCoordinate: CLLocationCoordinate2D?

    init(viewModel: TimelineViewModel, presetCoordinate: CLLocationCoordinate2D? = nil) {
        self.viewModel = viewModel
        self.presetCoordinate = presetCoordinate
        _includeLocation = State(initialValue: UserDefaults.standard.object(forKey: "defaultIncludeLocation") as? Bool ?? false)
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
        .alert("位置情報をデフォルトでオンにして投稿しますか？", isPresented: $isShowingLocationPrompt) {
            Button("いいえ", role: .cancel) {
                // 何もしない -> 投稿せず戻る
                dismiss()
            }
            Button("はい") {
                // デフォルトをオンにして投稿
                includeLocation = true
                defaultIncludeLocation = true
                locationManager.requestPermission()
                submitPost()
            }
        }
        .onAppear {
            if includeLocation {
                locationManager.requestPermission()
            }
        }
    }
    
    private func submitPost() {
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