import SwiftUI
import MapKit
import Combine // Added for Combine

// MARK: - 昼夜判定（太陽高度）
/// 緯度経度と日時から太陽高度を求め、夜かどうかを判定する（NOAA 近似式）
enum SolarCalculator {
    /// 太陽高度（度）。地平線より上なら昼。
    static func solarElevation(latitude lat: Double, longitude lon: Double, date: Date) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.hour, .minute, .second], from: date)
        let dayOfYear = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 1)
        let hourUTC = Double(comps.hour ?? 0)
            + Double(comps.minute ?? 0) / 60
            + Double(comps.second ?? 0) / 3600

        let gamma = 2 * Double.pi / 365 * (dayOfYear - 1 + (hourUTC - 12) / 24)
        // 均時差（分）
        let eqtime = 229.18 * (0.000075
            + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        // 太陽赤緯（ラジアン）
        let decl = 0.006918
            - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)

        let timeOffset = eqtime + 4 * lon            // 分（UTC 基準なのでタイムゾーン補正不要）
        let trueSolarTime = hourUTC * 60 + timeOffset // 真太陽時（分）
        let hourAngle = (trueSolarTime / 4 - 180) * Double.pi / 180
        let latRad = lat * Double.pi / 180
        let cosZenith = sin(latRad) * sin(decl) + cos(latRad) * cos(decl) * cos(hourAngle)
        let zenith = acos(max(-1, min(1, cosZenith)))
        return 90 - zenith * 180 / Double.pi
    }

    /// 夜かどうか（大気差を考慮し、太陽高度 -0.833° 未満を夜とみなす）
    static func isNight(latitude lat: Double, longitude lon: Double, date: Date) -> Bool {
        solarElevation(latitude: lat, longitude: lon, date: date) < -0.833
    }
}

// MARK: - マップスタイル切替
/// 衛星(hybrid) ⇔ マップ(standard) を切り替えるモディファイア
struct MapStyleModifier: ViewModifier {
    let isSatellite: Bool
    func body(content: Content) -> some View {
        if isSatellite {
            content.mapStyle(.hybrid(elevation: .realistic, pointsOfInterest: .all))
        } else {
            content.mapStyle(.standard(elevation: .realistic, pointsOfInterest: .all))
        }
    }
}

/// 縦2段のスタイル切替トグル（白いノブが上下にスライド）。上=衛星 / 下=マップ。
struct MapStyleToggle: View {
    @Binding var isSatellite: Bool
    private let cell: CGFloat = 40
    private let knob: CGFloat = 34

    var body: some View {
        ZStack(alignment: .top) {
            // スライドする白いノブ
            Circle()
                .fill(.white)
                .frame(width: knob, height: knob)
                .offset(y: (isSatellite ? 0 : cell) + (cell - knob) / 2)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
            // 上=衛星 / 下=マップ
            VStack(spacing: 0) {
                Image(systemName: "globe.americas.fill")
                    .frame(width: cell, height: cell)
                    .foregroundColor(isSatellite ? .black : .white)
                Image(systemName: "map.fill")
                    .frame(width: cell, height: cell)
                    .foregroundColor(isSatellite ? .white : .black)
            }
            .font(.system(size: 16, weight: .semibold))
        }
        .frame(width: cell, height: cell * 2)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSatellite)
        .onTapGesture { isSatellite.toggle() }
    }
}

/// マップ/衛星 共通のズーム距離（メートル）。衛星が近すぎないよう少し引いた値。
private let kStyleZoomDistance: Double = 1700

struct MapTimelineView: View {
    @StateObject private var viewModel = TimelineViewModel()
    @EnvironmentObject var locationManager: LocationManager
    @State private var isPresentingNewPost = false
    @State private var replyingTo: Post?
    @State private var reportingPost: Post?
    // Map のカメラ位置（3D の傾き付き）。ユーザ操作で自動的に更新される。
    @State private var cameraPosition: MapCameraPosition = .camera(
        MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: 35.681236, longitude: 139.767125),
                  distance: kStyleZoomDistance, heading: 0, pitch: 55)
    )
    // 直近のカメラ（スタイル切替時にズームだけ揃えるために保持）
    @State private var currentCamera: MapCamera?
    // 初回に現在地へジャンプしたかどうか
    @State private var hasCenteredOnUser = false
    // マップスタイル（true=衛星 hybrid がデフォルト / false=通常マップ）
    @State private var isSatellite = true
    // 現在地が夜か（通常マップを夜は自動でダーク表示）
    @State private var isNightAtUser = false
    @ObservedObject private var auth = AuthManager.shared
    @State private var isShowingAuth = false
    // 場所検索シートの表示
    @State private var isShowingSearch = false

    // MARK: - ピン配置（ドラッグ＆ドロップ）モード
    /// ピンを地図に置いて任意地点に投稿するモードか
    @State private var isPlacingPin = false
    /// 投稿（💬）ボタンを押している最中か（色変化＆掴み判定用）
    @GestureState private var isComposeButtonPressed = false
    /// 触る前は現在地アイコンに追従するか（true=追従 / false=ドラッグで自由配置）
    @State private var bubbleFollowsUser = true
    /// ドラッグ確定後に吹き出しを紐づける地図上の座標
    @State private var bubbleCoordinate: CLLocationCoordinate2D?
    /// ドラッグで確定した投稿地点
    @State private var newPostCoordinate: CLLocationCoordinate2D?

    /// 吹き出しの持ち上げ量（足のすぐ下にピン頭が来て、被らないよう少し上に）
    private let markerLift: CGFloat = 60
    /// 💬ドラッグ中、指の位置に足先を合わせるための下方向の補正量
    private let composeDragFootOffset: CGFloat = 30

    var body: some View {
        MapReader { proxy in
        ZStack(alignment: .bottomTrailing) {
            Map(position: $cameraPosition, interactionModes: .all) {
                // 現在地（立体的なカスタムマーカー）
                if let userLoc = locationManager.lastLocation {
                    Annotation("", coordinate: userLoc.coordinate, anchor: .bottom) {
                        UserLocationMarker3D()
                    }
                }
                // 投稿バブル
                ForEach(viewModel.postsWithLocation) { post in
                    // しっぽの先（吹き出し下端中央）が座標に一致するよう .bottom アンカー
                    Annotation("", coordinate: post.location!.coordinate, anchor: .bottom) {
                        ChatBubble(text: post.content)
                            .frame(maxWidth: 160)
                            .shadow(radius: 2)
                            .contentShape(Rectangle())
                            .onTapGesture { viewModel.selectedPost = post }
                    }
                }

                // 配置中の「書き込み中」吹き出し（MapKit アノテーションなので回転・傾けでも足先が座標に貼り付く）
                // ドラッグは下の透明レイヤーで捕捉するため、ここは表示専用（ヒットテスト無効）
                if isPlacingPin {
                    let placeCoord = bubbleFollowsUser
                        ? (locationManager.lastLocation?.coordinate ?? viewModel.region.center)
                        : (bubbleCoordinate ?? viewModel.region.center)
                    Annotation("", coordinate: placeCoord, anchor: .bottom) {
                        TypingBubble()
                            // 追従中はアイコンの上に持ち上げる
                            .offset(y: bubbleFollowsUser ? -markerLift : 0)
                            .allowsHitTesting(false)
                    }
                }
            }
            // 選択中のマップスタイルを適用（衛星 ⇔ 通常）
            .modifier(MapStyleModifier(isSatellite: isSatellite))
            // 通常マップは現在地が夜ならダーク、昼ならライト（衛星時は影響なし）
            .environment(\.colorScheme, (!isSatellite && isNightAtUser) ? .dark : .light)
            .mapControls {
                MapCompass()
            }
            // 昼夜判定を定期更新（10分ごと）
            .onReceive(Timer.publish(every: 600, on: .main, in: .common).autoconnect()) { _ in
                updateDayNight()
            }
            // 可視リージョンを保持。.continuous でパン中も連続更新し、吹き出しを地図へ追従させる
            .onMapCameraChange(frequency: .continuous) { context in
                viewModel.region = context.region
                currentCamera = context.camera
            }
            // スタイル切替時はズーム距離を共通値に揃える
            .onChange(of: isSatellite) { _, _ in
                normalizeZoomForStyle()
            }
            .ignoresSafeArea(.container, edges: .top)
            .onAppear {
                print("[MapTimelineView] onAppear 呼び出し。初期 region center = {lat: \(viewModel.region.center.latitude), lon: \(viewModel.region.center.longitude)}")
                print("[MapTimelineView] location authorizationStatus = \(locationManager.authorizationStatus.rawValue)")
                viewModel.fetchPosts()
                if locationManager.authorizationStatus == .notDetermined {
                    locationManager.requestPermission()
                } else {
                    locationManager.startUpdatingLocation()
                }
                updateDayNight()
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("OpenReply"))) { notif in
                if let p = notif.object as? Post {
                    if auth.isLoggedIn {
                        replyingTo = p
                    } else {
                        isShowingAuth = true
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("ReportPost"))) { notif in
                if let p = notif.object as? Post { reportingPost = p }
            }
            // ブロック状態が変わったらタイムラインを再取得
            .onReceive(NotificationCenter.default.publisher(for: .init("BlockStatusChanged"))) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    viewModel.fetchPosts()
                }
            }
            // 初回の位置取得時に現在地へ（3D カメラで）移動
            .onReceive(locationManager.$lastLocation) { loc in
                guard let loc = loc else { return }
                if !hasCenteredOnUser {
                    hasCenteredOnUser = true
                    withAnimation { cameraPosition = .camera(tiltedCamera(at: loc.coordinate)) }
                }
                updateDayNight()
            }
            .onReceive(auth.$isLoggedIn) { loggedIn in
                if loggedIn {
                    isShowingAuth = false
                } else {
                    // ログアウト後または初回起動時にゲストとしてタイムラインを更新
                    print("[MapTimelineView] Detected logout/guest mode. Refetching timeline.")
                    viewModel.fetchPosts()
                }
            }

            // ピン配置中のドラッグ捕捉レイヤー（吹き出しの周辺だけを捕捉。それ以外は地図のパン・回転に通す）
            // Map と同じ領域（セーフエリア無視）に重ね、座標変換のズレを防ぐ
            if isPlacingPin {
                GeometryReader { _ in
                    let placeCoord = bubbleFollowsUser
                        ? (locationManager.lastLocation?.coordinate ?? viewModel.region.center)
                        : (bubbleCoordinate ?? viewModel.region.center)
                    if let foot = proxy.convert(placeCoord, to: .local) {
                        let lift: CGFloat = bubbleFollowsUser ? markerLift : 0
                        let center = CGPoint(x: foot.x,
                                             y: foot.y - lift - TypingBubble.estimatedHeight / 2)
                        // 吹き出し付近だけの透明な掴みエリア
                        Color.white.opacity(0.001)
                            .frame(width: 110, height: TypingBubble.estimatedHeight + 44)
                            .position(center)
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .named("dragCatcher"))
                                    .onChanged { value in
                                        bubbleFollowsUser = false
                                        if let c = proxy.convert(value.location, from: .local) {
                                            bubbleCoordinate = c
                                        }
                                    }
                            )
                    }
                }
                .coordinateSpace(.named("dragCatcher"))
                .ignoresSafeArea(.container, edges: .top)
            }

            // ボタン群（投稿ボタンはドラッグ継続のため常設し、配置中は見た目だけ隠す）
            VStack(spacing: 12) {
                // 検索ボタン＆マップスタイル切替トグル（配置中は非表示）
                if !isPlacingPin {
                    Button(action: { isShowingSearch = true }) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.white)
                            .padding(14)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    MapStyleToggle(isSatellite: $isSatellite)
                }
                // 投稿（💬）ボタン: 押すと色が変わり吹き出しを掴む。スライドして離した場所に置く。
                Image(systemName: "bubble.left.fill")
                    .foregroundColor(.white)
                    .padding(16)
                    .background(Circle().fill(isComposeButtonPressed ? Color.green : Color.green.opacity(0.85)))
                    .scaleEffect(isComposeButtonPressed ? 1.12 : 1.0)
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                    .contentShape(Circle())
                    .opacity(isPlacingPin && !isComposeButtonPressed ? 0 : 1)
                    .allowsHitTesting(!(isPlacingPin && !isComposeButtonPressed))
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isComposeButtonPressed)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("appSpace"))
                            .updating($isComposeButtonPressed) { _, state, _ in state = true }
                            .onChanged { value in
                                guard auth.isLoggedIn else { return }
                                if !isPlacingPin {
                                    isPlacingPin = true
                                    bubbleFollowsUser = false
                                }
                                // 足先が指の位置に来るよう少し下げて変換
                                let pt = CGPoint(x: value.location.x, y: value.location.y + composeDragFootOffset)
                                if let c = proxy.convert(pt, from: .local) {
                                    bubbleCoordinate = c
                                }
                            }
                            .onEnded { value in
                                guard auth.isLoggedIn else { isShowingAuth = true; return }
                                let moved = hypot(value.translation.width, value.translation.height)
                                if moved <= 8 {
                                    // タップ扱い: 既定の配置（現在地が見えていれば追従、なければ中央）
                                    if let userCoord = locationManager.lastLocation?.coordinate,
                                       isCoordinateVisible(userCoord) {
                                        bubbleFollowsUser = true
                                        bubbleCoordinate = nil
                                    } else {
                                        bubbleFollowsUser = false
                                        bubbleCoordinate = viewModel.region.center
                                    }
                                } else {
                                    let pt = CGPoint(x: value.location.x, y: value.location.y + composeDragFootOffset)
                                    if let c = proxy.convert(pt, from: .local) {
                                        bubbleFollowsUser = false
                                        bubbleCoordinate = c
                                    }
                                }
                            }
                    )
                // 現在地ボタン（配置中は非表示）
                if !isPlacingPin {
                    Button(action: {
                        if let loc = locationManager.lastLocation {
                            withAnimation {
                                cameraPosition = .camera(tiltedCamera(at: loc.coordinate))
                            }
                        }
                    }) {
                        Image(systemName: "location.fill")
                            .foregroundColor(.white)
                            .padding(14)
                            .background(Color.blue.opacity(0.75))
                            .clipShape(Circle())
                    }
                }
            }
            .padding()
        }
        .ignoresSafeArea(.container, edges: .top)
        .coordinateSpace(.named("appSpace"))
        // 配置モードの説明バナー
        .overlay(alignment: .top) {
            if isPlacingPin {
                Text("吹き出しをドラッグして投稿する場所を決めてください")
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 60)
            }
        }
        // 配置モードの確定/キャンセルバー
        .overlay(alignment: .bottom) {
            if isPlacingPin {
                HStack {
                    Button("キャンセル") { isPlacingPin = false }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button {
                        confirmPinPlacement()
                    } label: {
                        Label("ここに投稿", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.ultraThinMaterial)
            }
        }
        .sheet(isPresented: $isPresentingNewPost) {
            NewPostView(viewModel: viewModel, presetCoordinate: newPostCoordinate)
                .environmentObject(locationManager)
        }
        .sheet(isPresented: $isShowingSearch) {
            PlaceSearchView { coordinate in
                withAnimation {
                    cameraPosition = .camera(tiltedCamera(at: coordinate))
                }
            }
        }
        .sheet(item: $viewModel.selectedPost) { post in
            PostDetailSheet(post: post)
        }
        .sheet(item: $replyingTo) { parent in
            ReplyView(parent: parent, viewModel: viewModel)
        }
        .fullScreenCover(isPresented: $isShowingAuth) {
            LoginView()
        }
        .alert("投稿を通報しますか？", isPresented: Binding(get: { reportingPost != nil }, set: { newVal in if !newVal { reportingPost = nil } })) {
            Button("キャンセル", role: .cancel) { reportingPost = nil }
            Button("通報", role: .destructive) {
                if let post = reportingPost {
                    viewModel.report(post: post, reason: nil)
                }
                reportingPost = nil
            }
        }
        } // MapReader
    }

    // MARK: - カメラ
    /// 指定座標を中心にした 3D（傾き付き）カメラを返す
    private func tiltedCamera(at coordinate: CLLocationCoordinate2D) -> MapCamera {
        MapCamera(centerCoordinate: coordinate, distance: kStyleZoomDistance, heading: 0, pitch: 55)
    }

    /// スタイル切替時に、中心・向き・傾きは保ったままズーム距離だけ共通値に合わせる
    private func normalizeZoomForStyle() {
        let center = currentCamera?.centerCoordinate ?? viewModel.region.center
        let heading = currentCamera?.heading ?? 0
        let pitch = currentCamera?.pitch ?? 55
        withAnimation {
            cameraPosition = .camera(MapCamera(centerCoordinate: center,
                                               distance: kStyleZoomDistance,
                                               heading: heading,
                                               pitch: pitch))
        }
    }

    /// 現在地の昼夜を判定して isNightAtUser を更新（現在地不明なら region 中心で代用）
    private func updateDayNight() {
        let coord = locationManager.lastLocation?.coordinate ?? viewModel.region.center
        isNightAtUser = SolarCalculator.isNight(latitude: coord.latitude,
                                                longitude: coord.longitude,
                                                date: Date())
    }

    // MARK: - ピン配置ヘルパー
    /// 座標が現在の表示範囲内かどうか（端で見切れないよう少し内側で判定）
    private func isCoordinateVisible(_ coord: CLLocationCoordinate2D) -> Bool {
        let r = viewModel.region
        let dLat = abs(coord.latitude - r.center.latitude)
        let dLon = abs(coord.longitude - r.center.longitude)
        return dLat <= r.span.latitudeDelta * 0.45 && dLon <= r.span.longitudeDelta * 0.45
    }

    /// 投稿地点を確定して投稿画面を開く（追従中=現在地 / 配置済み=確定座標）
    private func confirmPinPlacement() {
        newPostCoordinate = bubbleFollowsUser
            ? (locationManager.lastLocation?.coordinate ?? viewModel.region.center)
            : (bubbleCoordinate ?? viewModel.region.center)
        isPlacingPin = false
        isPresentingNewPost = true
    }
}

struct PostDetailSheet: View {
    let post: Post
    @State private var replies: [Post] = []
    @State private var isLoadingReplies = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(post.user.username)
                .font(.headline)
                .contextMenu {
                    if AuthManager.shared.isLoggedIn,
                       let me = AuthManager.shared.currentUser,
                       me.id != post.user.id {
                        if AuthManager.shared.blockedUserIDs.contains(post.user.id) {
                            Button("ブロック解除") {
                                AuthManager.shared.unblock(userID: post.user.id)
                            }
                        } else {
                            Button("ブロック", role: .destructive) {
                                showBlockConfirm = true
                            }
                        }
                    }
                }
            Text(post.content)
                .font(.body)
            if let loc = post.location {
                Text("\(loc.latitude), \(loc.longitude)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(post.createdAt, style: .date)
                .font(.caption2)
                .foregroundColor(.secondary)

            // アクションボタン
            HStack {
                Button("返信") {
                    // 先にシートを閉じてから ReplyView を開く
                    dismiss()
                    // 少し遅延して通知（閉じるアニメ完了後）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        NotificationCenter.default.post(name: .init("OpenReply"), object: post)
                    }
                }
                Spacer()
                Button(action: { showMenu = true }) {
                    Image(systemName: "ellipsis")
                }
            }
            .padding(.top, 8)

            // アクションメニュー
            .confirmationDialog("操作", isPresented: $showMenu, titleVisibility: .visible) {
                Button("通報", role: .destructive) {
                    showReportConfirm = true
                }
                if AuthManager.shared.isLoggedIn {
                    let myID = AuthManager.shared.currentUser?.id
                    if myID == nil || myID != post.user.id {
                        if AuthManager.shared.blockedUserIDs.contains(post.user.id) {
                            Button("ブロック解除", role: .destructive) {
                                showUnblockConfirm = true
                            }
                        } else {
                            Button("ブロック", role: .destructive) {
                                showBlockConfirm = true
                            }
                        }
                    }
                }
                Button("キャンセル", role: .cancel) {}
            }

            // 各確認アラート
            .alert("このユーザーをブロックしますか？", isPresented: $showBlockConfirm) {
                Button("キャンセル", role: .cancel) {}
                Button("ブロック", role: .destructive) {
                    AuthManager.shared.block(userID: post.user.id)
                    dismiss()
                }
            }

            .alert("ブロックを解除しますか？", isPresented: $showUnblockConfirm) {
                Button("キャンセル", role: .cancel) {}
                Button("解除", role: .destructive) {
                    AuthManager.shared.unblock(userID: post.user.id)
                }
            }

            .alert("この投稿を通報しますか？", isPresented: $showReportConfirm) {
                Button("キャンセル", role: .cancel) {}
                Button("通報", role: .destructive) {
                    NotificationCenter.default.post(name: .init("ReportPost"), object: post)
                }
            }

            Divider()

            if isLoadingReplies {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if replies.isEmpty {
                Text("返信はありません")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(replies) { reply in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(reply.user.username)
                                .font(.caption)
                                .bold()
                            Spacer()
                            Text(reply.createdAt, style: .time)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Text(reply.content)
                            .font(.caption)
                            .foregroundColor(.primary)
                            .padding(6)
                            .background(Color.gray.opacity(0.05))
                            .cornerRadius(6)
                    }
                    .padding(.vertical, 4)
                }
            }
            Spacer()
        }
        .padding()
        .onAppear(perform: loadReplies)
        .alert("このユーザーをブロックしますか？", isPresented: $showBlockConfirm) {
            Button("キャンセル", role: .cancel) {}
            Button("ブロック", role: .destructive) {
                AuthManager.shared.block(userID: post.user.id)
                dismiss()
            }
        }        
    }

    private func loadReplies() {
        isLoadingReplies = true
        APIService.shared.fetchReplies(parentID: post.id)
            .sink(receiveCompletion: { _ in
                isLoadingReplies = false
            }, receiveValue: { replies in
                self.replies = replies
            })
            .store(in: &cancellables)
    }

    // Store for Combine
    @State private var cancellables = Set<AnyCancellable>()

    @State private var showMenu = false
    @State private var showBlockConfirm = false
    @State private var showUnblockConfirm = false
    @State private var showReportConfirm = false
}

// MARK: - 現在地マーカー（立体的）
/// ツヤのある球体ヘッド（少し小さめ）＋はっきりしたソリッドな脚＋地面の影とパルスリング。
/// 傾いた 3D マップ上でも立体的に見える現在地マーカー。
struct UserLocationMarker3D: View {
    @State private var pulse = false
    private let accent = Color(red: 0.13, green: 0.55, blue: 1.0)

    var body: some View {
        VStack(spacing: -2) {
            // 球体ヘッド（少し小さめ）
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white,
                            accent,
                            accent.opacity(0.9),
                            Color(red: 0.0, green: 0.28, blue: 0.75)
                        ],
                        center: UnitPoint(x: 0.33, y: 0.28),
                        startRadius: 0,
                        endRadius: 20
                    )
                )
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(.white, lineWidth: 2.5))
                .overlay(
                    // ハイライト（光沢）
                    Ellipse()
                        .fill(.white.opacity(0.75))
                        .frame(width: 8, height: 5)
                        .blur(radius: 1.5)
                        .offset(x: -4, y: -5)
                )
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 3)
                .zIndex(1)

            // はっきりした脚（ソリッドな支柱・円柱風）
            Capsule()
                .fill(accent)
                .frame(width: 5, height: 16)
                .overlay(
                    // 円柱っぽい陰影（左を明るく右を暗く）
                    Capsule().fill(
                        LinearGradient(
                            colors: [.white.opacity(0.3), .clear, .black.opacity(0.2)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                )
                .overlay(Capsule().stroke(.white.opacity(0.9), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 1.5, x: 0, y: 1)

            // 地面の影＋パルスリング
            ZStack {
                Ellipse()
                    .fill(.black.opacity(0.28))
                    .frame(width: 18, height: 6)
                    .blur(radius: 2)
                Ellipse()
                    .stroke(accent.opacity(0.6), lineWidth: 2)
                    .frame(width: 16, height: 6)
                    .scaleEffect(pulse ? 2.6 : 1.0)
                    .opacity(pulse ? 0 : 0.7)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

// MARK: - 書き込み中の吹き出し（投稿地点プレビュー）
/// 「・・・」がタイピング風に弾む、角丸本体からしっぽがなめらかに生える吹き出し。
/// しっぽの先が投稿地点を指す。
struct TypingBubble: View {
    @State private var animating = false

    private let tailLength: CGFloat = 13
    /// レイアウト上のおおよその高さ（しっぽの先を座標に合わせる計算に使用）
    /// 内訳: ドット7 + 上padding13 + 下padding13 + しっぽ13 = 46
    static let estimatedHeight: CGFloat = 46

    var body: some View {
        let shape = SmoothTailBubble(cornerRadius: 16, tailWidth: 8, tailLength: tailLength)
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.gray.opacity(0.7))
                    .frame(width: 7, height: 7)
                    // スケールで脈動（フレーム内に収まるのではみ出さない）
                    .scaleEffect(animating ? 1.0 : 0.45)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever()
                            .delay(Double(i) * 0.2),
                        value: animating
                    )
            }
        }
        .frame(height: 7)
        .padding(.horizontal, 18)
        .padding(.top, 13)
        .padding(.bottom, 13 + tailLength) // 本文余白 + しっぽの長さ
        .background(
            shape
                .fill(Color.white)
                .overlay(shape.stroke(Color.gray.opacity(0.35), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
        )
        .onAppear { animating = true }
    }
}

/// 角丸本体の底中央から、しっぽがなめらかに生える吹き出し（iMessage/LINE 風）。
/// しっぽの先は下中央の一点（= 投稿地点）。
struct SmoothTailBubble: Shape {
    var cornerRadius: CGFloat = 16
    var tailWidth: CGFloat = 24
    var tailLength: CGFloat = 13

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let bodyH = rect.height - tailLength
        let r = min(cornerRadius, min(rect.width, bodyH) / 2)
        let midX = rect.midX
        let half = tailWidth / 2

        // 上辺
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        // 右上角
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                       control: CGPoint(x: rect.maxX, y: rect.minY))
        // 右側
        p.addLine(to: CGPoint(x: rect.maxX, y: bodyH - r))
        // 右下角
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: bodyH),
                       control: CGPoint(x: rect.maxX, y: bodyH))
        // 底辺 → しっぽ右付け根
        p.addLine(to: CGPoint(x: midX + half, y: bodyH))
        // しっぽ右側を先端へなめらかに
        p.addQuadCurve(to: CGPoint(x: midX, y: rect.maxY),
                       control: CGPoint(x: midX + half * 0.35, y: bodyH + tailLength * 0.85))
        // 先端 → しっぽ左付け根へなめらかに
        p.addQuadCurve(to: CGPoint(x: midX - half, y: bodyH),
                       control: CGPoint(x: midX - half * 0.35, y: bodyH + tailLength * 0.85))
        // 底辺 → 左下
        p.addLine(to: CGPoint(x: rect.minX + r, y: bodyH))
        // 左下角
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: bodyH - r),
                       control: CGPoint(x: rect.minX, y: bodyH))
        // 左側
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        // 左上角
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - 場所検索
/// MKLocalSearchCompleter で入力に応じた候補を返すモデル
final class PlaceSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query: String = "" {
        didSet {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                results = []
            } else {
                completer.queryFragment = trimmed
            }
        }
    }
    @Published var results: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}

/// 場所検索シート。候補をタップするとその座標を onSelect で返す。
struct PlaceSearchView: View {
    @StateObject private var model = PlaceSearchCompleter()
    @Environment(\.dismiss) private var dismiss
    var onSelect: (CLLocationCoordinate2D) -> Void

    var body: some View {
        NavigationStack {
            List(model.results, id: \.self) { result in
                Button {
                    resolve(result)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title)
                            .foregroundColor(.primary)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if model.query.isEmpty {
                    ContentUnavailableView("場所を検索", systemImage: "magnifyingglass",
                                           description: Text("地名・住所・施設名を入力してください"))
                } else if model.results.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                }
            }
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "場所を検索")
            .navigationTitle("検索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    /// 候補を実際の座標に解決して返す
    private func resolve(_ completion: MKLocalSearchCompletion) {
        let request = MKLocalSearch.Request(completion: completion)
        MKLocalSearch(request: request).start { response, _ in
            guard let coordinate = response?.mapItems.first?.placemark.coordinate else { return }
            onSelect(coordinate)
            dismiss()
        }
    }
}

#Preview {
    MapTimelineView()
        .environmentObject(LocationManager())
} 