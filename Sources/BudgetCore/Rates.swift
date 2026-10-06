import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum RateProvider {
    public static func cbrURL(on day: Day?) -> URL {
        var c = URLComponents(string: "https://www.cbr.ru/scripts/XML_daily.asp")!
        if let d = day { let p = d.rawValue.split(separator: "-"); c.queryItems = [URLQueryItem(name: "date_req", value: "\(p[2])/\(p[1])/\(p[0])")] }; return c.url!
    }
    public static func frankfurterURL(base: String, quote: String, on day: Day?) throws -> URL {
        _ = try Currency.get(base); _ = try Currency.get(quote)
        var c = URLComponents(string: "https://api.frankfurter.dev/v2/rate/\(base)/\(quote)")!
        if let day { c.queryItems = [URLQueryItem(name: "date", value: day.rawValue)] }; return c.url!
    }
    public static func parseCBR(_ data: Data, requested: Day = .today) throws -> [FXRate] {
        guard data.count <= 2_097_152 else { throw BudgetError.invalid("Ответ провайдера слишком большой.") }
        let inspect = String(decoding: data, as: UTF8.self).uppercased()
        guard !inspect.contains("<!DOCTYPE"), !inspect.contains("<!ENTITY") else { throw BudgetError.invalid("Небезопасный XML отклонён.") }
        let delegate = CBRParser(); let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil, let date = delegate.day, date <= requested, !delegate.values.isEmpty else { throw BudgetError.invalid("Банк России вернул некорректные курсы или будущую дату.") }
        return try delegate.values.map { code, value in
            let rate = FXRate(base: code, quote: "RUB", rate: value, date: date, provider: "Банк России"); try Ledger.validateRate(rate); return rate
        }
    }
    public static func parseFrankfurter(_ data: Data, base: String, quote: String, requested: Day = .today) throws -> FXRate {
        struct Response: Decodable { let date: Day; let base: String; let quote: String; let rate: Decimal }
        guard data.count <= 2_097_152 else { throw BudgetError.invalid("Ответ провайдера слишком большой.") }
        let response: Response; do { response = try JSONDecoder().decode(Response.self, from: data) } catch { throw BudgetError.invalid("Frankfurter вернул некорректный ответ.") }
        guard response.base.uppercased() == base, response.quote.uppercased() == quote, response.date <= requested, response.rate > 0 else { throw BudgetError.invalid("Пара, дата или курс Frankfurter не соответствует запросу.") }
        let r = FXRate(base: base, quote: quote, rate: NSDecimalNumber(decimal: response.rate).stringValue, date: response.date, provider: "Frankfurter v2"); try Ledger.validateRate(r); return r
    }
}

private final class CBRParser: NSObject, XMLParserDelegate {
    var day: Day?; var values: [String: String] = [:]; var fields: [String: String] = [:]; var text = ""; var failure: Error?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        text = ""
        if elementName == "ValCurs", let date = attributeDict["Date"] { let p = date.split(separator: "."); if p.count == 3 { day = try? Day("\(p[2])-\(p[1])-\(p[0])") } }
        if elementName == "Valute" { fields = [:] }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if ["CharCode", "Nominal", "Value"].contains(elementName) { fields[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if elementName == "Valute", let code = fields["CharCode"], code != "RUB", (try? Currency.get(code)) != nil {
            do { let n = try Money.decimal(fields["Nominal"] ?? ""); let v = try Money.decimal((fields["Value"] ?? "").replacingOccurrences(of: ",", with: ".")); guard n > 0, v > 0 else { throw BudgetError.corrupt }; values[code] = NSDecimalNumber(decimal: try Money.divide(v, n)).stringValue }
            catch { failure = error; parser.abortParsing() }
        }
        text = ""
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { failure = BudgetError.corrupt; parser.abortParsing(); return nil }
}

private final class SafeRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url; completionHandler(url?.scheme == "https" && ["www.cbr.ru", "api.frankfurter.dev"].contains(url?.host ?? "") ? request : nil)
    }
}
public final class RateClient: @unchecked Sendable {
    private let session: URLSession
    public init() {
        let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 15; c.timeoutIntervalForResource = 15; c.httpShouldSetCookies = false; c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: c, delegate: SafeRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func cancel() { session.invalidateAndCancel() }
    public func download(_ url: URL) async throws -> Data {
        guard url.scheme == "https", ["www.cbr.ru", "api.frankfurter.dev"].contains(url.host ?? "") else { throw BudgetError.invalid("Внешний адрес не разрешён.") }
        var last: Error = BudgetError.storage("Курсы недоступны. Повторите или введите вручную.")
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let (bytes, response) = try await session.bytes(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw BudgetError.storage("Источник курсов недоступен. Повторите или используйте ручной курс.") }
                guard response.expectedContentLength <= 2_097_152 else { throw BudgetError.invalid("Ответ источника слишком большой.") }
                var data = Data(); for try await byte in bytes { if data.count >= 2_097_152 { throw BudgetError.invalid("Ответ источника слишком большой.") }; data.append(byte) }; return data
            } catch { last = error; if Task.isCancelled { throw CancellationError() }; if let h = error as? BudgetError, case .invalid = h { throw h }; if attempt < 2 { try await Task.sleep(for: .seconds(attempt + 1)) } }
        }
        throw last
    }
    public func cbr(on day: Day? = nil) async throws -> [FXRate] {
        // The latest registered publication can already be effective tomorrow.
        // Request the effective day explicitly and keep it fixed across midnight.
        let requested = day ?? .today
        return try RateProvider.parseCBR(await download(RateProvider.cbrURL(on: requested)), requested: requested)
    }
    public func fetch(base: String, quote: String, on day: Day? = nil) async throws -> FXRate {
        if let values = try? await cbr(on: day), let value = try Reports.rate(from: base, to: quote, rates: values, on: day ?? .today), let date = values.first?.date { return FXRate(base: base, quote: quote, rate: value, date: date, provider: "Банк России") }
        try Task.checkCancellation()
        return try RateProvider.parseFrankfurter(await download(RateProvider.frankfurterURL(base: base, quote: quote, on: day)), base: base, quote: quote, requested: day ?? .today)
    }
}
