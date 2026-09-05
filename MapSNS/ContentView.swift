//
//  ContentView.swift
//  MapSNS
//
//  Created by 大林恒心 on 2025/07/15.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var locationManager = LocationManager()
    @State private var showPermissionAlert = false

    @StateObject private var auth = AuthManager.shared

    /// 初回起動チュートリアルを見せたか
    @AppStorage("hasSeenTutorial") private var hasSeenTutorial = false
    @State private var showTutorial = false

    /// 地図を自分で触る時間をどれだけ取るか（チュートリアルを出すまでの待ち）
    private let tutorialDelaySeconds: Double = 15

    var body: some View {
        // ゲスト閲覧: 未ログインでも地図をそのまま見せる。
        // ログインを要求するのは書き込み操作の直前だけ（各画面が AuthPromptView を出す）。
        // サーバ側は /api/posts/global/ と /api/webcams/ が AllowAny なので匿名で取得できる。
        mainTabView
            .overlay {
                if showTutorial {
                    TutorialOverlay(isPresented: $showTutorial)
                }
            }
            .onChange(of: showTutorial) { showing in
                // チュートリアルを見終えてから位置情報を聞く。
                // 用途はチュートリアルで説明済みなので、独自の確認は挟まず OS のダイアログへ直行する。
                if !showing {
                    hasSeenTutorial = true
                    // 閉じるアニメーションが終わってから許可ダイアログを出す（畳みかけない）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        locationManager.requestPermission()
                    }
                }
            }
            .onAppear { autoLoginForScreenshotsIfNeeded() }
    }

    private func askLocationPermissionIfNeeded() {
        if locationManager.authorizationStatus == .notDetermined {
            showPermissionAlert = true
        }
    }

    /// スクリーンショット撮影用の自動ログイン（DEBUGビルド限定・環境変数があるときだけ動く。Releaseには含まれない）
    private func autoLoginForScreenshotsIfNeeded() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard !auth.isLoggedIn,
              let user = env["SCREENSHOT_USER"],
              let pass = env["SCREENSHOT_PASS"] else { return }
        AuthManager.shared.login(username: user, password: pass) { _ in }
        #endif
    }

    private var mainTabView: some View {
        TabView {
            MapTimelineView()
                .tabItem {
                    Label("タイムライン", systemImage: "map")
                }

            SettingsView()
                .tabItem {
                    Label("設定", systemImage: "gearshape")
                }
        }
        .environmentObject(locationManager)
        .onAppear {
            if !hasSeenTutorial {
                // すぐ被せない。まず地図そのものを自由に触ってもらい、
                // 「これは何だ」と思い始めた頃に説明を差し出す。
                DispatchQueue.main.asyncAfter(deadline: .now() + tutorialDelaySeconds) {
                    guard !hasSeenTutorial else { return }
                    withAnimation(.easeInOut(duration: 0.35)) { showTutorial = true }
                }
            } else {
                askLocationPermissionIfNeeded()
            }
        }
        .alert("地図上にコメントを配置するため、位置情報を使用します。同意いただける場合のみ位置情報を取得します。", isPresented: $showPermissionAlert, actions: {
            Button("許可") { locationManager.requestPermission() }
            Button("許可しない", role: .cancel) {}
        })
    }
}

#Preview {
    ContentView()
}
