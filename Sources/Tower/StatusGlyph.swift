import AppKit
import Foundation

/// Tower's own menu-bar mark (the Beacon glyph), drawn next to the status title.
/// The art lives in `Resources/StatusGlyph/` (made by `scripts/make-icon.sh`) and
/// `build-app.sh` copies it into the bundle's Resources. It is a template image, so
/// macOS tints it for light and dark menu bars; it is never a vendor mark.
enum StatusGlyph {
    /// The resource name, without scale suffix or extension.
    static let name = "TowerGlyph"
    /// Menu-bar glyph size in points.
    static let pointSize = NSSize(width: 18, height: 18)

    /// Loads the glyph from a directory holding `TowerGlyph.png` and `TowerGlyph@2x.png`.
    static func image(in directory: URL) -> NSImage? {
        let reps = ["\(name).png", "\(name)@2x.png"].compactMap { file -> NSImageRep? in
            let url = directory.appendingPathComponent(file)
            guard let rep = NSImageRep(contentsOf: url) else { return nil }
            rep.size = pointSize
            return rep
        }
        guard !reps.isEmpty else { return nil }
        let image = NSImage(size: pointSize)
        image.addRepresentations(reps)
        image.isTemplate = true
        image.accessibilityDescription = "Tower"
        return image
    }

    /// Where `tower selftest` checks the art: the running bundle's Resources when they ship
    /// the glyph (a release build, compiled on CI, whose `#filePath` names a path on that
    /// machine), otherwise the checkout's `Resources/StatusGlyph` (a `swift build` run).
    static func selftestDirectory(bundleResources: URL?, sourceFile: String) -> URL {
        if let bundleResources,
           FileManager.default.fileExists(atPath: bundleResources.appendingPathComponent("\(name).png").path) {
            return bundleResources
        }
        return URL(fileURLWithPath: sourceFile)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/StatusGlyph")
    }

    /// The glyph shipped in the running bundle, or nil (a `swift run` build has no bundle
    /// resources; the status item then shows its title alone, as before).
    static func bundled(_ bundle: Bundle = .main) -> NSImage? {
        guard let dir = bundle.resourceURL else { return nil }
        return image(in: dir)
    }
}
