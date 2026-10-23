import AppKit
import SwiftUI

struct GodAccountView: View {
    @ObservedObject var cloud: GodWorkspace
    @ObservedObject var authentication: GodAuthentication
    @State private var origin = ""
    @State private var configurationError: String?
    init(cloud: GodWorkspace) { self.cloud = cloud; self.authentication = cloud.authentication }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("God 工作台", systemImage: "person.crop.circle").font(.subheadline.weight(.medium))
                Spacer()
                if let user = authentication.user { Text(user.label).font(.caption).foregroundStyle(.secondary) }
            }
            if authentication.user != nil {
                Toggle("同步菜单栏开关状态", isOn: Binding(get: { cloud.syncSwitches }, set: { cloud.setSyncSwitches($0) }))
                    .toggleStyle(.switch).controlSize(.small)
                HStack {
                    if cloud.isSyncing { ProgressView().controlSize(.mini); Text("正在同步").font(.caption) }
                    else if let time = cloud.lastSynced { Text("已同步 · " + time.formatted(.dateTime.hour().minute())).font(.caption).foregroundStyle(.secondary) }
                    else { Text("等待同步").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("立即同步") { Task { await cloud.synchronize() } }.disabled(cloud.isSyncing)
                    Button("退出登录") { authentication.signOut() }
                }
                if !cloud.syncSwitches {
                    Text("账号资料和历史仍会同步，开关布局保留在此设备。")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if authentication.isSigningIn {
                Text("在 God 页面完成 Passkey 登录并确认此设备。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let code = authentication.userCode {
                    HStack {
                        Text(code).font(.system(.body, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                        Button("复制确认码") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }
                        Spacer()
                    }
                }
                HStack {
                    ProgressView().controlSize(.small)
                    Button("打开 God 页面") { authentication.openVerification() }.disabled(authentication.verificationURL == nil)
                    Spacer(); Button("取消") { authentication.cancelSignIn() }
                }
            } else {
                if authentication.connection == nil {
                    TextField("工作台 HTTPS 地址", text: $origin).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("God 工作台地址")
                }
                Button {
                    do {
                        if authentication.connection == nil { try authentication.configure(origin) }
                        configurationError = nil; authentication.signIn()
                    } catch { configurationError = (error as? GodError ?? .invalidResponse).localizedDescription }
                } label: { Label("使用 God Passkey 登录", systemImage: "person.badge.key.fill") }
                .buttonStyle(.borderedProminent)
            }
            if let message = configurationError ?? authentication.message ?? cloud.syncMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct GodDashboardRoot: View {
    @ObservedObject var cloud: GodWorkspace
    var onPanelSizeChange: (CGSize) -> Void
    var body: some View {
        DashboardView(store: cloud.store, cloud: cloud, onPanelSizeChange: onPanelSizeChange)
            .id(ObjectIdentifier(cloud.store))
    }
}
