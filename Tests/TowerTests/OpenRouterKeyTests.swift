import XCTest
import Foundation
@testable import Tower

final class OpenRouterKeyTests: XCTestCase {
    func testConfiguredCommandIsTheOnlySourceWhenSet() {
        var calls: [[String]] = []
        let source = OpenRouter.KeySource(command: ["/fixture/reader", "--item", "openrouter"],
                                          environmentKey: "fixture-stale-env-key")
        let key = OpenRouter.apiKey(source: source, run: { argv in
            calls.append(argv)
            return "  fixture-current-key\n"
        })
        XCTAssertEqual(calls, [["/fixture/reader", "--item", "openrouter"]])
        XCTAssertEqual(key, "fixture-current-key")
        XCTAssertNil(OpenRouter.apiKey(source: source, run: { _ in nil }),
                     "a failed command never falls back to the environment copy")
    }

    func testEnvironmentKeyIsUsedWithoutACommand() {
        let source = OpenRouter.KeySource(environmentKey: " fixture-env-key ")
        var ran = false
        let key = OpenRouter.apiKey(source: source, run: { _ in ran = true; return nil })
        XCTAssertEqual(key, "fixture-env-key")
        XCTAssertFalse(ran, "no command is run without one configured")
    }

    func testRotationReadsTheSourceAgain() {
        var current = "fixture-old-key"
        let source = OpenRouter.KeySource(command: ["/fixture/reader"])
        XCTAssertEqual(OpenRouter.apiKey(source: source, run: { _ in current }), "fixture-old-key")
        current = "fixture-rotated-key"
        XCTAssertEqual(OpenRouter.apiKey(source: source, run: { _ in current }), "fixture-rotated-key")
    }

    func testBlankOutputIsNoKey() {
        let source = OpenRouter.KeySource(command: ["/fixture/reader"])
        XCTAssertNil(OpenRouter.apiKey(source: source, run: { _ in " \n" }))
    }

    func testSourceIsReadFromSettingsAndEnvironment() {
        let suite = "test-openrouter-source-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(OpenRouter.KeySource.current(defaults: defaults, env: [:]).isConfigured)
        XCTAssertEqual(OpenRouter.KeySource.current(defaults: defaults, env: [:]).kind, "none")
        XCTAssertEqual(OpenRouter.KeySource.current(defaults: defaults,
                                                    env: ["OPENROUTER_API_KEY": "k"]).kind, "environment")
        defaults.set(["/fixture/reader"], forKey: OpenRouter.KeySource.commandPreference)
        defaults.set("/fixture/cache", forKey: OpenRouter.KeySource.cacheFilePreference)
        let source = OpenRouter.KeySource.current(defaults: defaults, env: [:])
        XCTAssertEqual(source.command, ["/fixture/reader"])
        XCTAssertEqual(source.cacheFile, "/fixture/cache")
        XCTAssertEqual(source.kind, "command")
    }

    func testUnconfiguredSourceHidesTheSection() async {
        var read = false
        let outcome = await OpenRouter.fetch(isConfigured: { false }, readKey: { read = true; return nil })
        XCTAssertEqual(outcome, .notConfigured)
        XCTAssertFalse(read)
    }

    func testUnreadableConfiguredKeyKeepsTheFailureVisible() async {
        let outcome = await OpenRouter.fetch(isConfigured: { true }, readKey: { nil })
        XCTAssertEqual(outcome, .unavailable)
    }

    func testKeyCommandRunsWithoutAShellAndRequiresSuccess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("reader")
        let script = """
        #!/bin/sh
        [ "$#" = 2 ] || exit 1
        [ "$1" = 'item; echo injected' ] || exit 1
        [ "$2" = 8 ] || exit 1
        printf 'fixture-current-key'
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        XCTAssertEqual(OpenRouter.runKeyCommand([helper.path, "item; echo injected", "8"]),
                       "fixture-current-key")
        try "#!/bin/sh\nprintf 'fixture-partial-output'; exit 1\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        XCTAssertNil(OpenRouter.runKeyCommand([helper.path, "item; echo injected", "8"]))
        XCTAssertNil(OpenRouter.runKeyCommand([]))
    }

    func testOutcomeRejectedCarriesFingerprintAndLastSuccess() {
        // Test that rejected case carries key fingerprint and last-success time
        let fingerprint = "9f3c"
        let lastSuccess = Date(timeIntervalSince1970: 1_800_000_000)
        
        let outcome = OpenRouter.Outcome.rejected(401, keyFingerprint: fingerprint, lastSuccessAt: lastSuccess)
        
        if case .rejected(let code, let fp, let ls) = outcome {
            XCTAssertEqual(code, 401)
            XCTAssertEqual(fp, fingerprint)
            XCTAssertEqual(ls, lastSuccess)
        } else {
            XCTFail("Expected rejected case")
        }
    }
    
    func testOutcomeRejectedWithNilFingerprintAndLastSuccess() {
        // Test that rejected case can have nil values
        let outcome = OpenRouter.Outcome.rejected(403, keyFingerprint: nil, lastSuccessAt: nil)
        
        if case .rejected(let code, let fp, let ls) = outcome {
            XCTAssertEqual(code, 403)
            XCTAssertNil(fp)
            XCTAssertNil(ls)
        } else {
            XCTFail("Expected rejected case")
        }
    }
    
    func testOutcomeEquatable() {
        // Test that outcomes with same parameters are equal
        let a = OpenRouter.Outcome.rejected(401, keyFingerprint: "9f3c", lastSuccessAt: nil)
        let b = OpenRouter.Outcome.rejected(401, keyFingerprint: "9f3c", lastSuccessAt: nil)
        XCTAssertEqual(a, b)
        
        // Different fingerprints should not be equal
        let c = OpenRouter.Outcome.rejected(401, keyFingerprint: "sk-di-", lastSuccessAt: nil)
        XCTAssertNotEqual(a, c)
        
        // Different last success times should not be equal
        let t1 = Date(timeIntervalSince1970: 1_800_000_000)
        let t2 = Date(timeIntervalSince1970: 1_900_000_000)
        let d = OpenRouter.Outcome.rejected(401, keyFingerprint: "9f3c", lastSuccessAt: t1)
        let e = OpenRouter.Outcome.rejected(401, keyFingerprint: "9f3c", lastSuccessAt: t2)
        XCTAssertNotEqual(d, e)
    }
    
    func testLastSuccessTimeDefaultsToNil() {
        // When no successful fetch has been recorded, lastSuccessTime should be nil
        let suite = "test-openrouter-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        
        XCTAssertNil(OpenRouter.lastSuccessTime(defaults: defaults))
    }
    
    func testRecordSuccessUpdatesLastSuccessTime() throws {
        let suite = "test-openrouter-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        OpenRouter.recordSuccess(now: now, defaults: defaults)
        
        let retrieved = try XCTUnwrap(OpenRouter.lastSuccessTime(defaults: defaults))
        XCTAssertEqual(retrieved.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1.0)
    }
}
