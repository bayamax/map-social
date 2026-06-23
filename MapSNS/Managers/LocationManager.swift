import Foundation
import CoreLocation
import Combine
import SwiftUI

/// 位置情報管理クラス
class LocationManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var lastLocation: CLLocation?
    
    // MARK: - Private
    private let locationManager = CLLocationManager()
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Init
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        authorizationStatus = locationManager.authorizationStatus
        print("[LocationManager] 初期化完了 現在の認可ステータス: \(authorizationStatus.rawValue)")
    }
    
    // MARK: - Permission Handling
    func requestPermission() {
        print("[LocationManager] requestPermission 呼び出し 現在の認可ステータス: \(authorizationStatus.rawValue)")
        switch authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            print("[LocationManager] まだ未決定なので requestWhenInUseAuthorization を実行")
        case .denied, .restricted:
            // ユーザーが拒否した場合は設定アプリへ誘導
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
            }
            print("[LocationManager] 権限が拒否/制限状態です。設定アプリへリダイレクトしました")
        default:
            break
        }
    }
    
    func startUpdatingLocation() {
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            print("[LocationManager] startUpdatingLocation を開始します")
            locationManager.startUpdatingLocation()
        } else {
            print("[LocationManager] 権限不足のため startUpdatingLocation は開始されません")
        }
    }
    
    func stopUpdatingLocation() {
        print("[LocationManager] stopUpdatingLocation 呼び出し")
        locationManager.stopUpdatingLocation()
    }
}

// MARK: - CLLocationManagerDelegate
extension LocationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        print("[LocationManager] locationManagerDidChangeAuthorization ステータス更新: \(manager.authorizationStatus.rawValue)")
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            startUpdatingLocation()
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        print("[LocationManager] didUpdateLocations 取得: \(location.coordinate.latitude), \(location.coordinate.longitude)")
        lastLocation = location
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location update error: \(error.localizedDescription)")
    }
} 