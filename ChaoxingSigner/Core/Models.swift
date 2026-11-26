import Foundation

// MARK: - 账号

struct Account: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var fid: Int = -1
    var phone: String = ""
    /// 仅本机保存，用于会话失效后自动重登
    var password: String = ""
    var uid: Int = 0
    var userName: String = ""
    var schoolName: String = ""
    var avatarURL: String = ""
    /// 每账号独立的设备码，对应原版 `Lde0;.e` / deviceCode
    var deviceCode: String = DeviceIdentity.makeCode()
    var lastLoginAt: Date?
    var cookies: [StoredCookie] = []
    var enabled: Bool = true

    var isLoggedIn: Bool { uid > 0 && !cookies.isEmpty }

    var displayName: String {
        if !userName.isEmpty { return userName }
        return phone.isEmpty ? "未登录" : phone
    }
}

struct StoredCookie: Codable, Equatable, Hashable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Date?

    var isExpired: Bool {
        if let expires { return expires < Date() }
        return false
    }
}

// MARK: - 活动

struct SignActivity: Identifiable, Codable, Equatable {
    var activeId: Int64
    /// 原版字段名：nameOne
    var title: String
    /// 原版字段名：nameFour（副标题，常为教师/班级）
    var subtitle: String
    var courseId: Int64
    var classId: Int
    var activeType: Int
    var signType: Int
    var startTime: Int64
    var endTime: Int64
    /// 0 未签 / 1 已签（原版 userStatus）
    var userStatus: Int
    var status: Int
    var otherId: String
    var isLook: Bool

    var id: Int64 { activeId }

    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(startTime) / 1000) }
    var endDate: Date { Date(timeIntervalSince1970: TimeInterval(endTime) / 1000) }
    var signed: Bool { userStatus == 1 }

    var ended: Bool { endDate < Date() }

    /// 原版 `ChaoxingSignActivityEntity.signType` 名称映射（签到类型）
    var signTypeName: String {
        switch signType {
        case 0: return "普通签到"
        case 1: return "手势签到"
        case 2: return "位置签到"
        case 3: return "二维码签到"
        case 4: return "拍照签到"
        case 5: return "签到码签到"
        default: return "签到(\(signType))"
        }
    }
}

// MARK: - 签到结果

enum SignEvent: Equatable {
    case success(String)
    case alreadySigned
    case predictedAlreadySigned
    case deviceDuplicated
    case noPermission
    case ended
    case expired
    case qrCodeExpired
    case wrongPosition(Float)
    /// 服务端要求带 validate 重试（`validate_xxx`）
    case validateRetry(String)
    case faceRequired(String)
    case captchaRequired
    case failure(String)

    var isSuccess: Bool {
        switch self {
        case .success, .validateRetry: return true
        default: return false
        }
    }
}

struct SignOutcome {
    var event: SignEvent
    var rawBody: String
    var httpStatus: Int
    var attempts: Int
    var finishedAt: Date = Date()
}

// MARK: - 错误

enum ChaoxingError: LocalizedError {
    case notLoggedIn
    case sessionOutdated
    case loginFailed(String)
    case passwordRule(String)
    case network(String)
    case parse(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:      return "请先登录学习通账号"
        case .sessionOutdated:  return "登录会话已失效，请重新登录"
        case .loginFailed(let m): return "登录失败：\(m)"
        case .passwordRule(let m): return m
        case .network(let m):   return "网络异常：\(m)"
        case .parse(let m):     return "解析数据失败：\(m)"
        case .unsupported(let m): return "不支持的操作：\(m)"
        }
    }
}

// MARK: - 定位数据（对应原版 `Lxh0;.c` 生成的 JSON）

struct SignLocation: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var address: String
    /// 原版 mockData 开关（随机化定位策略）
    var useMockData: Bool = false

    /// 复刻 `xh0.c`：先 String(format:"%.6f") 再 parseDouble，因此尾零会被丢弃
    private static func rounded(_ v: Double) -> Double {
        Double(String(format: "%.6f", v)) ?? v
    }

    func queryValue() -> String {
        // 手工拼装以严格匹配字段顺序：result, latitude, longitude, address[, mockData]
        let quote = "\""
        let escapedAddress = address
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: quote, with: "\\" + quote)
        let mockField = "\"mockData\":\"{\\\"strategy\\\":0,\\\"probability\\\":-1}\""

        var parts: [String] = []
        parts.append("\"result\":1")
        parts.append("\"latitude\":\(Self.rounded(latitude))")
        parts.append("\"longitude\":\(Self.rounded(longitude))")
        parts.append("\"address\":\"" + escapedAddress + "\"")
        if useMockData { parts.append(mockField) }
        return "{" + parts.joined(separator: ",") + "}"
    }
}