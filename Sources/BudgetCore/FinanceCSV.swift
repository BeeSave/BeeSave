import Foundation

/// CSV carries facts and contract identities, never future conditions or reminders.
struct FinanceCSVContract: Codable, Equatable {
    var id: UUID; var accountID: UUID; var kind: AccountKind; var start: Day; var end: Day?
    init(_ contract: FinancialContract) { id = contract.id; accountID = contract.accountID; kind = contract.kind; start = contract.start; end = contract.end }
    var stub: FinancialContract {
        var value = FinancialContract(accountID: accountID, kind: kind, start: start, end: end)
        value.id = id; value.status = .draft; value.note = "Импортированы факты. Условия договора заполните вручную или восстановите полную копию."
        return value
    }
}
struct FinanceCSVDetails: Codable, Equatable {
    var version = 1
    var createdAt: Date
    var operation: FinanceOperationDetails?
    var contracts: [FinanceCSVContract]
    var group: FinanceOperationGroup?
    var fulfillments: [FinanceFulfillment]
    var statements: [CreditStatement]?
    init(_ operation: Operation, db: Database) {
        createdAt = operation.createdAt; self.operation = operation.financial
        contracts = db.financeData.contracts.filter { $0.accountID == operation.accountID || $0.accountID == operation.toAccountID }.map(FinanceCSVContract.init)
        group = db.financeData.groups.first { $0.id == operation.financial?.groupID }
        fulfillments = db.financeData.fulfillments.filter { $0.operationIDs.contains(operation.id) }
        let statementIDs = Set((operation.financial?.statementAllocations ?? []).map(\.statementID))
        statements = statementIDs.isEmpty ? nil : db.financeData.statements.filter { statementIDs.contains($0.id) }
    }
}
