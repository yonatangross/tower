import Foundation
import XCTest
@testable import Tower

final class OpenRouterRotationTests: XCTestCase {
    private final class Probe {
        var keys: [String?] = ["fixture-old-a111", "fixture-new-b222"]
        var statuses = [401, 200]
        var events: [String] = []
        var canClear = true

        func read() -> String? {
            events.append("read")
            return keys.isEmpty ? nil : keys.removeFirst()
        }

        func clear() -> Bool {
            events.append("clear")
            return canClear
        }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            events.append(request.value(forHTTPHeaderField: "Authorization") ?? "missing auth")
            guard !statuses.isEmpty else { throw URLError(.badServerResponse) }
            let response = HTTPURLResponse(url: request.url!, statusCode: statuses.removeFirst(),
                                           httpVersion: nil, headerFields: nil)!
            return (Data(#"{"data":{"total_credits":50,"total_usage":4}}"#.utf8), response)
        }

        func fetch() async -> OpenRouter.Outcome {
            await OpenRouter.fetch(isConfigured: { true }, readKey: read, clearCache: clear, request: send)
        }
    }

    func test401ClearsBeforeRereadAndRetriesWithRotatedKey() async {
        let probe = Probe()
        let outcome = await probe.fetch()
        guard case .ok(let budget) = outcome else { return XCTFail("rotation recovers credits") }
        XCTAssertEqual(budget.spent, 4)
        XCTAssertEqual(probe.events, ["read", "Bearer fixture-old-a111", "clear",
                                      "read", "Bearer fixture-new-b222"], "clear before reread")
    }

    func testSecond401StopsAndReportsFreshFingerprint() async {
        let probe = Probe()
        probe.statuses = [401, 401, 200]
        let lastSuccess = OpenRouter.lastSuccessTime()
        let outcome = await probe.fetch()
        XCTAssertEqual(outcome, .rejected(401, keyFingerprint: "b222", lastSuccessAt: lastSuccess))
        XCTAssertEqual(probe.events, ["read", "Bearer fixture-old-a111", "clear",
                                      "read", "Bearer fixture-new-b222"], "one recovery attempt")
        XCTAssertEqual(probe.statuses, [200], "third request forbidden")
    }

    func testOtherHTTPStatusesNeverInvalidateOrRetry() async {
        for status in [200, 403, 429, 500] {
            let probe = Probe()
            probe.statuses = [status]
            let outcome = await probe.fetch()
            XCTAssertEqual(probe.events, ["read", "Bearer fixture-old-a111"], "only401 recovers")
            if status == 403 {
                XCTAssertEqual(outcome, .rejected(403, keyFingerprint: "a111",
                                                   lastSuccessAt: OpenRouter.lastSuccessTime()))
            } else if status != 200 {
                XCTAssertEqual(outcome, .unavailable)
            }
        }
    }

    func testFailedInvalidationPreserves401AndDoesNotReread() async {
        let probe = Probe()
        probe.canClear = false
        let lastSuccess = OpenRouter.lastSuccessTime()
        let outcome = await probe.fetch()
        XCTAssertEqual(outcome, .rejected(401, keyFingerprint: "a111", lastSuccessAt: lastSuccess))
        XCTAssertEqual(probe.events, ["read", "Bearer fixture-old-a111", "clear"])
    }

    func testUnreadableRotatedKeyPreserves401WithoutRetry() async {
        let probe = Probe()
        probe.keys = ["fixture-old-a111", nil]
        let lastSuccess = OpenRouter.lastSuccessTime()
        let outcome = await probe.fetch()
        XCTAssertEqual(outcome, .rejected(401, keyFingerprint: "a111", lastSuccessAt: lastSuccess))
        XCTAssertEqual(probe.events, ["read", "Bearer fixture-old-a111", "clear", "read"])
    }

    func testRetryTransportFailureIsUnavailableWithoutFurtherRecovery() async {
        let probe = Probe()
        probe.statuses = [401]
        let outcome = await probe.fetch()
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(probe.events, ["read", "Bearer fixture-old-a111", "clear",
                                      "read", "Bearer fixture-new-b222"])
    }

    func testCacheInvalidationRemovesOnlyTheConfiguredFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = directory.appendingPathComponent("openrouter-key")
        let other = directory.appendingPathComponent("another-entry")
        try Data("fixture-old-a111".utf8).write(to: entry)
        try Data("fixture-unrelated".utf8).write(to: other)
        let source = OpenRouter.KeySource(command: ["/fixture/reader"], cacheFile: entry.path)
        XCTAssertTrue(OpenRouter.clearKeyCache(source: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.path), "configured entry removed")
        XCTAssertEqual(try Data(contentsOf: other), Data("fixture-unrelated".utf8), "other entry preserved")
        XCTAssertTrue(OpenRouter.clearKeyCache(source: source), "already absent is invalidated")
    }

    func testNoCacheFileMeansNoRetry() {
        XCTAssertFalse(OpenRouter.clearKeyCache(source: OpenRouter.KeySource(command: ["/fixture/reader"])))
    }

    func testCacheRemovalFailureIsReported() {
        final class RefusingFiles: FileManager, @unchecked Sendable {
            override func removeItem(at URL: URL) throws {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        let source = OpenRouter.KeySource(command: ["/fixture/reader"], cacheFile: "/fixture-home/cache")
        XCTAssertFalse(OpenRouter.clearKeyCache(source: source, fileManager: RefusingFiles()))
    }
}
