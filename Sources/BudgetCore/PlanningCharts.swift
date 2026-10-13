import Foundation

public struct PlanningChartPoint: Equatable, Identifiable, Sendable {
    public var id: String; public var date: Day; public var income: Int64; public var expense: Int64; public var forecast: Bool; public var missing: [String]
}
public enum PlanningCharts {
    public static func monthly(db: Database, from: Day, through: Day, cash: Bool, filters: Filters = Filters(), forecast: [PlannedOccurrence]) throws -> [PlanningChartPoint] {
        let currency = db.settings.baseCurrency
        var amounts: [String:(Int64,Int64)] = [:], gaps: [String:[String]] = [:]
        let selectedAccounts = Set(db.accounts.filter { !cash || ($0.kind == .ordinary && $0.businessProjectID == nil) }.map(\.id)).intersection(filters.accounts.isEmpty ? Set(db.accounts.map(\.id)) : filters.accounts)
        let selectedFlowIDs = Set(Reports.selected(db,filters:filters,kinds:[.income,.expense]).map(\.id))
        for o in db.operations where o.date >= from && o.date <= .today && o.date <= through {
            try Task.checkCancellation(); let key = o.date.month
            if !cash && (!o.kind.isFlow || !selectedFlowIDs.contains(o.id)) { continue }
            do {
                var signed: Int64 = 0
                if cash {
                    if selectedAccounts.contains(o.accountID) && o.kind != .opening && o.kind != .adjustment {
                        let a = try db.account(o.accountID), rate = try Reports.rate(from:a.currency,to:currency,rates:o.fx,on:o.date)
                        guard a.currency == currency || rate != nil else { throw BudgetError.missing("Нет курса") }
                        signed = a.currency == currency ? o.posting(for:a.id) : try Money.convert(o.posting(for:a.id),from:a.currency,to:currency,rate:rate!)
                    }
                    if let id = o.toAccountID,selectedAccounts.contains(id) {
                        let a = try db.account(id),rate = try Reports.rate(from:a.currency,to:currency,rates:o.fx,on:o.date)
                        guard a.currency == currency || rate != nil else { throw BudgetError.missing("Нет курса") }
                        signed = try Money.add(signed,a.currency == currency ? o.posting(for:id) : Money.convert(o.posting(for:id),from:a.currency,to:currency,rate:rate!))
                    }
                } else {
                    let a = try db.account(o.accountID), rate = try Reports.rate(from:a.currency,to:currency,rates:o.fx,on:o.date)
                    guard a.currency == currency || rate != nil else { throw BudgetError.missing("Нет курса") }
                    let amount = a.currency == currency ? o.amount : try Money.convert(o.amount,from:a.currency,to:currency,rate:rate!)
                    signed = o.kind == .income ? amount : -amount
                }
                var pair = amounts[key] ?? (0,0)
                if signed >= 0 { pair.0 = try Money.add(pair.0,signed) } else { pair.1 = try Money.add(pair.1,FinanceMath.positiveMagnitude(signed)) }; amounts[key] = pair
            } catch BudgetError.overflow { throw BudgetError.overflow } catch { gaps[key,default:[]].append(o.id.uuidString) }
        }
        var future: [String:(Int64,Int64)] = [:]
        for e in forecast where (e.date >= .today || (!e.income && e.date < .today)) && e.date <= through {
            if cash && !PlanningEngine.affectsPersonal(e,db:db) { continue }
            let key = max(e.date,.today).month
            if !filters.accounts.isEmpty,let id = e.accountID,!filters.accounts.contains(id) { continue }
            if let id = filters.projectID,e.projectID != id { continue }
            if e.incomplete == true { gaps[key,default:[]].append(e.title + ": условия не уточнены") }
            guard let amount = cash ? e.remaining : e.reportAmount else { gaps[key,default:[]].append(e.title); continue }
            do {
                let amount = try PlanningEngine.converted(amount,currency:e.currency,to:currency,db:db,date:e.date)
                var pair = future[key] ?? (0,0); if e.income { pair.0 = try Money.add(pair.0,amount) } else { pair.1 = try Money.add(pair.1,amount) }; future[key] = pair
            } catch BudgetError.overflow { throw BudgetError.overflow } catch { gaps[key,default:[]].append(e.title) }
        }
        var rows: [PlanningChartPoint] = [], month = from.firstOfMonth
        while month <= through {
            let actual = amounts[month.month] ?? (0,0), expected = future[month.month] ?? (0,0), missing = gaps[month.month] ?? []
            if month <= .today { rows.append(PlanningChartPoint(id:month.month+".fact",date:min(month.lastOfMonth,.today),income:actual.0,expense:actual.1,forecast:false,missing:missing)) }
            if month.lastOfMonth >= .today { rows.append(PlanningChartPoint(id:month.month+".forecast",date:month.lastOfMonth,income:try Money.add(actual.0,expected.0),expense:try Money.add(actual.1,expected.1),forecast:true,missing:missing)) }
            month = try FinanceMath.addingMonths(month,1)
        }
        return rows
    }
}
