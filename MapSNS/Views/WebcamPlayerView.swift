import SwiftUI
import WebKit
import Combine

/// ライブカメラ再生シート。YouTube IFrame Player API で再生し、
/// 保存IDのライブが終了/削除されていたら同チャンネルの現行ライブ
/// （embed/live_stream?channel=...）へ自動フォールバックする。
///
/// 中身は「ライブ映像＋コメント」だけ。巡回ボタンや次の街のチップは
/// 案内が多くてうるさかったので外した（地図上のピンから直接開く導線に統一）。
struct WebcamPlayerView: View {
    let webcam: Webcam
    /// 再生中のカメラ（以前は巡回で入れ替わっていた名残。今は開いたカメラ固定）
    private var current: Webcam { webcam }

    @Environment(\.dismiss) private var dismiss
    /// このアプリで同じカメラをいま見ている人数（自分を含む・リアルタイム）
    @State private var appWatchers: Int?
    /// このカメラのコメント（アンカー投稿への返信）
    @State private var comments: [Post] = []
    @State private var commentText = ""
    @State private var isSending = false

    // ゲスト: コメント送信の直前にだけ登録を促す
    @ObservedObject private var auth = AuthManager.shared
    @State private var isShowingAuth = false
    // 15秒ごとの再取得で購読が積み上がらないよう、用途ごとに1本だけ保持
    @State private var loadCancellable: AnyCancellable?
    @State private var sendCancellable: AnyCancellable?

    private var watchersLine: String? {
        guard let n = appWatchers, n >= 1 else { return nil }
        return String(localized: "いま\(n)人が見ています")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label(current.displayName, systemImage: "video.fill")
                        .font(.headline)
                        .lineLimit(1)
                    if let line = watchersLine {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color(red: 0.90, green: 0.15, blue: 0.20))
                                .frame(width: 6, height: 6)
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            // 在席ハートビート＆人数・コメント更新（15秒ごと。シートを閉じると自動停止→60秒で退室扱い）
            .task(id: current.id) {
                loadComments()
                while !Task.isCancelled {
                    if let n = await WebcamService.heartbeatAppWatchers(camID: current.id), !Task.isCancelled {
                        appWatchers = n
                    }
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    if !Task.isCancelled { loadComments() }
                }
            }

            YouTubeLiveView(videoID: current.video, channelID: current.channel)
                .id(current.id)   // カメラが変わったら WebView を作り直す
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Color.black)

            HStack {
                if let watch = current.watchURL {
                    Link(destination: watch) {
                        Label("YouTubeで開く", systemImage: "arrow.up.right.square")
                            .font(.subheadline)
                    }
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // コメント（このカメラのアンカー投稿への返信スレッド）
            if current.post != nil {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if comments.isEmpty {
                                Text("コメントはまだありません")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.top, 12)
                            }
                            ForEach(comments) { c in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(c.user.username)
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                    LinkedText(c.content)
                                        .font(.callout)
                                    Spacer(minLength: 0)
                                }
                                .id(c.id)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    // チャットとして自然なように、新着が来たら一番下(最新)へ
                    .onChange(of: comments.last?.id) { _, newLast in
                        if let id = newLast {
                            withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("コメントを書く…", text: $commentText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { sendComment() }
                    Button { sendComment() } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.title3)
                    }
                    .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            } else {
                Spacer(minLength: 0)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $isShowingAuth) {
            AuthPromptView(message: "登録すると、いま書いたコメントがこのライブに送信されます。")
        }
        .onChange(of: auth.isLoggedIn) { _, loggedIn in
            if loggedIn && isShowingAuth {
                isShowingAuth = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    sendComment()
                }
            }
        }
    }

    /// コメント一覧（アンカーへの返信）を取得。古い順=チャットの流れで下が最新。
    private func loadComments() {
        guard let pid = current.post else { return }
        loadCancellable = APIService.shared.fetchReplies(parentID: pid)
            .sink(receiveCompletion: { _ in }, receiveValue: { posts in
                comments = posts.sorted { $0.createdAt < $1.createdAt }
            })
    }

    private func sendComment() {
        guard let pid = current.post else { return }
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        // ゲストはここで登録へ。commentText は保持されるので、登録成功後に自動で続行する。
        guard auth.isLoggedIn else {
            isShowingAuth = true
            return
        }
        isSending = true
        sendCancellable = APIService.shared.createPost(content: text, location: nil, parentPostID: pid)
            .sink(receiveCompletion: { _ in isSending = false },
                  receiveValue: { _ in
                      commentText = ""
                      loadComments()
                  })
    }
}

/// バックエンドが配信するプレーヤーページ（IFrame Player API + チャンネル現行ライブへの
/// 自動フォールバック）を WKWebView で開く。実URLで開くことで埋め込み元 origin/referer が
/// 実在ドメインになり、YouTube の埋め込み拒否（エラー150/152系）を踏まない。
private struct YouTubeLiveView: UIViewRepresentable {
    let videoID: String
    let channelID: String?

    private static var apiBase: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String) ?? ""
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.scrollView.isScrollEnabled = false
        web.isOpaque = false
        web.backgroundColor = .black
        var comps = URLComponents(string: "\(Self.apiBase)/api/webcams/player/")
        comps?.queryItems = [URLQueryItem(name: "v", value: videoID)]
        if let ch = channelID {
            comps?.queryItems?.append(URLQueryItem(name: "ch", value: ch))
        }
        if let url = comps?.url {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
}
