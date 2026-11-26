import Foundation
import UIKit

@MainActor
final class AppState: ObservableObject {
    let store = AccountStore()
    let location = LocationProvider()
    let coordinator = SignCoordinator()
    private let client = ChaoxingClient()

    @Published var activities: [SignActivity] = []
    @Published var loadingActivities = false
    @Published var lastError: String?
    @Published var selectedAccountID: UUID?

    var currentAccount: Account? {
        if let id = selectedAccountID, let a = store.accounts.first(where: { $0.id == id }) {
            return a
        }
        return store.activeAccounts.first
    }

    func login(fid: Int, phone: String, password: String) async throws -> Account {
        var acct = Account()
        acct.fid = fid
        acct.phone = phone
        acct.password = password
        let result = try await client.login(account: acct)
        store.upsert(result)
        selectedAccountID = result.id
        await reloadActivities()
        return result
    }

    func reloadActivities() async {
        guard let account = currentAccount, account.isLoggedIn else {
            activities = []
            return
        }
        loadingActivities = true
        defer { loadingActivities = false }
        do {
            await CookieVault.shared.install(account.cookies)
            var acct = account
            let list = try await client.fetchActivities(account: acct)
            acct.cookies = await CookieVault.shared.snapshot()
            store.upsert(acct)
            activities = list.sorted { $0.startDate > $1.startDate }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signNow(activity: SignActivity, options: SignOptions) async -> SignOutcome? {
        guard let account = currentAccount else { return nil }
        let loc = options.useLocation ? location.snapshot(useMockData: store.useMockLocation) : nil
        let outcome = await coordinator.sign(account: account,
                                             activity: activity,
                                             options: options,
                                             location: loc,
                                             nameOverride: store.nameOverride)
        coordinator.append(SignLogEntry(account: account.displayName,
                                        activity: activity.title,
                                        message: SignCoordinator.describe(outcome.event),
                                        success: outcome.event.isSuccess))
        await reloadActivities()
        return outcome
    }
}