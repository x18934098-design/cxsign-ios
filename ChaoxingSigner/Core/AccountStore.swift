import Foundation

/// 账号与设置的本地持久化。密码字段随会话一起存放于应用沙盒
/// （若需要更稳妥，可改为 Keychain：加密口令本身仍是明文手机号/密码的 AES，用途单一）。
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published var autoSignEnabled: Bool = true {
        didSet { defaults.set(autoSignEnabled, forKey: "autoSign") }
    }
    @Published var pollIntervalSeconds: Int = 60 {
        didSet { defaults.set(pollIntervalSeconds, forKey: "poll") }
    }
    @Published var useMockLocation: Bool = false {
        didSet { defaults.set(useMockLocation, forKey: "mockLoc") }
    }
    @Published var nameOverride: String = "" {
        didSet { defaults.set(nameOverride, forKey: "nameOverride") }
    }

    private let defaults = UserDefaults.standard
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("accounts.json")
        autoSignEnabled = (defaults.object(forKey: "autoSign") as? Bool) ?? true
        pollIntervalSeconds = (defaults.object(forKey: "poll") as? Int) ?? 60
        useMockLocation = (defaults.object(forKey: "mockLoc") as? Bool) ?? false
        nameOverride = (defaults.object(forKey: "nameOverride") as? String) ?? ""
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        accounts = (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(accounts) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    func upsert(_ account: Account) {
        if let i = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[i] = account
        } else {
            accounts.append(account)
        }
        save()
    }

    func delete(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        save()
    }

    /// 自动签到轮询只使用已登录且启用的账号
    var activeAccounts: [Account] {
        accounts.filter { $0.isLoggedIn && $0.enabled }
    }
}