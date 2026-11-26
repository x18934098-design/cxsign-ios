import Foundation

/// 复刻原版 `Lxh0;.g`（签到响应）/ `xh0.f`（状态判定）/ `xh0.m`（预判）的全部真值表。
///
/// 服务端返回的是纯文本，不是 JSON：
///   success / success2 / 您已签到过了 / 同一设备不允许重复签到 /
///   validate_xxx / errorLocation_xx / checkFace_xxx / 迟到或签到已结束 /
///   fail-need-qrcode / 签到失败，请重新扫描。
enum SignResponseParser {

    /// 原版 `Lxh0;.u` = Set{1,2,3,9}
    static let signedStatuses: Set<Int> = [1, 2, 3, 9]

    static let primaryStatusPattern = #""primaryAttend"\s*:\s*\{[^{}]*?"status"\s*:\s*(\d+)"#
    static let signStatusPattern = #"signstatus\s*=\s*(\d+)"#

    // MARK: - 状态判定（xh0.f）

    static func statusSigned(body: String) -> Bool {
        if let n = firstInt(pattern: primaryStatusPattern, in: body) {
            return signedStatuses.contains(n)
        }
        if let n = firstInt(pattern: signStatusPattern, in: body) {
            return signedStatuses.contains(n)
        }
        // 两套正则都未命中：原版会再扫描“未签到页面标记”，命中即视为未签到，
        // 一个标记都没有则按未签到处理。
        return false
    }

    // MARK: - 预判（xh0.m）

    static func predict(body: String) -> PredictResult {
        if body.contains("校验失败，未查询到活动数据") { return .noPermission }
        if body.contains("下次早点哦") { return .expired }
        return statusSigned(body: body) ? .signed : .notSigned
    }

    // MARK: - 签到结果（xh0.g）

    static func parse(body rawBody: String, httpStatus: Int) -> SignEvent {
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)

        if body.contains("[face]") {
            return .faceRequired("人脸验证失败: " + String(body.dropFirst("[face]".count)))
        }
        if body.contains("success2") { return .success(body) }
        if body.contains("fail-need-qrcode") || body.contains("签到失败，请重新扫描。") {
            return .qrCodeExpired
        }
        if body.hasPrefix("checkFace_") {
            return .faceRequired("人脸验证失败: " + String(body.dropFirst("checkFace_".count)))
        }
        if body.contains("errorLocation") {
            // 形如 errorLocation_123.4，取 "_" 之后作为距离（米）
            let tail = body.components(separatedBy: "_").last ?? ""
            return .wrongPosition(Float(tail) ?? 0)
        }
        if body.contains("您已签到过了") { return .alreadySigned }
        if body.contains("同一设备不允许重复签到") { return .deviceDuplicated }
        if body.hasPrefix("validate_") {
            return .validateRetry(String(body.dropFirst("validate_".count)))
        }
        if body.contains("success") { return .success(body) }
        if body.contains("迟到或签到已结束") { return .ended }
        if httpStatus == 302 && body.contains("校验失败，未查询到活动数据") {
            return .noPermission
        }
        if body.contains("下次早点哦") { return .expired }
        if body.contains("签到失败：服务端要求提交二维码参数（enc）") {
            return .qrCodeExpired
        }
        if body.isEmpty { return .failure("服务端返回空响应（HTTP \(httpStatus)）") }
        return .failure(body)
    }

    // MARK: - 工具

    private static func firstInt(pattern: String, in text: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }
}