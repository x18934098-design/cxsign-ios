import Foundation

enum DeviceIdentity {
    /// 对应原版 `Lde0;.e` / deviceCode：每账号一个稳定随机标识。
    /// 学习通对同一 deviceCode 重复签到会返回「同一设备不允许重复签到」，
    /// 因此新增账号时重新生成即可规避。
    static func makeCode() -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(hex.prefix(24))
    }
}