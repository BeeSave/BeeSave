import XCTest
import CryptoKit
@testable import BudgetCore

private struct UpdateFixture: AppUpdateTransport {
    let metadata: Data
    let release: Data
    var archive = Data("verified archive fixture".utf8)
    var failure: AppUpdateError?
    var delay: UInt64 = 0
    var sparseSize: UInt64?
    func data(from url: URL, limit: Int) async throws -> Data {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let failure { throw failure }
        return url == AppUpdateURLs.latest ? release : metadata
    }
    func download(from url: URL, to file: URL, limit: Int, progress: @escaping @Sendable (Double?) -> Void) async throws {
        try archive.write(to: file)
        if let sparseSize {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.truncate(atOffset: sparseSize)
        }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let failure { throw failure }
        progress(1)
    }
}

final class AppUpdateTests: XCTestCase {
    private func manifest(_ changes: [String: Any] = [:]) throws -> Data {
        let archive = Data("verified archive fixture".utf8)
        var fields: [String: Any] = [
            "schema_version": 1, "version": "1.0.2", "build": 4, "minimum_macos": "26.0",
            "architecture": "arm64", "repository": "BeeSave/BeeSave", "tag": "v1.0.2",
            "asset_url": "https://github.com/BeeSave/BeeSave/releases/download/v1.0.2/BeeSave-macos-arm64.zip",
            "sha256": SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        ]
        fields.merge(changes) { _, rhs in rhs }
        return try JSONSerialization.data(withJSONObject: fields)
    }
    private func release(_ changes: [String: Any] = [:]) throws -> Data {
        var fields: [String: Any] = ["tag_name": "v1.0.2", "draft": false, "prerelease": false,
            "assets": [
                ["name": "latest.json", "browser_download_url": "https://github.com/BeeSave/BeeSave/releases/download/v1.0.2/latest.json"],
                ["name": "BeeSave-macos-arm64.zip", "browser_download_url": "https://github.com/BeeSave/BeeSave/releases/download/v1.0.2/BeeSave-macos-arm64.zip"]]]
        fields.merge(changes) { _, rhs in rhs }
        return try JSONSerialization.data(withJSONObject: fields)
    }
    private func fixture(_ changes: [String: Any] = [:]) throws -> UpdateFixture {
        try UpdateFixture(metadata: manifest(changes), release: release())
    }
    private func check(_ fixture: UpdateFixture, version: String = "1.0.1", build: Int = 3,
                       macOS: String = "26.0", architecture: String = "arm64") async throws -> AppUpdateResult {
        try await AppUpdateClient(transport: fixture).check(version: version, build: build, macOS: macOS, architecture: architecture)
    }
    func testNumericVersionsAndBuildOrdering() throws {
        XCTAssertTrue(try AppVersion("1.10") > AppVersion("1.9.99"))
        XCTAssertEqual(try AppVersion("1"), try AppVersion("1.0.0"))
        let incoming = try JSONDecoder().decode(AppUpdateManifest.self, from: manifest())
        XCTAssertTrue(try incoming.isNewer(than: "1.0.1", build: 999))
        XCTAssertTrue(try incoming.isNewer(than: "1.0.2", build: 3))
        XCTAssertFalse(try incoming.isNewer(than: "1.0.2", build: 4))
        XCTAssertFalse(try incoming.isNewer(than: "1.0.2", build: 5))
        XCTAssertFalse(try incoming.isNewer(than: "2.0", build: 1))
        for invalid in ["", "v1.0.2", "1..2", "1.0-beta", "-1.0", "1.2.3.4", "999999999999", "١.٢"] {
            XCTAssertThrowsError(try AppVersion(invalid), invalid)
        }
    }
    func testRejectsMalformedOrForeignManifest() throws {
        for change: [String: Any] in [
            ["schema_version": 2], ["build": 0], ["build": -1], ["architecture": "x86_64"],
            ["repository": "Other/BeeSave"], ["tag": "v1.0.3"], ["minimum_macos": "future"],
            ["sha256": String(repeating: "z", count: 64)], ["sha256": "abc"],
            ["asset_url": "http://github.com/BeeSave/BeeSave/releases/download/v1.0.2/BeeSave-macos-arm64.zip"],
            ["asset_url": "https://github.com/Other/BeeSave/releases/download/v1.0.2/BeeSave-macos-arm64.zip"],
            ["asset_url": "https://github.com/BeeSave/BeeSave/releases/download/v1.0.3/BeeSave-macos-arm64.zip"],
            ["asset_url": "https://github.com/BeeSave/BeeSave/releases/download/v1.0.2/BeeSave-macos-arm64.zip?token=1"]
        ] {
            let value = try JSONDecoder().decode(AppUpdateManifest.self, from: manifest(change))
            XCTAssertThrowsError(try value.validate(), "\(change)")
        }
    }
    func testAllowsOnlyHTTPSAndExpectedHostsForRedirects() {
        for url in [AppUpdateURLs.latest.absoluteString,
                    "https://github.com/BeeSave/BeeSave/releases/download/v1.0.2/latest.json",
                    "https://release-assets.githubusercontent.com/release-asset/test?signature=value",
                    "https://objects.githubusercontent.com/github-production-release-asset/test"] {
            XCTAssertTrue(AppUpdateURLs.allows(URL(string: url)!))
        }
        for url in ["http://github.com/BeeSave/BeeSave/releases/download/v1.0.2/latest.json",
                    "https://github.com.evil.test/BeeSave/BeeSave/releases/download/v1.0.2/latest.json",
                    "https://github.com/Other/BeeSave/releases/download/v1.0.2/latest.json",
                    "https://api.github.com/repos/Other/BeeSave/releases/latest",
                    "https://user:password@github.com/BeeSave/BeeSave/releases/download/v1.0.2/latest.json",
                    "https://github.com:8080/BeeSave/BeeSave/releases/download/v1.0.2/latest.json"] {
            XCTAssertFalse(AppUpdateURLs.allows(URL(string: url)!))
        }
    }
    func testAvailableCurrentAndOlderInstalledVersions() async throws {
        let f = try fixture()
        guard case .available(let manifest) = try await check(f) else { return XCTFail("Expected update") }
        XCTAssertEqual(manifest.version, "1.0.2")
        let current = try await check(f, version: "1.0.2", build: 4)
        let newer = try await check(f, version: "1.1", build: 1)
        let buildUpdate = try await check(f, version: "1.0.2", build: 3)
        XCTAssertEqual(current, .current); XCTAssertEqual(newer, .current)
        XCTAssertEqual(buildUpdate, .available(manifest))
    }
    func testIncompatibleOSAndArchitecture() async throws {
        let os = try await check(fixture(), macOS: "25.9")
        let cpu = try await check(fixture(), architecture: "x86_64")
        guard case .incompatible = os, case .incompatible = cpu else { return XCTFail("Expected incompatibility") }
    }
    func testNoReleaseRateLimitAndServerError() async throws {
        var f = try fixture(); f.failure = .http(404)
        let result = try await check(f); XCTAssertEqual(result, .noRelease)
        for error in [AppUpdateError.rateLimited, .http(500), .tooLarge] {
            f.failure = error
            do { _ = try await check(f); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? AppUpdateError, f.failure) }
        }
    }
    func testRejectsDraftPrereleaseMissingAssetsAndMalformedJSON() async throws {
        for changes: [String: Any] in [["draft": true], ["prerelease": true], ["assets": []], ["tag_name": "v1.0.2-beta"]] {
            let f = try UpdateFixture(metadata: manifest(), release: release(changes))
            do { _ = try await check(f); XCTFail("Expected rejection") }
            catch { XCTAssertEqual(error as? AppUpdateError, .invalidMetadata) }
        }
        let f = try UpdateFixture(metadata: Data("not JSON".utf8), release: release())
        do { _ = try await check(f); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? AppUpdateError, .invalidMetadata) }
    }
    func testRejectsManifestFromDifferentRelease() async throws {
        let f = try fixture(["version": "1.0.3", "tag": "v1.0.3",
                             "asset_url": "https://github.com/BeeSave/BeeSave/releases/download/v1.0.3/BeeSave-macos-arm64.zip"])
        do { _ = try await check(f); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? AppUpdateError, .invalidMetadata) }
    }
    func testDownloadsAndChecksArchiveWithoutChangingExistingFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("vault.beesave")
        let sentinel = Data("existing encrypted vault sentinel".utf8); try sentinel.write(to: existing)
        let f = try fixture(), value = try JSONDecoder().decode(AppUpdateManifest.self, from: f.metadata)
        let file = try await AppUpdateClient(transport: f).download(value, directory: directory)
        XCTAssertEqual(try Data(contentsOf: file), f.archive)
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
    }
    func testCorruptEmptyOrFailedDownloadRemovesPartialFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for mode in 0..<4 {
            var f = try fixture()
            if mode == 0 { f.archive = Data("corrupt".utf8) }
            if mode == 1 { f.archive = Data() }
            if mode == 2 { f.failure = .http(500) }
            if mode == 3 { f.sparseSize = UInt64(AppUpdateClient.archiveLimit + 1) }
            let value = try JSONDecoder().decode(AppUpdateManifest.self, from: f.metadata)
            do { _ = try await AppUpdateClient(transport: f).download(value, directory: directory); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? AppUpdateError, mode == 0 ? .checksum : mode == 1 ? .emptyArchive : mode == 2 ? .http(500) : .tooLarge) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }
    @MainActor private func settle(_ manager: AppUpdateManager) async throws {
        for _ in 0..<500 {
            if !manager.state.isBusy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Update did not finish")
    }
    @MainActor func testManagerPreventsDuplicateActionsAndSupportsRetryAfterCancellation() async throws {
        var f = try fixture(); f.delay = 30_000_000
        let manager = AppUpdateManager(version: "1.0.1", build: 3, macOS: "26", architecture: "arm64", client: AppUpdateClient(transport: f))
        manager.check(); manager.check(); XCTAssertEqual(manager.state, .checking)
        manager.cancel(); XCTAssertEqual(manager.state, .cancelled)
        manager.check(); try await settle(manager)
        guard case .available = manager.state else { return XCTFail("Retry failed") }
        manager.download(); manager.check()
        guard case .downloading = manager.state else { return XCTFail("Duplicate check replaced download") }
        try await settle(manager)
        guard case .downloaded(_, let archive) = manager.state else { return XCTFail("Download failed") }
        manager.dismiss(); XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }
    @MainActor func testCancelDuringDownloadCleansStageAndDoesNotPublishSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var f = try fixture(); f.delay = 100_000_000
        let manager = AppUpdateManager(version: "1", build: 1, macOS: "26", architecture: "arm64", directory: directory, client: AppUpdateClient(transport: f))
        manager.check(); try await settle(manager); manager.download()
        try await Task.sleep(nanoseconds: 30_000_000)
        manager.cancel(); try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(manager.state, .cancelled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }
    func testLiveGitHubMetadataAndArchive() async throws {
        guard ProcessInfo.processInfo.environment["BEESAVE_UPDATE_NETWORK"] == "1" else { throw XCTSkip("Separate opt-in GitHub integration test") }
        let client = AppUpdateClient()
        let result = try await client.check(version: "0", build: 0, macOS: "99", architecture: "arm64")
        guard case .available(let manifest) = result else { return XCTFail("Expected published release") }
        let file = try await client.download(manifest, directory: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertGreaterThan(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0)
        print("LIVE BeeSave update: version=\(manifest.version) build=\(manifest.build) SHA256 verified")
        let current = try await client.check(version: manifest.version, build: manifest.build, macOS: "99", architecture: "arm64")
        XCTAssertEqual(current, .current)
    }
}
