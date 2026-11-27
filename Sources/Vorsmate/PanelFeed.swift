// [INPUT]: 可见视图的结构化任务、每个来源的读取函数与刷新间隔。
// [OUTPUT]: 单项最近读数、错误状态与按单调时钟限频的刷新。
// [POS]: 天气和各项行情独立保留读数；视图消失时 SwiftUI 取消任务。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Combine
import Foundation
import VorsmateSystem

@MainActor
final class PanelFeed<Value: Sendable>: ObservableObject {
    @Published private(set) var value: Value?
    @Published private(set) var failed = false
    private let interval: Duration
    private var nextUpdate: ContinuousClock.Instant?
    private var revision = 0

    init(interval: Duration) {
        self.interval = interval
    }

    func clear() {
        revision += 1
        value = nil
        failed = false
        nextUpdate = nil
    }

    func watch(_ fetch: @Sendable () async throws -> Value) async {
        let current = revision
        let clock = ContinuousClock()
        while !Task.isCancelled && revision == current {
            if let nextUpdate {
                do { try await clock.sleep(until: nextUpdate) } catch { return }
            }
            guard !Task.isCancelled, revision == current else { return }
            do {
                let fresh = try await fetch()
                guard !Task.isCancelled, revision == current else { return }
                value = fresh
                failed = false
            } catch {
                guard !Task.isCancelled, revision == current else { return }
                failed = true
            }
            nextUpdate = clock.now.advanced(by: failed ? min(interval, .seconds(60)) : interval)
        }
    }
}

extension WeatherMarketClient {
    static let preview = Self { request in
        let json: String
        switch request.url?.host {
        case "api.open-meteo.com":
            json =
                #"{"current":{"temperature_2m":19,"weather_code":2,"time":1795752000},"daily":{"temperature_2m_min":[12],"temperature_2m_max":[21]}}"#
        case "geocoding-api.open-meteo.com":
            json = #"{"results":[{"name":"示例市","latitude":0,"longitude":0}]}"#
        case "api.nasdaq.com":
            json =
                #"{"data":{"primaryData":{"lastSalePrice":"20,000.00","percentageChange":"+0.42%","lastTradeTimestamp":"Nov 25, 2026"}}}"#
        case "api.coingecko.com":
            json = #"{"solana":{"usd":75.12,"usd_24h_change":-1.4,"last_updated_at":1795752000}}"#
        case "open.er-api.com":
            json = #"{"result":"success","base_code":"USD","rates":{"CNY":7.0012},"time_last_update_unix":1795737600}"#
        default: throw URLError(.unsupportedURL)
        }
        return Data(json.utf8)
    }
}
