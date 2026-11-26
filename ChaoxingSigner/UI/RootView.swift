import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var store: AccountStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            ActivityListView()
                .tabItem { Label("活动", systemImage: "checkmark.seal") }

            LogsView()
                .tabItem { Label("日志", systemImage: "text.alignleft") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(.accentColor)
        .overlay(alignment: .top) {
            if store.accounts.isEmpty {
                EmptyHint()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                state.coordinator.startAutoSign(store: store) {
                    state.location.snapshot(useMockData: store.useMockLocation)
                }
                Task { await state.reloadActivities() }
            case .background:
                BackgroundSigning.shared.schedule()
            default:
                break
            }
        }
    }
}

private struct EmptyHint: View {
    var body: some View {
        Text("还没有账号，去「设置」里添加学习通账号")
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 8)
    }
}

struct LogsView: View {
    @EnvironmentObject private var coordinator: SignCoordinator

    var body: some View {
        NavigationStack {
            List {
                if coordinator.logs.isEmpty {
                    ContentUnavailableView("暂无记录", systemImage: "text.alignleft",
                                           description: Text("签到动作会记录在这里"))
                }
                ForEach(coordinator.logs) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(entry.success ? .green : .red)
                            Text(entry.activity).font(.subheadline.weight(.medium))
                            Spacer()
                            Text(entry.at, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(entry.message).font(.caption).foregroundStyle(.secondary)
                        Text(entry.account).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("签到日志")
        }
    }
}