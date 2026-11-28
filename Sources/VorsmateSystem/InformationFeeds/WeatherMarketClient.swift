// [INPUT]: 用户选择的城市、Open-Meteo、Nasdaq、CoinGecko 与 ExchangeRate-API 的 HTTPS 响应。
// [OUTPUT]: 当前天气、当日温度范围，以及按来源时间标记的三项行情。
// [POS]: Vos 工具页的网络读取层，可注入传输替身。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import VorsmateCore

public struct WeatherReading: Sendable {
    public let temperature: Double
    public let condition: String
    public let low: Double?
    public let high: Double?
    public let observedAt: Date
}

public enum MarketInstrument: CaseIterable, Sendable {
    case nasdaq100, solana, dollarYuan

    public var title: String {
        switch self {
        case .nasdaq100: "纳斯达克 100"
        case .solana: "SOL / USD"
        case .dollarYuan: "USD / CNY"
        }
    }

    public var source: (name: String, url: URL) {
        switch self {
        case .nasdaq100: ("Nasdaq", URL(string: "https://www.nasdaq.com/market-activity/index/ndx")!)
        case .solana: ("CoinGecko", URL(string: "https://www.coingecko.com/en/coins/solana")!)
        case .dollarYuan: ("ExchangeRate-API", URL(string: "https://www.exchangerate-api.com")!)
        }
    }
}

public struct MarketQuote: Sendable {
    public let value: Double
    public let changePercent: Double?
    public let sourceTime: String
}

public struct WeatherMarketClient: Sendable {
    private let read: @Sendable (URLRequest) async throws -> Data

    public init(
        read: @escaping @Sendable (URLRequest) async throws -> Data = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return data
        }
    ) {
        self.read = read
    }

    private func get<Result: Decodable>(_ address: String, query: [URLQueryItem] = []) async throws -> Result {
        guard var parts = URLComponents(string: address) else { throw URLError(.badURL) }
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("Vorsmate/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try JSONDecoder().decode(Result.self, from: await read(request))
    }

    public func cities(matching name: String) async throws -> [WeatherCity] {
        struct Matches: Decodable { let results: [WeatherCity]? }
        let data: Matches = try await get(
            "https://geocoding-api.open-meteo.com/v1/search",
            query: [
                .init(name: "name", value: name), .init(name: "language", value: "zh"),
                .init(name: "count", value: "5"),
            ])
        return data.results ?? []
    }

    public func weather(in city: WeatherCity) async throws -> WeatherReading {
        struct Forecast: Decodable {
            struct Current: Decodable {
                let temperature: Double
                let weatherCode: Int
                let time: TimeInterval
                enum CodingKeys: String, CodingKey {
                    case temperature = "temperature_2m"
                    case weatherCode = "weather_code"
                    case time
                }
            }
            struct Daily: Decodable {
                let low: [Double?]
                let high: [Double?]
                enum CodingKeys: String, CodingKey {
                    case low = "temperature_2m_min"
                    case high = "temperature_2m_max"
                }
            }
            let current: Current
            let daily: Daily?
        }
        let forecast: Forecast = try await get(
            "https://api.open-meteo.com/v1/forecast",
            query: [
                .init(name: "latitude", value: String(city.latitude)),
                .init(name: "longitude", value: String(city.longitude)),
                .init(name: "current", value: "temperature_2m,weather_code"),
                .init(name: "daily", value: "temperature_2m_min,temperature_2m_max"),
                .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "1"),
                .init(name: "timeformat", value: "unixtime"),
            ])
        return WeatherReading(
            temperature: forecast.current.temperature,
            condition: Self.condition(forecast.current.weatherCode),
            low: forecast.daily?.low.first ?? nil,
            high: forecast.daily?.high.first ?? nil,
            observedAt: Date(timeIntervalSince1970: forecast.current.time))
    }

    public func quote(_ instrument: MarketInstrument) async throws -> MarketQuote {
        switch instrument {
        case .nasdaq100:
            struct Nasdaq: Decodable {
                struct Index: Decodable {
                    struct Price: Decodable {
                        let lastSalePrice: String
                        let percentageChange: String?
                        let lastTradeTimestamp: String?
                    }
                    let primaryData: Price
                }
                let data: Index
            }
            let data: Nasdaq = try await get("https://api.nasdaq.com/api/quote/NDX/info?assetclass=index")
            let price = data.data.primaryData
            guard let value = Double(price.lastSalePrice.replacingOccurrences(of: ",", with: "")), value.isFinite,
                value > 0
            else { throw URLError(.cannotParseResponse) }
            let change = price.percentageChange.flatMap { Double($0.replacingOccurrences(of: "%", with: "")) }
            return MarketQuote(
                value: value, changePercent: change, sourceTime: Self.nasdaqDate(price.lastTradeTimestamp))
        case .solana:
            struct Crypto: Decodable {
                struct Price: Decodable {
                    let usd: Double
                    let dailyChange: Double?
                    let updatedAt: Double?
                    enum CodingKeys: String, CodingKey {
                        case usd
                        case dailyChange = "usd_24h_change"
                        case updatedAt = "last_updated_at"
                    }
                }
                let solana: Price
            }
            let data: Crypto = try await get(
                "https://api.coingecko.com/api/v3/simple/price",
                query: [
                    .init(name: "ids", value: "solana"), .init(name: "vs_currencies", value: "usd"),
                    .init(name: "include_24hr_change", value: "true"),
                    .init(name: "include_last_updated_at", value: "true"),
                ])
            guard data.solana.usd > 0 else { throw URLError(.cannotParseResponse) }
            return MarketQuote(
                value: data.solana.usd, changePercent: data.solana.dailyChange,
                sourceTime: Self.localDate(data.solana.updatedAt))
        case .dollarYuan:
            struct Exchange: Decodable {
                let result: String
                let baseCode: String
                let rates: [String: Double]
                let updatedAt: Double
                enum CodingKeys: String, CodingKey {
                    case result
                    case baseCode = "base_code"
                    case rates
                    case updatedAt = "time_last_update_unix"
                }
            }
            let data: Exchange = try await get("https://open.er-api.com/v6/latest/USD")
            guard data.result == "success", data.baseCode == "USD", let rate = data.rates["CNY"], rate > 0 else {
                throw URLError(.cannotParseResponse)
            }
            return MarketQuote(value: rate, changePercent: nil, sourceTime: Self.localDate(data.updatedAt))
        }
    }

    private static func nasdaqDate(_ stamp: String?) -> String {
        guard let stamp, !stamp.isEmpty else { return "时间未提供" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        let trimmed = stamp.replacingOccurrences(of: #" (EDT|EST|ET)$"#, with: "", options: .regularExpression)
        for format in ["MMM d, yyyy h:mm:ss a", "MMM d, yyyy h:mm a", "MMM d, yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                formatter.dateFormat = format.contains(":") ? "MM/dd HH:mm" : "MM/dd"
                return "美东 " + formatter.string(from: date)
            }
        }
        return stamp
    }

    private static func localDate(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds > 0 else { return "时间未提供" }
        return Date(timeIntervalSince1970: seconds).formatted(
            .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }

    private static func condition(_ code: Int) -> String {
        switch code {
        case 0: "晴"
        case 1: "大部晴朗"
        case 2: "多云"
        case 3: "阴"
        case 45, 48: "雾"
        case 51, 53, 55: "毛毛雨"
        case 56, 57, 66, 67: "冻雨"
        case 61: "小雨"
        case 63: "中雨"
        case 65: "大雨"
        case 71, 73, 75, 77: "降雪"
        case 80...82: "阵雨"
        case 85, 86: "阵雪"
        case 95, 96, 99: "雷暴"
        default: "天气代码 \(code)"
        }
    }
}
