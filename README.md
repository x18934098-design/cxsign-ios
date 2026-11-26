# 随地大小签 · ChaoxingSigner for iOS

`ChaoxingSignFaker` 1.20.0-stable-261120（`org.aquamarine5.brainspark.chaoxingsignfaker`）的 iOS 复刻实现。
纯 SwiftUI，iOS 17+，零第三方依赖，可直接用 Xcode 打开构建。

逆向过程与结论见下文「逆向结论」，与源码一一对应；关键常量在 `Core/` 里都加了指向原 APK 方法名的注释。

---

## 一、逆向结论

### 1. 混淆结构

APK 是 Kotlin Multiplatform + Compose，业务代码被 R8 压成短类名，只能靠字符串/字段交叉引用定位：

| 混淆名 | 实际职责 |
| --- | --- |
| `Lmd0;` | 登录、AES 加解密、学校列表、会话流转 |
| `Lqd0;` | 全局会话单例（登录 URL 常量在其 `<clinit>`） |
| `Lde0;` | 请求上下文：`b`/`c` 用户名、`d` uid、`e` deviceCode、`i` fid、`f` 代签会话 |
| `Lxh0;` | 所有 URL 常量 + 签到请求构造 + 响应真值判定（`a`~`r` 全部方法） |
| `Ljg0` | 签到主协程（两步：探针 + 正式提交） |
| `Lhh0` | 签到类型分发（拍照 / 位置 / 二维码 / 其它） |
| `Lf90` | 带定位的签到变体 |
| `La00` | 活动列表拉取与解析 |
| `Lgd0` | 登录协程体（fanyalogin → userLogin4Uname.do） |

### 2. 加密

- 算法：`AES/CBC/PKCS5Padding`
- key = IV = `u2oh6Vu^HWe4_AES`（16 字节 ASCII，见 `Lmd0;.b`）
- 输出：`Base64.getEncoder().encodeToString`
- 用途：登录表单的 `uname`（手机号）与 `password`
- 密码长度校验：8–16 位，否则抛 `ChaoxingLoginException`（`Lmd0;.a`）

iOS 实现在 `Core/Crypto.swift`（CommonCrypto `CCCrypt`，`kCCOptionPKCS7Padding`）。

### 3. 接口表

| 用途 | 方法与地址 | 关键参数 |
| --- | --- | --- |
| 登录 | POST `https://passport2.chaoxing.com/fanyalogin` | `fid`、`uname`(AES)、`password`(AES)、`refer=https%3A%2F%2Fpassport2.chaoxing.com`、`t=true`、`forbidotherlogin=0` |
| 用户信息 | GET `https://sso.chaoxing.com/apis/login/userLogin4Uname.do` | 解析 `msg.{uid,name,uname,fid,pic,...}` |
| 活动列表 | GET `https://mobilelearn.chaoxing.com/v2/apis/active/student/activelist` | `useragent`、`latitude=-1`、`longitude=-1`、`fid=0`、`objectId` |
| 签到预判 | GET `https://data-xxt.aichaoxing.com/newsign/preSign` | `courseId`、`classId`、`activePrimaryId`、`general=1`、`sys=1`、`ls=1`、`appType=15`、`uid`、`isTeacherViewOpen=0` |
| 签到探针 | GET `https://mobilelearn.chaoxing.com/sign/stuSignajax` | `activeId`、`uid`、`clientip=""`、(课程/班级) |
| 正式签到 | GET `https://mobilelearn.chaoxing.com/pptSign/stuSignajax` | 见下方参数顺序 |
| 签到详情 | GET `https://mobilelearn.chaoxing.com/newsign/signDetail` | `activeId`、`uid` |
| 滑块验证码 | GET `https://captcha.chaoxing.com/captcha/{get/conf,get/verification/image,check/verification/result}` | `callback=cx_captcha_function`，JSONP 包装 |

### 4. 签到请求参数顺序（务必保持）

`Ljg0.invokeSuspend` 里逐条 `addQueryParameter`，顺序为：

```
enc?  name  activeId  uid  clientip=""  location?
latitude=-1  longitude=-1  fid  appType=15  deviceCode
vpProbability=-1  vpStrategy=""  signCode?  enc2?  validate?  locationResult?
```

- `name` 不是 uid，是会话上下文里的用户名（`Lde0.c` → `Lyh0.c`），可由设置项覆盖
- `latitude`/`longitude` 恒为 `-1`；真实坐标走 `location` / `locationResult` 的 JSON 字符串
- `Referer` 由 `xh0.k` 生成：先拼 `data-xxt.aichaoxing.com/newsign/preSign`，再把 host 换成 `mobilelearn.chaoxing.com`
- 定位 JSON 由 `xh0.c` 生成，字段顺序固定：

```json
{"result":1,"latitude":30.123456,"longitude":120.123456,"address":"...","mockData":"{\"strategy\":0,\"probability\":-1}"}
```

数值先 `String(format:"%.6f")` 再解析回 Double，所以尾零会被丢掉——iOS 侧 `SignLocation.queryValue()` 复刻了这个细节。

### 5. 响应真值表（`xh0.g` 判定顺序）

| 响应特征 | 结论 |
| --- | --- |
| 含 `[face]` | 人脸验证失败 |
| 含 `success2` | 成功 |
| `fail-need-qrcode` / `签到失败，请重新扫描。` | 二维码过期 |
| 前缀 `checkFace_` | 需要人脸 |
| 含 `errorLocation` | 位置错误（`_` 之后为距离） |
| 含 `您已签到过了` | 已签到 |
| 含 `同一设备不允许重复签到` | 设备码重复 |
| 前缀 `validate_` | 回填 `validate` 重试 |
| 含 `success` | 成功 |
| 含 `迟到或签到已结束` | 已结束 |
| 302 且含 `校验失败，未查询到活动数据` | 无权限 |
| 含 `下次早点哦` | 已截止 |

签到状态判定（`xh0.f`）：先正则 `"primaryAttend"\s*:\s*\{[^{}]*?"status"\s*:\s*(\d+)`，再退化为 `signstatus\s*=\s*(\d+)`，成功集合 `{1,2,3,9}`；两者都没有时扫描"未签到页面标记"，无标记则按未签到处理。

iOS 侧全部映射到 `Core/SignResponseParser.swift` 的 `SignEvent`，判定顺序与上表逐行一致。

---

## 二、目录结构

```
ChaoxingSigner-iOS/
├── project.yml                       # XcodeGen 备用工程描述
├── ChaoxingSigner.xcodeproj/         # 可直接打开的 Xcode 工程
└── ChaoxingSigner/
    ├── App/
    │   ├── ChaoxingSignerApp.swift   # @main，注入 store/location/coordinator
    │   └── AppState.swift            # 登录、拉活动、手动签到
    ├── Core/
    │   ├── Crypto.swift              # AES/CBC/PKCS5 + Base64
    │   ├── Models.swift              # Account / SignActivity / SignEvent / SignLocation
    │   ├── DeviceIdentity.swift      # deviceCode 生成
    │   ├── HTTPClient.swift          # URLSession + 保序 QueryBuilder + CookieVault
    │   ├── ChaoxingEndpoints.swift   # 全部 URL 常量、SignType、PredictResult
    │   ├── ChaoxingClient.swift      # 登录 / 活动 / 预判 / 签到 / 验证码
    │   ├── SignResponseParser.swift  # xh0.g 真值表
    │   ├── LocationProvider.swift    # CoreLocation + 手动坐标 + 逆地理
    │   ├── AccountStore.swift        # 多账号持久化 + 设置
    │   ├── SignCoordinator.swift     # 签到编排 + 自动轮询
    │   └── BackgroundSigning.swift   # BGAppRefreshTask
    ├── UI/                           # RootView / ActivityListView / SignActionSheet /
    │                                 # SettingsView / LoginView
    └── Resources/
        ├── Info.plist
        └── Assets.xcassets           # AppIcon + AccentColor
```

---

## 三、构建与安装

> 前提：iPhone 需要 **iOS 17 或更高**。设备第一次装非 App Store 的 App，都要在「设置 → 通用 → VPN与设备管理」里信任对应证书。

### 路线 A：有 Mac + Xcode（最快，5 分钟）

1. 双击 `ChaoxingSigner.xcodeproj`
2. 选中工程 → TARGETS `ChaoxingSigner` → Signing & Capabilities
   - Team：选自己的 Apple ID（Xcode → Settings → Accounts 里先登录，免费账号即可）
   - Bundle Identifier：改成全局唯一，例如 `com.yourname.cxsign`
3. 顶部设备选择框选自己的 iPhone（USB 连接，手机上点「信任此电脑」）
4. 按 ⌘R 运行，装完在手机「设置 → 通用 → VPN与设备管理 → 开发者 App」里点信任
5. 之后 App 图标出现在桌面

免费个人开发者账号的限制：签名 **7 天有效**，到期要重新 ⌘R 一次；同时最多 3 个自签 App。

### 路线 B：只有 Windows（GitHub Actions 云编译 + Sideloadly 自签）

1. 把 `ChaoxingSigner-iOS` 目录里的**全部内容**推到一个 GitHub 仓库（当作仓库根目录，`.github/workflows/build-ipa.yml` 已经在里面）
2. 仓库页面 → Actions → 左侧 `build-ipa` → `Run workflow`
3. 跑完（约 3–5 分钟）在该次运行底部下载 artifact `ChaoxingSigner-unsigned`，解压得到 `ChaoxingSigner-unsigned.ipa`
4. Windows 上装 **iTunes**（或 Microsoft Store 的「Apple 设备」+「iCloud」）和 **Sideloadly**（sideloadly.io）
5. 手机 USB 连电脑 → 打开 Sideloadly
   - IPA 选 `ChaoxingSigner-unsigned.ipa`
   - Apple ID 填自己的（会用于生成开发证书）
   - 如果之前装过同 bundle id 的版本，先在 iOS 设置里删掉旧 App
   - 点 Start，输入 Apple ID 密码（如开了双重认证，用「App 专用密码」）
6. 装完在手机「设置 → 通用 → VPN与设备管理」信任开发者证书

同样受 7 天限制：Sideloadly 勾选「Refresh periodically」并保持电脑开机，或到期重签一次。

### 路线 C：租云 Mac（一个月几十块）

MacinCloud / MacStadium 之类开一台带 Xcode 的云 Mac，把工程传上去，按路线 A 走（用 USB 无法直连时用 Xcode 的无线调试或直接 Archive 出 ipa 再走 Sideloadly）。

### 常见问题

| 现象 | 原因与处理 |
| --- | --- |
| `Signing for "ChaoxingSigner" requires a development team` | 没选 Team，或 Bundle ID 与他人重复，改成唯一值 |
| 安装到一半失败 / 「无法验证 App」 | 证书没信任：设置 → 通用 → VPN与设备管理 |
| 打开闪退 | 手机系统低于 iOS 17，或签名过期 |
| 定位不生效 | 首次进入要在弹窗里允许定位；也可在「设置 → 定位」切手动坐标 |
| 后台不签到 | iOS 限制，见下文第六节 |

### 用 XcodeGen（可选）

```bash
cd ChaoxingSigner-iOS
xcodegen generate       # 读取 project.yml 重新生成工程
open ChaoxingSigner.xcodeproj
```

---

## 四、已实现

- 多账号登录（AES 加密提交 + 会话 Cookie 持久化 + 失效自动重登）
- 活动列表拉取、状态徽章、下拉刷新
- 签到流程完整复刻：会话校验 → 已签短路 → preSign 预判 → 正式提交 → `validate_` 自动重试（最多 3 次）
- 手势码 / 签到码、二维码 `enc`、位置签到（真实定位 / 手动坐标 / `mockData` 开关）、`name` 覆盖、每账号独立 `deviceCode`
- 自动签到轮询（前台 30s 起）与 `BGAppRefreshTask` 后台兜底
- 完整中文错误文案，与 APK 异常类型一一对应

## 五、未实现（iOS 侧受限或需要额外工作）

| 项 | 原因 |
| --- | --- |
| 拍照签到上传 | APK 走 `pan-yz.chaoxing.com` 上传 + `enc2` 回填，链路长且依赖人脸/照片校验；当前保留 `enc2` 输入位 |
| 人脸签到 | APK 内置 ONNX 模型做活体检测，需要移植模型与推理；当前识别到 `[face]` 时给出提示 |
| 滑块验证码自动滑动 | 已实现 `captchaChallenge` / `captchaValidate` 接口层，UI 未接滑块控件 |
| 代签（导入他人 `cxsignfaker://import`） | URL Scheme 导入流程未移植，可复用现有 `login` + 多账号 |
| IM 群消息监听 | APK 依赖环信 SDK；iOS 端改为轮询活动列表 |
| 桌面小组件 / 快捷指令 | 可用 App Intents 扩展，本次未做 |

## 六、iOS 后台限制（务必了解）

- iOS 不允许长期后台轮询。`BGAppRefreshTask` 由系统调度，最早 15 分钟一次，且不保证执行
- 想让自动签到更稳，需要保持 App 在前台，或接受「后台可能漏签」
- `UIBackgroundModes` 已声明 `fetch` 与 `location`；若开启持续定位会显著耗电

## 七、服务端风控相关（逆向时观察到的事实）

- APK 内置黑名单拉取：`http://cdn.aquamarine5.fun/chaoxingsignfaker_banlist.json`
- 上报/统计走 Supabase：`https://zpkavhhjdtghljleztpb.supabase.co/rest/v1/...`；iOS 版未实现任何上报
- 签到接口会校验 `deviceCode`（同一设备重复签到会被拒）与 `validate`（风控校验串），本实现保留这两个字段

## 八、对照自检（无 Xcode 环境下的验证手段）

本机没有 swiftc，所以用 Python 复刻了同一套逻辑做基准值：`tools/ref_sign.py`（与 `Core/HTTPClient.swift:QueryBuilder`、`Core/ChaoxingClient.swift:signURL`、`Core/Crypto.swift` 逐行对应）。跑 `python tools/ref_sign.py` 可得到下列向量，Swift 侧输出必须完全一致。

AES（key=IV=`u2oh6Vu^HWe4_AES`，PKCS7，Base64）：

```
"13800138000" -> yYcVatS+4J+JGnm88UM56A==
"abc12345"    -> npjWUyPelEBXd/K48vJ0lQ==
```

普通签到（无 enc / 无定位，`activeId=123456789&uid=9876543&fid=12345`）：

```
https://mobilelearn.chaoxing.com/pptSign/stuSignajax?name=%E5%BC%A0%E4%B8%89&activeId=123456789&uid=9876543&clientip=&latitude=-1&longitude=-1&fid=12345&appType=15&deviceCode=abcd1234ef567890abcd1234&vpProbability=-1&vpStrategy=
```

位置签到会额外插入 `location=`（在 `clientip` 之后、`latitude` 之前）与 `locationResult=`（末尾），两者内容相同：

```
{"result":1,"latitude":30.123457,"longitude":120.987654,"address":"浙江省杭州市西湖区"}
```

其它可用的自检脚本：`tools/test_parser.py`（响应真值表 14 条 + 状态 6 条 + 预判 4 条，全部断言通过）、`tools/swiftbalance.py`（剥离注释与字符串后校验括号配对）。

在没有 Xcode 的机器上已经做过的静态校验：

- 18 个 Swift 文件的括号/字符串配对（`tools/swiftbalance.py`）
- 跨文件 API 核对：`ChaoxingClient` / `SignCoordinator` / `AccountStore` / `LocationProvider` / `SignResponseParser` 的每个调用点标签与声明一致
- 无重复顶层类型名（40 个声明）；4 个 `@EnvironmentObject` 注入与 6 处使用一一覆盖
- `project.pbxproj`：Sources 阶段 18 个文件与磁盘一致，引用 ID 无悬空（56 defined / 56 referenced / 0 missing）
- `Info.plist` 与 Assets 的 JSON 均可被 `plistlib` / `json` 正确解析

仍未覆盖的部分：真实编译与真机运行（本机无 Xcode / swiftc），以及服务端联调。