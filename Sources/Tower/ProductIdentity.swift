import Foundation
import CoreGraphics
import SwiftUI
import AppKit

/// Display name and install identity. Builds before v0.1 installed as
/// `ai.yonatan-hq.claude-limits` with the executable and support directory
/// `HQClaudeLimits`; `LegacyInstallMigration` carries such an install over on its
/// first launch. Keychain seat items are found by their own label and service, not by
/// the bundle id, so they survive the rename; their ACL names the old build and is
/// re-trusted by the normal repair path after one Keychain approval.
enum ProductIdentity {
    static let displayName = "Tower"
    static let bundleIdentifier = "ai.yonyon.tower"
    static let supportDirectoryName = "Tower"
    static let processName = "Tower"

    /// The pre-v0.1 identity, read only by the migration and the installers.
    static let legacyBundleIdentifier = "ai.yonatan-hq.claude-limits"
    static let legacySupportDirectoryName = "HQClaudeLimits"
    static let legacyProcessName = "HQClaudeLimits"

    /// The Tower.app this process runs from. `Bundle.main` answers that only when the
    /// executable was started by its path inside the bundle. `tower` on the PATH is a
    /// symlink into the bundle (`~/.local/bin/tower`), and started that way `Bundle.main`
    /// is a bare executable with no identifier and no Info.plist (#121). Resolving the
    /// symlink finds the real bundle, so the CLI and the MCP server report the same build
    /// and read the same settings as the panel.
    static func runningBundle(main: Bundle = .main) -> Bundle? {
        if main.bundleIdentifier != nil { return main }
        return enclosingAppBundle(executablePath: main.executablePath)
    }

    /// `.../Tower.app/Contents/MacOS/Tower`, after resolving symlinks, names
    /// `.../Tower.app`; anything else (a `swift build` product in `.build`) is no bundle.
    static func enclosingAppBundle(executablePath: String?) -> Bundle? {
        guard let executablePath, !executablePath.isEmpty else { return nil }
        let real = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        let macOS = real.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return Bundle(url: app)
    }
}

/// #121: one settings domain for every Tower process. The panel is a bundled app, so its
/// `UserDefaults.standard` is the bundle id's domain. `tower status` and `tower mcp` run
/// through the PATH symlink, where `.standard` fell back to the domain `tower`: the panel
/// stored "Remember Claude seats" OFF while the CLI and MCP read ON from a domain that never
/// had the key. The poll then skipped every retained seat (no renewal, no capture) while
/// `tower_seats` reported retention on and a seat 5 hours past due. Every Tower setting now
/// reads and writes the domain named here.
enum TowerPreferences {
    /// The running bundle's own id (a dev copy keeps its own `.dev` domain), the enclosing
    /// app's id for a symlinked CLI, and the installed id for a bare `swift build` binary,
    /// which is a Tower run from source reading the installed Tower's settings.
    static func domain(runningBundleIdentifier: String?) -> String {
        guard let id = runningBundleIdentifier, !id.isEmpty else { return ProductIdentity.bundleIdentifier }
        return id
    }

    /// `.standard` when the domain already is this process's own; a suite otherwise.
    /// Foundation refuses a suite named after the main bundle, so that case must not
    /// construct one.
    static func defaults(domain: String, mainBundleIdentifier: String?) -> UserDefaults {
        if domain == mainBundleIdentifier { return .standard }
        return UserDefaults(suiteName: domain) ?? .standard
    }

    static let domainName = domain(runningBundleIdentifier: ProductIdentity.runningBundle()?.bundleIdentifier)
    static let shared = defaults(domain: domainName, mainBundleIdentifier: Bundle.main.bundleIdentifier)
}

/// #121 readability: one multiplier for every font and text-bearing width in the panel.
/// The panel was designed at 8 to 12 pt, which the operator could not read. A multiplier
/// on the size keeps every row's proportions (the lane-row width tests measure at base
/// size, and base text and base widths scale together) and renders text crisply, which a
/// transform over the whole view would not.
enum TowerTextSize: String, CaseIterable {
    case s, m, l, xl

    static let preferenceKey = "textSize"
    /// `panelshot` and a dev run can pick a size without touching the stored setting.
    static let environmentKey = "TOWER_TEXT_SIZE"
    /// A fresh install starts one step up from the original panel.
    static let fallback: TowerTextSize = .m

    var factor: CGFloat {
        switch self {
        case .s: return 1.0
        case .m: return 1.15
        case .l: return 1.3
        case .xl: return 1.5
        }
    }

    var label: String { rawValue.uppercased() }

    static func stored(defaults: UserDefaults = TowerPreferences.shared,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> TowerTextSize {
        if let forced = environment[environmentKey].flatMap({ TowerTextSize(rawValue: $0.lowercased()) }) {
            return forced
        }
        return defaults.string(forKey: preferenceKey).flatMap(TowerTextSize.init(rawValue:)) ?? fallback
    }

    static func store(_ size: TowerTextSize, defaults: UserDefaults = TowerPreferences.shared) {
        defaults.set(size.rawValue, forKey: preferenceKey)
    }

    /// The live multiplier. Read at render; the panel re-renders its root on a change.
    static var current: CGFloat { stored().factor }

    /// A design size in points, scaled. Widths grow with the type scale (`TowerType.layoutScale`)
    /// so a column written for the 2026-09-29 sizes still holds its text at the panel v2 sizes.
    static func pt(_ base: CGFloat) -> CGFloat { base * current * TowerType.layoutScale }
}

/// The popover type scale. Approved 2026-09-29 as body 13, small 12, minimum 11, headers 16;
/// raised 2026-09-30 (panel v2, "everything and fonts should be bigger, all, and more") to
/// body 18, small 16, minimum 15, headers 22 semibold, at the default text size. No view
/// names a point size; it names a role, so the next "make it bigger" is one edit here.
///
/// A role's size is its approved base times the stored text size relative to the default
/// (`TowerTextSize.fallback`), so the default size renders exactly the approved numbers and
/// S, L and XL scale around them. Layout widths keep scaling through `TowerTextSize.pt`.
enum TowerType {
    enum Role: CaseIterable {
        case header, body, small, minimum

        /// Points at the default text size.
        var base: CGFloat {
            switch self {
            case .header: return 22
            case .body: return 18
            case .small: return 16
            case .minimum: return 15
            }
        }
    }

    /// The role's size in layout units, the unit `TowerTextSize.pt` takes and every column
    /// width is written in. Tests measure real text against widths in this unit.
    static func designSize(_ role: Role) -> CGFloat {
        role.base / (TowerTextSize.fallback.factor * layoutScale)
    }

    /// How much the panel v2 scale grew the body text over the 2026-09-29 scale (18 over
    /// 13). Every layout width is still written in 2026-09-29 units; `TowerTextSize.pt`
    /// multiplies by this so widths and text grow together.
    static let layoutScale: CGFloat = Role.body.base / 13

    /// The floor for any text, at any text size: the approved minimum. Text size S would
    /// otherwise take the smallest role to about 9.6 pt, the size the operator called
    /// unreadable.
    static let floor: CGFloat = Role.minimum.base

    /// The role's size on screen at the given text size, never under `floor`.
    static func size(_ role: Role, textSize: TowerTextSize = TowerTextSize.stored()) -> CGFloat {
        max(floor, role.base * (textSize.factor / TowerTextSize.fallback.factor))
    }

    static func font(_ role: Role, weight: Font.Weight = .regular,
                     design: Font.Design = .default) -> Font {
        .system(size: size(role), weight: weight, design: design)
    }

    /// The popover's width in layout units (`TowerTextSize.pt` scales it). Panel v2 stacks a
    /// seat's pools as three lines (approved variant B), so the meter column shrank and the
    /// panel lands near 700 pt at the default size instead of the 1000 pt a single-line row
    /// would need at the larger type.
    static let panelWidth: CGFloat = 440

    /// Secondary text was the system grey, which read as a smudge at the old sizes. Label colour at 75 percent stays clearly below
    /// the primary text and clears 7:1 contrast on both appearances (asserted in
    /// PopoverTypeScaleTests).
    static let secondaryOpacity = 0.75
    static let secondary = Color(nsColor: .labelColor).opacity(secondaryOpacity)

    /// Quiet text and unmeasured meter tracks. Still readable: 55 percent, not the 25
    /// percent of the system tertiary grey.
    static let dimOpacity = 0.55
    static let dim = Color(nsColor: .labelColor).opacity(dimOpacity)
}
