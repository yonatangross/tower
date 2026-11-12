import Foundation

/// The list of lanes that no other session's tooling may read (card personal-lane-privacy).
/// A session whose cwd is at or under one of the folders, or whose `~/.claude/projects`
/// folder is that folder's slug, is skipped by the lane-cost recorder entirely: its
/// transcript is not opened, it is not in any account total, and it gets no record.
struct PrivateLanes: Equatable {
    /// Absolute folder paths, `~` already expanded.
    var folders: [String]

    // RED STUB: placeholders so the new tests compile and fail on their assertions.
    static func load(from url: URL, home: URL) -> PrivateLanes? { nil }
    func isPrivate(cwd: String?) -> Bool { false }
    func isPrivate(projectFolder: String) -> Bool { false }
}
