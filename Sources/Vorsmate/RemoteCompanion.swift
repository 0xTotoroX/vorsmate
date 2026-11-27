// [INPUT]: 同目录的配套签名应用、PluginHost 开关与显隐通知。
// [OUTPUT]: 可选插件的发现、子进程状态与面板编辑管道。
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
    @Published private(set) var activeProfileLabel: String?
    @Published private(set) var editor: RemoteEditorState?
    @Published private(set) var editorError: String?
    @Published private(set) var pending: UUID?
    private var observing = false
    private(set) var face: NSImage?
    var voiceReadiness: (Bool?) -> Void = { _ in }
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

    private var managesVoice: Bool {
        Bundle(url: url)?.object(forInfoDictionaryKey: "VorsmateRemoteVoiceProtocol") as? Int == 1
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
        face =
            exists
            ? Bundle(url: url)?.url(forResource: "RC003", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
            : nil
        available = exists
        if !exists {
            voiceReadiness(nil)
            closeSession()
        } else if wanted {
            launch()
        }
    }
    func activate() {
        wanted = true
        launch()
    }
    func deactivate() {
        wanted = false
        voiceReadiness(nil)
        closeSession()
        activeProfileLabel = nil
        status = "已停用"
    }
    func refresh() { discover() }
    func panelDidChangeVisibility(_ visible: Bool) { if visible { discover() } }

    private var supportsEditor: Bool {
        Bundle(url: url)?.object(forInfoDictionaryKey: "VorsmateRemoteMappingProtocol") as? Int == 1
    }

    func beginEditing() {
        observing = true
        editorError = nil
        guard available && wanted && supportsEditor else {
            editorError = "请使用与 Vorsmate 配套的遥控器插件。"
            return
        }
        if child == nil {
            launch()
        } else if !stopping {
            send(.observe)
        }
    }

    func endEditing() {
        observing = false
        if child != nil, supportsEditor { send(.stopObserving) }
        editor = nil
    }

    func configure(_ edit: RemoteMappingEdit, revision: UUID?) {
        guard observing, pending == nil, let revision else { return }
        let id = UUID()
        pending = id
        editorError = nil
        send(.configure(id: id, revision: revision, edit: edit))
    }

    func requestPermission(input: Bool) { send(input ? .inputPermission : .postPermission) }

    private func send(_ request: RemoteEditorCommand) {
        do {
            guard let control, !stopping else { throw CocoaError(.fileWriteUnknown) }
            var data = try JSONEncoder().encode(request)
            data.append(0x0a)
            try control.write(contentsOf: data)
        } catch {
            pending = nil
            editorError = "无法与遥控器插件通信"
        }
    }

    private func receive(_ reply: RemoteEditorReply) {
        switch reply {
        case .state(let state):
            activeProfileLabel = state.frontApp.flatMap { state.profile.applications?[$0]?.name } ?? "默认方案"
            if observing { editor = state }
        case .saved(let id, let state, let error):
            guard pending == id else { return }
            pending = nil
            activeProfileLabel = state.frontApp.flatMap { state.profile.applications?[$0]?.name } ?? "默认方案"
            if observing {
                editor = state
                editorError = error
            }
        }
    }

    private func closeSession() {
        editor = nil
        pending = nil
        stopping = child != nil
        try? control?.close()
        control = nil
    }
    private func launch() {
        guard child == nil, available, trusted() else { return }
        if !preview { voiceReadiness(managesVoice ? false : nil) }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = url.appending(path: "Contents/MacOS/VorsmateRemote")
        process.arguments = preview ? ["--host-v1", "--preview"] : ["--host-v1"]
        if supportsEditor { process.arguments?.append("--editor-v1") }
        if !preview, managesVoice { process.arguments?.append("--voice-status-v1") }
        process.standardInput = input
        process.standardOutput = output
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.child === process else { return }
                let restart = self.stopping && self.wanted && self.available
                self.child = nil
                self.pending = nil
                self.editor = nil
                if self.observing { self.editorError = "插件已退出，请重新连接。" }
                try? self.control?.close()
                self.control = nil
                self.stopping = false
                if restart {
                    self.launch()
                } else if self.wanted && self.available {
                    self.status = "插件已退出"
                    self.voiceReadiness(self.managesVoice ? false : nil)
                }
            }
        }
        do { try process.run() } catch {
            status = "插件启动失败"
            editorError = status
            return
        }
        child = process
        control = input.fileHandleForWriting
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        status = "正在连接"
        if observing && supportsEditor {
            editorError = nil
            send(.observe)
        }
        Task { [weak self] in
            do {
                for try await line in output.fileHandleForReading.bytes.lines {
                    guard let self, self.child === process, self.wanted, !self.stopping else { continue }
                    if line.hasPrefix("{") {
                        if let reply = try? JSONDecoder().decode(RemoteEditorReply.self, from: Data(line.utf8)) {
                            self.receive(reply)
                        }
                        continue
                    }
                    switch line {
                    case "voice=ready": self.voiceReadiness(true)
                    case "voice=offline": self.voiceReadiness(false)
                    case "voice=external": self.voiceReadiness(nil)
                    default:
                        if line.hasPrefix("profile\t") {
                            let name = String(line.dropFirst("profile\t".count))
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            self.activeProfileLabel = name.isEmpty ? nil : name
                        } else {
                            self.status = line
                        }
                    }
                }
            } catch {}
        }
    }
}

struct RemoteRow: View {
    @ObservedObject var plugin: RemoteCompanion
    let open: () -> Void
    var body: some View {
        let value = plugin.activeProfileLabel ?? (plugin.status == "遥控器就绪" ? "默认方案" : "小米 2 Pro")
        Button(action: open) {
            PanelSummaryRow(
                title: "遥控器", symbol: PluginID.remote.symbol, status: plugin.status, value: value,
                navigation: .detail)
        }.buttonStyle(.plain).accessibilityIdentifier("remote.open")
    }
}
