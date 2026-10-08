import Foundation
import CryptoKit

public struct BankRecord: Codable, Equatable, Identifiable, Sendable {
    public var assetRank: Int? = nil
    public var rankingSource: String? = nil
    public var id: String; public var name: String; public var legalName: String; public var country: String; public var type: String; public var aliases: [String]; public var regulatorIDs: [String: String]; public var active: Bool; public var website: String?; public var logoResource: String?; public var logoSource: String?; public var logoUsage: String?; public var logoSHA256: String?; public var logoCheckedOn: String?
    public init(id: String, name: String, country: String, type: String = "bank", aliases: [String] = [], regulatorIDs: [String: String] = [:]) { self.id = id; self.name = name; self.legalName = name; self.country = country; self.type = type; self.aliases = aliases; self.regulatorIDs = regulatorIDs; self.active = true }
}
public struct BankCatalogSource: Codable, Equatable, Sendable {
    public var name: String; public var url: String; public var retrievedOn: String?; public var effectiveOn: String?; public var records: Int; public var complete: Bool
}
public struct BankCatalogManifest: Codable, Equatable, Sendable {
    public var nameScope: String? = nil; public var version: Int; public var builtOn: String; public var sources: [BankCatalogSource]; public var namesComplete: Bool; public var logosComplete: Bool; public var notes: [String]
}
public struct BankCatalog: Codable, Equatable, Sendable {
    public var manifest: BankCatalogManifest; public var banks: [BankRecord]
    public static let shared: BankCatalog = {
        guard let url = Bundle.module.url(forResource: "banks", withExtension: "json"), let bytes = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(BankCatalog.self, from: bytes) else {
            return BankCatalog(manifest: BankCatalogManifest(version: 1, builtOn: "", sources: [], namesComplete: false, logosComplete: false, notes: ["Каталог банков недоступен; можно добавить банк вручную."]), banks: [])
        }
        return catalog
    }()
    private static let sharedByID = Dictionary(uniqueKeysWithValues: shared.banks.map { ($0.id, $0) })
    public static func get(_ id: String) -> BankRecord? { sharedByID[id] }
    func matching(_ text: String, country: String? = nil, includeInactive: Bool = false) -> [BankRecord] {
        let query = Ledger.normalized(text)
        return banks.filter { bank in
            (country == nil || bank.country == country) && (includeInactive || bank.active) && (query.isEmpty || ([bank.name, bank.legalName] + bank.aliases).contains { Ledger.normalized($0).contains(query) })
        }
    }
    public func search(_ text: String, country: String? = nil, includeInactive: Bool = false, primaryCurrency: String? = nil) -> [BankRecord] {
        let preferred = BankMarket.preferredCountries(currency: primaryCurrency)
        return matching(text, country: country, includeInactive: includeInactive).sorted {
            if $0.country != $1.country { return Self.countryPrecedes($0.country, $1.country, preferred: preferred) }
            return Self.bankPrecedes(rank: $0.assetRank, name: $0.name, id: $0.id, rank: $1.assetRank, name: $1.name, id: $1.id)
        }
    }
    public func logoURL(_ bank: BankRecord) -> URL? {
        guard let resource = bank.logoResource, !resource.contains(".."), !resource.contains(":") else { return nil }
        return Bundle.module.url(forResource: resource, withExtension: nil, subdirectory: "BankLogos") ?? Bundle.module.url(forResource: resource, withExtension: nil)
    }
    public var readinessIssues: [String] {
        var issues = manifest.notes
        if manifest.nameScope == "top20-economies-plus-retained" {
            for market in BankMarket.all where market.economyRank != nil {
                let ranked = banks.filter { $0.country == market.id && $0.active && $0.assetRank != nil }
                let dataset = BankRankingManifest.shared?.countries[market.id]
                let expected = dataset?.smallSystem?.activeBanks ?? 20
                let identities = Set(dataset?.banks.map(\.id) ?? [])
                if dataset == nil || ranked.count != expected || ranked.compactMap(\.assetRank).sorted() != Array(1...max(1, expected)) || Set(ranked.map(\.id)) != identities {
                    issues.append("Рейтинг банков не подготовлен: " + market.name)
                }
                if market.requiresLogos {
                    for bank in ranked where bank.logoResource == nil { issues.append("Обязательный логотип не подготовлен: " + bank.id) }
                }
            }
        } else if !manifest.namesComplete && manifest.nameScope != "top20-per-market" { issues.append("Покрытие банков каталога не подтверждено.") }
        if !manifest.logosComplete { issues.append("Проверенные логотипы двадцати крупнейших банков каждого рынка не подготовлены.") }
        for bank in banks where bank.logoResource != nil {
            guard let url = logoURL(bank), let bytes = try? Data(contentsOf: url), (try? BankImages.validate(bytes)) != nil, bank.logoSource?.isEmpty == false, bank.logoUsage?.isEmpty == false, bank.logoCheckedOn != nil, SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == bank.logoSHA256 else { issues.append("Не проверен ресурс / контрольная сумма логотипа: " + bank.id); continue }
        }
        return issues
    }
}
