// [INPUT]: 用户选择的城市及其经纬度。
// [OUTPUT]: 可保存在 Preferences 中的天气地点。
// [POS]: 本机设置与 Open-Meteo 查询共用的位置。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public struct WeatherCity: Codable, Hashable, Sendable {
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let admin1: String?
    public let country: String?

    public init(name: String, latitude: Double, longitude: Double, admin1: String? = nil, country: String? = nil) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.admin1 = admin1
        self.country = country
    }
}
