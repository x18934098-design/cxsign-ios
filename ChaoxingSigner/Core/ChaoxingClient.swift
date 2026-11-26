import Foundation

/// 一次签到所需的全部参数。字段顺序与原版 `Ljg0` 拼装顺序一致，
/// 调整顺序会改变 Query 串（服务端不敏感，但保持一致性便于抓包比对）。
struct SignRequest {
    var activeId: Int64
    var courseId: Int64 = 0
    var classId: Int = 0
    var uid: Int
    var fid: Int
    var name: String
    var deviceCode: String

    /// 二维码签到扫出的 enc
    var enc: String?
    /// 拍照签到服务端返回的 enc2
    var enc2: String?
    /// 服务端要求校验时回传的 validate
    var validate: String?
    /// 手势/签到码
    var signCode: String?
    /// 位置签到数据
    var location: SignLocation?
    /// 是否附带 locationResult（定位签到必须为 true）
    var sendLocationResult: Bool = true
}

final class ChaoxingClient {
    private let http = HTTPClient.shared
    private let vault = CookieVault.shared

    // MARK: - 登录

    /// POST https://passport2.chaoxing.com/fanyalogin
    /// body: fid / uname(AES) / password(AES) / refer / t=true / forbidotherlogin=0
    func login(account: Account) async throws -> Account {
        var account = account
        guard !account.phone.isEmpty else {
            throw ChaoxingError.loginFailed("请输入手机号")
        }
        let pwd = account.password
        guard !pwd.isEmpty else {
            throw ChaoxingError.passwordRule("密码不能为空")
        }
        guard pwd.count >= 8 && pwd.count <= 16 else {
            throw ChaoxingError.passwordRule("密码位数应该在8-16位")
        }

        await vault.clear()

        let encUser = try ChaoxingCrypto.aesEncryptBase64(account.phone)
        let encPwd = try ChaoxingCrypto.aesEncryptBase64(pwd)

        let form: [(String, String)] = [
            ("fid", String(account.fid)),
            ("uname", encUser),
            ("password", encPwd),
            ("refer", "https%3A%2F%2Fpassport2.chaoxing.com"),
            ("t", "true"),
            ("forbidotherlogin", "0")
        ]

        guard let url = URL(string: CX.fanyalogin) else {
            throw ChaoxingError.network("登录地址非法")
        }

        let resp = try await http.post(url, form: form,
                                       referer: "https://passport2.chaoxing.com/")

        let json = parseJSONObject(resp.text)
        let status = json?.bool("status") ?? false
        if !status {
            let msg = json?.str("msg") ?? (resp.text.isEmpty ? "账号或密码错误" : resp.text)
            throw ChaoxingError.loginFailed(msg)
        }

        // 登录成功即刻落 cookie，随后拉用户信息
        account.cookies = await vault.snapshot()
        account = try await refreshUserInfo(account: account)
        account.lastLoginAt = Date()
        account.cookies = await vault.snapshot()
        return account
    }

    /// GET https://sso.chaoxing.com/apis/login/userLogin4Uname.do
    /// 响应键：msg / name / puid / uid / fid / uname / pic / accountInfo / imAccount / password / clientId
    func refreshUserInfo(account: Account) async throws -> Account {
        var account = account
        guard let url = URL(string: CX.userInfo) else {
            throw ChaoxingError.network("用户信息地址非法")
        }
        let resp = try await http.get(url, referer: "https://passport2.chaoxing.com/")
        guard let root = parseJSONObject(resp.text) else {
            throw ChaoxingError.parse("获取用户信息失败")
        }
        // msg 既可能是对象，也可能是字符串
        let info = root.dict("msg") ?? root
        if let uid = info.int("uid"), uid > 0 {
            account.uid = uid
        } else {
            throw ChaoxingError.sessionOutdated
        }
        if let n = info.str("name") ?? info.str("uname") { account.userName = n }
        if let f = info.int("fid"), f > 0 { account.fid = f }
        if var pic = info.str("pic"), !pic.isEmpty {
            if pic.hasPrefix("http://") {
                pic = "https://" + String(pic.dropFirst("http://".count))
            }
            account.avatarURL = pic
        }
        account.lastLoginAt = Date()
        return account
    }

    /// 校验会话是否仍然有效（原版 `ChaoxingUserSessionOutdatedException`）
    func validateSession(account: Account) async -> Bool {
        guard account.uid > 0 else { return false }
        do {
            let fresh = try await refreshUserInfo(account: account)
            return fresh.uid == account.uid
        } catch {
            return false
        }
    }

    // MARK: - 活动列表

    /// GET .../v2/apis/active/student/activelist?fid=0&showNotStartedActive=0
    /// params: useragent / latitude=-1 / longitude / fid=0 / objectId
    func fetchActivities(account: Account, objectId: String = "") async throws -> [SignActivity] {
        guard var comps = URLComponents(string: CX.activeList) else {
            throw ChaoxingError.network("活动列表地址非法")
        }
        var q = [URLQueryItem(name: "useragent", value: HTTPClient.userAgent),
                 URLQueryItem(name: "latitude", value: "-1"),
                 URLQueryItem(name: "longitude", value: "-1"),
                 URLQueryItem(name: "fid", value: "0")]
        if !objectId.isEmpty { q.append(URLQueryItem(name: "objectId", value: objectId)) }
        comps.queryItems = (comps.queryItems ?? []) + q
        guard let url = comps.url else { throw ChaoxingError.network("活动列表地址非法") }

        let resp = try await http.get(url, referer: "https://mobilelearn.chaoxing.com/")
        guard let root = parseJSONObject(resp.text) else {
            throw ChaoxingError.parse("解析课程活动数据失败：\(resp.text.prefix(120))")
        }
        let data = root.dict("data") ?? root
        let list = data.array("activeList") ?? []
        return list.compactMap { item -> SignActivity? in
            guard let id = item.int64("id") else { return nil }
            return SignActivity(
                activeId: id,
                title: item.str("nameOne") ?? "未知活动",
                subtitle: item.str("nameFour") ?? "",
                courseId: item.int64("courseId") ?? 0,
                classId: item.int("classId") ?? 0,
                activeType: item.int("activeType") ?? 0,
                signType: item.int("type") ?? 0,
                startTime: item.int64("startTime") ?? 0,
                endTime: item.int64("endTime") ?? 0,
                userStatus: item.int("userStatus") ?? 0,
                status: item.int("status") ?? 0,
                otherId: item.str("otherId") ?? "",
                isLook: item.bool("isLook") ?? false
            )
        }
    }

    /// GET .../newsign/signDetail
    func fetchSignDetail(account: Account, activeId: Int64) async throws -> [String: Any] {
        var b = QueryBuilder(CX.signDetail)
        b.add("activeId", activeId)
        b.add("uid", account.uid)
        guard let url = b.url() else { throw ChaoxingError.network("签到详情地址非法") }
        let resp = try await http.get(url, referer: "https://mobilelearn.chaoxing.com/")
        return parseJSONObject(resp.text) ?? ["raw": resp.text]
    }

    // MARK: - 预判（原版 `xh0.e` + `xh0.f` + `xh0.m`）

    /// GET https://data-xxt.aichaoxing.com/newsign/preSign
    /// courseId / classId / activePrimaryId / general=1 / sys=1 / ls=1 / appType=15 / uid / isTeacherViewOpen=0
    func preSignURL(account: Account, activeId: Int64, courseId: Int64, classId: Int) -> URL? {
        var b = QueryBuilder(CX.preSign)
        b.add("courseId", courseId)
        b.add("classId", String(classId))
        b.add("activePrimaryId", String(activeId))
        b.add("general", "1")
        b.add("sys", "1")
        b.add("ls", "1")
        b.add("appType", "15")
        b.add("uid", account.uid)
        b.add("isTeacherViewOpen", "0")
        return b.url()
    }

    /// Referer 兜底：原版 `xh0.k` 会把 data-xxt 域名换成 mobilelearn 域名
    func refererURL(account: Account, activeId: Int64, courseId: Int64, classId: Int) -> String {
        guard let url = preSignURL(account: account, activeId: activeId,
                                   courseId: courseId, classId: classId) else {
            return "https://mobilelearn.chaoxing.com/"
        }
        var s = url.absoluteString
        if s.contains("data-xxt.aichaoxing.com") {
            s = s.replacingOccurrences(of: "data-xxt.aichaoxing.com", with: "mobilelearn.chaoxing.com")
        }
        return s
    }

    func predict(account: Account, activeId: Int64, courseId: Int64, classId: Int) async -> PredictResult {
        guard let url = preSignURL(account: account, activeId: activeId,
                                   courseId: courseId, classId: classId) else {
            return .noPermission
        }
        do {
            let resp = try await http.get(url, referer: refererURL(account: account, activeId: activeId,
                                                                  courseId: courseId, classId: classId))
            return SignResponseParser.predict(body: resp.text)
        } catch {
            return .notSigned
        }
    }

    // MARK: - 签到

    /// GET https://mobilelearn.chaoxing.com/pptSign/stuSignajax
    /// 参数顺序：enc? / name / activeId / uid / clientip / location? / latitude=-1 /
    ///          longitude=-1 / fid / appType=15 / deviceCode / vpProbability=-1 /
    ///          vpStrategy / signCode? / enc2? / validate? / locationResult?
    func signURL(account: Account, request req: SignRequest) -> URL? {
        var b = QueryBuilder(CX.pptStuSignajax)
        b.add("enc", req.enc)
        b.add("name", req.name)
        b.add("activeId", String(req.activeId))
        b.add("uid", req.uid)
        b.add("clientip", "")
        if let loc = req.location {
            b.add("location", loc.queryValue())
        }
        b.add("latitude", "-1")
        b.add("longitude", "-1")
        b.add("fid", String(req.fid))
        b.add("appType", "15")
        b.add("deviceCode", req.deviceCode)
        b.add("vpProbability", "-1")
        b.add("vpStrategy", "")
        b.add("signCode", req.signCode)
        b.add("enc2", req.enc2)
        b.add("validate", req.validate)
        if let loc = req.location, req.sendLocationResult {
            b.add("locationResult", loc.queryValue())
        }
        return b.url()
    }

    /// 真正的签到请求。返回原始响应，交给 `SignResponseParser` 判定。
    func performSign(account: Account, request req: SignRequest) async throws -> HTTPClient.Response {
        guard let url = signURL(account: account, request: req) else {
            throw ChaoxingError.network("签到地址非法")
        }
        let referer = refererURL(account: account, activeId: req.activeId,
                                 courseId: req.courseId, classId: req.classId)
        return try await http.get(url, referer: referer, headers: [
            "X-Requested-With": "XMLHttpRequest"
        ])
    }

    /// 预检探针（原版 `xh0.d`）：命中「您已签到过了」即可提前结束
    func probeSign(account: Account, activeId: Int64, courseId: Int64, classId: Int) async -> Bool {
        var b = QueryBuilder(CX.stuSignajax)
        b.add("activeId", String(activeId))
        b.add("uid", account.uid)
        b.add("clientip", "")
        if courseId > 0 { b.add("courseId", courseId) }
        if classId > 0 { b.add("classId", String(classId)) }
        guard let url = b.url() else { return false }
        do {
            let resp = try await http.get(url, referer: refererURL(account: account, activeId: activeId,
                                                                  courseId: courseId, classId: classId))
            return SignResponseParser.statusSigned(body: resp.text)
        } catch {
            return false
        }
    }

    // MARK: - 验证码

    /// 原版流程：`xh0.q` 取 conf → 用户滑动 → `captcha/check/verification/result`
    /// 返回 (captchaId, imageBase64 或 nil)
    func captchaChallenge(token: String?) async throws -> (captchaId: String, imageBase64: String?) {
        var b = QueryBuilder(CX.captchaConf)
        b.add("v", "1.1.20")
        b.add("token", token ?? "")
        guard let url = b.url() else { throw ChaoxingError.network("验证码地址非法") }
        let conf = try await http.get(url, referer: "https://mobilelearn.chaoxing.com/")
        let json = parseJSONObject(conf.text)
        let cid = json?.dict("data")?.str("captchaId") ?? json?.str("captchaId") ?? ""
        guard !cid.isEmpty else { throw ChaoxingError.parse("验证码配置获取失败") }

        var ib = QueryBuilder(CX.captchaImage)
        ib.add("captchaId", cid)
        ib.add("type", json?.dict("data")?.str("type") ?? "slide")
        guard let iurl = ib.url() else { throw ChaoxingError.network("验证码图片地址非法") }
        let img = try await http.get(iurl, referer: "https://mobilelearn.chaoxing.com/")
        let imgJson = parseJSONObject(img.text)
        let base64 = imgJson?.dict("data")?.str("image") ?? imgJson?.str("image")
        return (cid, base64)
    }

    /// 提交滑块距离，返回可回填到签到请求 `validate` 参数的值
    func captchaValidate(captchaId: String, offset: Double) async throws -> String {
        var b = QueryBuilder(CX.captchaResult)
        b.add("captchaId", captchaId)
        b.add("offset", String(format: "%.0f", offset))
        guard let url = b.url() else { throw ChaoxingError.network("验证码地址非法") }
        let resp = try await http.get(url, referer: "https://mobilelearn.chaoxing.com/")
        let json = parseJSONObject(resp.text)
        if let v = json?.dict("data")?.str("validate") ?? json?.str("validate"), !v.isEmpty {
            return v
        }
        throw ChaoxingError.parse("验证码校验未通过")
    }
}