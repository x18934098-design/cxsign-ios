import Foundation

struct SignOptions {
    /// 手势码 / 签到码（对应 signCode 参数）
    var signCode: String?
    /// 二维码扫出的 enc
    var qrEnc: String?
    /// 拍照签到服务端给出的 enc2
    var photoEnc2: String?
    /// 是否附带定位（位置签到必须）
    var useLocation: Bool = false
    /// 服务端要求的 validate（内部重试时自动回填）
    var validate: String?
}

struct SignLogEntry: Identifiable, Equatable {
    let id = UUID()
    var at: Date = Date()
    var account: String
    var activity: String
    var message: String
    var success: Bool
}

/// 签到编排器：把 APK 里 `Ljg0` / `Lhh0` / `xh0.*` 的流程按顺序拼起来。
@MainActor
final class SignCoordinator: ObservableObject {
    @Published private(set) var logs: [SignLogEntry] = []
    @Published private(set) var running = false

    private let client = ChaoxingClient()
    private let vault = CookieVault.shared
    private var timerTask: Task<Void, Never>?

    func append(_ entry: SignLogEntry) {
        logs.insert(entry, at: 0)
        if logs.count > 200 { logs.removeLast(logs.count - 200) }
    }

    // MARK: - 单次签到

    func sign(account original: Account,
              activity: SignActivity,
              options: SignOptions,
              location: SignLocation?,
              nameOverride: String = "") async -> SignOutcome {

        var account = original
        await vault.install(account.cookies)

        // 会话可能已过期：先确认，必要时用本地保存的凭据重登
        if account.uid == 0 {
            return SignOutcome(event: .failure("账号未登录"), rawBody: "", httpStatus: 0, attempts: 0)
        }

        // ① 活动已经是“已签到”状态，直接返回
        if activity.signed {
            return SignOutcome(event: .alreadySigned, rawBody: "", httpStatus: 0, attempts: 0)
        }

        // ② 预判：preSign 页面里的 primaryAttend.status / signstatus
        let predicted = await client.predict(account: account,
                                            activeId: activity.activeId,
                                            courseId: activity.courseId,
                                            classId: activity.classId)
        switch predicted {
        case .signed:
            return SignOutcome(event: .predictedAlreadySigned, rawBody: "", httpStatus: 0, attempts: 0)
        case .expired:
            return SignOutcome(event: .expired, rawBody: "", httpStatus: 0, attempts: 0)
        case .noPermission:
            return SignOutcome(event: .noPermission, rawBody: "", httpStatus: 0, attempts: 0)
        case .notSigned:
            break
        }

        let displayName = nameOverride.isEmpty ? account.userName : nameOverride

        var request = SignRequest(
            activeId: activity.activeId,
            courseId: activity.courseId,
            classId: activity.classId,
            uid: account.uid,
            fid: account.fid,
            name: displayName,
            deviceCode: account.deviceCode
        )
        request.enc = options.qrEnc
        request.enc2 = options.photoEnc2
        request.validate = options.validate
        request.signCode = options.signCode
        request.location = options.useLocation ? location : nil
        request.sendLocationResult = options.useLocation

        var attempts = 0
        var lastRaw = ""
        var lastStatus = 0

        // ③ 服务端可能返回 validate_xxx，要求带校验串重试（最多 3 次）
        while attempts < 3 {
            attempts += 1
            do {
                let resp = try await client.performSign(account: account, request: request)
                lastRaw = resp.text
                lastStatus = resp.status
                let event = SignResponseParser.parse(body: resp.text, httpStatus: resp.status)

                switch event {
                case .validateRetry(let token):
                    request.validate = token
                    continue
                case .captchaRequired:
                    account.cookies = await vault.snapshot()
                    return SignOutcome(event: .captchaRequired, rawBody: lastRaw,
                                       httpStatus: lastStatus, attempts: attempts)
                default:
                    account.cookies = await vault.snapshot()
                    append(SignLogEntry(account: account.displayName,
                                        activity: activity.title,
                                        message: Self.describe(event),
                                        success: event.isSuccess))
                    return SignOutcome(event: event, rawBody: lastRaw,
                                       httpStatus: lastStatus, attempts: attempts)
                }
            } catch let e as ChaoxingError {
                return SignOutcome(event: .failure(e.localizedDescription),
                                   rawBody: lastRaw, httpStatus: lastStatus, attempts: attempts)
            } catch {
                return SignOutcome(event: .failure(error.localizedDescription),
                                   rawBody: lastRaw, httpStatus: lastStatus, attempts: attempts)
            }
        }

        let final = SignResponseParser.parse(body: lastRaw, httpStatus: lastStatus)
        return SignOutcome(event: final, rawBody: lastRaw, httpStatus: lastStatus, attempts: attempts)
    }

    /// 用探针方式预检（对应原版 `xh0.d` + `xh0.g`）
    func probe(account: Account, activity: SignActivity) async -> Bool {
        await vault.install(account.cookies)
        return await client.probeSign(account: account,
                                      activeId: activity.activeId,
                                      courseId: activity.courseId,
                                      classId: activity.classId)
    }

    // MARK: - 自动签到

    func startAutoSign(store: AccountStore, location: @escaping @MainActor () -> SignLocation?) {
        timerTask?.cancel()
        guard store.autoSignEnabled else { return }
        let interval = UInt64(max(30, store.pollIntervalSeconds)) * 1_000_000_000
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runAutoSignPass(store: store, location: location)
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func stopAutoSign() {
        timerTask?.cancel()
        timerTask = nil
    }

    func runAutoSignPass(store: AccountStore, location: @escaping @MainActor () -> SignLocation?) async {
        guard !running else { return }
        running = true
        defer { running = false }

        for account in store.activeAccounts {
            var acct = account
            await vault.install(acct.cookies)

            let valid = await client.validateSession(account: acct)
            if !valid {
                if acct.password.isEmpty {
                    append(SignLogEntry(account: acct.displayName, activity: "-",
                                        message: "会话已失效，请重新登录", success: false))
                    continue
                }
                do {
                    acct = try await client.login(account: acct)
                    store.upsert(acct)
                } catch {
                    append(SignLogEntry(account: acct.displayName, activity: "-",
                                        message: error.localizedDescription, success: false))
                    continue
                }
            }

            do {
                let activities = try await client.fetchActivities(account: acct)
                acct.cookies = await vault.snapshot()
                store.upsert(acct)

                for act in activities where !act.signed {
                    guard act.endDate > Date() else { continue }
                    var opts = SignOptions()
                    opts.useLocation = (act.signType == SignType.location.rawValue)
                    let loc = opts.useLocation ? location() : nil
                    let outcome = await sign(account: acct, activity: act, options: opts,
                                             location: loc, nameOverride: store.nameOverride)
                    if outcome.event.isSuccess {
                        append(SignLogEntry(account: acct.displayName, activity: act.title,
                                            message: "自动签到成功", success: true))
                    }
                }
            } catch {
                append(SignLogEntry(account: acct.displayName, activity: "-",
                                    message: error.localizedDescription, success: false))
            }
        }
    }

    // MARK: - 文案

    static func describe(_ event: SignEvent) -> String {
        switch event {
        case .success(let raw):        return "签到成功（\(raw)）"
        case .alreadySigned:           return "已经签到过了"
        case .predictedAlreadySigned:  return "预判：已签到，无需重复提交"
        case .deviceDuplicated:        return "同一设备不允许重复签到，请在设置里换一个设备码"
        case .noPermission:            return "没有该活动权限（校验失败，未查询到活动数据）"
        case .ended:                   return "迟到或签到已结束"
        case .expired:                 return "签到已截止（下次早点哦）"
        case .qrCodeExpired:           return "二维码已过期，请重新扫描"
        case .wrongPosition(let d):    return "位置错误，距离签到点约 \(Int(d)) 米"
        case .validateRetry:           return "服务端要求校验，已重试"
        case .faceRequired(let m):     return "需要人脸验证：\(m)"
        case .captchaRequired:         return "需要滑块验证码"
        case .failure(let m):          return "签到失败：\(m)"
        }
    }
}