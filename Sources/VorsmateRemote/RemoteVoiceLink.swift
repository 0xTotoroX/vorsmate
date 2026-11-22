// [INPUT]: 已连接的 RC003、CoreBluetooth ATVV 通知与现有虚拟音频端点。
// [OUTPUT]: 语音键按住期间的 PCM、设备就绪状态；所有会话在主队列串行处理。
import CoreBluetooth
import Foundation
import VorsmateCore

@MainActor
final class RemoteVoiceLink: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private static func uuid(_ field: Int) -> CBUUID {
        CBUUID(string: String(format: "AB5E%04X-5A21-4F05-BC7D-AF01F617B664", field))
    }
    private let service = uuid(1), txID = uuid(2), audioID = uuid(3), controlID = uuid(4)
    private var central: CBCentralManager?
    private var peer: CBPeripheral?
    private var tx: CBCharacteristic?, audio: CBCharacteristic?, control: CBCharacteristic?
    private var deviceIdentity: UUID?
    private var requestedCaps = false
    private var version: UInt16?
    private var opening = false
    private var receiving = false
    private var session: UInt8 = 0
    private var decoder = RemoteVoiceDecoder()
    private let output = RemoteAudioOutput()
    private var deadline: TimeInterval = 0
    private var voiceDeadline: RemoteVoiceDeadline?
    private var retryAfter: TimeInterval = 0
    private var samples = 0
    private var peak: Int = 0
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var status: (String, Bool) -> Void = { _, _ in }
    var keyPressed: (Bool) -> Void = { _ in }
    var receipt: ((Int, Int) -> Void)?

    override init() {
        super.init()
        output.onFailure = { [weak self] error in self?.reset(error.localizedDescription) }
    }

    func poll(identity: UUID?) {
        if deviceIdentity != identity {
            stop()
            deviceIdentity = identity
        }
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
            return
        }
        guard let central, central.state == .poweredOn, now >= retryAfter else { return }
        if peer == nil {
            // Only peripherals already connected to macOS. Never connect to an advertising neighbour.
            let connected = central.retrieveConnectedPeripherals(withServices: [service, CBUUID(string: "1812")])
            let candidates = connected.filter {
                RemoteVoice.matchesPeripheral($0.identifier, name: $0.name, identity: identity)
            }
            guard candidates.count == 1, let target = candidates.first else {
                status(candidates.isEmpty ? "等待遥控器蓝牙语音服务" : "请只连接一只遥控器", false)
                return
            }
            peer = target
            target.delegate = self
            deadline = now + 10
            status("正在连接遥控器麦克风", false)
            central.connect(target)
        } else if version != nil && !output.isBound {
            reset("虚拟麦克风已断开")
        } else if let expiry = voiceDeadline?.expiry(at: now) {
            switch expiry {
            case .firstPacket: reset("未收到遥控器语音，正在重连")
            case .interrupted: reset("遥控器语音已中断，正在重连")
            case .maximumDuration: reset("遥控器语音会话已超时")
            }
        } else if deadline > 0 && now >= deadline {
            reset("遥控器语音连接超时")
        }
    }

    func stop() {
        clearPeer()
        central?.delegate = nil
        central = nil
        deviceIdentity = nil
        retryAfter = 0
    }

    private func clearPeer() {
        if opening || receiving {
            closeRemoteMic()
            keyPressed(false)
        }
        let old = peer
        peer = nil
        old?.delegate = nil
        if let old { central?.cancelPeripheralConnection(old) }
        output.close()
        decoder = RemoteVoiceDecoder()
        tx = nil
        audio = nil
        control = nil
        version = nil
        requestedCaps = false
        receiving = false
        opening = false
        deadline = 0
        voiceDeadline = nil
        samples = 0
        peak = 0
    }
    private func reset(_ message: String) {
        clearPeer()
        retryAfter = now + 3
        status(message, false)
    }
    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        guard manager === central else { return }
        switch manager.state {
        case .poweredOn: poll(identity: deviceIdentity)
        case .unauthorized: reset("请在隐私与安全性中允许遥控器使用蓝牙")
        case .poweredOff: reset("蓝牙已关闭")
        default: reset("等待蓝牙可用")
        }
    }
    func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard manager === central, peripheral === peer else { return }
        peripheral.discoverServices([service])
    }
    func centralManager(_ manager: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard manager === central, peripheral === peer else { return }
        reset("遥控器麦克风连接失败")
    }
    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard manager === central, peripheral === peer else { return }
        reset("遥控器麦克风已断开")
    }
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        if peripheral === peer && invalidatedServices.contains(where: { $0.uuid == service }) {
            reset("遥控器语音服务已变化")
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === peer else { return }
        guard error == nil, let found = peripheral.services?.first(where: { $0.uuid == service }) else {
            reset("遥控器没有可用的 ATVV 语音服务")
            return
        }
        peripheral.discoverCharacteristics([txID, audioID, controlID], for: found)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === peer, service.uuid == self.service else { return }
        let chars = service.characteristics ?? []
        tx = chars.first { $0.uuid == txID }
        audio = chars.first { $0.uuid == audioID }
        control = chars.first { $0.uuid == controlID }
        guard error == nil, let tx, let audio, let control,
            !tx.properties.intersection([.write, .writeWithoutResponse]).isEmpty
        else {
            reset("遥控器语音通道不完整")
            return
        }
        peripheral.setNotifyValue(true, for: audio)
        peripheral.setNotifyValue(true, for: control)
    }
    func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard peripheral === peer else { return }
        guard error == nil, characteristic.isNotifying else {
            reset("遥控器语音订阅失败")
            return
        }
        if audio?.isNotifying == true, control?.isNotifying == true, !requestedCaps {
            requestedCaps = true
            write([0x0a, 1, 0, 0, 3, 3])
        }
    }
    private func write(_ bytes: [UInt8]) {
        guard let tx, let peer, peer.state == .connected else { return }
        let type: CBCharacteristicWriteType = tx.properties.contains(.write) ? .withResponse : .withoutResponse
        peer.writeValue(Data(bytes), for: tx, type: type)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if peripheral === peer, characteristic === tx, error != nil { reset("遥控器语音指令失败") }
    }
    private func closeRemoteMic() {
        guard let version else { return }
        write(version >= 0x0100 ? [0x0d, session] : [0x0d])
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === peer else { return }
        guard error == nil, let value = characteristic.value else {
            reset("遥控器语音读取失败")
            return
        }
        if characteristic === control {
            handleControl(Array(value))
        } else if characteristic === audio, voiceDeadline != nil, !value.isEmpty, value.count <= 512 {
            if !receiving { begin() }
            let pcm = decoder.decode(value)
            do {
                try output.write(pcm)
                if samples == 0 {
                    status("遥控器麦克风正在收音", true)
                }
                voiceDeadline?.receivedPacket(at: now)
                samples += pcm.count
                if receipt != nil { peak = max(peak, pcm.reduce(0) { max($0, abs(Int($1))) }) }
            } catch { reset(error.localizedDescription) }
        }
    }
    private func begin() {
        receiving = true
        opening = false
        status("等待遥控器语音数据", true)
    }
    private func handleControl(_ bytes: [UInt8]) {
        guard let opcode = bytes.first else { return }
        if opcode == 0x0b && requestedCaps && version == nil {
            guard let accepted = RemoteVoice.version16k(bytes) else {
                reset("遥控器不支持 16 kHz 语音")
                return
            }
            do { try output.prepare() } catch {
                reset(error.localizedDescription)
                return
            }
            version = accepted
            deadline = 0
            status("遥控器麦克风就绪", true)
            return
        }
        guard let version else { return }
        switch opcode {
        case 8 where !receiving && !opening:
            // START_SEARCH is generated by the physical voice key.
            keyPressed(true)
            opening = true
            session = 0
            voiceDeadline = RemoteVoiceDeadline(openedAt: now)
            decoder = RemoteVoiceDecoder()
            write(version >= 0x0100 ? [0x0c, 0] : [0x0c, 0, 2])
        case 4 where voiceDeadline != nil:
            guard bytes.count < 3 || bytes[2] == 2 else {
                reset("遥控器切换到了不支持的语音格式")
                return
            }
            session = bytes.count > 3 ? bytes[3] : 0
            if !receiving { begin() }
        case 0 where receiving || opening:
            keyPressed(false)
            output.end()
            let count = samples
            let level = peak
            receiving = false
            opening = false
            voiceDeadline = nil
            decoder = RemoteVoiceDecoder()
            samples = 0
            peak = 0
            status("遥控器麦克风就绪", true)
            receipt?(count, level)
        case 0x0a where bytes.count >= 7:
            let seed = Int16(bitPattern: UInt16(bytes[4]) << 8 | UInt16(bytes[5]))
            decoder = RemoteVoiceDecoder(predictor: seed, index: bytes[6])
        default: break
        }
    }
}
