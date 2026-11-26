import SwiftUI

/// 提交签到前的参数面板：手势码 / 二维码 enc / 位置开关
struct SignActionSheet: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var location: LocationProvider
    @Environment(\.dismiss) private var dismiss

    let activity: SignActivity
    let onSubmit: (SignOptions) -> Void

    @State private var signCode = ""
    @State private var qrEnc = ""
    @State private var useLocation = false
    @State private var useMock = false

    var body: some View {
        NavigationStack {
            Form {
                Section("活动") {
                    LabeledContent("标题", value: activity.title)
                    LabeledContent("activeId", value: String(activity.activeId))
                    LabeledContent("类型", value: activity.signTypeName)
                    LabeledContent("courseId / classId",
                                   value: "\(activity.courseId) / \(activity.classId)")
                }

                Section("签到方式") {
                    TextField("手势码 / 签到码（signCode）", text: $signCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("二维码 enc（扫码后自动填入）", text: $qrEnc)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("携带定位（位置签到必须）", isOn: $useLocation)
                    if useLocation {
                        Toggle("附加 mockData（随机化策略）", isOn: $useMock)
                        LabeledContent("坐标", value: coordinateText)
                        Text("可在「设置 → 定位」里切换真实定位或手动坐标")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        var opts = SignOptions()
                        opts.signCode = signCode.isEmpty ? nil : signCode
                        opts.qrEnc = qrEnc.isEmpty ? nil : qrEnc
                        opts.useLocation = useLocation
                        opts.photoEnc2 = nil
                        onSubmit(opts)
                        dismiss()
                    } label: {
                        Label("立即签到", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } footer: {
                    Text("提交顺序与原版一致：enc → name → activeId → uid → clientip → location → latitude/longitude=-1 → fid → appType=15 → deviceCode → vpProbability/vpStrategy → signCode → enc2 → validate → locationResult")
                        .font(.caption2)
                }
            }
            .navigationTitle("签到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                useLocation = activity.signType == SignType.location.rawValue
                useMock = store.useMockLocation
            }
        }
    }

    private var coordinateText: String {
        let loc = location.snapshot(useMockData: useMock)
        guard let loc else { return "不可用" }
        return String(format: "%.6f, %.6f", loc.latitude, loc.longitude)
    }
}