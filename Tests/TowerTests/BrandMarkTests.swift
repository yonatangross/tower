import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Tower

/// Seat and lane rows carry the PRODUCT mark; the account issuer's mark is
/// account chrome only. These tests pin the engine-to-asset contract the rows
/// render through `BrandMark`.
final class BrandMarkTests: XCTestCase {

    /// Repo root, resolved from this file so the assertions check the real
    /// Resources directories the app bundle copies verbatim.
    private var resourcesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TowerTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Resources")
    }

    /// Real extracted app icons ship under BrandMarks/; the grayscale template
    /// marks stay under icons/.
    private func iconFile(_ name: String) -> URL {
        let dir = name.hasPrefix("icon-") ? "icons" : "BrandMarks"
        return resourcesDir.appendingPathComponent(dir)
            .appendingPathComponent("\(name).png")
    }

    func testClaudeSeatShowsTheRealClaudeAppIcon() {
        XCTAssertEqual(Provider.claude.brandIconName, "claude")
    }

    func testAnthropicMarkIsVendorChromeNeverARowMark() {
        XCTAssertEqual(Provider.claude.vendorIconName, "icon-anthropic")
        for provider in Provider.allCases {
            XCTAssertNotEqual(provider.brandIconName, "icon-anthropic",
                              "\(provider) must not put the vendor mark on a row")
        }
    }

    func testLaneAndSeatProductMarks() {
        XCTAssertEqual(Provider.codex.brandIconName, "chatgpt")
        XCTAssertEqual(Provider.cursor.brandIconName, "cursor")
        XCTAssertEqual(Provider.openrouter.brandIconName, "icon-openrouter")
        XCTAssertEqual(Provider.agy.brandIconName, "antigravity")
        XCTAssertEqual(Provider.devin.brandIconName, "devin")
    }

    func testLanesWithoutAPublicMarkFallBackToMonogram() {
        XCTAssertNil(Provider.typesafe.brandIconName)
        XCTAssertNil(Provider.muse.brandIconName)
    }

    /// The repo ships no product icons. A checkout that ran
    /// scripts/extract-brand-marks.sh has them, and then every mapped mark must exist.
    private func skipUnlessPresent(_ directory: String) throws {
        let dir = resourcesDir.appendingPathComponent(directory)
        let pngs = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.hasSuffix(".png") } ?? []
        try XCTSkipIf(pngs.isEmpty, "no icons under Resources/\(directory); the bundle falls back to monograms")
    }

    func testExtractedAppIconsCoverEveryProductMark() throws {
        try skipUnlessPresent("BrandMarks")
        for provider in Provider.allCases {
            guard let name = provider.brandIconName, !name.hasPrefix("icon-") else { continue }
            let file = iconFile(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                          "\(provider) maps to \(name) but \(file.lastPathComponent) is missing")
        }
    }

    func testTemplateMarksExistWhenShipped() throws {
        try skipUnlessPresent("icons")
        for provider in Provider.allCases {
            for name in [provider.brandIconName, provider.vendorIconName].compactMap({ $0 })
            where name.hasPrefix("icon-") {
                let file = iconFile(name)
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                              "\(provider) maps to \(name) but \(file.lastPathComponent) is missing")
            }
        }
    }

    /// Marks under icons/ render `.template`, which paints every pixel that is not
    /// transparent in the tint. An opaque asset is a solid square on screen: the
    /// OpenRouter money row was a blank white tile until 2026-09-27.
    func testTemplateMarksCarryTransparency() throws {
        try skipUnlessPresent("icons")
        for provider in Provider.allCases {
            for name in [provider.brandIconName, provider.vendorIconName].compactMap({ $0 })
            where name.hasPrefix("icon-") {
                XCTAssertTrue(BrandMark.templateMarkHasTransparency(atPath: iconFile(name).path),
                              "\(name).png has no transparent pixel, so it renders as a solid square")
            }
        }
    }

    func testAnOpaqueImageIsRefusedAsATemplateMark() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opaque-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        // Filled through CoreGraphics, not NSBitmapImageRep.setColor: setColor(.white)
        // takes a calibrated white NSColor it cannot convert ("Unrecognized colorspace
        // number -1"), writes nothing, and leaves the fixture fully transparent.
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertFalse(BrandMark.templateMarkHasTransparency(atPath: url.path))
    }

    /// Real app icons also carry a 128 px @2x rep next to the 64 px base, so
    /// rows stay crisp on Retina displays.
    func testRealAppIconsShipARetinaRep() throws {
        try skipUnlessPresent("BrandMarks")
        for provider in Provider.allCases {
            guard let name = provider.brandIconName, !name.hasPrefix("icon-") else { continue }
            let retina = iconFile("\(name)@2x")
            XCTAssertTrue(FileManager.default.fileExists(atPath: retina.path),
                          "\(provider) maps to \(name) but is missing its @2x rep")
        }
    }
}
