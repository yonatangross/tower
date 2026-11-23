import Foundation
import XCTest
@testable import Tower

final class ProfileEmailCacheTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-profile-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ email: String, to url: URL, mtime: Date) throws {
        let json = "{\"oauthAccount\":{\"emailAddress\":\"\(email)\"}}"
        try json.write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    func testUnchangedFileParsesOnce() throws {
        let url = dir.appendingPathComponent(".claude.json")
        try write("a@example.test", to: url, mtime: Date().addingTimeInterval(-60))
        let cache = ProfileEmailCache()
        XCTAssertEqual(cache.email(at: url), "a@example.test")
        XCTAssertEqual(cache.email(at: url), "a@example.test")
        XCTAssertEqual(cache.email(at: url), "a@example.test")
        XCTAssertEqual(cache.parseCount, 1)
    }

    func testChangedFileReparsesAndReturnsNewEmail() throws {
        let url = dir.appendingPathComponent(".claude.json")
        try write("a@example.test", to: url, mtime: Date().addingTimeInterval(-60))
        let cache = ProfileEmailCache()
        XCTAssertEqual(cache.email(at: url), "a@example.test")
        // Same byte length, different mtime.
        try write("b@example.test", to: url, mtime: Date().addingTimeInterval(-30))
        XCTAssertEqual(cache.email(at: url), "b@example.test")
        XCTAssertEqual(cache.parseCount, 2)
    }

    func testSameSizeSameMtimeRewriteIsNotServedStale() throws {
        let url = dir.appendingPathComponent(".claude.json")
        // A fresh file with an identical size and pinned identical mtime: only the racy
        // window keeps the cache from serving the old email.
        let pinned = Date()
        try write("a@example.test", to: url, mtime: pinned)
        let cache = ProfileEmailCache()
        XCTAssertEqual(cache.email(at: url), "a@example.test")
        try write("b@example.test", to: url, mtime: pinned)
        XCTAssertEqual(cache.email(at: url), "b@example.test")
    }

    /// Past the racy window only ctime can tell this rewrite from the cached file.
    func testRewriteThatRestoresAnOldMtimeIsNotServedStale() throws {
        let url = dir.appendingPathComponent(".claude.json")
        let old = Date().addingTimeInterval(-60)
        try write("a@example.test", to: url, mtime: old)
        let cache = ProfileEmailCache()
        XCTAssertEqual(cache.email(at: url), "a@example.test")
        try write("b@example.test", to: url, mtime: old)
        XCTAssertEqual(cache.email(at: url), "b@example.test")
    }

    func testDeletedFileReturnsNil() throws {
        let url = dir.appendingPathComponent(".claude.json")
        try write("a@example.test", to: url, mtime: Date().addingTimeInterval(-60))
        let cache = ProfileEmailCache()
        XCTAssertEqual(cache.email(at: url), "a@example.test")
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(cache.email(at: url))
        XCTAssertNil(cache.email(at: url))
    }

    func testFootprintLogOnlyOnMeaningfulChange() {
        XCTAssertTrue(FootprintLog.shouldLog(mb: 140, last: nil))
        XCTAssertFalse(FootprintLog.shouldLog(mb: 150, last: 140))
        XCTAssertTrue(FootprintLog.shouldLog(mb: 220, last: 140))
        XCTAssertTrue(FootprintLog.shouldLog(mb: 515, last: 510))
    }
}
