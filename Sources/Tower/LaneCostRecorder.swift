import Foundation

/// Turns "a session left the `claude agents` list" into one ledger line.
enum LaneCostRecorder {
    struct Environment {
        var home: URL
        /// Tower's own support directory (`~/Library/Application Support/Tower`).
        var supportDir: URL
        var now: Date
    }

    // RED STUB: placeholders so the tests compile and fail on their assertions.
    static func projectFolder(cwd: String) -> String { "" }
    static func transcriptURL(live: LaneCost.Live, home: URL) -> URL? { nil }
    static func paceSamples(supportDir: URL, email: String?) -> [LaneCost.PaceSample] { [] }
    static func accountOutput(uuid: String?, from: Date, to: Date, home: URL) -> Int? { nil }
    @discardableResult
    static func recordClosed(previous: [LaneCost.Live], current: [LaneCost.Live], env: Environment) -> [LaneCost.Record] { [] }
}
