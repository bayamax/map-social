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

/// 散歩モードのドラッグ種別（開始位置で決まる）
enum WalkDragZone { case move, look }

struct MapTimelineView: View {
    @StateObject private var viewModel = TimelineViewModel()
    @StateObject private var vehicleService = VehicleService()
    @StateObject private var aircraftService = AircraftService()
    @StateObject private var webcamService = WebcamService()
    @StateObject private var iss = ISSService()
    /// タップされたライブカメラ（シートで再生）
    @State private var selectedWebcam: Webcam?
    @StateObject private var weatherService = WeatherService()
    @StateObject private var walk = WalkController()
    @StateObject private var presence = PresenceService()
    @EnvironmentObject var locationManager: LocationManager
    // 散歩モードの操作（下半分=移動 / 上半分=視点回転）
    @State private var walkDragZone: WalkDragZone?
    @State private var walkLastLookX: CGFloat = 0
    // バーチャルスティック表示（移動操作の起点と現在点）
    @State private var joyStart: CGPoint?
    @State private var joyCurrent: CGPoint?
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
    // 場所検索シートの表示
    @State private var isShowingSearch = false
    // 検索で立てたピン（現在地ピンとは別）
    @State private var searchedPlace: SearchedPlace?

    // MARK: - ピン配置（ドラッグ＆ドロップ）モード
    /// ピンを地図に置いて任意地点に投稿するモードか
    @State private var isPlacingPin = false
    /// 投稿（💬）ボタンを押している最中か（色変化＆掴み判定用）
    @GestureState private var isComposeButtonPressed = false
    /// 触る前は現在地アイコンに追従するか（true=追従 / false=ドラッグで自由配置）
    @State private var bubbleFollowsUser = true
    /// 固定座標アンカー時に吹き出しをピンの上へ持ち上げるか（検索ピン起点など）
    @State private var bubbleLifted = false
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
            Map(position: $cameraPosition, interactionModes: walk.isActive ? [] : .all) {
                // 現在地（立体的なカスタムマーカー）
                if let userLoc = locationManager.lastLocation {
                    Annotation("", coordinate: userLoc.coordinate, anchor: .bottom) {
                        UserLocationMarker3D()
                    }
                }
                // 検索した地点のピン（現在地ピンと同じ世界観の立体マーカー・赤系、パルス無し）。タップで消える。
                if let place = searchedPlace {
                    Annotation(place.name, coordinate: place.coordinate, anchor: .bottom) {
                        UserLocationMarker3D(
                            accent: Color(red: 0.95, green: 0.34, blue: 0.34),
                            deep: Color(red: 0.70, green: 0.10, blue: 0.12),
                            pulsing: false
                        )
                        .onTapGesture { searchedPlace = nil }
                    }
                }
                // 投稿バブル
                ForEach(viewModel.postsWithLocation) { post in
                    // しっぽの先（吹き出し下端中央）が座標に一致するよう .bottom アンカー
                    Annotation("", coordinate: post.location!.coordinate, anchor: .bottom) {
                        ChatBubble(text: LinkedText.stripped(post.content))
                            .frame(maxWidth: 160)
                            .shadow(radius: 2)
                            .contentShape(Rectangle())
                            .onTapGesture { viewModel.selectedPost = post }
                    }
                }

                // 乗り物（リアルタイム・補間済み）。表示は VehicleService が範囲・上限を管理。
                ForEach(vehicleService.displayVehicles) { dv in
                    Annotation("", coordinate: dv.coordinate, anchor: .center) {
                        VehicleMarker(vehicle: dv,
                                      mapHeading: currentCamera?.heading ?? 0,
                                      mapPitch: currentCamera?.pitch ?? 0)
                    }
                }

                // 飛行機（adsb.lol・推測航法で滑らかに移動）。乗り物トグルと連動。
                // 引きの表示では便名を出さない（60機×ラベルはクラッタ）
                let showFlightLabels = viewModel.region.span.latitudeDelta < 0.8
                // 地球儀の範囲では、マーカーごとに視点からの角度を幾何で出すためのカメラ
                let globeCam: MarkerProjection.GlobeCamera? =
                    (viewModel.region.span.latitudeDelta > AircraftTuning.hideAboveSpan ? currentCamera : nil)
                        .map { .init(center: $0.centerCoordinate, distance: $0.distance) }
                ForEach(aircraftService.displayAircraft) { ac in
                    Annotation("", coordinate: ac.coordinate, anchor: AircraftMarker.anchor) {
                        // 世界モード（地球儀）は機体ごとに視点からの角度を幾何で出す：
                        // 視点直下は真上から（平面）、縁に寄るほど横から見た立体になる。
                        AircraftMarker(aircraft: ac,
                                       mapHeading: currentCamera?.heading ?? 0,
                                       mapPitch: currentCamera?.pitch ?? 0,
                                       showLabel: showFlightLabels && !aircraftService.isWorldMode,
                                       scale: aircraftService.isWorldMode ? 0.8 : 1,
                                       liftOverride: aircraftService.isWorldMode ? 15 : nil,
                                       globe: globeCam)
                    }
                }

                // 世界ライブカメラ（タップでシート再生）
                // ISS のカメラだけは実位置（wheretheiss.at）に追従して地球を回る
                ForEach(webcamService.cams) { cam in
                    Annotation(cam.id == "iss" ? "" : cam.displayName,
                               coordinate: resolvedCoordinate(of: cam),
                               anchor: cam.id == "iss" ? ISSMarker.anchor : .bottom) {
                        Group {
                            if cam.id == "iss" {
                                // 飛行機と同じ擬似3D。地球儀では視点からの角度、平面ではカメラの傾きで描く
                                ISSMarker(coordinate: resolvedCoordinate(of: cam),
                                          heading: iss.heading,
                                          mapHeading: currentCamera?.heading ?? 0,
                                          mapPitch: currentCamera?.pitch ?? 0,
                                          watchers: webcamService.counts[cam.id] ?? 0,
                                          isDaylight: iss.isDaylight,
                                          scale: globeCam == nil ? 1 : 0.85,
                                          globe: globeCam)
                                    // タップ領域は本体まわりだけ（キャンバスは広いので）
                                    .contentShape(Rectangle().size(width: 90, height: 70).offset(x: 35, y: 40))
                            } else {
                                WebcamMarker(name: cam.displayName,
                                             watchers: webcamService.counts[cam.id] ?? 0)
                                    .contentShape(Rectangle())
                            }
                        }
                        .onTapGesture { selectedWebcam = cam }
                    }
                }

                // 散歩モードのアバター（自分の仮想の分身）
                // 他のユーザーの分身（presence）。通常モードでも常に表示。
                ForEach(presence.others) { p in
                    Annotation("", coordinate: p.coordinate, anchor: .center) {
                        AvatarMarker(heading: p.heading,
                                     mapHeading: currentCamera?.heading ?? 0,
                                     mapPitch: currentCamera?.pitch ?? 0,
                                     shirt: Self.avatarColor(for: p.id),
                                     name: p.name)
                    }
                }
                // 自分の分身（散歩モード中のみ）
                if walk.isActive {
                    Annotation("", coordinate: walk.coordinate, anchor: .center) {
                        AvatarMarker(heading: walk.avatarHeading,
                                     mapHeading: walk.viewHeading,
                                     mapPitch: currentCamera?.pitch ?? walk.pitch)
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
                            // ピン（現在地/検索）起点のときはアイコンの上に持ち上げる
                            .offset(y: (bubbleFollowsUser || bubbleLifted) ? -markerLift : 0)
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
                // 表示中心を渡す（バックエンドが範囲内の都市だけ返す）
                vehicleService.updateRegion(context.region)
                aircraftService.updateRegion(context.region)
                // presence の観測範囲＝見えている範囲（世界ズームなら地球全体の散歩者が見える）
                presence.updateFocus(context.region)
            }
            // 地図の移動が終わったら、その表示範囲で即取得（移動＝更新トリガー）
            .onMapCameraChange(frequency: .onEnd) { context in
                vehicleService.refreshNow(region: context.region)
                aircraftService.refreshNow(region: context.region)
                weatherService.updateRegion(context.region)
                // 見ている場所の昼夜・天気に合わせる
                updateDayNight()
            }
            // 散歩モード：アバターにカメラを追従させる（30fps）
            .onChange(of: walk.frame) { _, _ in
                guard walk.isActive else { return }
                cameraPosition = .camera(MapCamera(centerCoordinate: walk.coordinate,
                                                   distance: walk.distance,
                                                   heading: walk.viewHeading,
                                                   pitch: walk.pitch))
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
                // 未決定のときの許可要求は ContentView に一元化している
                // （初回はチュートリアルを見終えてから聞く）。ここでは許可済みの場合だけ開始する。
                if locationManager.authorizationStatus != .notDetermined {
                    locationManager.startUpdatingLocation()
                }
                vehicleService.resumeIfEnabled()
                aircraftService.resumeIfEnabled()
                weatherService.resumeIfEnabled()
                webcamService.loadIfNeeded()
                webcamService.startCountsPolling()
                iss.start()
                presence.start()
                presence.updateFocus(viewModel.region)
                updateDayNight()
                applyScreenshotHooksIfNeeded()
            }
            .onDisappear {
                // タブを離れたら通信は止める（有効状態は保持）
                vehicleService.pause()
                aircraftService.pause()
                weatherService.pause()
                webcamService.stopCountsPolling()
                iss.stop()
                presence.stop()
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("OpenReply"))) { notif in
                if let p = notif.object as? Post {
                    // ゲストも返信画面は開ける。登録を促すのは「送信」を押した時（ReplyView 側）。
                    replyingTo = p
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
            .onReceive(auth.$isLoggedIn) { _ in
                // ゲスト⇄ログインで取得内容（いいね状態・ブロック除外）が変わるので取り直す
                viewModel.fetchPosts()
            }

            // 天気エフェクト（雨/雪/霧）。地図の上・ボタンの下に重ねる。タッチは透過。
            if weatherService.isEnabled {
                WeatherOverlay(effect: weatherService.effect)
                    .allowsHitTesting(false)
            }

            // 散歩モードの操作レイヤー：下半分ドラッグ=移動 / 上半分ドラッグ=視点回転
            // （投稿配置中は歩行を止める）
            if walk.isActive && !isPlacingPin {
                GeometryReader { geo in
                    ZStack {
                        Color.white.opacity(0.001)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 2)
                                    .onChanged { v in
                                        if walkDragZone == nil {
                                            walkDragZone = v.startLocation.y > geo.size.height * 0.5 ? .move : .look
                                        }
                                        switch walkDragZone {
                                        case .move:
                                            walk.setMove(v.translation)
                                            joyStart = v.startLocation
                                            joyCurrent = v.location
                                        case .look:
                                            // 指のスライド方向と地図の回り方を一致させる（符号反転）
                                            let d = v.translation.width - walkLastLookX
                                            walk.rotateView(by: Double(d) * -0.4)
                                            walkLastLookX = v.translation.width
                                        case .none:
                                            break
                                        }
                                    }
                                    .onEnded { _ in
                                        walk.clearMove()
                                        walkDragZone = nil
                                        walkLastLookX = 0
                                        joyStart = nil
                                        joyCurrent = nil
                                    }
                            )

                        // バーチャルスティック（移動の起点＝最初のタッチ点に表示）
                        if let s = joyStart, let c = joyCurrent {
                            let r: CGFloat = 46
                            let dx = c.x - s.x, dy = c.y - s.y
                            let dist = max(hypot(dx, dy), 0.0001)
                            let kx = dist > r ? s.x + dx / dist * r : c.x
                            let ky = dist > r ? s.y + dy / dist * r : c.y
                            Group {
                                Circle()
                                    .fill(Color.black.opacity(0.12))
                                    .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 2))
                                    .frame(width: r * 2, height: r * 2)
                                    .position(s)
                                Circle()
                                    .fill(Color.white.opacity(0.5))
                                    .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5))
                                    .frame(width: 44, height: 44)
                                    .position(x: kx, y: ky)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                }
                .ignoresSafeArea()
            }

            // ピン配置中のドラッグ捕捉レイヤー（吹き出しの周辺だけを捕捉）。散歩モードはアバター位置固定なので不要。
            if isPlacingPin && !walk.isActive {
                GeometryReader { _ in
                    let placeCoord = bubbleFollowsUser
                        ? (locationManager.lastLocation?.coordinate ?? viewModel.region.center)
                        : (bubbleCoordinate ?? viewModel.region.center)
                    if let foot = proxy.convert(placeCoord, to: .local) {
                        let lift: CGFloat = (bubbleFollowsUser || bubbleLifted) ? markerLift : 0
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
                                        bubbleLifted = false
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
                    // 動くもの（バス・電車=GTFS-Realtime ＋ 飛行機=ADS-B）表示トグル
                    Button(action: { toggleVehicles() }) {
                        Image(systemName: isMovingLayerOn ? "bus.fill" : "bus")
                            .foregroundColor(.white)
                            .padding(14)
                            .background(isMovingLayerOn ? Color.green.opacity(0.85) : Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    // 天気エフェクト トグル（雨/雪の演出。デフォルトOFF）
                    Button(action: { toggleWeather() }) {
                        Image(systemName: weatherService.isEnabled ? weatherIconName : "cloud")
                            .foregroundColor(.white)
                            .padding(14)
                            .background(weatherService.isEnabled ? Color.blue.opacity(0.85) : Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    // 散歩モード（仮想アバターで歩く）。もう一度押すと終了。
                    Button(action: { toggleWalk() }) {
                        Image(systemName: "figure.walk")
                            .foregroundColor(.white)
                            .padding(14)
                            .background(walk.isActive ? Color.orange.opacity(0.9) : Color.black.opacity(0.6))
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
                                // 散歩モード：アバターの座標に固定で吹き出し（持ち上げ＝現在地投稿と同じ高さ）
                                if walk.isActive {
                                    isPlacingPin = true
                                    bubbleFollowsUser = false
                                    bubbleLifted = true
                                    bubbleCoordinate = walk.coordinate
                                    return
                                }
                                if !isPlacingPin {
                                    isPlacingPin = true
                                    bubbleFollowsUser = false
                                    bubbleLifted = false
                                }
                                // 足先が指の位置に来るよう少し下げて変換
                                let pt = CGPoint(x: value.location.x, y: value.location.y + composeDragFootOffset)
                                if let c = proxy.convert(pt, from: .local) {
                                    bubbleCoordinate = c
                                }
                            }
                            .onEnded { value in
                                // 散歩モード：アバール位置に確定（高さ織り込み）
                                if walk.isActive {
                                    bubbleFollowsUser = false
                                    bubbleLifted = true
                                    bubbleCoordinate = walk.coordinate
                                    return
                                }
                                let moved = hypot(value.translation.width, value.translation.height)
                                if moved <= 8 {
                                    // タップ扱い: 既定の配置
                                    // 優先順位: 画面内の検索ピン → 画面内の現在地 → 中央
                                    if let place = searchedPlace, isCoordinateVisible(place.coordinate) {
                                        bubbleFollowsUser = false
                                        bubbleLifted = true
                                        bubbleCoordinate = place.coordinate
                                    } else if let userCoord = locationManager.lastLocation?.coordinate,
                                              isCoordinateVisible(userCoord) {
                                        bubbleFollowsUser = true
                                        bubbleLifted = false
                                        bubbleCoordinate = nil
                                    } else {
                                        bubbleFollowsUser = false
                                        bubbleLifted = false
                                        bubbleCoordinate = viewModel.region.center
                                    }
                                } else {
                                    let pt = CGPoint(x: value.location.x, y: value.location.y + composeDragFootOffset)
                                    if let c = proxy.convert(pt, from: .local) {
                                        bubbleFollowsUser = false
                                        bubbleLifted = false
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
        // 散歩モード：注釈（他人にも見えている）。プライバシー配慮の明示。
        .overlay(alignment: .top) {
            if walk.isActive {
                Text("散歩中：あなたのアバターが近くの人にも見えています")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(.top, 60)
            }
        }
        // 地球のどこかで散歩中の人（見えている範囲の人数）。タップでその人のところへ飛ぶ。
        .overlay(alignment: .top) {
            if !walk.isActive && !isPlacingPin && !presence.others.isEmpty {
                let n = presence.others.count
                let isWorld = viewModel.region.span.latitudeDelta > 20
                Button {
                    if let p = presence.others.first {
                        withAnimation(.easeInOut(duration: 1.2)) {
                            cameraPosition = .camera(MapCamera(centerCoordinate: p.coordinate,
                                                               distance: 1200, heading: 0, pitch: 55))
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "figure.walk")
                        if isWorld { Text("いま \(n) 人が地球を散歩中") } else { Text("この範囲で \(n) 人が散歩中") }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .opacity(0.7)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.55), in: Capsule())
                }
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // 散歩モード：操作ヒント
        .overlay(alignment: .bottom) {
            if walk.isActive && !isPlacingPin {
                Text("下半分ドラッグ＝移動 ／ 上半分＝見回す ／ 🚶ボタンで終了")
                    .font(.caption)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 24)
            }
        }
        // 配置モードの説明バナー
        .overlay(alignment: .top) {
            if isPlacingPin && !walk.isActive {
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
            PlaceSearchView { coordinate, name in
                searchedPlace = SearchedPlace(coordinate: coordinate, name: name)
                withAnimation {
                    cameraPosition = .camera(tiltedCamera(at: coordinate))
                }
            }
        }
        .sheet(item: $viewModel.selectedPost) { post in
            PostDetailSheet(post: post)
        }
        .sheet(item: $selectedWebcam) { cam in
            WebcamPlayerView(webcam: cam)
        }
        .sheet(item: $replyingTo) { parent in
            ReplyView(parent: parent, viewModel: viewModel)
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
    /// スクリーンショット撮影用フック（DEBUGビルド限定・環境変数があるときだけ動く。Releaseには含まれない）
    /// ライブカメラの表示座標。ISS は登録座標ではなく実位置。
    private func resolvedCoordinate(of cam: Webcam) -> CLLocationCoordinate2D {
        cam.id == "iss" ? (iss.coordinate ?? cam.coordinate) : cam.coordinate
    }

    /// SCREENSHOT_CAMERA="lat,lon,distance[,pitch]" で地図カメラを固定、
    /// SCREENSHOT_OPENCAM="<webcam id>" で指定ライブカメラのシートを自動で開く。
    private func applyScreenshotHooksIfNeeded() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let spec = env["SCREENSHOT_CAMERA"] {
            let p = spec.split(separator: ",").compactMap { Double($0) }
            if p.count >= 3 {
                let pitch = p.count >= 4 ? p[3] : 0
                // 初回位置取得のカメラ移動と競合しないよう、SCREENSHOT_CAMERA_DELAY 秒（既定2）待ってから当てる
                let delay = Double(env["SCREENSHOT_CAMERA_DELAY"] ?? "") ?? 2
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    cameraPosition = .camera(MapCamera(
                        centerCoordinate: .init(latitude: p[0], longitude: p[1]),
                        distance: p[2], heading: 0, pitch: pitch))
                }
            }
        }
        // SCREENSHOT_VEHICLES=1 / SCREENSHOT_WEATHER=1 でレイヤーを自動ON（カメラ固定後に範囲を渡す）
        if env["SCREENSHOT_VEHICLES"] == "1" || env["SCREENSHOT_WEATHER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if env["SCREENSHOT_VEHICLES"] == "1", !vehicleService.isEnabled {
                    vehicleService.start(region: viewModel.region)
                    // 傾けたカメラでは region.center が注視点から大きくずれるので、モック機体はカメラ中心に撒く
                    var r = viewModel.region
                    if let c = currentCamera?.centerCoordinate { r.center = c }
                    aircraftService.start(region: r)
                }
                if env["SCREENSHOT_WEATHER"] == "1", !weatherService.isEnabled {
                    weatherService.start(region: viewModel.region)
                }
            }
        }
        if let camID = env["SCREENSHOT_OPENCAM"] {
            // 一覧ロードが遅い環境でも空振りしないよう、見つかるまで最大30秒リトライ
            Task { @MainActor in
                for _ in 0..<30 {
                    if let cam = webcamService.cams.first(where: { $0.id == camID }) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        cameraPosition = .camera(tiltedCamera(at: cam.coordinate))
                        selectedWebcam = cam
                        return
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        #endif
    }

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

    /// 「見ている地図の中心」で昼夜を判定（現在地ではなく表示中の場所に合わせる＝世界都市に追従）
    private func updateDayNight() {
        let coord = viewModel.region.center
        isNightAtUser = SolarCalculator.isNight(latitude: coord.latitude,
                                                longitude: coord.longitude,
                                                date: Date())
    }

    private func toggleWeather() {
        if weatherService.isEnabled {
            weatherService.stop()
        } else {
            weatherService.start(region: viewModel.region)
        }
    }

    /// 散歩モードの ON/OFF。ON で今の地図中心にアバターを置き、寄りの追従カメラへ。
    private func toggleWalk() {
        if walk.isActive {
            presence.endWalking()
            walk.stop()
        } else {
            let center = viewModel.region.center
            let heading = currentCamera?.heading ?? 0
            walk.start(at: center, heading: heading)
            presence.setWalking(me: walk, name: AuthManager.shared.currentUser?.username ?? "さんぽ")
            withAnimation(.easeInOut(duration: 0.5)) {
                cameraPosition = .camera(MapCamera(centerCoordinate: center,
                                                   distance: walk.distance,
                                                   heading: heading,
                                                   pitch: walk.pitch))
            }
        }
    }

    /// 他者アバターの色（IDから決定的に色相を決める）
    static func avatarColor(for id: String) -> Color {
        var h: UInt64 = 5381
        for b in id.utf8 { h = h &* 33 &+ UInt64(b) }
        let hue = Double(h % 360) / 360.0
        return Color(hue: hue, saturation: 0.7, brightness: 0.85)
    }

    /// 天気トグルのアイコン（ON時は現在のエフェクトを表す）
    private var weatherIconName: String {
        switch weatherService.effect {
        case .rain: return "cloud.rain.fill"
        case .snow: return "snowflake"
        case .fog:  return "cloud.fog.fill"
        case .none: return "cloud.sun.fill"
        }
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

    // MARK: - 動くもの（リアルタイム）
    private var isMovingLayerOn: Bool { vehicleService.isEnabled || aircraftService.isEnabled }

    /// 動くもの表示の ON/OFF。バス（対応都市のみ）と飛行機（世界中）を同時に切り替える。
    /// カメラは動かさず、今見ている範囲で取得（移動は不要）。
    private func toggleVehicles() {
        if isMovingLayerOn {
            vehicleService.stop()
            aircraftService.stop()
        } else {
            vehicleService.start(region: viewModel.region)
            aircraftService.start(region: viewModel.region)
        }
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
            LinkedText(post.content)
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
                        LinkedText(reply.content)
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
    /// 球体・脚・パルスの基調色
    var accent: Color = Color(red: 0.13, green: 0.55, blue: 1.0)
    /// 球体の深い影色（グラデの最暗部）
    var deep: Color = Color(red: 0.0, green: 0.28, blue: 0.75)
    /// パルスリングを出すか（現在地=true / 検索ピン=false）
    var pulsing: Bool = true

    @State private var pulse = false

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
                            deep
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

            // 地面の影＋（現在地のみ）パルスリング
            ZStack {
                Ellipse()
                    .fill(.black.opacity(0.28))
                    .frame(width: 18, height: 6)
                    .blur(radius: 2)
                if pulsing {
                    Ellipse()
                        .stroke(accent.opacity(0.6), lineWidth: 2)
                        .frame(width: 16, height: 6)
                        .scaleEffect(pulse ? 2.6 : 1.0)
                        .opacity(pulse ? 0 : 0.7)
                }
            }
        }
        // 波紋だけをアニメーションする（withAnimation で包むとピンの位置更新まで巻き込まれて揺れる）
        .animation(pulsing ? .easeOut(duration: 1.8).repeatForever(autoreverses: false) : nil, value: pulse)
        .onAppear {
            guard pulsing else { return }
            pulse = true
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

/// 検索で立てるピンの情報
struct SearchedPlace: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let name: String
}

/// 場所検索シート。候補をタップすると座標と名称を onSelect で返す。
/// NavigationStack/.searchable は使わず、シンプルな自前レイアウトで状態の持ち越しを防ぐ。
struct PlaceSearchView: View {
    @StateObject private var model = PlaceSearchCompleter()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool
    var onSelect: (CLLocationCoordinate2D, String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 検索バー（虫眼鏡 + 入力 + クリア + 閉じる）
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("場所を検索", text: $model.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($fieldFocused)
                    .submitLabel(.search)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
                Button("閉じる") { dismiss() }
            }
            .padding()

            Divider()

            if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView("場所を検索", systemImage: "magnifyingglass",
                                       description: Text("地名・住所・施設名を入力してください"))
            } else if model.results.isEmpty {
                ContentUnavailableView.search(text: model.query)
            } else {
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
            }
        }
        .onAppear { fieldFocused = true }
    }

    /// 候補を実際の座標に解決して返す
    private func resolve(_ completion: MKLocalSearchCompletion) {
        let request = MKLocalSearch.Request(completion: completion)
        MKLocalSearch(request: request).start { response, _ in
            let item = response?.mapItems.first
            guard let coordinate = item?.placemark.coordinate else { return }
            let name = item?.name ?? completion.title
            onSelect(coordinate, name)
            dismiss()
        }
    }
}

#Preview {
    MapTimelineView()
        .environmentObject(LocationManager())
} 