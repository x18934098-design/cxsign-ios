import Foundation

// MARK: - 保序查询串构造（等价于原版 okhttp HttpUrl.Builder）

struct QueryBuilder {
    private let base: String
    private var items: [(String, String)] = []

    init(_ base: String) { self.base = base }

    /// 仅在 value 非 nil 时追加，保持与 APK 相同的参数顺序
    @discardableResult
    mutating func add(_ name: String, _ value: String?) -> QueryBuilder {
        if let value { items.append((name, value)) }
        return self
    }

    @discardableResult
    mutating func add(_ name: String, _ value: Int) -> QueryBuilder {
        items.append((name, String(value)))
    }

    @discardableResult
    mutating func add(_ name: String, _ value: Int64) -> QueryBuilder {
        items.append((name, String(value)))
    }

    /// 原版 `xh0.k` 的 Referer 兜底：data-xxt 域被替换成 mobilelearn
    func url() -> URL? {
        var s = base
        var parts: [String] = []
        for (k, v) in items {
            parts.append("\(QueryBuilder.encode(k))=\(QueryBuilder.encode(v))")
        }
        if !parts.isEmpty {
            s += (s.contains("?") ? "&" : "?") + parts.joined(separator: "&")
        }
        return URL(string: s)
    }

    static func encode(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }
}

// MARK: - Cookie 保管

/// 多账号切换时需要把 `HTTPCookieStorage.shared` 的内容整体换入换出。
/// 所有访问都串行化，避免两条签到流程互相污染会话。
actor CookieVault {
    static let shared = CookieVault()

    private let storage = HTTPCookieStorage.shared

    func snapshot() -> [StoredCookie] {
        (storage.cookies ?? []).map {
            StoredCookie(name: $0.name,
                         value: $0.value,
                         domain: $0.domain,
                         path: $0.path,
                         expires: $0.expiresDate)
        }
    }

    func install(_ cookies: [StoredCookie]) {
        storage.removeCookies(since: .distantPast)
        for c in cookies where !c.isExpired {
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: c.name,
                .value: c.value,
                .domain: c.domain,
                .path: c.path.isEmpty ? "/" : c.path
            ]
            if let e = c.expires { props[.expires] = e }
            if let cookie = HTTPCookie(properties: props) {
                storage.setCookie(cookie)
            }
        }
    }

    func clear() {
        storage.removeCookies(since: .distantPast)
    }

    func merged(with fresh: [StoredCookie]) -> [StoredCookie] {
        var map: [String: StoredCookie] = [:]
        for c in fresh { map["\(c.domain)|\(c.name)"] = c }
        for c in snapshot() { map["\(c.domain)|\(c.name)"] = c }
        return Array(map.values).filter { !$0.isExpired }
    }
}

// MARK: - 网络

final class HTTPClient {
    static let shared = HTTPClient()

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 40
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = [
            "User-Agent": HTTPClient.userAgent
        ]
        session = URLSession(configuration: cfg)
    }

    /// 学习通 App 的 UA，服务端会据此返回移动端签到页
    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Mobile/15E148 ChaoXingStudy/ChaoxingMobile"

    struct Response {
        var data: Data
        var status: Int
        var headers: [AnyHashable: Any]

        var text: String {
            if let s = String(data: data, encoding: .utf8) { return s }
            // 学习通偶尔返回 GB18030
            let gb = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
            return String(decoding: data, as: UTF8.self)
        }

        var finalURL: String { (headers["url"] as? URL)?.absoluteString ?? "" }
    }

    func get(_ url: URL, referer: String? = nil, headers: [String: String] = [:]) async throws -> Response {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return try await send(req, referer: referer, headers: headers)
    }

    func post(_ url: URL, form: [(String, String)], referer: String? = nil,
              headers: [String: String] = [:]) async throws -> Response {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                     forHTTPHeaderField: "Content-Type")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let body = form.map { "\(QueryBuilder.encode($0.0))=\(QueryBuilder.encode($0.1))" }
                       .joined(separator: "&")
        req.httpBody = body.data(using: .utf8)
        return try await send(req, referer: referer, headers: headers)
    }

    private func send(_ request: URLRequest, referer: String?,
                      headers: [String: String]) async throws -> Response {
        var req = request
        if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw ChaoxingError.network("响应格式异常")
            }
            var hs = http.allHeaderFields
            hs["url"] = http.url
            return Response(data: data, status: http.statusCode, headers: hs)
        } catch let e as ChaoxingError {
            throw e
        } catch {
            throw ChaoxingError.network(error.localizedDescription)
        }
    }
}

// MARK: - JSON 宽松读取

extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) -> Int? {
        if let v = self[key] as? Int { return v }
        if let v = self[key] as? Int64 { return Int(v) }
        if let v = self[key] as? Double { return Int(v) }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }

    func int64(_ key: String) -> Int64? {
        if let v = self[key] as? Int64 { return v }
        if let v = self[key] as? Int { return Int64(v) }
        if let v = self[key] as? Double { return Int64(v) }
        if let s = self[key] as? String { return Int64(s) }
        return nil
    }

    func str(_ key: String) -> String? {
        if let s = self[key] as? String { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let b = self[key] as? Bool { return b }
        if let n = self[key] as? NSNumber { return n.boolValue }
        if let s = self[key] as? String { return s == "true" || s == "1" }
        return nil
    }

    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func array(_ key: String) -> [[String: Any]]? { self[key] as? [[String: Any]] }
}

func parseJSONObject(_ text: String) -> [String: Any]? {
    var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // 去掉 JSONP 包装：cx_captcha_function({...})
    if let lp = s.firstIndex(of: "("), let rp = s.lastIndex(of: ")"), lp < rp {
        let inner = s[s.index(after: lp)..<rp]
        if inner.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
            s = String(inner)
        }
    }
    guard let data = s.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}