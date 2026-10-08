import SwiftUI
import AppKit

struct ConnectView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var provider: ProviderKind = .codex
    @State private var method: ConnectionMethod = .localFile
    @State private var name = ""
    @State private var location = ""
    @State private var secret = ""
    @State private var sourceAccountID = ""
    @State private var sshHost = ""
    @State private var sshUseSudo = false
    @State private var serviceLabel = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("添加账号").font(.title3.weight(.semibold))
                    Text("接入自己的账号，额度各自独立。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain).disabled(isConnecting).accessibilityLabel("取消添加账号")
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    Picker("服务", selection: $provider) {
                        Text("Codex").tag(ProviderKind.codex)
                        Text("Claude").tag(ProviderKind.claude)
                        Text("Grok").tag(ProviderKind.grok)
                        Text("JSON").tag(ProviderKind.snapshot)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .onChange(of: provider) { _, newValue in reset(for: newValue) }

                    Text(providerDescription)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("账号备注").font(.caption.weight(.medium))
                        TextField("例如：个人账号、工作账号", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    if provider == .claude {
                        Picker("接入方式", selection: $method) {
                            Text("钥匙串").tag(ConnectionMethod.keychain)
                            Text("凭据文件").tag(ConnectionMethod.localFile)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: method) { _, _ in clearSource() }
                    } else if provider == .snapshot {
                        Picker("接入方式", selection: $method) {
                            Text("本地文件").tag(ConnectionMethod.snapshotFile)
                            Text("HTTPS").tag(ConnectionMethod.snapshotURL)
                            Text("SSH").tag(ConnectionMethod.snapshotSSH)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: method) { _, _ in clearSource() }
                    }

                    sourceFields

                    if provider == .snapshot {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("服务名称（可选）").font(.caption.weight(.medium))
                            TextField("例如：Codex、Claude、公司 Agent", text: $serviceLabel)
                                .textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("数据源账号 ID（多账号文件必填）").font(.caption.weight(.medium))
                            TextField("单账号来源可留空", text: $sourceAccountID)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    if method == .snapshotURL {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Bearer Token（可选）").font(.caption.weight(.medium))
                            SecureField("服务需要验证时填写", text: $secret)
                                .textFieldStyle(.roundedBorder)
                            Text("验证后保存到 macOS 钥匙串。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    }

                    Label(privacyText, systemImage: "lock.shield")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .disabled(isConnecting)
            }
            Divider()
            HStack {
                Button("取消") { dismiss() }.disabled(isConnecting)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isConnecting { ProgressView().controlSize(.small) }
                Button(isConnecting ? "正在验证…" : "验证并添加") {
                    Task { await connect() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting || !canConnect)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 440, height: 590)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var sourceFields: some View {
        if method == .keychain {
            VStack(alignment: .leading, spacing: 7) {
                Text("钥匙串服务名称").font(.caption.weight(.medium))
                TextField("Claude Code-credentials", text: $location)
                    .textFieldStyle(.roundedBorder)
                Button("使用 Claude Code 默认服务") { location = "Claude Code-credentials" }
                    .buttonStyle(.link).font(.caption)
                Text("如读取被拒绝，请在“钥匙串访问”中授权，或选择自己的凭据文件。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } else if method == .snapshotSSH {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SSH 主机别名").font(.caption.weight(.medium))
                    TextField("本机 SSH 配置中的主机别名", text: $sshHost)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("远程 JSON 文件绝对路径").font(.caption.weight(.medium))
                    TextField("/var/lib/agent/usage.json", text: $location)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("使用已有 sudo 只读权限", isOn: $sshUseSudo)
                    .toggleStyle(.checkbox).font(.caption)
                Text("仅支持已信任且可免交互连接的 SSH，不会新增密钥或权限。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if method == .snapshotURL {
            VStack(alignment: .leading, spacing: 7) {
                Text("额度 JSON 地址").font(.caption.weight(.medium))
                TextField("https://example.com/usage.json", text: $location)
                    .textFieldStyle(.roundedBorder)
                Text("只支持 HTTPS。由你的服务输出 TokenBar JSON 格式。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                Text(method == .grokCLI ? "Grok 可执行文件" : provider == .snapshot ? "额度 JSON 文件" : "登录凭据文件")
                    .font(.caption.weight(.medium))
                HStack(spacing: 7) {
                    TextField(pathPlaceholder, text: $location)
                        .textFieldStyle(.roundedBorder)
                    Button("选择…") { chooseFile() }
                }
                if provider != .snapshot {
                    Button("使用默认位置") { location = provider.defaultPath }
                        .buttonStyle(.link).font(.caption)
                }
                Text(sourceHint).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var providerDescription: String {
        switch provider {
        case .codex:
            return "读取已登录 Codex 的账号凭据，查询订阅额度、附加额度与点数。"
        case .claude:
            return "使用 Claude Code 已有登录，读取账号提供的额度窗口。"
        case .grok:
            return "通过本机已登录的 Grok CLI 查询额度。"
        case .snapshot:
            return "接入其他 Agent 或自建服务：读取本地、HTTPS 或 SSH 上的额度 JSON。"
        }
    }

    private var pathPlaceholder: String {
        switch provider {
        case .codex: return "~/.codex/auth.json"
        case .claude: return "~/.claude/.credentials.json"
        case .grok: return "~/.grok/bin/grok"
        case .snapshot: return "/path/to/usage.json"
        }
    }

    private var sourceHint: String {
        switch provider {
        case .codex, .claude:
            return "先在官方客户端登录。多个账号请分别选择各自 CLI 配置目录里的凭据。"
        case .grok:
            return "请选择你信任的本机 Grok CLI；添加时会运行额度查询。"
        case .snapshot:
            return "额度文件需包含采集时间；过期数据会标为历史记录。"
        }
    }

    private var privacyText: String {
        switch method {
        case .snapshotURL: return "请求直接发往你填写的地址，凭据仅保存在本机。"
        case .snapshotSSH: return "使用本机 SSH 配置连接，只读取你指定的额度文件。"
        default: return "只在你选择后读取此数据源，TokenBar 不代你登录。"
        }
    }

    private var canConnect: Bool {
        let path = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return false }
        if method == .snapshotSSH {
            return path.hasPrefix("/") && !sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private func reset(for provider: ProviderKind) {
        switch provider {
        case .codex: method = .localFile
        case .claude: method = .keychain
        case .grok: method = .grokCLI
        case .snapshot: method = .snapshotFile
        }
        clearSource()
        sourceAccountID = ""
        serviceLabel = ""
    }

    private func clearSource() {
        location = ""
        secret = ""
        sshHost = ""
        sshUseSudo = false
        errorMessage = nil
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = method == .grokCLI ? "选择 Grok CLI" : "选择数据源文件"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let candidate = (location.isEmpty ? provider.defaultPath : location) as NSString
        if !candidate.isEqual(to: "") {
            panel.directoryURL = URL(fileURLWithPath: candidate.expandingTildeInPath).deletingLastPathComponent()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            if response == .OK, let url = panel.url { location = url.path }
        }
    }

    @MainActor
    private func connect() async {
        isConnecting = true
        errorMessage = nil
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedService = serviceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = AccountConfig(
            provider: provider,
            name: trimmedName.isEmpty ? provider.title : trimmedName,
            method: method,
            location: location.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceAccountID: sourceAccountID.trimmingCharacters(in: .whitespacesAndNewlines),
            sshHost: method == .snapshotSSH ? sshHost.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            sshUseSudo: method == .snapshotSSH ? sshUseSudo : nil,
            serviceLabel: provider == .snapshot && !trimmedService.isEmpty ? trimmedService : nil
        )
        do {
            try await store.connect(config, secret: secret.isEmpty ? nil : secret)
            secret = ""
            dismiss()
        } catch let error as ProviderError {
            errorMessage = error.message
        } catch {
            errorMessage = "连接未完成，请检查数据源后重试。"
        }
        isConnecting = false
    }
}
