// [INPUT]: 固定的天气、指数、代币价格和外汇响应。
// [OUTPUT]: 验证天气取当前时刻、行情来源日期与百分数，缺失价格保留不可用状态。
// [POS]: Vos 信息模块的数据边界测试，不请求外部服务。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing
import VorsmateCore
import VorsmateSystem

@Suite("天气与行情数据")
struct WeatherMarketTests {
    @Test("当前天气使用当前代码，最低最高温取当日，保留零度")
    func weather() async throws {
        let client = WeatherMarketClient { request in
            let url = try #require(request.url)
            let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(query.contains(.init(name: "latitude", value: "30.1")))
            #expect(query.contains(.init(name: "timezone", value: "auto")))
            return Data(
                #"{"current":{"temperature_2m":0,"weather_code":71,"time":1600000000},"daily":{"temperature_2m_min":[-2],"temperature_2m_max":[3]}}"#
                    .utf8)
        }
        let reading = try await client.weather(in: WeatherCity(name: "示例", latitude: 30.1, longitude: 121))
        #expect(reading.temperature == 0 && reading.condition == "降雪")
        #expect(reading.low == -2 && reading.high == 3)
        #expect(reading.observedAt == Date(timeIntervalSince1970: 1_600_000_000))
    }

    @Test("休市日期、日涨幅和参考汇率各自保留来源语义")
    func markets() async throws {
        let client = WeatherMarketClient { request in
            switch request.url?.host {
            case "api.nasdaq.com":
                return Data(
                    #"{"data":{"primaryData":{"lastSalePrice":"10,123.45","percentageChange":"-1.25%","lastTradeTimestamp":"Feb 6, 2026"}}}"#
                        .utf8)
            case "api.coingecko.com":
                return Data(#"{"solana":{"usd":123.45,"usd_24h_change":null,"last_updated_at":1700000000}}"#.utf8)
            default:
                return Data(
                    #"{"result":"success","base_code":"USD","rates":{"CNY":7.00123},"time_last_update_unix":1700000000}"#
                        .utf8)
            }
        }
        let index = try await client.quote(.nasdaq100)
        #expect(index.value == 10_123.45 && index.changePercent == -1.25)
        #expect(index.sourceTime == "美东 02/06")
        let sol = try await client.quote(.solana)
        #expect(sol.value == 123.45 && sol.changePercent == nil)
        let fx = try await client.quote(.dollarYuan)
        #expect(fx.value == 7.00123 && fx.changePercent == nil)
    }

    @Test("缺价与请求失败都不会伪装成零")
    func missingPrice() async {
        let client = WeatherMarketClient { _ in
            Data(#"{"data":{"primaryData":{"lastSalePrice":"N/A","lastTradeTimestamp":null}}}"#.utf8)
        }
        await #expect(throws: URLError.self) { try await client.quote(.nasdaq100) }
    }
}
