import Foundation

/// Bank geography is independent of a contract's calculation profile.
public struct BankMarket: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var currency: String
    public var areaRank: Int?
    public var economyRank: Int?
    public var requiresLogos: Bool

    public static let all: [BankMarket] = {
        guard let url = Bundle.module.url(forResource: "bank-markets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let markets = try? JSONDecoder().decode([BankMarket].self, from: data) else { return [] }
        return markets
    }()
    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    public static func get(_ id: String) -> BankMarket? { byID[id] }
    public static func preferredCountries(currency: String?) -> Set<String> {
        Set(all.filter { $0.currency == currency }.map(\.id))
    }
}

public struct BankChoice: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var country: String
    public var assetRank: Int?
}

public struct BankChoiceGroup: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var banks: [BankChoice]
}

struct BankRankingManifest: Decodable, Sendable {
    struct Dataset: Decodable, Sendable {
        struct Entry: Decodable, Sendable { var id: String; var rank: Int }
        struct SmallSystem: Decodable, Sendable { var activeBanks: Int; var url: String; var effectiveOn: String; var sourceSHA256: String }
        var url: String
        var effectiveOn: String
        var banks: [Entry]
        var smallSystem: SmallSystem?
    }
    var countries: [String: Dataset]
    static let shared: BankRankingManifest? = {
        guard let url = Bundle.module.url(forResource: "bank-rankings", withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }()
}

extension BankCatalog {
    public func selectionGroups(_ text: String, primaryCurrency: String?, userBanks: [UserBank] = []) -> [BankChoiceGroup] {
        let query = Ledger.normalized(text)
        var choices = matching(text).map { BankChoice(id: $0.id, name: $0.name, country: $0.country, assetRank: $0.assetRank) }
        choices += userBanks.filter { !$0.archived && (query.isEmpty || Ledger.normalized($0.name).contains(query)) }.map {
            BankChoice(id: $0.id, name: $0.name, country: $0.country == .other ? "OTHER" : $0.country.rawValue, assetRank: nil)
        }
        let preferred = BankMarket.preferredCountries(currency: primaryCurrency)
        let grouped = Dictionary(grouping: choices, by: \.country)
        return grouped.keys.sorted { Self.countryPrecedes($0, $1, preferred: preferred) }.map { country in
            BankChoiceGroup(id: country, name: BankMarket.get(country)?.name ?? (country == "OTHER" ? "Другие банки" : country),
                            banks: grouped[country, default: []].sorted { Self.bankPrecedes(rank: $0.assetRank, name: $0.name, id: $0.id,
                                                                                        rank: $1.assetRank, name: $1.name, id: $1.id) })
        }
    }

    static func countryPrecedes(_ lhs: String, _ rhs: String, preferred: Set<String>) -> Bool {
        if preferred.contains(lhs) != preferred.contains(rhs) { return preferred.contains(lhs) }
        if (lhs == "OTHER") != (rhs == "OTHER") { return rhs == "OTHER" }
        let left = BankMarket.get(lhs)?.name ?? lhs, right = BankMarket.get(rhs)?.name ?? rhs
        let order = left.compare(right, options: [.caseInsensitive, .numeric], locale: Locale(identifier: "ru_RU"))
        return order == .orderedSame ? lhs < rhs : order == .orderedAscending
    }

    static func bankPrecedes(rank lhsRank: Int?, name lhsName: String, id lhsID: String,
                             rank rhsRank: Int?, name rhsName: String, id rhsID: String) -> Bool {
        let left = lhsRank ?? Int.max, right = rhsRank ?? Int.max
        if left != right { return left < right }
        let order = lhsName.localizedStandardCompare(rhsName)
        return order == .orderedSame ? lhsID < rhsID : order == .orderedAscending
    }
}
