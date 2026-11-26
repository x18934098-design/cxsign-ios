import Foundation
import BackgroundTasks

/// iOS 没有 Android 那种常驻前台服务，自动签到退化为：
///  1) App 在前台时的定时轮询（SignCoordinator.startAutoSign）
///  2) BGAppRefreshTask 在系统允许的时机做一次补齐扫描
/// 需要在 Info.plist 里声明 BGTaskSchedulerPermittedIdentifiers。
final class BackgroundSigning {
    static let shared = BackgroundSigning()
    static let taskID = "fun.aquamarine5.cxsign.refresh"

    private var registered = false

    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskID,
                                                   using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            self.handle(refresh)
        }
    }

    private func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task { @MainActor in
            let store = AccountStore()
            let coordinator = SignCoordinator()
            let location = LocationProvider()
            await coordinator.runAutoSignPass(store: store) {
                location.snapshot(useMockData: store.useMockLocation)
            }
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}