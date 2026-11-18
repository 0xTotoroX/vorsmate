// [INPUT]: 同目录的配套签名应用、PluginHost 开关与显隐通知。
// [OUTPUT]: 可选插件的发现、子进程状态和键位窗口入口。
// [POS]: 控制管道随宿主退出关闭；宿主不获取输入监控权限。
import AppKit
import Security
import SwiftUI
import VorsmateCore

@MainActor
final class RemoteCompanion: ObservableObject, VorsmatePlugin {
    let id = PluginID.remote
    @Published private(set) var available = false
    @Published private(set) var status = "已停用"
    private let preview: Bool
    private var wanted = false
    private var stopping = false
    private var child: Process?
    private var control: FileHandle?
    private var url: URL { Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "VorsmateRemote.app") }

    init(preview: Bool) {
        self.preview = preview
        discover()
    }

    private func trusted() -> Bool {
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == "app.vorsmate.remote",
            bundle.object(forInfoDictionaryKey: "VorsmateRemoteProtocol") as? Int == 1,
            bundle.executableURL?.lastPathComponent == "VorsmateRemote"
        else { return false }
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
            SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess,
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let remote = info as? [String: Any], let hash = remote[kSecCodeInfoUnique as String] as? Data
        else { return false }

        var host: SecCode?
        var hostStatic: SecStaticCode?
        var hostInfo: CFDictionary?
        guard SecCodeCopySelf([], &host) == errSecSuccess, let host,
            SecCodeCopyStaticCode(host, [], &hostStatic) == errSecSuccess, let hostStatic,
            SecCodeCopySigningInformation(hostStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &hostInfo)
                == errSecSuccess
        else { return false }
        if let team = (hostInfo as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String {
            var requirement: SecRequirement?
            let rule =
                "anchor apple generic and identifier \"app.vorsmate.remote\" and certificate leaf[subject.OU] = \"\(team)\""
            return SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess
                && SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
        }
        let pinned = Bundle.main.object(forInfoDictionaryKey: "VorsmateRemoteDevelopmentHashes") as? [String]
        return pinned?.contains(hash.map { String(format: "%02x", $0) }.joined()) == true
    }

    func discover() {
        let exists = trusted()
        if available == exists { return }
        available = exists
        if !exists { closeSession() } else if wanted { launch() }
    }
    func activate() {
        wanted = true
        launch()
    }
    func deactivate() {
        wanted = false
        closeSession()
        status = "已停用"
    }
    func refresh() { discover() }
    func panelDidChangeVisibility(_ visible: Bool) { if visible { discover() } }

    func openEditor() {
        guard available && wanted else { return }
        if child == nil { launch() }
        try? control?.write(contentsOf: Data("open\n".utf8))
    }

    private func closeSession() {
        stopping = child != nil
        try? control?.close()
        control = nil
    }
    private func launch() {
        guard child == nil, available, trusted() else { return }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = url.appending(path: "Contents/MacOS/VorsmateRemote")
        process.arguments = preview ? ["--host-v1", "--preview"] : ["--host-v1"]
        process.standardInput = input
        process.standardOutput = output
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.child === process else { return }
                let restart = self.stopping && self.wanted && self.available
                self.child = nil
                try? self.control?.close()
                self.control = nil
                self.stopping = false
                if self.wanted { self.status = "插件已退出" }
                if restart { self.launch() }
            }
        }
        do { try process.run() } catch {
            status = "插件启动失败"
            return
        }
        child = process
        control = input.fileHandleForWriting
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        status = "正在连接"
        Task { [weak self] in
            do {
                for try await line in output.fileHandleForReading.bytes.lines {
                    guard let self, self.child === process, self.wanted, !self.stopping else { continue }
                    self.status = line
                }
            } catch {}
        }
    }
}

struct RemoteRow: View {
    @ObservedObject var plugin: RemoteCompanion
    @Binding var expanded: Bool
    var body: some View {
        VStack(alignment: .leading) {
            Button {
                expanded.toggle()
            } label: {
                PanelSummaryRow(
                    title: "遥控器", symbol: PluginID.remote.symbol, status: plugin.status, value: "小米 2 Pro",
                    expanded: expanded)
            }.buttonStyle(.plain)
            if expanded {
                Button("查看确定键映射") { plugin.openEditor() }
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
    }
}
