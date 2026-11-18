// [INPUT]: RC003 专用 HID 管理器、设备映射租约与蓝牙语音连接。
// [OUTPUT]: 实际按键与蓝牙状态，以及独立的单次动作派发。
// [POS]: 主运行循环串行处理报告；断连、竞争、停用均清理按键状态。
import AppKit
import IOKit.hid
import VorsmateCore

@MainActor
final class RemoteMonitor: ObservableObject {
    @Published private(set) var status = "等待连接"
    @Published private(set) var sent = 0
    @Published private(set) var needsPermission = false
    var report: (String) -> Void = { _ in }
    @Published private(set) var voiceStatus = "等待遥控器麦克风"
    private var voiceReady: String?
    private let voice = RemoteVoiceLink()
    private func voiceState(_ message: String, _ state: String) {
        if voiceStatus != message {
            voiceStatus = message
            if CommandLine.arguments.contains("--verify") { report("mic: " + message) }
        }
        if voiceReady != state {
            voiceReady = state
            if CommandLine.arguments.contains("--voice-status-v1") || CommandLine.arguments.contains("--verify") {
                report("voice=" + state)
            }
        }
    }
    private let lease = ReturnLease()
    private var manager: IOHIDManager?
    private var sourceID: UInt64?
    @Published private(set) var profile = RemoteProfile()
    @Published var feedback: String?
    private(set) var preview: Bool
    private var profileError: String?
    private var gestures = RemoteGestures()
    private var pending: [(RemoteStroke, RemoteAction)] = []
    private var sending = false
    private var generation = 0
    @Published private(set) var lastGesture: String?

    private var deadlineTimer: Timer?
    private var activeMap: [UInt64: UInt64] = [:]
    private var now: Int { Int(ProcessInfo.processInfo.systemUptime * 1000) }

    init(preview: Bool) {
        self.preview = preview
        voice.status = { [weak self] message, ready in self?.voiceState(message, ready ? "ready" : "offline") }
        if CommandLine.arguments.contains("--verify") {
            voice.receipt = { [weak self] count, peak in self?.report("voiceSamples=\(count) peak=\(peak)") }
        }
        if preview {
            profile = .editorPreview
        } else {
            reloadProfile()
        }
    }

    var editorState: RemoteEditorState {
        RemoteEditorState(
            profile: profile, status: preview ? "预览" : status, voice: preview ? "预览" : voiceStatus,
            needsInput: !preview && needsPermission, needsPost: !preview && !CGPreflightPostEventAccess(),
            problem: profileError, feedback: feedback)
    }

    func reloadProfile() {
        guard !preview else { return }
        do {
            let saved = try RemoteProfile.read()
            let changed = saved != profile || profileError != nil
            profileError = nil
            if changed {
                cancelGestures()
                profile = saved
                if locked { tick() }
            }
        } catch {
            profileError = error.localizedDescription
            if locked { tick() }
        }
    }

    @discardableResult
    func edit(_ button: RemoteButton, gesture: RemoteGesture, action: RemoteAction, previous: RemoteAction? = nil)
        -> String?
    {
        if let profileError { return profileError }
        do {
            let next = try profile.editing(
                button, gesture: gesture, previous: previous ?? profile.action(for: button, gesture: gesture),
                action: action)
            if !preview { try next.save(replacing: profile) }
            cancelGestures()
            profile = next
            feedback = nil
            if locked { tick() }
            return nil
        } catch {
            reloadProfile()
            feedback = error.localizedDescription
            return feedback
        }
    }

    func requestPostAccess() {
        guard !preview else { return }
        _ = CGRequestPostEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func cancelGestures() {
        generation &+= 1
        pending.removeAll()
        gestures = RemoteGestures()
        deadlineTimer?.invalidate()
        deadlineTimer = nil
    }
    private var timer: Timer?
    private var locked = false
    private var sleeping = false

    private var competing: Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let id = app.bundleIdentifier else { return false }
            return id == "com.hd838a.RemoteMic" || id.hasPrefix("com.hd838a.RemoteMic.")
        }
    }
    func start() {
        do {
            try lease.lock()
            locked = true
        } catch {
            update(error.localizedDescription)
            return
        }
        let events = NSWorkspace.shared.notificationCenter
        events.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        events.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func update(_ message: String) {
        guard status != message else { return }
        status = message
        report(message)
    }

    func requestAccess() {
        guard !preview else { return }
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        tick()
    }

    private func idle(_ message: String, external: Bool = false) {
        voice.stop()
        voiceState(message, external ? "external" : "offline")
        sourceID = nil
        cancelGestures()
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, 0)
            self.manager = nil
        }
        do {
            try lease.recover()
            update(message)
        } catch { update(error.localizedDescription) }
    }

    @objc private func willSleep() {
        sleeping = true
        idle("等待唤醒")
    }

    @objc private func didWake() {
        sleeping = false
        tick()
    }

    private func tick() {
        guard locked && !sleeping else { return }
        if let profileError {
            idle("无法读取按键配置：\(profileError)")
            return
        }
        if competing {
            idle("请先退出 SayAll，再接管遥控器", external: true)
            return
        }
        needsPermission = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted
        if needsPermission {
            idle("需要输入监控权限")
            return
        }
        if manager == nil {
            let hid = IOHIDManagerCreate(nil, 0)
            IOHIDManagerSetDeviceMatching(hid, ReturnLease.identity as CFDictionary)
            IOHIDManagerRegisterDeviceRemovalCallback(
                hid,
                { context, _, _, device in
                    guard let context else { return }
                    let monitor = Unmanaged<RemoteMonitor>.fromOpaque(context).takeUnretainedValue()
                    MainActor.assumeIsolated {
                        guard let current = monitor.sourceID, RemoteMonitor.registryID(device) == current else {
                            return
                        }
                        monitor.voice.stop()
                        monitor.voiceState("遥控器麦克风已断开", "offline")
                        monitor.sourceID = nil
                        monitor.cancelGestures()
                        do {
                            try monitor.lease.recover()
                            monitor.update("等待遥控器连接")
                        } catch { monitor.update(error.localizedDescription) }
                    }
                }, Unmanaged.passUnretained(self).toOpaque())
            IOHIDManagerRegisterInputReportCallback(
                hid,
                { context, result, sender, _, reportID, bytes, length in
                    guard result == kIOReturnSuccess, reportID == 1, length == 6 || length == 7,
                        let context, let sender
                    else { return }
                    let monitor = Unmanaged<RemoteMonitor>.fromOpaque(context).takeUnretainedValue()
                    guard
                        CFGetTypeID(Unmanaged<CFTypeRef>.fromOpaque(sender).takeUnretainedValue())
                            == IOHIDDeviceGetTypeID()
                    else { return }
                    let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
                    let payload = Array(UnsafeBufferPointer(start: bytes, count: length))
                    MainActor.assumeIsolated { monitor.receive(device: device, id: reportID, bytes: payload) }
                }, Unmanaged.passUnretained(self).toOpaque())
            IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            manager = hid
            guard IOHIDManagerOpen(hid, 0) == kIOReturnSuccess else {
                idle("无法打开遥控器，请检查输入监控权限")
                return
            }
        }
        guard let manager else { return }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        let only = devices.count == 1 ? devices.first : nil
        let current = only.flatMap(Self.registryID)
        if sourceID != current || current == nil {
            sourceID = nil
            cancelGestures()
            do { try lease.recover() } catch {
                update(error.localizedDescription)
                return
            }
        }
        guard let current, let only else {
            voice.stop()
            voiceState("等待遥控器连接", "offline")
            update(devices.isEmpty ? "等待遥控器连接" : "请只连接一只 RC003")
            return
        }
        let unique = IOHIDDeviceGetProperty(only, "PhysicalDeviceUniqueID" as CFString) as? String
        voice.poll(identity: unique.flatMap(UUID.init(uuidString:)))
        var desired = profile.deviceMap
        if !CGPreflightPostEventAccess() {
            for button in RemoteButton.allCases where button != .voice {
                guard let binding = profile.buttons[button.rawValue] else { continue }
                // A mapped confirm shortcut must never fall through as a physical Return.
                if button == .ok && binding.single.kind == .shortcut { continue }
                let canPerform = RemoteGesture.allCases.contains {
                    [.typeless, .openApplication].contains(binding[$0].kind)
                }
                let key = UInt64(7) << 32 | UInt64(button.usage)
                if !canPerform && desired[key] == 0 { desired.removeValue(forKey: key) }
            }
        }
        if sourceID == current && activeMap == desired && lease.isSuppressed() { return }
        sourceID = nil
        cancelGestures()
        do {
            try lease.acquire(desired)
            activeMap = desired
            sourceID = current
            update("遥控器就绪")
        } catch { update(error.localizedDescription) }
    }

    private static func registryID(_ device: IOHIDDevice) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id) == KERN_SUCCESS ? id : nil
    }

    private func receive(device: IOHIDDevice, id: UInt32, bytes: [UInt8]) {
        guard let sourceID, Self.registryID(device) == sourceID,
            let pressed = RemoteButton.pressed(reportID: id, bytes: bytes)
        else { return }
        let claimed = pressed.filter { activeMap[UInt64(7) << 32 | UInt64($0.usage)] == 0 }
        let actions = gestures.ingest(claimed, at: now, profile: profile)
        scheduleDeadline()
        deliver(actions)
    }

    private func scheduleDeadline() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let due = gestures.deadline else { return }
        let timer = Timer(timeInterval: Double(max(0, due - now)) / 1000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let actions = self.gestures.advance(to: self.now)
                self.scheduleDeadline()
                self.deliver(actions)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    private func deliver(_ strokes: [RemoteStroke]) {
        guard !strokes.isEmpty else { return }
        guard sourceID != nil, !competing, lease.isSuppressed() else {
            cancelGestures()
            tick()
            return
        }
        for stroke in strokes {
            guard let action = profile.buttons[stroke.button.rawValue]?[stroke.gesture], action.kind != .none else {
                continue
            }
            pending.append((stroke, action))
        }
        guard !sending, !pending.isEmpty else { return }
        sending = true
        Task {
            defer { sending = false }
            while !pending.isEmpty {
                let (stroke, action) = pending.removeFirst()
                let current = generation
                guard sourceID != nil, !competing, lease.isSuppressed() else {
                    cancelGestures()
                    tick()
                    return
                }
                do {
                    try await ActionOutput.send(action)
                    if current == generation {
                        feedback = nil
                        lastGesture = "\(stroke.button.name) · \(stroke.gesture.name)"
                        sent += 1
                    }
                } catch { if current == generation { feedback = error.localizedDescription } }
            }
        }
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        timer?.invalidate()
        timer = nil
        if locked { idle("已停用") }
    }
}

extension RemoteProfile {
    fileprivate static var editorPreview: Self {
        var profile = Self()
        func shortcut(_ code: UInt16, _ label: String) -> RemoteAction {
            var value = RemoteAction(.shortcut)
            value.keyCode = code
            value.flags = 0
            value.label = label
            return value
        }
        for (button, action) in [
            (RemoteButton.power, shortcut(53, "Esc")), (.left, shortcut(123, "←")), (.right, shortcut(124, "→")),
            (.up, shortcut(126, "↑")), (.down, shortcut(125, "↓")), (.back, shortcut(51, "退格")),
            (.volumeUp, RemoteAction(.volumeUp)), (.volumeDown, RemoteAction(.volumeDown)),
        ] {
            var binding = RemoteBinding()
            binding.single = action
            profile.buttons[button.rawValue] = binding
        }
        var ok = RemoteBinding()
        ok.single = .dictationShortcut
        ok.double = shortcut(87, "Numpad5")
        ok.long = shortcut(36, "回车")
        profile.buttons[RemoteButton.ok.rawValue] = ok
        return profile
    }
}
