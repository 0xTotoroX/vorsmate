// [INPUT]: 用户选择的城市、可见面板的天气及行情读数。
// [OUTPUT]: 工具页的天气摘要与原地换城、按来源标记时间的三行行情。
// [POS]: 复用总览模块样式，天气及行情独立启停。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import SwiftUI
import VorsmateCore
import VorsmateSystem

struct WeatherSection: View {
    @ObservedObject var feed: PanelFeed<WeatherReading>
    let city: WeatherCity?
    let client: WeatherMarketClient
    let visible: Bool
    @Binding var expanded: Bool
    let selectCity: (WeatherCity) -> Void
    let protectInteraction: (Bool) -> Void
    @State private var changingCity = false

    private var summary: String {
        guard let city else { return "选择城市" }
        if feed.failed { return city.name + (feed.value == nil ? " · 暂不可用" : " · 上次数据") }
        return city.name + (feed.value.map { " · " + $0.condition } ?? " · 正在获取")
    }

    private func degrees(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0))) + "°"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                PanelSummaryRow(
                    title: "天气", symbol: PluginID.weather.symbol, status: summary,
                    value: feed.value.map { degrees($0.temperature) + "C" } ?? "—",
                    navigation: .disclosure(expanded: expanded))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("weather.summary")
            .accessibilityLabel("天气")
            .accessibilityValue(summary + " " + (feed.value.map { degrees($0.temperature) } ?? ""))
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let reading = feed.value {
                        HStack {
                            if let low = reading.low, let high = reading.high {
                                Text("今日 \(degrees(low)) – \(degrees(high))")
                            }
                            Spacer()
                            Text(reading.observedAt.formatted(.dateTime.month().day().hour().minute()))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    if city == nil || changingCity {
                        WeatherCityPicker(client: client, protectInteraction: protectInteraction) { location in
                            selectCity(location)
                            changingCity = false
                        }
                    } else {
                        HStack {
                            Link("Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
                            Spacer()
                            Button("更换城市") { changingCity = true }
                        }
                        .font(.caption)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
        .onChange(of: expanded) { _, open in if !open { changingCity = false } }
        .task(id: visible ? city : nil) {
            guard visible, let city else { return }
            await feed.watch { try await client.weather(in: city) }
        }
    }
}

private struct WeatherCityPicker: View {
    let client: WeatherMarketClient
    let protectInteraction: (Bool) -> Void
    let select: (WeatherCity) -> Void
    @State private var query = ""
    @State private var options: [WeatherCity] = []
    @State private var message = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("搜索城市", text: $query).textFieldStyle(.roundedBorder).focused($focused)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            ForEach(options, id: \.self) { location in
                Button {
                    select(location)
                } label: {
                    HStack {
                        Text(location.name)
                        Spacer()
                        Text([location.admin1, location.country].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .onChange(of: focused) { _, active in protectInteraction(active) }
        .onDisappear { if focused { protectInteraction(false) } }
        .task(id: query) {
            options = []
            message = ""
            let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 2 else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
                let found = try await client.cities(matching: name)
                try Task.checkCancellation()
                options = found
                if found.isEmpty { message = "未找到城市" }
            } catch {
                if !Task.isCancelled { message = "暂时无法搜索城市" }
            }
        }
    }
}

struct MarketsSection: View {
    let feeds: [MarketInstrument: PanelFeed<MarketQuote>]
    let client: WeatherMarketClient
    let visible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("行情", systemImage: PluginID.markets.symbol).font(.system(size: 14, weight: .semibold))
            ForEach(MarketInstrument.allCases, id: \.self) { instrument in
                if let feed = feeds[instrument] {
                    MarketPriceRow(instrument: instrument, feed: feed)
                        .task(id: visible) {
                            guard visible else { return }
                            await feed.watch { try await client.quote(instrument) }
                        }
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

private struct MarketPriceRow: View {
    let instrument: MarketInstrument
    @ObservedObject var feed: PanelFeed<MarketQuote>

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(instrument.title)
                Link(instrument.source.name, destination: instrument.source.url)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                if let quote = feed.value {
                    HStack(spacing: 6) {
                        Text(
                            quote.value.formatted(.number.precision(.fractionLength(instrument == .dollarYuan ? 4 : 2)))
                        )
                        if let change = quote.changePercent {
                            Text((instrument == .solana ? "24h " : "") + String(format: "%+.2f%%", change))
                                .font(.caption)
                        }
                    }
                    Text((feed.failed ? "上次数据 · " : "") + quote.sourceTime).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(feed.failed ? "暂不可用" : "正在获取…").foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
        }
        .font(.callout)
    }
}
