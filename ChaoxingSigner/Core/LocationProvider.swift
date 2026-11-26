import Foundation
import CoreLocation

/// 定位来源：真实 GPS / 手动伪造坐标（原版对应 `Lgf0;` 那套 Baidu 定位封装）
@MainActor
final class LocationProvider: NSObject, ObservableObject {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case real, manual
        var id: String { rawValue }
        var title: String { self == .real ? "真实定位" : "手动坐标" }
    }

    @Published var mode: Mode = .real {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "loc.mode") }
    }
    @Published var currentLatitude: Double = 0
    @Published var currentLongitude: Double = 0
    @Published var address: String = ""
    @Published var authorizationDenied = false

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        if let raw = UserDefaults.standard.string(forKey: "loc.mode"),
           let m = Mode(rawValue: raw) {
            mode = m
        }
        currentLatitude = UserDefaults.standard.double(forKey: "loc.lat")
        currentLongitude = UserDefaults.standard.double(forKey: "loc.lng")
        address = UserDefaults.standard.string(forKey: "loc.addr") ?? ""
    }

    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            authorizationDenied = true
        default:
            manager.startUpdatingLocation()
        }
    }

    func refresh() {
        if mode == .real {
            requestPermission()
            manager.startUpdatingLocation()
        }
    }

    /// 生成签到用的定位对象；返回 nil 表示当前没有可用坐标
    func snapshot(useMockData: Bool) -> SignLocation? {
        let lat = mode == .real ? currentLatitude : UserDefaults.standard.double(forKey: "loc.lat")
        let lng = mode == .real ? currentLongitude : UserDefaults.standard.double(forKey: "loc.lng")
        guard lat != 0 || lng != 0 else { return nil }
        let addr = mode == .real ? address : (UserDefaults.standard.string(forKey: "loc.addr") ?? address)
        return SignLocation(latitude: lat, longitude: lng, address: addr, useMockData: useMockData)
    }

    func setManual(latitude: Double, longitude: Double, address: String) {
        UserDefaults.standard.set(latitude, forKey: "loc.lat")
        UserDefaults.standard.set(longitude, forKey: "loc.lng")
        UserDefaults.standard.set(address, forKey: "loc.addr")
        currentLatitude = latitude
        currentLongitude = longitude
        self.address = address
    }

    private func persist(_ loc: CLLocation) {
        currentLatitude = loc.coordinate.latitude
        currentLongitude = loc.coordinate.longitude
        UserDefaults.standard.set(currentLatitude, forKey: "loc.lat")
        UserDefaults.standard.set(currentLongitude, forKey: "loc.lng")
        geocoder.reverseGeocodeLocation(loc) { [weak self] marks, _ in
            guard let self, let m = marks?.first else { return }
            let text = [m.name, m.thoroughfare, m.subLocality]
                .compactMap { $0 }
                .joined(separator: "")
            Task { @MainActor in
                if !text.isEmpty {
                    self.address = text
                    UserDefaults.standard.set(text, forKey: "loc.addr")
                }
            }
        }
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.persist(loc) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.authorizationDenied = false
                manager.startUpdatingLocation()
            case .denied, .restricted:
                self.authorizationDenied = true
            default:
                break
            }
        }
    }
}