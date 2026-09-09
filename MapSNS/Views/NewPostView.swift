import SwiftUI
import CoreLocation
import PhotosUI
import UIKit

struct NewPostView: View {
    @EnvironmentObject var locationManager: LocationManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: TimelineViewModel
    
    @State private var content: String = ""
    @AppStorage("defaultIncludeLocation") private var defaultIncludeLocation = true
    @State private var includeLocation: Bool
    @State private var isPosting = false

    // 写真投稿
    @State private var attachment: PhotoAttachment?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isShowingCamera = false
    /// ライブラリ写真に撮影地点がある場合、そこに貼るか（既定 ON）
    @State private var useCapturedCoordinate = true
    @State private var photoError: String?

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
                
                photoSection

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
                } else if usingCapturedCoordinate {
                    // 写真の撮影地点に貼るので、現在地の話は出さない（二重に場所を聞かない）
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.circle.fill").foregroundColor(.red)
                        Text("写真を撮った場所に投稿します")
                    }
                    .font(.subheadline)
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
                    .disabled(isPostButtonDisabled)
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
            #if DEBUG
            // 撮影用: SCREENSHOT_ATTACH_PHOTO=<画像パス> で写真を添付した状態にする
            let env = ProcessInfo.processInfo.environment
            if attachment == nil, let path = env["SCREENSHOT_ATTACH_PHOTO"],
               let image = UIImage(contentsOfFile: path) {
                var a = PhotoAttachment(image: image, fromCamera: env["SCREENSHOT_ATTACH_CAMERA"] != "0")
                if a?.fromCamera == false, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    let meta = ImageMetadata.read(from: data)
                    a?.capturedAt = meta.date
                    a?.capturedCoordinate = meta.coordinate
                }
                attachment = a
                if let text = env["SCREENSHOT_ATTACH_TEXT"], content.isEmpty { content = text }
            }
            #endif
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker { image in
                if let a = PhotoAttachment(image: image, fromCamera: true) {
                    attachment = a
                } else {
                    photoError = "写真を読み込めませんでした"
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            Task { await loadLibraryPhoto(item) }
        }
        .alert("写真", isPresented: Binding(get: { photoError != nil }, set: { if !$0 { photoError = nil } })) {
            Button("OK", role: .cancel) { photoError = nil }
        } message: {
            Text(photoError ?? "")
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
        } else if let shot = attachment?.capturedCoordinate, useCapturedCoordinate {
            // ライブラリ写真は「撮った場所」に貼るのが自然（本人が外せる）
            location = CLLocation(latitude: shot.latitude, longitude: shot.longitude)
        } else {
            location = includeLocation ? locationManager.lastLocation : nil
        }
        viewModel.createPost(content: content, location: location, imageData: attachment?.jpeg)
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

    // MARK: - 写真

    /// 写真の撮影地点をそのまま投稿地点に使う状態か
    private var usingCapturedCoordinate: Bool {
        attachment?.capturedCoordinate != nil && useCapturedCoordinate
    }

    private var isPostButtonDisabled: Bool {
        let hasText = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 写真だけの投稿も許す（地図に写真が貼られるのが主役なので）
        if !hasText && attachment == nil { return true }
        if isPosting { return true }
        // 撮影地点を使う場合は現在地を待つ必要がない
        if usingCapturedCoordinate { return false }
        return presetCoordinate == nil && includeLocation && locationManager.lastLocation == nil
    }

    @ViewBuilder
    private var photoSection: some View {
        if let attachment {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: attachment.preview)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 160)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Button {
                        self.attachment = nil
                        pickerItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, .black.opacity(0.5))
                    }
                    .padding(8)
                }
                if attachment.fromCamera {
                    Label("いま撮影した写真", systemImage: "camera.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    if let date = attachment.capturedAt {
                        Label(date.formatted(date: .abbreviated, time: .shortened) + " の写真",
                              systemImage: "photo.on.rectangle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if attachment.capturedCoordinate != nil {
                        Toggle("撮影した場所に貼る", isOn: $useCapturedCoordinate)
                            .font(.caption)
                    }
                }
            }
        } else {
            HStack(spacing: 12) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        isShowingCamera = true
                    } label: {
                        Label("撮影", systemImage: "camera.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Label("ライブラリ", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
    }

    private func loadLibraryPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              var a = PhotoAttachment(image: image, fromCamera: false) else {
            await MainActor.run { photoError = "写真を読み込めませんでした" }
            return
        }
        // EXIF は「いつ・どこで撮ったか」を拾うためだけに読む（送信データには載せない）
        let meta = ImageMetadata.read(from: data)
        a.capturedAt = meta.date
        a.capturedCoordinate = meta.coordinate
        await MainActor.run { attachment = a }
    }
}

#Preview {
    NewPostView(viewModel: TimelineViewModel())
        .environmentObject(LocationManager())
} 