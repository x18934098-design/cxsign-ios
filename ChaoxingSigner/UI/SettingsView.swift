import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var location: LocationProvider
    @EnvironmentObject private var coordinator: SignCoordinator

    @State private var showLogin = false
    @State private var editingAccount: Account?

    var body: some View {
        NavigationStack {
            Form {
                Section("账号") {
                    ForEach(store.accounts) { acct in
                        Button {
                            editingAccount = acct
                        } label: {
                            AccountRow(account: acct)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { idx in
                        for i in idx { store.delete(store.accounts[i]) }
                    }
                    Button {
                        showLogin = true
                    } label: {
                        Label("添加学习通账号", systemImage: "plus.circle.fill")
                    }
                }

                Section("自动签到") {
                    Toggle("启用自动签到", isOn: Binding(
                        get: { store.autoSignEnabled },
                        set: { store.autoSignEnabled = $0; restart() }))
                    Stepper(value: Binding(
                        get: { store.pollIntervalSeconds },
                        set: { store.pollIntervalSeconds = $0; restart() }),
                            in: 30...900, step: 30) {
                        LabeledContent("轮询间隔", value: "\(store.pollIntervalSeconds) 秒")
                    }
                    Button {
                        Task {
                            await coordinator.runAutoSignPass(store: store) {
                                location.snapshot(useMockData: store.useMockLocation)
                            }
                        }
                    } label: {
                        Label("立即执行一轮", systemImage: "bolt.horizontal.circle")
                    }
                }

                Section("定位") {
                    Picker("定位来源", selection: Binding(
                        get: { location.mode },
                        set: { location.mode = $0; location.refresh() })) {
                        ForEach(LocationProvider.Mode.allCases) { m in
                            Text(m.title).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    LabeledContent("当前坐标", value: String(format: "%.6f, %.6f",
                                                             location.currentLatitude,
                                                             location.currentLongitude))
                    LabeledContent("地址", value: location.address.isEmpty ? "—" : location.address)

                    NavigationLink("手动设置坐标") {
                        ManualLocationView()
                    }

                    Toggle("签到附带 mockData 字段", isOn: Binding(
                        get: { store.useMockLocation },
                        set: { store.useMockLocation = $0 }))

                    if location.authorizationDenied {
                        Text("定位权限被拒绝，请在系统设置中允许")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                Section("高级") {
                    TextField("覆盖签到 name 参数（默认取登录用户名）",
                              text: Binding(get: { store.nameOverride },
                                            set: { store.nameOverride = $0 }))
                    LabeledContent("UA", value: "ChaoXingStudy/ChaoxingMobile")
                    LabeledContent("AES Key", value: ChaoxingCrypto.aesKey)
                }

                Section("关于") {
                    Text("接口与参数顺序逆向自 ChaoxingSignFaker 1.20.0-stable-261120（GPL-3.0）。"
                         + "仅供本机学习用途，签到行为会记录在学习通服务端。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showLogin) {
                LoginView()
            }
            .sheet(item: $editingAccount) { acct in
                AccountDetailView(account: acct)
            }
        }
    }

    private func restart() {
        coordinator.stopAutoSign()
        coordinator.startAutoSign(store: store) {
            location.snapshot(useMockData: store.useMockLocation)
        }
    }
}

private struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: account.avatarURL)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName).font(.subheadline.weight(.medium))
                Text("uid \(account.uid) · fid \(account.fid)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if !account.enabled {
                Text("停用").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct AccountDetailView: View {
    @EnvironmentObject private var store: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State var account: Account
    @State private var relogging = false
    @State private var message: String?

    private let client = ChaoxingClient()

    var body: some View {
        NavigationStack {
            Form {
                Section("账号信息") {
                    LabeledContent("手机号", value: account.phone)
                    LabeledContent("uid", value: String(account.uid))
                    LabeledContent("fid", value: String(account.fid))
                    LabeledContent("用户名", value: account.userName.isEmpty ? "—" : account.userName)
                    LabeledContent("deviceCode", value: account.deviceCode)
                }
                Section("设备码") {
                    Button("重新生成 deviceCode") {
                        account.deviceCode = DeviceIdentity.makeCode()
                        store.upsert(account)
                    }
                    Text("服务端对同一 deviceCode 限制重复签到，换码可绕开该限制。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("参与自动签到", isOn: Binding(
                        get: { account.enabled },
                        set: { account.enabled = $0; store.upsert(account) }))
                    Button {
                        relog()
                    } label: {
                        if relogging { ProgressView() } else { Text("重新登录刷新会话") }
                    }
                    .disabled(relogging || account.password.isEmpty)
                }
                if let message {
                    Section { Text(message).font(.caption) }
                }
                Section {
                    Button(role: .destructive) {
                        store.delete(account)
                        dismiss()
                    } label: { Text("删除账号") }
                }
            }
            .navigationTitle(account.displayName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func relog() {
        relogging = true
        Task {
            var acct = account
            do {
                acct = try await client.login(account: acct)
                store.upsert(acct)
                account = acct
                message = "会话已刷新"
            } catch {
                message = error.localizedDescription
            }
            relogging = false
        }
    }
}

struct ManualLocationView: View {
    @EnvironmentObject private var location: LocationProvider
    @Environment(\.dismiss) private var dismiss

    @State private var lat = ""
    @State private var lng = ""
    @State private var addr = ""

    var body: some View {
        Form {
            Section("坐标（WGS84 / GCJ02 均可，学习通只做距离比对）") {
                TextField("纬度 latitude", text: $lat).keyboardType(.numbersAndPunctuation)
                TextField("经度 longitude", text: $lng).keyboardType(.numbersAndPunctuation)
                TextField("地址文本（可为空）", text: $addr)
            }
            Button("保存") {
                if let la = Double(lat), let ln = Double(lng) {
                    location.setManual(latitude: la, longitude: ln, address: addr)
                    location.mode = .manual
                    dismiss()
                }
            }
            .disabled(Double(lat) == nil || Double(lng) == nil)
        }
        .navigationTitle("手动坐标")
        .onAppear {
            lat = String(format: "%.6f", location.currentLatitude)
            lng = String(format: "%.6f", location.currentLongitude)
            addr = location.address
        }
    }
}