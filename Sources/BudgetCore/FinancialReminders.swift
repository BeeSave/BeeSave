import Foundation
import CryptoKit

public struct FinancialReminderRequest: Equatable, Sendable {
    public var id: String
    public var databaseToken: String
    public var eventToken: String
    public var fireAt: Date
    public var timeZoneID: String
}
public enum FinancialReminderPlanner {
    public static let prefix = "beesave.finance."
    public static func databaseToken(_ id: UUID) -> String { SHA256.hash(data: Data(id.uuidString.utf8)).map { String(format: "%02x", $0) }.joined() }
    public static func plan(db: Database, events: [FinanceEvent], now: Date = Date(), windowDays: Int = 45, limit: Int = 60, delivered: Set<String> = []) throws -> [FinancialReminderRequest] {
        guard db.financeData.reminders.systemEnabled else { return [] }
        let token = databaseToken(db.id), horizon = now.addingTimeInterval(TimeInterval(windowDays) * 86400)
        let contracts = Dictionary(uniqueKeysWithValues: db.financeData.contracts.map { ($0.id, $0) })
        let previous = delivered.union(db.financeData.reminders.deliveredKeys)
        var requests: [String: FinancialReminderRequest] = [:]
        for event in events where !event.isFulfilled {
            guard let contract = contracts[event.contractID], contract.status == .active, contract.reminders.enabled, let zone = TimeZone(identifier: contract.timeZoneID) else { continue }
            let offsets: [Int]
            switch event.kind {
            case .depositMaturity, .renewalDecision: offsets = contract.reminders.maturityOffsets
            case .rateChange: offsets = contract.reminders.rateOffsets
            case .depositInterest: guard contract.reminders.interestEnabled else { continue }; offsets = contract.reminders.paymentOffsets
            default: offsets = contract.reminders.paymentOffsets
            }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            for offset in Set(offsets) {
                let day = event.date.adding(-offset)
                var components = DateComponents(); components.year = FinanceMath.year(day); components.month = FinanceMath.month(day); components.day = FinanceMath.day(day); components.hour = contract.reminders.hour; components.minute = contract.reminders.minute; components.timeZone = zone
                guard let scheduled = calendar.date(from: components) else { continue }
                let key = prefix + SHA256.hash(data: Data((token + "|" + event.id + "|" + day.rawValue + "|" + String(contract.reminders.hour) + ":" + String(contract.reminders.minute) + "|" + zone.identifier).utf8)).map { String(format: "%02x", $0) }.joined()
                let postponed = db.financeData.reminders.eventSnoozedUntil?[event.id]
                let fire = db.financeData.reminders.snoozedUntil[key] ?? max(scheduled, postponed ?? scheduled)
                let explicitlyPostponed = postponed != nil || db.financeData.reminders.snoozedUntil[key] != nil
                guard fire > now, fire <= horizon, !previous.contains(key) || explicitlyPostponed else { continue }
                requests[key] = FinancialReminderRequest(id: key, databaseToken: token, eventToken: event.id, fireAt: fire, timeZoneID: zone.identifier)
            }
        }
        var unique = Set<String>()
        let deduplicated = requests.values.sorted { $0.id < $1.id }.filter { unique.insert($0.eventToken + "|" + String($0.fireAt.timeIntervalSince1970)).inserted }
        return Array(deduplicated.sorted { $0.fireAt == $1.fireAt ? $0.id < $1.id : $0.fireAt < $1.fireAt }.prefix(max(0, limit)))
    }
}
