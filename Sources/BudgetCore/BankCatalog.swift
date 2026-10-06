import Foundation
import CryptoKit

public struct BankRecord: Codable, Equatable, Identifiable, Sendable {
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
    public func search(_ text: String, country: String? = nil, includeInactive: Bool = false) -> [BankRecord] {
        let query = Ledger.normalized(text)
        return banks.filter { bank in
            (country == nil || bank.country == country) && (includeInactive || bank.active) && (query.isEmpty || ([bank.name, bank.legalName] + bank.aliases).contains { Ledger.normalized($0).contains(query) })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func logoURL(_ bank: BankRecord) -> URL? {
        guard let resource = bank.logoResource, !resource.contains(".."), !resource.contains(":") else { return nil }
        return Bundle.module.url(forResource: resource, withExtension: nil, subdirectory: "BankLogos") ?? Bundle.module.url(forResource: resource, withExtension: nil)
    }
    public var readinessIssues: [String] {
        var issues = manifest.notes
        if !manifest.namesComplete && manifest.nameScope != "top20-per-market" { issues.append("Полное покрытие банков трёх рынков не подтверждено.") }
        if !manifest.logosComplete { issues.append("Проверенные логотипы двадцати крупнейших банков каждого рынка не подготовлены.") }
        for bank in banks where bank.logoResource != nil {
            guard let url = logoURL(bank), let bytes = try? Data(contentsOf: url), (try? BankImages.validate(bytes)) != nil, bank.logoSource?.isEmpty == false, bank.logoUsage?.isEmpty == false, bank.logoCheckedOn != nil, SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == bank.logoSHA256 else { issues.append("Не проверен ресурс / контрольная сумма логотипа: " + bank.id); continue }
        }
        return issues
    }
}
