// [INPUT]: 已支持的 RC003 蓝牙 HID 键盘身份及映射属性。
// [OUTPUT]: 接管与只读诊断共用的匹配条件。
package enum RemoteDeviceIdentity {
    package static let keyboard: [String: any Sendable] = [
        "VendorID": 0x2717, "ProductID": 0x32b8, "Transport": "Bluetooth Low Energy",
        "PrimaryUsagePage": 1, "PrimaryUsage": 6,
    ]
    package static let mapping = "UserKeyMapping"
    package static let mappingOwner = "VorsmateRemoteLease"
}
