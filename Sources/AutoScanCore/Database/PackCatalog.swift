import Foundation

/// Каталог пакетів марок, що лежить в інтернеті (у репозиторії програми на GitHub).
public struct PackCatalog: Codable, Sendable {
    public struct Item: Codable, Identifiable, Hashable, Sendable {
        public let id: String
        public let brand: String
        public let title: String
        public let version: String
        public let matches: [String]
        public let file: String
        public let codes: Int

        public func applies(toBrand brand: String?) -> Bool {
            guard let b = brand?.lowercased() else { return false }
            return matches.contains { b.hasPrefix($0.lowercased()) }
        }
    }

    public let version: Int
    public let packs: [Item]

    /// Адреса каталогу. Нові марки, викладені в папку packs/ репозиторію, з'являються в програмі самі.
    public static let baseURL = URL(string: "https://raw.githubusercontent.com/romanslbdn-sudo/AutoScan/main/packs/")!
    public static var indexURL: URL { baseURL.appendingPathComponent("index.json") }

    public static func fileURL(_ item: Item) -> URL { baseURL.appendingPathComponent(item.file) }

    /// Чи новіша версія в каталозі за встановлену (порівняння «1.2» > «1.10» по числах).
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let l = local.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0, b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
