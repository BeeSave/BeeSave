import XCTest
@testable import BudgetCore

private struct InstallReleaseFixture: AppUpdateTransport {
    var release: Data
    var manifest: Data
    func data(from url: URL, limit: Int) async throws -> Data { url == AppUpdateURLs.latest ? release : manifest }
    func download(from url: URL, to file: URL, limit: Int, progress: @escaping @Sendable (Double?) -> Void) async throws { XCTFail("Discovery must not download an archive") }
}

final class InstallUpdateReleaseTests: XCTestCase {
    private let names = ["latest.json", "BeeSave-macos-arm64.zip", "BeeSave-macos-arm64.zip.sha256", "BeeSave-macos-arm64.dmg", "BeeSave-macos-arm64.dmg.sha256", "appcast.xml"]
    private func fixture(assets: [String]? = nil, tag: String = "v1.2.0", manifestTag: String = "v1.2.0", draft: Bool = false, prerelease: Bool = false, foreign: Bool = false) throws -> InstallReleaseFixture {
        let prefix = "https://github.com/\(foreign ? "Other" : "BeeSave")/BeeSave/releases/download/\(tag)/"
        let release: [String: Any] = ["tag_name": tag, "draft": draft, "prerelease": prerelease,
            "assets": (assets ?? names).map { ["name": $0, "browser_download_url": prefix + $0] }]
        let manifest: [String: Any] = ["schema_version": 1, "version": "1.2.0", "build": 6, "minimum_macos": "26.0", "architecture": "arm64", "repository": "BeeSave/BeeSave", "tag": manifestTag, "asset_url": "https://github.com/BeeSave/BeeSave/releases/download/v1.2.0/BeeSave-macos-arm64.zip", "sha256": String(repeating: "a", count: 64)]
        return try InstallReleaseFixture(release: JSONSerialization.data(withJSONObject: release), manifest: JSONSerialization.data(withJSONObject: manifest))
    }
    private func check(_ fixture: InstallReleaseFixture, version: String = "1.1.0", os: String = "26.0") async throws -> InstallUpdateResult {
        try await AppUpdateClient(transport: fixture).checkInstall(version: version, build: 5, macOS: os, architecture: "arm64")
    }
    func testPinsAllInstallAssetsToOneStableRelease() async throws {
        for os in ["26.0", "26.7", "27.0", "27.1"] {
            guard case .available(let result) = try await check(fixture(), os: os) else { return XCTFail("Expected install release on macOS \(os)") }
            XCTAssertEqual(result.feedURL.absoluteString, "https://github.com/BeeSave/BeeSave/releases/download/v1.2.0/appcast.xml")
            XCTAssertEqual(result.archiveURL.absoluteString, "https://github.com/BeeSave/BeeSave/releases/download/v1.2.0/BeeSave-macos-arm64.dmg")
            XCTAssertEqual(result.manifest.build, 6)
        }
    }
    func testMissingDuplicateForeignAndMixedTagAssetsAreRejected() async throws {
        var fixtures = [try fixture(tag: "v1.3.0"), try fixture(manifestTag: "v1.3.0"), try fixture(foreign: true)]
        for name in names { fixtures.append(try fixture(assets: names.filter { $0 != name })); fixtures.append(try fixture(assets: names + [name])) }
        for f in fixtures {
            do { _ = try await check(f); XCTFail("Invalid release accepted") }
            catch { XCTAssertEqual(error as? AppUpdateError, .invalidMetadata) }
        }
    }
    func testDraftPrereleaseAndInvalidVersionsAreRejected() async throws {
        for f in [try fixture(draft: true), try fixture(prerelease: true), try fixture(tag: "v1.2-beta")] {
            do { _ = try await check(f); XCTFail("Unstable release accepted") }
            catch { XCTAssertEqual(error as? AppUpdateError, .invalidMetadata) }
        }
    }
    func testExistingOlderReleaseWithoutInstallerIsStillCurrent() async throws {
        let result = try await check(fixture(assets: ["latest.json", "BeeSave-macos-arm64.zip"]), version: "1.3.0")
        XCTAssertEqual(result, .current)
        guard case .incompatible = try await check(fixture(), os: "25.0") else { return XCTFail("Expected incompatible") }
    }
}
