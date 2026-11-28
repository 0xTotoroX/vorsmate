// [INPUT]: Sparkle / URLSession 的嵌套错误以及更新阶段。
// [OUTPUT]: 可解释的中文失败原因，不把服务器或验签错误混成断网。
// [POS]: 更新窗口的失败分类；不输出服务器 URL、设备信息或底层日志。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Sparkle

enum UpdateStage: Equatable { case checking, offered, downloading, preparing, ready, installing, finished }
struct UpdateTimeouts {
    var checking: Duration = .seconds(20)
    var downloading: Duration = .seconds(60)
    var preparing: Duration = .seconds(120)
}

enum UpdateFailure: Error, Equatable {
    case timedOut(UpdateStage)
    case offline, unreachable
    case http(Int)
    case invalidFeed, invalidSignature, untrustedSource
    case configuration, installation, other

    init(_ error: Error) {
        if let failure = error as? Self {
            self = failure
            return
        }
        let error = error as NSError
        var errors = [error]
        var next = error.userInfo[NSUnderlyingErrorKey] as? NSError
        while let value = next, errors.count < 8 {
            errors.append(value)
            next = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if errors.contains(where: { $0.domain == SUSparkleErrorDomain && [3001, 3002].contains($0.code) }) {
            self = .invalidSignature
        } else if errors.contains(where: { $0.domain == NSURLErrorDomain && $0.code == NSURLErrorTimedOut }) {
            self = .timedOut(.checking)
        } else if errors.contains(where: {
            $0.domain == NSURLErrorDomain && $0.code == NSURLErrorNotConnectedToInternet
        }) {
            self = .offline
        } else if errors.contains(where: {
            $0.domain == NSURLErrorDomain
                && [
                    NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
                    NSURLErrorNetworkConnectionLost, NSURLErrorSecureConnectionFailed,
                ].contains($0.code)
        }) {
            self = .unreachable
        } else if let status = errors.compactMap({ item -> Int? in
            guard item.domain == SUSparkleErrorDomain, item.code == 2001,
                let range = item.localizedDescription.range(of: #"\([45][0-9]{2}\)$"#, options: .regularExpression)
            else { return nil }
            return Int(item.localizedDescription[range].dropFirst().dropLast())
        }).first {
            self = .http(status)
        } else if errors.contains(where: { $0.domain == SUSparkleErrorDomain && [1000, 1002].contains($0.code) }) {
            self = .invalidFeed
        } else if errors.contains(where: { $0.domain == SUSparkleErrorDomain && (1...7).contains($0.code) }) {
            self = .configuration
        } else if errors.contains(where: { $0.domain == SUSparkleErrorDomain && (3000...4999).contains($0.code) }) {
            self = .installation
        } else {
            self = .other
        }
    }
    var title: String {
        switch self {
        case .timedOut: "更新等待超时"
        case .invalidSignature: "更新验签失败"
        case .untrustedSource: "更新来源不匹配"
        case .configuration: "更新配置异常"
        default: "暂时无法完成更新"
        }
    }
    var detail: String {
        switch self {
        case .timedOut(.downloading): "下载长时间没有进展，已停止等待。可以重试。"
        case .timedOut(.preparing): "准备更新耗时过长，已停止本次操作。可以重试。"
        case .timedOut: "检查更新超过等待时间，已取消本次检查。可以重试。"
        case .offline: "当前没有网络连接。连接后可以重试。"
        case .unreachable: "暂时无法连接更新服务器。请检查网络连接后重试。"
        case .http(403): "更新服务器拒绝了请求（403）。请稍后重试。"
        case .http(429): "更新服务器暂时限制了请求频率（429）。请稍后重试。"
        case .http(404): "暂时找不到更新源或安装包（404）。请稍后重试。"
        case .http(let code): "更新服务器返回错误（\(code)）。请稍后重试。"
        case .invalidFeed: "更新描述文件无法读取，已停止更新。请稍后重试。"
        case .invalidSignature: "更新文件的签名验证未通过，已停止更新。请重试或反馈问题。"
        case .untrustedSource: "安装包不属于此项目的官方发布，已停止更新。"
        case .configuration: "更新器配置不完整。请从官方发布页获取新版或反馈问题。"
        case .installation: "安装或重启未完成。请稍后重试。"
        case .other: "更新过程中发生错误。可以重试；若持续失败，请反馈问题。"
        }
    }
}
