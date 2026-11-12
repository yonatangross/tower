import Foundation

/// The list of lanes that no other session's tooling may read (card personal-lane-privacy).
/// A session whose cwd is at or under one of the folders, or whose `~/.claude/projects`
/// folder is that folder's slug, is skipped by the lane-cost recorder entirely: its
/// transcript is not opened, it is not in any account total, and it gets no record.
struct PrivateLanes: Equatable {
    /// Absolute folder paths, `~` already expanded.
    var folders: [String]

    /// Reads `{"private_lanes": ["~/folder", ...]}` (other keys are ignored). nil when the
    /// file is missing, is not JSON, or has no list of strings under that key: the caller
    /// then reads and writes nothing (fail closed). An empty list is a valid policy.
    static func load(from url: URL, home: URL) -> PrivateLanes? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["private_lanes"] as? [String] else { return nil }
        let folders = list.map { entry -> String in
            if entry == "~" { return home.path }
            if entry.hasPrefix("~/") { return home.path + String(entry.dropFirst(1)) }
            return entry
        }
        return PrivateLanes(folders: folders)
    }

    /// What a read of the policy file found: three different things, so a missing file is
    /// never mistaken for an empty or a bad one.
    enum Readback: Equatable {
        case ok(PrivateLanes)
        case missing(String)
        case unreadable(String)
    }

    /// Reads the policy once and says which of the three it found. The caller that needs the
    /// list loudly (the recorder's note, the install script's check) uses this, not `load`.
    static func readback(from url: URL, home: URL) -> Readback {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing(url.path) }
        if let policy = load(from: url, home: home) { return .ok(policy) }
        return .unreadable(url.path)
    }

    /// A cwd at or under a private folder. A cwd that is not known cannot be shown to be
    /// public, so it counts as private. A sibling that only shares a name prefix does not.
    func isPrivate(cwd: String?) -> Bool {
        guard let cwd, !cwd.isEmpty else { return true }
        let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
        return folders.contains { folder in
            let f = URL(fileURLWithPath: folder).standardizedFileURL.path
            return path == f || path.hasPrefix(f + "/")
        }
    }

    /// A `~/.claude/projects` folder named after a private folder or anything below it.
    /// Claude Code names a project folder after the cwd with `/` and `.` as `-`, so a
    /// sibling such as `personal-desk-2` also matches: it errs toward not reading.
    func isPrivate(projectFolder name: String) -> Bool {
        folders.contains { folder in
            let slug = LaneCostRecorder.projectFolder(cwd: folder)
            return name == slug || name.hasPrefix(slug + "-")
        }
    }
}
