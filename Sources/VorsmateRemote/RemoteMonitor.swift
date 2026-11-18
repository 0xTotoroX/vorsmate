// [INPUT]: RC003 专用 HID 管理器、设备映射租约和虚拟键盘桥。
// [OUTPUT]: 实际状态及中心键的单次听写切换请求。
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
    private let lease = ReturnLease()
    private var manager: IOHIDManager?
    private var sourceID: UInt64?
    private var confirm = RemoteConfirm()
    private var timer: Timer?
    private var dispatchFailed = false
    private var locked = false
    private var sleeping = false

    private var competing: Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let id = app.bundleIdentifier else { return false }
            return id == "com.hd838a.RemoteMic" || id.hasPrefix("com.hd838a.RemoteMic.")
        }
    }
    private var typelessRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "now.typeless.desktop").isEmpty
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
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        tick()
    }

    private func idle(_ message: String) {
        sourceID = nil
        confirm = RemoteConfirm()
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
        if competing {
            idle("请先退出 SayAll，再接管确定键")
            return
        }
        needsPermission = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted
        if needsPermission {
            idle("需要输入监控权限")
            return
        }
        guard typelessRunning else {
            idle("等待 Typeless 打开")
            return
        }
        guard TypelessBridge.available else {
            idle("虚拟键盘桥未就绪")
            return
        }
        if manager == nil {
            let hid = IOHIDManagerCreate(nil, 0)
            IOHIDManagerSetDeviceMatching(hid, ReturnLease.identity as CFDictionary)
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
            confirm = RemoteConfirm()
            do { try lease.recover() } catch {
                update(error.localizedDescription)
                return
            }
        }
        guard let current else {
            update(devices.isEmpty ? "等待遥控器连接" : "请只连接一只 RC003")
            return
        }
        if sourceID == current && lease.isSuppressed() { return }
        sourceID = nil
        confirm = RemoteConfirm()
        do {
            try lease.acquire()
            sourceID = current
            update(dispatchFailed ? "上次发送未获确认" : "确定键就绪")
        } catch { update(error.localizedDescription) }
    }

    private static func registryID(_ device: IOHIDDevice) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id) == KERN_SUCCESS ? id : nil
    }

    private func receive(device: IOHIDDevice, id: UInt32, bytes: [UInt8]) {
        guard let sourceID, Self.registryID(device) == sourceID,
            confirm.released(reportID: id, bytes: bytes)
        else { return }
        guard !competing, typelessRunning, lease.isSuppressed() else {
            tick()
            return
        }
        // One synchronous, bounded request. Never retry an ambiguous receipt or queue stale toggles.
        dispatchFailed = !TypelessBridge.toggle()
        if !dispatchFailed { sent += 1 }
        update(dispatchFailed ? "发送未获确认" : "确定键就绪")
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        timer?.invalidate()
        timer = nil
        if locked { idle("已停用") }
    }
}
