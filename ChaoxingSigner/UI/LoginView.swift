import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var fid = "-1"
    @State private var phone = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    /// 常见 fid，便于快速选择（可自行改成自己学校的 fid）
    private let presets: [(String, String)] = [
        ("-1", "自动识别/不指定"),
        ("1", "示例：单位 1"),
        ("0", "示例：单位 0")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("学校 / 单位 fid", text: $fid)
                        .keyboardType(.numbersAndPunctuation)
                    Picker("常用", selection: $fid) {
                        ForEach(presets, id: \.0) { item in
                            Text("\(item.1)（\(item.0)）").tag(item.0)
                        }
                    }
                } header: {
                    Text("学校")
                } footer: {
                    Text("fid 可在学习通网页版登录后地址栏或学校列表接口里查到；不确定就填 -1。")
                        .font(.caption2)
                }

                Section("账号") {
                    TextField("手机号 / 学号", text: $phone)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码（8-16 位）", text: $password)
                }

                Section {
                    Button {
                        submit()
                    } label: {
                        HStack {
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text(busy ? "登录中…" : "登录")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || phone.isEmpty || password.isEmpty)
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red).font(.caption)
                    } else {
                        Text("登录口令会以 AES/CBC/PKCS5（key=iv=u2oh6Vu^HWe4_AES）加密后提交，与原版一致。")
                            .font(.caption2)
                    }
                }
            }
            .navigationTitle("添加账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func submit() {
        error = nil
        busy = true
        Task {
            do {
                _ = try await state.login(fid: Int(fid) ?? -1, phone: phone, password: password)
                busy = false
                dismiss()
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }
}