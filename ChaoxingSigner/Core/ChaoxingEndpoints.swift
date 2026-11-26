import Foundation

/// 全部接口地址取自 APK 字符串常量（类 `Lxh0;.<clinit>` / `Lqd0;.<clinit>`）
enum CX {
    static let preSign        = "https://data-xxt.aichaoxing.com/newsign/preSign"
    static let pptActiveInfo  = "https://mobilelearn.chaoxing.com/v2/apis/active/getPPTActiveInfo"
    static let analysis       = "https://mobilelearn.chaoxing.com/pptSign/analysis?vs=1&DB_STRATEGY=RANDOM"
    static let analysis2       = "https://mobilelearn.chaoxing.com/pptSign/analysis2?DB_STRATEGY=RANDOM"
    static let preStuSign     = "https://mobilelearn.chaoxing.com/sign/preStuSign"
    static let stuSignajax    = "https://mobilelearn.chaoxing.com/sign/stuSignajax"
    static let pptStuSignajax = "https://mobilelearn.chaoxing.com/pptSign/stuSignajax"
    static let signDetail     = "https://mobilelearn.chaoxing.com/newsign/signDetail"

    static let activeList     = "https://mobilelearn.chaoxing.com/v2/apis/active/student/activelist?fid=0&showNotStartedActive=0"

    static let fanyalogin     = "https://passport2.chaoxing.com/fanyalogin"
    static let fanyaloginAlt  = "https://chaoxing.com/fanyalogin"
    static let userInfo       = "https://sso.chaoxing.com/apis/login/userLogin4Uname.do"

    static let captchaConf    = "https://captcha.chaoxing.com/captcha/get/conf?callback=cx_captcha_function"
    static let captchaResult  = "https://captcha.chaoxing.com/captcha/check/verification/result?callback=cx_captcha_function"
    static let captchaImage   = "https://captcha.chaoxing.com/captcha/get/verification/image"
}

/// 签到类型（原版 `Lxh0;.u` 只把 1/2/3/9 视为“已签到”状态值，
/// 这里的 signType 是活动类型字段，两者不同，注意区分）
enum SignType: Int {
    case normal = 0
    case gesture = 1
    case location = 2
    case qrCode = 3
    case photo = 4
    case code = 5
}

/// 预判结果（原版 `xh0.m` 返回的 `Lzg0` 枚举）
enum PredictResult {
    case notSigned
    case signed
    case expired
    case noPermission
}