import Foundation

/// Carries a pre-v0.1 install (bundle id `ai.yonatan-hq.claude-limits`, support
/// directory `HQClaudeLimits`) over to the Tower identity. Runs at the top of every
/// launch mode, before anything opens the store, and is a no-op once done.
///
/// What it moves:
/// - the support directory's entries (usage store, known accounts, nicknames) into the
///   new directory, never overwriting an entry the new directory already has;
/// - the settings domain's keys into the new domain, once, never overwriting a key the
///   new domain already has.
///
/// What it cannot move, and why the README says so: macOS keys privacy grants and the
/// login item by bundle id, so either may ask again once. Remembered Keychain seats are
/// not touched here: the panel's Re-trust reads them once (one Always Allow per old
/// seat item, the first time only) and writes the new build's seat bundle.
enum LegacyInstallMigration {
    /// Written into the new settings domain after the copy, naming the domain it came from.
    static let settingsMarkerKey = "migratedFromLegacyDomain"

    struct Report: Equatable {
        var movedEntries: [String] = []
        var copiedSettings: [String] = []
        var problems: [String] = []
    }

    /// The legacy domain for a Tower settings domain: the installed id maps to the old
    /// installed id and a suffixed copy (`.dev`) to the old id with the same suffix.
    /// Any other domain has no legacy counterpart.
    static func legacyDomain(for domain: String) -> String? {
        let current = ProductIdentity.bundleIdentifier
        if domain == current { return ProductIdentity.legacyBundleIdentifier }
        if domain.hasPrefix(current + ".") {
            return ProductIdentity.legacyBundleIdentifier + domain.dropFirst(current.count)
        }
        return nil
    }

    /// Moves every entry of `base/<legacy>` that `base/<current>` lacks, then removes
    /// the legacy directory when it is empty. The lock file is skipped: each directory
    /// guards only itself, and a stale lock carries no data.
    static func migrateSupportDirectory(base: URL, fileManager fm: FileManager = .default) -> Report {
        var report = Report()
        let legacy = base.appendingPathComponent(ProductIdentity.legacySupportDirectoryName, isDirectory: true)
        let current = base.appendingPathComponent(ProductIdentity.supportDirectoryName, isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: legacy.path, isDirectory: &isDir), isDir.boolValue else { return report }
        do {
            try fm.createDirectory(at: current, withIntermediateDirectories: true)
            let entries = try fm.contentsOfDirectory(atPath: legacy.path).sorted()
            for name in entries where name != ".accounts.lock" {
                let target = current.appendingPathComponent(name)
                if fm.fileExists(atPath: target.path) { continue }
                do {
                    try fm.moveItem(at: legacy.appendingPathComponent(name), to: target)
                    report.movedEntries.append(name)
                } catch {
                    report.problems.append("could not move \(name): \(error.localizedDescription)")
                }
            }
            let left = try fm.contentsOfDirectory(atPath: legacy.path).filter { $0 != ".accounts.lock" }
            if left.isEmpty { try fm.removeItem(at: legacy) }
        } catch {
            report.problems.append("support directory: \(error.localizedDescription)")
        }
        return report
    }

    /// Copies the legacy domain's keys into `defaults` once. `legacyValues` is the
    /// legacy domain as stored (`UserDefaults.persistentDomain(forName:)`), injectable
    /// so a test never touches a real domain.
    static func migrateSettings(domain: String, into defaults: UserDefaults,
                                legacyValues: (String) -> [String: Any]?) -> Report {
        var report = Report()
        guard defaults.object(forKey: settingsMarkerKey) == nil,
              let legacy = legacyDomain(for: domain),
              let values = legacyValues(legacy), !values.isEmpty else { return report }
        for key in values.keys.sorted() where defaults.object(forKey: key) == nil {
            defaults.set(values[key], forKey: key)
            report.copiedSettings.append(key)
        }
        defaults.set(legacy, forKey: settingsMarkerKey)
        return report
    }

    /// The launch entry point. `TOWER_SUPPORT_DIR` points the store elsewhere (the MCP
    /// integration test), so the real support directory is left alone then.
    @discardableResult
    static func runAtLaunch(env: [String: String] = ProcessInfo.processInfo.environment) -> Report {
        var report = Report()
        if (env["TOWER_SUPPORT_DIR"] ?? "").isEmpty {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            report = migrateSupportDirectory(base: base)
        }
        let settings = migrateSettings(
            domain: TowerPreferences.domainName, into: TowerPreferences.shared,
            legacyValues: { UserDefaults.standard.persistentDomain(forName: $0) })
        report.copiedSettings = settings.copiedSettings
        if !report.movedEntries.isEmpty || !report.copiedSettings.isEmpty || !report.problems.isEmpty {
            let line = "legacy install migration: moved \(report.movedEntries.count) support entries, "
                + "copied \(report.copiedSettings.count) settings"
                + (report.problems.isEmpty ? "" : "; problems: " + report.problems.joined(separator: "; "))
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        return report
    }
}
