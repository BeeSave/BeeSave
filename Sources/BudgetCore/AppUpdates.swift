import Foundation
import CryptoKit
import Combine

public enum AppUpdateError: Error, LocalizedError, Equatable {
    case invalidMetadata, untrustedURL, incompatible, tooLarge, checksum, noRelease
    case http(Int), rateLimited, emptyArchive
    public var errorDescription: String? {
        switch self {
        case .invalidMetadata: "GitHub вернул некорректные сведения об обновлении. Повторите проверку позже."
        case .untrustedURL: "Адрес обновления не относится к разрешённому репозиторию BeeSave."
        case .incompatible: "Этот выпуск не поддерживает вашу версию macOS или процессор."
        case .tooLarge: "Файл обновления превышает допустимый размер."
        case .checksum: "Проверка архива не пройдена. Скачайте обновление повторно."
        case .noRelease: "Опубликованных стабильных выпусков пока нет."
        case .http(let code): "GitHub недоступен (код \(code)). Повторите проверку позже."
        case .rateLimited: "GitHub временно ограничил запросы. Повторите проверку позже."
        case .emptyArchive: "GitHub вернул пустой архив. Скачайте обновление повторно."
        }
    }
}

/// Stable numeric release versions. Missing trailing components are zero.
public struct AppVersion: Comparable, Equatable, Sendable {
    private let parts: [Int]
    public init(_ value: String) throws {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count), components.allSatisfy({
            !$0.isEmpty && $0.count <= 9 && $0.utf8.allSatisfy { (48...57).contains($0) }
        }) else { throw AppUpdateError.invalidMetadata }
        parts = components.map { Int($0)! } + Array(repeating: 0, count: 3 - components.count)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

public struct AppUpdateManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let version: String
    public let build: Int
    public let minimumMacOS: String
    public let architecture: String
    public let repository: String
    public let tag: String
    public let assetURL: URL
    public let sha256: String
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", version, build, minimumMacOS = "minimum_macos"
        case architecture, repository, tag, assetURL = "asset_url", sha256
    }
    public func validate() throws {
        _ = try AppVersion(version); _ = try AppVersion(minimumMacOS)
        guard schemaVersion == 1, build > 0, repository == "BeeSave/BeeSave", tag == "v" + version,
              architecture == "arm64", sha256.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw AppUpdateError.invalidMetadata }
        guard assetURL.absoluteString == "https://github.com/BeeSave/BeeSave/releases/download/\(tag)/BeeSave-macos-arm64.zip"
        else { throw AppUpdateError.untrustedURL }
    }
    public func isNewer(than version: String, build: Int) throws -> Bool {
        let incoming = try AppVersion(self.version), installed = try AppVersion(version)
        return incoming > installed || (incoming == installed && self.build > build)
    }
    public func isCompatible(macOS: String, architecture: String) throws -> Bool {
        try AppVersion(macOS) >= AppVersion(minimumMacOS) && architecture == self.architecture
    }
}

public enum AppUpdateResult: Equatable, Sendable {
    case current, noRelease, available(AppUpdateManifest), incompatible(AppUpdateManifest)
}

public enum AppUpdateURLs {
    public static let latest = URL(string: "https://api.github.com/repos/BeeSave/BeeSave/releases/latest")!
    public static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        switch url.host {
        case "api.github.com": return url.path == latest.path && url.query == nil
        case "github.com": return url.path.hasPrefix("/BeeSave/BeeSave/releases/download/") && url.query == nil
        case "release-assets.githubusercontent.com", "objects.githubusercontent.com": return true
        default: return false
        }
    }
}

public protocol AppUpdateTransport: Sendable {
    func data(from url: URL, limit: Int) async throws -> Data
    func download(from url: URL, to file: URL, limit: Int, progress: @escaping @Sendable (Double?) -> Void) async throws
}

private class UpdateRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(AppUpdateURLs.allows) == true ? request : nil)
    }
}

private final class UpdateDownloadProgress: UpdateRedirects, URLSessionDownloadDelegate, @unchecked Sendable {
    private let limit: Int
    private let progress: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var exceeded = false
    var exceededLimit: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
    init(limit: Int, progress: @escaping @Sendable (Double?) -> Void) { self.limit = limit; self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            lock.lock(); exceeded = true; lock.unlock(); downloadTask.cancel(); return
        }
        progress(totalBytesExpectedToWrite > 0 ? min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1) : nil)
    }
}

public struct URLSessionUpdateTransport: AppUpdateTransport {
    public init() {}
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 300
        return URLSession(configuration: config, delegate: UpdateRedirects(), delegateQueue: nil)
    }
    private func request(_ url: URL) throws -> URLRequest {
        guard AppUpdateURLs.allows(url) else { throw AppUpdateError.untrustedURL }
        var request = URLRequest(url: url)
        request.setValue("BeeSave-Updater", forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        return request
    }
    private func validate(_ response: URLResponse, limit: Int) throws {
        guard let response = response as? HTTPURLResponse else { throw AppUpdateError.invalidMetadata }
        guard response.statusCode == 200 else {
            if response.statusCode == 403 || response.statusCode == 429 { throw AppUpdateError.rateLimited }
            throw AppUpdateError.http(response.statusCode)
        }
        guard response.expectedContentLength <= limit else { throw AppUpdateError.tooLarge }
    }
    public func data(from url: URL, limit: Int) async throws -> Data {
        let request = try request(url), session = session()
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            let (bytes, response) = try await session.bytes(for: request)
            try validate(response, limit: limit)
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else { throw AppUpdateError.tooLarge }
                data.append(byte)
            }
            return data
        } onCancel: { session.invalidateAndCancel() }
    }
    public func download(from url: URL, to file: URL, limit: Int, progress: @escaping @Sendable (Double?) -> Void) async throws {
        let request = try request(url), session = session()
        let delegate = UpdateDownloadProgress(limit: limit, progress: progress)
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            do {
                // URLSession streams into a temporary file without per-byte async overhead.
                let (temporary, response) = try await session.download(for: request, delegate: delegate)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                try validate(response, limit: limit)
                let count = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard !delegate.exceededLimit, count <= limit else { throw AppUpdateError.tooLarge }
                guard count > 0 else { throw AppUpdateError.emptyArchive }
                if response.expectedContentLength >= 0 && count != response.expectedContentLength { throw AppUpdateError.checksum }
                try FileManager.default.moveItem(at: temporary, to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                progress(1)
            } catch {
                if delegate.exceededLimit { throw AppUpdateError.tooLarge }
                throw error
            }
        } onCancel: { session.invalidateAndCancel() }
    }
}

public final class AppUpdateClient: @unchecked Sendable {
    public static let archiveLimit = 200 * 1024 * 1024
    private let transport: any AppUpdateTransport
    public init(transport: any AppUpdateTransport = URLSessionUpdateTransport()) { self.transport = transport }
    private struct Release: Decodable {
        let tag_name: String, draft: Bool, prerelease: Bool
        let assets: [Asset]
        struct Asset: Decodable { let name: String, browser_download_url: URL }
    }
    public func check(version: String, build: Int, macOS: String, architecture: String) async throws -> AppUpdateResult {
        let data: Data
        do { data = try await transport.data(from: AppUpdateURLs.latest, limit: 1_048_576) }
        catch AppUpdateError.http(404) { return .noRelease }
        try Task.checkCancellation()
        do {
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard !release.draft, !release.prerelease, release.tag_name.hasPrefix("v") else { throw AppUpdateError.invalidMetadata }
            _ = try AppVersion(String(release.tag_name.dropFirst()))
            let manifests = release.assets.filter { $0.name == "latest.json" }
            let archives = release.assets.filter { $0.name == "BeeSave-macos-arm64.zip" }
            let prefix = "https://github.com/BeeSave/BeeSave/releases/download/\(release.tag_name)/"
            guard manifests.count == 1, archives.count == 1,
                  manifests[0].browser_download_url.absoluteString == prefix + "latest.json",
                  archives[0].browser_download_url.absoluteString == prefix + "BeeSave-macos-arm64.zip"
            else { throw AppUpdateError.invalidMetadata }
            let bytes = try await transport.data(from: manifests[0].browser_download_url, limit: 65_536)
            let manifest = try JSONDecoder().decode(AppUpdateManifest.self, from: bytes)
            try manifest.validate()
            guard manifest.tag == release.tag_name, manifest.assetURL == archives[0].browser_download_url else { throw AppUpdateError.invalidMetadata }
            guard try manifest.isNewer(than: version, build: build) else { return .current }
            return try manifest.isCompatible(macOS: macOS, architecture: architecture) ? .available(manifest) : .incompatible(manifest)
        } catch is DecodingError { throw AppUpdateError.invalidMetadata }
    }
    /// The archive remains staged until its checksum passes. Failures remove all partial files.
    public func download(_ manifest: AppUpdateManifest, directory: URL,
                         progress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws -> URL {
        try manifest.validate()
        let stage = directory.appendingPathComponent("BeeSave-update-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = stage.appendingPathComponent("BeeSave-\(manifest.version)-arm64.zip")
        do {
            try await transport.download(from: manifest.assetURL, to: archive, limit: Self.archiveLimit, progress: progress)
            try Task.checkCancellation()
            let handle = try FileHandle(forReadingFrom: archive); defer { try? handle.close() }
            let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.archiveLimit else { throw AppUpdateError.tooLarge }
            var hash = SHA256(), total = 0
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                try Task.checkCancellation(); total += chunk.count
                guard total <= Self.archiveLimit else { throw AppUpdateError.tooLarge }
                hash.update(data: chunk)
            }
            guard total > 0 else { throw AppUpdateError.emptyArchive }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.sha256 else { throw AppUpdateError.checksum }
            try Task.checkCancellation()
            return archive
        } catch { try? FileManager.default.removeItem(at: stage); throw error }
    }
}

public enum AppUpdateState: Equatable {
    case idle, checking, current, noRelease, available(AppUpdateManifest), incompatible(AppUpdateManifest)
    case downloading(AppUpdateManifest, Double?), downloaded(AppUpdateManifest, URL), cancelled, failed(String)
    public var isBusy: Bool { switch self { case .checking, .downloading: true; default: false } }
}

@MainActor public final class AppUpdateManager: ObservableObject {
    @Published public private(set) var state: AppUpdateState = .idle
    public let version: String, build: Int
    private let macOS: String, architecture: String, directory: URL, client: AppUpdateClient
    private var task: Task<Void, Never>?, generation = UUID()
    public init(version: String, build: Int, macOS: String, architecture: String,
                directory: URL = FileManager.default.temporaryDirectory, client: AppUpdateClient = AppUpdateClient()) {
        self.version = version; self.build = build; self.macOS = macOS
        self.architecture = architecture; self.directory = directory; self.client = client
    }
    public func check() {
        guard !state.isBusy else { return }
        removeArchive(); generation = UUID(); let run = generation; state = .checking
        task = Task {
            do {
                let result = try await client.check(version: version, build: build, macOS: macOS, architecture: architecture)
                try Task.checkCancellation(); guard run == generation else { return }
                switch result {
                case .current: state = .current
                case .noRelease: state = .noRelease
                case .available(let manifest): state = .available(manifest)
                case .incompatible(let manifest): state = .incompatible(manifest)
                }
            } catch { finish(error, run: run) }
        }
    }
    public func download() {
        guard case .available(let manifest) = state else { return }
        generation = UUID(); let run = generation; state = .downloading(manifest, 0)
        task = Task {
            do {
                let url = try await client.download(manifest, directory: directory) { [weak observer = self] progress in
                    Task { @MainActor in
                        guard let observer, observer.generation == run, observer.state.isBusy else { return }
                        observer.state = .downloading(manifest, progress)
                    }
                }
                guard !Task.isCancelled, run == generation else {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent()); return
                }
                state = .downloaded(manifest, url)
            } catch { finish(error, run: run) }
        }
    }
    public func cancel() {
        guard state.isBusy else { return }
        generation = UUID(); task?.cancel(); task = nil; state = .cancelled
    }
    public func dismiss() {
        cancel(); removeArchive()
        if case .downloaded = state { state = .idle }
    }
    private func finish(_ error: Error, run: UUID) {
        guard run == generation else { return }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { state = .cancelled }
        else if error is URLError { state = .failed("Не удалось связаться с GitHub. Проверьте подключение к интернету и повторите попытку.") }
        else { state = .failed(error.localizedDescription) }
    }
    private func removeArchive() {
        if case .downloaded(_, let url) = state { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
}
