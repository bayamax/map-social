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

    var body: some View {
        if auth.isLoggedIn {
            mainTabView
        } else {
            LoginView()
        }
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
            if locationManager.authorizationStatus == .notDetermined {
                showPermissionAlert = true
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
