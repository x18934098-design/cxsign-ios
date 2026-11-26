import SwiftUI

struct ActivityListView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var store: AccountStore

    @State private var signing: SignActivity?
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            Group {
                if state.currentAccount == nil {
                    ContentUnavailableView("未登录", systemImage: "person.crop.circle.badge.exclamationmark",
                                           description: Text("请到「设置」添加学习通账号"))
                } else if state.activities.isEmpty {
                    ContentUnavailableView {
                        Label("没有待签活动", systemImage: "checkmark.seal")
                    } description: {
                        Text(state.loadingActivities ? "正在加载…" : "下拉刷新试试")
                    }
                } else {
                    List {
                        Section {
                            ForEach(state.activities) { act in
                                ActivityRow(activity: act) {
                                    signing = act
                                }
                            }
                        } header: {
                            HStack {
                                Text(state.currentAccount?.displayName ?? "")
                                Spacer()
                                Text("fid \(state.currentAccount?.fid ?? -1)")
                            }
                        }
                    }
                    .refreshable { await state.reloadActivities() }
                }
            }
            .navigationTitle("签到活动")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await state.reloadActivities() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(state.loadingActivities)
                }
            }
            .overlay {
                if state.loadingActivities { ProgressView() }
            }
            .sheet(item: $signing) { act in
                SignActionSheet(activity: act) { options in
                    Task {
                        let outcome = await state.signNow(activity: act, options: options)
                        if let outcome {
                            toast = SignCoordinator.describe(outcome.event)
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.footnote)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .task(id: toast) {
                            try? await Task.sleep(nanoseconds: 2_800_000_000)
                            self.toast = nil
                        }
                }
            }
        }
    }
}

private struct ActivityRow: View {
    let activity: SignActivity
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(activity.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer()
                    Text(activity.signed ? "已签" : (activity.ended ? "已结束" : "待签"))
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(badgeColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(badgeColor)
                }
                if !activity.subtitle.isEmpty {
                    Text(activity.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Label(activity.signTypeName, systemImage: iconName)
                    Label(timeText, systemImage: "clock")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private var badgeColor: Color {
        if activity.signed { return .green }
        if activity.ended { return .gray }
        return .orange
    }

    private var iconName: String {
        switch activity.signType {
        case SignType.location.rawValue: return "location"
        case SignType.qrCode.rawValue: return "qrcode"
        case SignType.gesture.rawValue: return "hand.draw"
        case SignType.photo.rawValue: return "camera"
        default: return "checkmark.seal"
        }
    }

    private var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return "\(f.string(from: activity.startDate)) → \(f.string(from: activity.endDate))"
    }
}