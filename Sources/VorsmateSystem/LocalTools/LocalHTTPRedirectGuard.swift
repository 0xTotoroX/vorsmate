// [INPUT]: 本机客户端收到的 HTTP 重定向。
// [OUTPUT]: 拒绝重定向，留给调用者处理原响应。
// [POS]: 提醒事项与封面收藏共用的回环连接保护。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

final class LocalHTTPRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
