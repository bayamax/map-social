//
//  MapSNSApp.swift
//  MapSNS
//
//  Created by 大林恒心 on 2025/07/15.
//

import SwiftUI

@main
struct MapSNSApp: App {
    @StateObject private var locationManager = LocationManager()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(locationManager)
        }
    }
}
