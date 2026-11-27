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
    var onActiveProfileChanged: ((String) -> Void)?
    private var lastReportedProfileName: String?
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
    private var saving = false
    private var generation = 0
    private var revision = UUID()
    @Published private(set) var frontApp: String?
    @Published private(set) var highlightedButtons: Set<RemoteButton> = []
    private var rawPressed: Set<RemoteButton> = []
    private var voicePressed = false
    private var clearHighlight: Task<Void, Never>?
    private var effective = RemoteProfile()

    @Published private(set) var lastGesture: String?

    private var deadlineTimer: Timer?
    private var remapAfterRelease = false
    private var activeMap: [UInt64: UInt64] = [:]
    private static let nanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()
    private static let reportDeliveryMargin = 20
    private var now: Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

    init(preview: Bool) {
        self.preview = preview
        voice.status = { [weak self] message, ready in self?.voiceState(message, ready ? "ready" : "offline") }
        voice.keyPressed = { [weak self] down in
            self?.voicePressed = down
            self?.updateHighlight()
        }
        if CommandLine.arguments.contains("--verify") {
            voice.receipt = { [weak self] count, peak in self?.report("voiceSamples=\(count) peak=\(peak)") }
        }
        if preview {
            profile = .editorPreview
            effective = profile
        } else {
            reloadProfile()
        }
    }

    var editorState: RemoteEditorState {
        var state = RemoteEditorState(
            profile: profile, status: preview ? "预览" : status, voice: preview ? "预览" : voiceStatus,
            needsInput: !preview && needsPermission, needsPost: !preview && !CGPreflightPostEventAccess(),
            problem: profileError, feedback: feedback)
        state.revision = revision
        state.frontApp = frontApp
        state.highlightedButtons = RemoteButton.allCases.filter(highlightedButtons.contains)
        return state
    }

    private func updateHighlight() {
        var pressed = rawPressed
        if voicePressed { pressed.insert(.voice) }
        clearHighlight?.cancel()
        if !pressed.isEmpty {
            if highlightedButtons != pressed { highlightedButtons = pressed }
        } else if !highlightedButtons.isEmpty {
            clearHighlight = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                self?.highlightedButtons = []
            }
        }
    }

    private func resetPressed() {
        rawPressed = []
        voicePressed = false
        clearHighlight?.cancel()
        if !highlightedButtons.isEmpty { highlightedButtons = [] }
    }

    func reloadProfile() {
        guard !preview else { return }
        do {
            let saved = try RemoteProfile.read()
            let changed = saved != profile || profileError != nil
            profileError = nil
            if changed {
                cancelGestures()
                replaceProfile(saved)
                if locked { tick() }
            }
        } catch {
            profileError = error.localizedDescription
            if locked { tick() }
        }
    }

    var activeProfileName: String {
        frontApp.flatMap { profile.applications?[$0]?.name } ?? "默认方案"
    }

    func emitCurrentActiveProfile() {
        let name = activeProfileName
        lastReportedProfileName = name
        onActiveProfileChanged?(name)
    }

    private func notifyActiveProfileIfNeeded() {
        let name = activeProfileName
        guard lastReportedProfileName != name else { return }
        lastReportedProfileName = name
        onActiveProfileChanged?(name)
    }

    @discardableResult
    func edit(_ button: RemoteButton, gesture: RemoteGesture, action: RemoteAction, previous: RemoteAction? = nil)
        -> String?
    {
        if let profileError { return profileError }
        Task { @MainActor [weak self] in
            _ = await self?.editAsync(button, gesture: gesture, action: action, previous: previous)
        }
        return nil
    }

    func editAsync(
        _ button: RemoteButton, gesture: RemoteGesture, action: RemoteAction, previous: RemoteAction? = nil
    ) async -> String? {
        await saveAsync {
            try profile.editing(
                button, gesture: gesture, previous: previous ?? profile.action(for: button, gesture: gesture),
                action: action)
        }
    }

    func configureAsync(_ edit: RemoteMappingEdit, revision expected: UUID) async -> String? {
        await saveAsync {
            guard expected == revision else { throw PreferenceError.changedOnDisk }
            return try profile.applying(edit)
        }
    }

    private func replaceProfile(_ value: RemoteProfile) {
        revision = UUID()
        profile = value
        effective = value.resolved(for: frontApp)
        notifyActiveProfileIfNeeded()
    }

    private func saveAsync(_ change: () throws -> RemoteProfile) async -> String? {
        if let profileError { return profileError }
        guard !saving else { return "正在保存上一次配置更改，请稍候" }
        do {
            let previous = profile
            let next = try change()
            saving = true
            defer { saving = false }
            if !preview {
                try await Task.detached(priority: .userInitiated) {
                    try next.save(replacing: previous)
                }.value
            }
            cancelGestures()
            replaceProfile(next)
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
        gestures.cancel(holding: rawPressed)
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
        resetPressed()
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

    @discardableResult
    private func refreshFrontmost() -> Bool {
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard id != frontApp else { return false }
        cancelGestures()
        frontApp = id
        effective = profile.resolved(for: id)
        notifyActiveProfileIfNeeded()
        return true
    }

    func observeFrontmost() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontmostChanged), name: NSWorkspace.didActivateApplicationNotification,
            object: nil)
        refreshFrontmost()
    }

    @objc private func frontmostChanged() {
        if refreshFrontmost() { tick() }
    }

    private func tick() {
        guard locked && !sleeping else { return }
        refreshFrontmost()
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
                        monitor.resetPressed()
                        monitor.cancelGestures()
                        do {
                            try monitor.lease.recover()
                            monitor.update("等待遥控器连接")
                        } catch { monitor.update(error.localizedDescription) }
                    }
                }, Unmanaged.passUnretained(self).toOpaque())
            IOHIDManagerRegisterInputReportWithTimeStampCallback(
                hid,
                { context, result, sender, _, reportID, bytes, length, timestamp in
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
                    MainActor.assumeIsolated {
                        monitor.receive(device: device, id: reportID, bytes: payload, timestamp: timestamp)
                    }
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
            resetPressed()
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
        let desired = effective.deviceMap(canPost: CGPreflightPostEventAccess())
        if sourceID == current && lease.isSuppressed() {
            if activeMap == desired {
                remapAfterRelease = false
                return
            }
            // Retain a held native modifier's existing mapping until its release.
            if !rawPressed.isEmpty {
                remapAfterRelease = true
                return
            }
        }
        sourceID = nil
        cancelGestures()
        do {
            try lease.acquire(desired)
            remapAfterRelease = false
            activeMap = desired
            sourceID = current
            update("遥控器就绪")
        } catch { update(error.localizedDescription) }
    }

    private static func registryID(_ device: IOHIDDevice) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id) == KERN_SUCCESS ? id : nil
    }

    private func receive(device: IOHIDDevice, id: UInt32, bytes: [UInt8], timestamp: UInt64) {
        guard let sourceID, Self.registryID(device) == sourceID,
            let pressed = RemoteButton.pressed(reportID: id, bytes: bytes)
        else { return }
        if refreshFrontmost() { tick() }
        guard self.sourceID == sourceID else { return }
        if rawPressed != pressed {
            voice.physicalKeyChanged(down: pressed.contains(.voice))
            rawPressed = pressed
            updateHighlight()
        }
        if remapAfterRelease {
            gestures.cancel(holding: pressed)
            if pressed.isEmpty { tick() }
            return
        }
        pending.removeAll { $0.0.repeated && !pressed.contains($0.0.button) }
        let claimed = pressed.filter { activeMap[UInt64(7) << 32 | UInt64($0.usage)] == 0 }
        let reportTime = timestamp > 0 ? Int(Double(timestamp) * Self.nanosecondsPerTick / 1_000_000) : now
        let actions = gestures.ingest(claimed, at: min(reportTime, now), profile: effective)
        scheduleDeadline()
        deliver(actions)
    }

    private func scheduleDeadline() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let due = gestures.deadline else { return }
        // 给截止前到达 HID 层的报告留出交付时间，手势窗口仍按其原始时间戳计算。
        let delay = max(0, due + Self.reportDeliveryMargin - now)
        let timer = Timer(timeInterval: Double(delay) / 1000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.refreshFrontmost() {
                    self.tick()
                    return
                }
                let actions = self.gestures.advance(to: self.now - Self.reportDeliveryMargin)
                self.scheduleDeadline()
                self.deliver(actions)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    private func deliver(_ strokes: [RemoteStroke]) {
        guard !strokes.isEmpty else { return }
        if refreshFrontmost() {
            tick()
            return
        }
        guard sourceID != nil, !competing, lease.isSuppressed() else {
            cancelGestures()
            tick()
            return
        }
        for stroke in strokes {
            if stroke.repeated && (sending || !rawPressed.contains(stroke.button)) { continue }
            guard let action = effective.buttons[stroke.button.rawValue]?[stroke.gesture], action.kind != .none else {
                continue
            }
            pending.append((stroke, action))
        }
        guard !sending, !pending.isEmpty else { return }
        sending = true
        Task {
            defer { sending = false }
            while !pending.isEmpty {
                if refreshFrontmost() {
                    tick()
                    return
                }
                let (stroke, action) = pending.removeFirst()
                let current = generation
                guard sourceID != nil, !competing, lease.isSuppressed() else {
                    cancelGestures()
                    tick()
                    return
                }
                do {
                    try await ActionOutput.send(action) { [weak self] in
                        guard let self else { return true }
                        return self.generation != current || self.refreshFrontmost() || self.sourceID == nil
                            || self.competing || !self.lease.isSuppressed()
                    }
                    if current == generation {
                        feedback = nil
                        lastGesture = "\(stroke.button.name) · \(stroke.gesture.name)"
                        sent += 1
                    }
                } catch is CancellationError {
                    if current == generation {
                        cancelGestures()
                    }
                } catch {
                    if current == generation {
                        feedback = error.localizedDescription
                        cancelGestures()
                    }
                }
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
        // Representative per-app overrides are confined to the in-memory UI preview.
        let chrome = "com.google.Chrome"
        do {
            profile = try profile.applying(.addApp(id: chrome, name: "Google Chrome"))
            var previous = shortcut(33, "[")
            previous.flags = RemoteModifier.flags(RemoteModifier.all.filter { $0.code == 55 })
            var next = previous
            next.keyCode = 30
            next.label = "]"
            profile = try profile.applying(.action(app: chrome, button: .left, gesture: .single, value: previous))
            profile = try profile.applying(.action(app: chrome, button: .right, gesture: .single, value: next))
        } catch { assertionFailure("无效的遥控器预览配置") }
        return profile
    }
}
