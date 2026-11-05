import SwiftUI
import AppKit

// MARK: - Harness iconography

extension Provider {
    /// Short monogram shown inside the harness tile. Two letters keeps every tile
    /// the same size; the Jev and Clef manual credits ride on the TypeSafe provider.
    var boardMark: String {
        switch self {
        case .claude: return "cc"
        case .codex: return "cx"
        case .cursor: return "cu"
        case .openrouter: return "or"
        case .typesafe: return "ts"
        case .muse: return "mu"
        case .devin: return "dv"
        case .agy: return "ag"
        case .pi: return "pi"
        }
    }

    /// Same hue the section dots already used, so the tile reads as the provider
    /// the operator already learned.
    var boardColor: Color {
        switch self {
        case .claude: return .orange
        case .codex: return .teal
        case .cursor: return Color(nsColor: .secondaryLabelColor)
        case .openrouter: return .blue
        case .typesafe: return .pink
        case .muse: return .purple
        case .devin: return .mint
        case .agy: return .indigo
        case .pi: return .brown
        }
    }

    /// Bundled product mark name for providers with a real logo, or nil for
    /// lanes that have no public mark (Jev and Muse fall back to their
    /// monogram). Rows always show the PRODUCT mark, the same icon macOS shows
    /// in the Dock: Claude seats carry the Claude app icon, Codex seats the
    /// ChatGPT icon, Antigravity its own mark, never the vendor's. Names
    /// without the "icon-" prefix resolve under Resources/BrandMarks (real
    /// extracted app icons); "icon-*" names resolve under Resources/icons
    /// (grayscale template marks).
    var brandIconName: String? {
        switch self {
        case .claude: return "claude"
        case .codex: return "chatgpt"
        case .cursor: return "cursor"
        case .openrouter: return "icon-openrouter"
        case .agy: return "antigravity"
        case .devin: return "devin"
        default: return nil
        }
    }

    /// The real app-bundle icon under BrandMarks/, when one ships for this
    /// provider. Checked against the bundle so a missing asset degrades to the
    /// monogram tile instead of a blank square.
    var bundledAppIcon: NSImage? {
        guard let name = brandIconName, !name.hasPrefix("icon-"),
              let path = Bundle.main.path(forResource: "\(name)@2x", ofType: "png",
                                          inDirectory: "BrandMarks")
                          ?? Bundle.main.path(forResource: name, ofType: "png",
                                              inDirectory: "BrandMarks")
        else { return nil }
        return NSImage(contentsOfFile: path)
    }

    /// The account issuer's own mark, kept for account chrome only (tooltips,
    /// expanded detail). Never rendered on a seat or lane row.
    var vendorIconName: String? {
        switch self {
        case .claude: return "icon-anthropic"
        default: return nil
        }
    }

    /// Who issued the account, for "<nickname>, <vendor> account" tooltips.
    /// Falls back to the product label where the operator already reads the
    /// vendor and product as one name.
    var vendorName: String {
        switch self {
        case .claude:   return "Anthropic"
        case .codex:    return "OpenAI"
        case .cursor:   return "Anysphere"
        case .devin:    return "Cognition"
        case .agy:      return "Google"
        case .typesafe: return "TypeSafe"
        default:        return label
        }
    }
}

/// A provider's product mark. Real app-bundle icons (Resources/BrandMarks)
/// render `.original` so they keep their own colours; the older grayscale
/// marks (Resources/icons) render `.template` and take the caller's tint.
/// Lanes without a public mark fall back to the two-letter monogram.
struct BrandMark: View {
    let provider: Provider
    var size: CGFloat = 14
    /// Render the account issuer's mark instead of the product mark. Vendor
    /// marks are for account chrome only (tooltips, expanded detail).
    var vendor = false

    var body: some View {
        if !vendor, let image = provider.bundledAppIcon {
            Image(nsImage: image)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: TowerTextSize.pt(size), height: TowerTextSize.pt(size))
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22,
                                            style: .continuous))
        } else if let name = vendor ? provider.vendorIconName : provider.brandIconName,
                  let path = Bundle.main.path(forResource: name, ofType: "png",
                                              inDirectory: "icons"),
                  let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: TowerTextSize.pt(size), height: TowerTextSize.pt(size))
        } else {
            Text(provider.boardMark)
                .font(.system(size: TowerTextSize.pt(size) * 0.62, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }
}

extension BrandMark {
    /// A template mark draws through its alpha channel alone: `.template` paints every
    /// pixel that is not transparent in the caller's tint. An asset with no transparent
    /// pixel therefore renders as a solid tile of the tint, which is how the OpenRouter
    /// money row showed a blank white square until 2026-09-27 (its PNG was a grey mark
    /// on an opaque white field). True when the PNG at `path` has at least one fully
    /// transparent pixel; false for an opaque or unreadable file.
    nonisolated static func templateMarkHasTransparency(atPath path: String) -> Bool {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] == 0 }
    }
}

/// The row's leading icon. Providers with a real app-bundle icon show it at
/// the full row size with no tint and no background tile, the same mark the
/// Dock shows. Providers without one keep the provider-colored tile carrying
/// a template mark or the seat's initials.
struct SeatIcon: View {
    let provider: Provider
    let nickname: String
    var size: CGFloat = 26

    private var initials: String {
        let chars = nickname.uppercased().filter { $0.isLetter || $0.isNumber }
        return String(chars.prefix(2))
    }

    var body: some View {
        if provider.bundledAppIcon != nil {
            BrandMark(provider: provider, size: size)
                .frame(width: TowerTextSize.pt(size), height: TowerTextSize.pt(size))
        } else {
            ZStack {
                if provider.brandIconName != nil {
                    BrandMark(provider: provider, size: size * 0.66)
                        .foregroundStyle(.white)
                } else {
                    Text(initials)
                        .font(.system(size: TowerTextSize.pt(size) * 0.4, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: TowerTextSize.pt(size), height: TowerTextSize.pt(size))
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(provider.boardColor)
            )
        }
    }
}

/// The provider tile alone, for rows that have no seat initials (money, lanes).
struct ProviderIcon: View {
    let provider: Provider
    var size: CGFloat = 24

    var body: some View {
        if provider.bundledAppIcon != nil {
            BrandMark(provider: provider, size: size)
                .frame(width: TowerTextSize.pt(size), height: TowerTextSize.pt(size))
        } else {
            ZStack {
                BrandMark(provider: provider, size: size * 0.66)
                    .foregroundStyle(.white)
            }
            .frame(width: TowerTextSize.pt(size), height: TowerTextSize.pt(size))
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(provider.boardColor)
            )
        }
    }
}

// MARK: - Segmented window meter

/// One mini-track per real window the provider actually has. The labels come
/// straight from RestingDrawer.meterWindows: Cursor's two dashboard pools stay
/// named instead of borrowing Claude's window vocabulary.
/// The status line's braille meter, drawn as dots rather than set as braille glyphs:
/// the system fonts render braille at a fraction of the cell, so a glyph meter read as
/// specks. The dot pattern is `BrailleMeterMath`'s, cell for cell.
struct BrailleMeter: View {
    /// Percent the meter fills; nil draws every cell unlit.
    let percent: Double?
    let cells: Int
    /// A single colour for every lit cell (money meters, stale readings). nil colours each
    /// cell along the quota gradient, the status line's look.
    var flat: Color? = nil

    /// One cell in layout units: a status line cell at the small role's size.
    nonisolated static let cellWidth: CGFloat = 6.4
    nonisolated static let cellHeight: CGFloat = 10.8

    static func width(cells: Int) -> CGFloat { TowerTextSize.pt(cellWidth * CGFloat(cells)) }

    static func color(_ rgb: BrailleMeterMath.RGB) -> Color {
        Color(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }

    var body: some View {
        let steps = percent.map { BrailleMeterMath.steps(percent: $0, cells: cells) }
            ?? Array(repeating: 0, count: cells)
        Canvas { context, size in
            let w = size.width / CGFloat(max(cells, 1))
            let h = size.height
            let radius = w * 0.155
            for (index, step) in steps.enumerated() {
                let colour = step == 0 ? Self.color(BrailleMeterMath.unlit)
                    : flat ?? Self.color(BrailleMeterMath.gradient(cell: index, of: cells))
                let mask = BrailleMeterMath.masks[step]
                for (bit, position) in BrailleMeterMath.dotPositions.enumerated()
                where mask & (1 << bit) != 0 {
                    let x = CGFloat(index) * w + w * (0.3 + 0.4 * CGFloat(position.column))
                    let y = h * (0.147 + 0.235 * CGFloat(position.row))
                    context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                                        width: radius * 2, height: radius * 2)),
                                 with: .color(colour))
                }
            }
        }
        .frame(width: Self.width(cells: cells), height: TowerTextSize.pt(Self.cellHeight))
        .accessibilityLabel(percent.map { "\(Int($0)) percent" } ?? "unknown")
    }
}

/// A seat's usage pools, stacked one per line (panel v2, approved variant B): the pool
/// label, a braille meter and the percent in its level colour. Stacking is what lets the
/// larger type keep full labels; three meters side by side needed a 1000 pt panel.
struct SegmentedMeter: View {
    let windows: [RestingDrawer.MeterWindow]

    nonisolated static let cells = 6
    /// Layout units: the widest label ("Fable") and "100%" at the small monospaced size.
    nonisolated static let labelWidth: CGFloat = 32
    nonisolated static let percentWidth: CGFloat = 26
    nonisolated static let rowWidth: CGFloat = labelWidth + cellWidthTotal + percentWidth + 8 // two gaps
    nonisolated static var cellWidthTotal: CGFloat { BrailleMeter.cellWidth * CGFloat(cells) }

    /// Claude and Codex labels add "used" for the expanded drawer. The dense
    /// board can omit that suffix. A Cursor pool prints its short board name here
    /// ("Auto", "Opus"); the full name that says what the pool means to a lane rides
    /// in the tooltip and on the LANES line (see `CursorPool`).
    nonisolated static func displayLabel(_ label: String) -> String {
        CursorPool.boardLabel(label).replacingOccurrences(of: " used", with: "")
    }

    nonisolated static func displayPercent(_ percent: Double?) -> String {
        percent.map { "\(Int($0))%" } ?? "?"
    }

    /// The board's labels, percent and meter fit the meter column at the base text size.
    nonisolated static func labelsFit() -> Bool {
        let size = TowerType.designSize(.small)
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let labels = ["5h", "7d", "Fable", "Auto", "Opus"]
        return labels.allSatisfy {
            ($0 as NSString).size(withAttributes: [.font: font]).width <= labelWidth
        } && ("100%" as NSString).size(withAttributes: [.font: font]).width <= percentWidth
            && rowWidth <= SeatBoardRow.meterWidth
    }

    static func tint(_ window: RestingDrawer.MeterWindow) -> Color {
        guard window.trust == .live, let pct = window.percent else { return TowerType.dim }
        return levelColor(pct)
    }

    static func levelColor(_ usedPercent: Double) -> Color {
        switch BrailleMeterMath.level(usedPercent: usedPercent) {
        case .high: return .red
        case .watch: return .orange
        case .ok: return .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TowerTextSize.pt(1)) {
            ForEach(windows, id: \.label) { window in
                let live = window.trust == .live
                HStack(spacing: TowerTextSize.pt(4)) {
                    Text(Self.displayLabel(window.label))
                        .foregroundStyle(TowerType.secondary)
                        .lineLimit(1)
                        .frame(width: TowerTextSize.pt(Self.labelWidth), alignment: .leading)
                    BrailleMeter(percent: window.percent, cells: Self.cells,
                                 flat: live ? nil : TowerType.dim)
                    Text(Self.displayPercent(window.percent))
                        .foregroundStyle(Self.tint(window))
                        .lineLimit(1)
                        .frame(width: TowerTextSize.pt(Self.percentWidth), alignment: .trailing)
                }
                .font(TowerType.font(.small, design: .monospaced))
                .help(CursorPool.displayLabel(window.label))
            }
        }
    }
}

// MARK: - Seat board

/// Flat status board: every rankable seat across every quota provider, grouped
/// by provider, ready seats before resting ones. One row answers "which seat
/// do I open" at a glance; expanding a row shows the per-window detail.
struct SeatBoard: View {
    @ObservedObject var model: LimitsModel
    let accounts: [AccountSnapshot]
    let now: Date
    /// The verified active login, or nil while Tower cannot prove which seat the
    /// CLI holds. nil suppresses every switch affordance on the board.
    var activeEmail: String? = nil
    var onSwitch: ((AccountSnapshot) -> Void)?

    @State private var hoveredID: String?

    private static let providers: [Provider] = [.claude, .codex, .cursor]
    /// The pool column is how much of each window is USED; the room column is what is
    /// LEFT on the tightest one. Each heading says which, so no bare number is ambiguous.
    static let meterHeading = "used"
    static let roomHeading = "room"
    /// The disclosure that holds the stale seats.
    static let staleDisclosureID = "seats.stale"

    private var split: (active: [AccountSnapshot],
                        resting: [(AccountSnapshot, AccountSnapshot.RestReason)]) {
        AccountSnapshot.partition(accounts, rule: .either, now: now)
    }

    private var summaryText: String {
        // Ready means a quota seat you can act on; money rows like OpenRouter are
        // not quota and never count.
        MenuContent.readySummary(ready: split.active.filter { $0.kind.isRankable }.count,
                               total: accounts.filter { $0.kind.isRankable }.count,
                               resting: split.resting, now: now)
    }

    /// A seat that is only stale (no reading, no ceiling) has nothing to say until it is
    /// refreshed, so it folds into one "+ N stale" line. A capped seat stays in the list:
    /// its reopening clock is the information the row exists to give.
    nonisolated static func isFolded(_ rest: AccountSnapshot.RestReason?) -> Bool {
        guard let rest else { return false }
        return rest.isStale && !rest.isCapped
    }

    /// The same, for a known row: a seat whose fresh reply only lacked the 5h window
    /// (`fiveHourUnreported`) is not stale, so it keeps its own row and its "5h not reported"
    /// label stays visible instead of hiding inside "+ N stale" (2026-11-01).
    nonisolated static func isFolded(_ rest: AccountSnapshot.RestReason?, account: AccountSnapshot, now: Date) -> Bool {
        isFolded(rest) && !account.fiveHourUnreported(now: now)
    }

    nonisolated static func staleLine(count: Int, open: Bool) -> String {
        // Read as a control, not a row: "- 7 stale" under the last seat read as a stray line.
        open ? "▾ Hide \(count) stale seats" : "▸ Show \(count) stale seats"
    }

    private func rows(for provider: Provider) -> [(AccountSnapshot, AccountSnapshot.RestReason?)] {
        let active = split.active.filter { $0.kind == provider }
            .map { ($0, nil as AccountSnapshot.RestReason?) }
        let resting = split.resting.filter { $0.0.kind == provider }
            .map { ($0.0, Optional($0.1)) }
        return active + resting
    }

    private var shownRows: [(AccountSnapshot, AccountSnapshot.RestReason?)] {
        Self.providers.flatMap { rows(for: $0) }.filter { !Self.isFolded($0.1, account: $0.0, now: now) }
    }

    private var foldedRows: [(AccountSnapshot, AccountSnapshot.RestReason?)] {
        Self.providers.flatMap { rows(for: $0) }.filter { Self.isFolded($0.1, account: $0.0, now: now) }
    }

    private func row(_ account: AccountSnapshot, _ rest: AccountSnapshot.RestReason?) -> some View {
        SeatBoardRow(
            account: account,
            rest: rest,
            now: now,
            expanded: model.disclosure("seat.\(account.id)"),
            hovered: hoveredID == account.id,
            activeEmail: activeEmail,
            onSwitch: { onSwitch?(account) }
        )
        .onHover { hovering in
            hoveredID = hovering ? account.id : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("SEATS")
                    .font(TowerType.font(.header, weight: .semibold))
                Spacer()
                Text(summaryText)
                    .font(TowerType.font(.small, design: .monospaced))
                    .foregroundStyle(TowerType.secondary)
            }

            HStack(spacing: 4) {
                Spacer().frame(width: TowerTextSize.pt(SeatBoardRow.leadWidth))
                Text("seat")
                    .frame(width: TowerTextSize.pt(SeatBoardRow.seatWidth), alignment: .leading)
                Text(Self.meterHeading)
                    .frame(width: TowerTextSize.pt(SeatBoardRow.meterWidth), alignment: .leading)
                Text(Self.roomHeading)
                    .frame(width: TowerTextSize.pt(SeatBoardRow.roomWidth), alignment: .trailing)
                Text("reset")
                    .frame(width: TowerTextSize.pt(SeatBoardRow.resetWidth), alignment: .trailing)
            }
            .font(TowerType.font(.minimum))
            .foregroundStyle(TowerType.dim)

            ForEach(shownRows, id: \.0.id) { (account, rest) in
                row(account, rest)
            }

            let folded = foldedRows
            if !folded.isEmpty {
                let open = model.disclosure(Self.staleDisclosureID)
                Button(action: { open.wrappedValue.toggle() }) {
                    Text(Self.staleLine(count: folded.count, open: open.wrappedValue))
                        .font(TowerType.font(.small))
                        .foregroundStyle(TowerType.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, TowerTextSize.pt(SeatBoardRow.leadWidth + 4))
                .help("Seats with no current reading. Switch into one and refresh to read it.")
                if open.wrappedValue {
                    ForEach(folded, id: \.0.id) { (account, rest) in
                        row(account, rest)
                    }
                }
            }
        }
    }
}

struct SeatBoardRow: View {
    let account: AccountSnapshot
    let rest: AccountSnapshot.RestReason?
    let now: Date
    @Binding var expanded: Bool
    let hovered: Bool
    /// Verified active login, or nil while unverified; gates `canSwitch`.
    var activeEmail: String? = nil
    let onSwitch: () -> Void

    /// Layout units, the same unit `TowerTextSize.pt` scales. The plan line ("claude code
    /// max") is the longest string the seat column holds; the meter column holds one stacked
    /// pool line ("Fable", six braille cells, "100%"), see `SegmentedMeter.rowWidth`.
    static let seatWidth: CGFloat = 92
    nonisolated static let meterWidth: CGFloat = 106
    static let roomWidth: CGFloat = 46
    static let resetWidth: CGFloat = 86
    /// What sits left of the seat column: chevron, gap, icon. The column header row and the
    /// folded-seat line align to it.
    static let leadWidth: CGFloat = 42

    private var live: Bool {
        account.worstTrust(now: now) == .live
    }

    /// The clock this row is waiting on, when a clock exists. A stale row is
    /// waiting on a refresh, not a time, so it gets none, unless one of its
    /// windows has already reopened, which is said instead of "due".
    private var resetCell: SeatUsagePresentation.ResetCell {
        SeatUsagePresentation.resetCell(account, rest: rest, now: now)
    }

    private var roomPct: Double? {
        account.trustedUsedPct(now: now).map { max(0, 100 - $0) }
    }

    nonisolated static let switchToRefresh = "switch in\nto refresh"

    /// The room column. A resting row that is stale has no room it can stand behind, so it
    /// prints "?" rather than the cached figure, which read as usable room at 77 percent
    /// on a seat last read three days earlier. The cached figure stays in the expanded
    /// detail and in `tower status`, never in the number the eye scans.
    nonisolated static func roomCell(usage: SeatUsagePresentation,
                                     rest: AccountSnapshot.RestReason?) -> String {
        if let rest, rest.isStale, !usage.isLive { return "?" }
        return usage.roomText
    }

    private var usage: SeatUsagePresentation {
        SeatUsagePresentation(account: account, now: now)
    }

    private var roomColor: Color {
        guard let room = roomPct, live else {
            return TowerType.dim
        }
        if room <= 5 { return .red }
        if room <= 20 { return .orange }
        return .green
    }

    private var restLabel: String {
        guard let rest else { return "" }
        return SeatUsagePresentation.restLabel(rest, account: account, now: now)
    }

    private var planLabel: String {
        account.plan.isEmpty ? (account.tier ?? "-") : account.plan
    }

    /// Both switch controls use the same availability and quota reason.
    enum SwitchAction: Equatable {
        case hidden
        case enabled
        case disabled(String)
    }

    nonisolated static func switchAction(account: AccountSnapshot,
                                         rest: AccountSnapshot.RestReason?,
                                         activeEmail: String?, now: Date) -> SwitchAction {
        guard account.kind == .claude else { return .hidden }
        guard let activeEmail, account.email != activeEmail else { return .hidden }
        if (account.effectiveWeekly(now: now).pct ?? 0) >= 90 {
            return .disabled("7d at or above 90 %: wait for reset")
        }
        return rest == nil || rest?.isTimeGated == false ? .enabled : .hidden
    }

    private var switchAction: SwitchAction {
        Self.switchAction(account: account, rest: rest, activeEmail: activeEmail, now: now)
    }

    private var canSwitch: Bool { switchAction == .enabled }
    private var showsSwitch: Bool { switchAction != .hidden }
    private var switchColor: Color { canSwitch ? .orange : TowerType.dim }
    private var switchDisabledReason: String? {
        if case .disabled(let reason) = switchAction { return reason }
        return nil
    }

    private var windows: [RestingDrawer.MeterWindow] {
        RestingDrawer.meterWindows(account, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: { expanded.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(TowerType.font(.minimum, weight: .bold))
                        .foregroundStyle(TowerType.dim)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: TowerTextSize.pt(12))

                    SeatIcon(provider: account.kind, nickname: account.nickname)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(account.nickname)
                            .font(TowerType.font(.body, weight: .semibold))
                            .lineLimit(1)
                        // Product + plan, not the plan alone: the cursor seat and the
                        // cursor LANES row draw the same product mark, so "cursor
                        // ultra" is what tells the subscription seat from the
                        // "cursor / model auto" agent row (#96). It also separates
                        // same-nickname seats across providers.
                        Text("\(account.kind.label.lowercased()) \(planLabel)")
                            .font(TowerType.font(.small))
                            .foregroundStyle(TowerType.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: TowerTextSize.pt(Self.seatWidth), alignment: .leading)

                    if rest != nil {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(restLabel)
                                .font(TowerType.font(.minimum, weight: .medium))
                                .foregroundStyle(TowerType.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .help("from the \(account.kind.readingSource); Refresh reads it again")
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(Color(nsColor: .separatorColor).opacity(0.35))
                                )
                            if let note = SeatUsagePresentation.reopenedNote(account, rest: rest, now: now) {
                                Text(note)
                                    .font(TowerType.font(.minimum))
                                    .foregroundStyle(TowerType.dim)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            } else if rest?.isStale == true, !usage.isLive {
                                // Where the old number came from, so the user knows what to check.
                                Text(account.kind.readingSource)
                                    .font(TowerType.font(.minimum))
                                    .foregroundStyle(TowerType.dim)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                        }
                        .frame(width: TowerTextSize.pt(Self.meterWidth), alignment: .leading)
                    } else {
                        SegmentedMeter(windows: windows)
                            .frame(width: TowerTextSize.pt(Self.meterWidth), alignment: .leading)
                    }

                    Text(Self.roomCell(usage: usage, rest: rest))
                        .font(TowerType.font(.body, weight: .bold, design: .monospaced))
                        .foregroundStyle(roomColor)
                        .frame(width: TowerTextSize.pt(Self.roomWidth), alignment: .trailing)

                    VStack(alignment: .trailing, spacing: 0) {
                        switch resetCell {
                        case .countdown(let countdown, let clock):
                            Text(countdown)
                                .font(TowerType.font(.small, weight: .medium, design: .monospaced))
                            Text(clock)
                                .font(TowerType.font(.minimum))
                                .foregroundStyle(TowerType.secondary)
                        case .reopened(let detail):
                            Text("reopened")
                                .font(TowerType.font(.small, weight: .medium, design: .monospaced))
                            Text(detail)
                                .font(TowerType.font(.minimum))
                                .foregroundStyle(TowerType.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        case .switchToCheck:
                            // The row's number is old, so the cell names the action that
                            // replaces it (bug b, 2026-09-30): not a wait, not a figure.
                            Text(Self.switchToRefresh)
                                .font(TowerType.font(.small, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .multilineTextAlignment(.trailing)
                                .lineLimit(2)
                        case .none:
                            Text("-")
                                .font(TowerType.font(.small, design: .monospaced))
                                .foregroundStyle(TowerType.secondary)
                        }
                    }
                    .frame(width: TowerTextSize.pt(Self.resetWidth), alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(account.nickname), \(account.kind.vendorName) account")
            .overlay(alignment: .trailing) {
                if hovered && showsSwitch {
                    VStack(alignment: .trailing, spacing: 2) {
                        Button(action: onSwitch) {
                            Text("→ switch")
                                .font(TowerType.font(.small, weight: .semibold))
                                .foregroundStyle(switchColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().stroke(switchColor, lineWidth: 1)
                                        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSwitch)
                        if switchDisabledReason != nil {
                            Text("7d at or above 90 %")
                                .font(TowerType.font(.minimum))
                                .foregroundStyle(TowerType.dim)
                        }
                    }
                    .help(switchDisabledReason ?? "Switch to this seat")
                    .offset(x: Self.resetWidth + 12)
                }
            }

            if expanded {
                expandedDetail
                    .padding(.leading, TowerTextSize.pt(SeatBoardRow.leadWidth + 4))
            }
        }
        .opacity(rest == nil ? 1 : 0.7)
    }

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(windows, id: \.label) { window in
                HStack(spacing: 6) {
                    Text(window.label)
                        .frame(width: TowerTextSize.pt(80), alignment: .leading)
                    Text(window.percent.map { "\(Int($0))%" } ?? "-")
                        .font(TowerType.font(.small, design: .monospaced))
                        .frame(width: TowerTextSize.pt(38), alignment: .trailing)
                    if let resetsAt = window.resetsAt {
                        Text("\(BoardText.countdown(resetsAt, now: now)) · \(CLI.clock(resetsAt))")
                            .font(TowerType.font(.small, design: .monospaced))
                    } else {
                        Text(window.didReset ? "reset pending" : "-")
                            .font(TowerType.font(.small, design: .monospaced))
                    }
                    if window.isBinding {
                        Text("binding")
                            .font(TowerType.font(.minimum))
                            .foregroundStyle(.orange)
                    }
                }
            }
            HStack(spacing: 8) {
                if account.kind.vendorIconName != nil {
                    HStack(spacing: 3) {
                        BrandMark(provider: account.kind, size: 9, vendor: true)
                            .foregroundStyle(TowerType.secondary)
                        Text("\(account.kind.vendorName) account")
                    }
                }
                Text("captured \(CLI.age(account.capturedAt, now: now))")
                if let err = account.lastError {
                    Text(err).foregroundStyle(.red).lineLimit(1)
                }
                if account.kind == .cursor, CursorUsage.needsConnect(account.lastError) {
                    CursorConnectButton()
                }
                if showsSwitch {
                    Button("switch to this seat", action: onSwitch)
                        .buttonStyle(.plain)
                        .foregroundStyle(switchColor)
                        .disabled(!canSwitch)
                }
            }
            .font(TowerType.font(.small))
            .foregroundStyle(TowerType.secondary)
            if let reason = switchDisabledReason, showsSwitch {
                Text(reason)
                    .font(TowerType.font(.small))
                    .foregroundStyle(TowerType.dim)
            }
        }
        .font(TowerType.font(.small))
        .foregroundStyle(.primary)
        .padding(.vertical, 2)
    }
}

// MARK: - Money rows

/// Cash balances are not quotas, so they render on their own band: a meter of
/// remaining-vs-added for OpenRouter, and a TypeSafe group with a threshold bar per
/// decision model (Jev, Clef) where the amber $10 and red $5 ticks are the point.
struct MoneyBoard: View {
    let orOutcome: OpenRouter.Outcome
    let orHistory: [OpenRouter.History.Sample]
    let now: Date
    /// Whether a TypeSafe model's credit row is open. Each folds into one line by default:
    /// the figure is operator-entered and usually old, so it has little to say until it is
    /// low. A function rather than one binding per model, so a third model needs no new
    /// parameter; the panel keys it as `money.<model>` (Jev keeps `money.jev`).
    let creditOpen: (TypeSafe.Model) -> Binding<Bool>

    /// The disclosure id a model's fold is stored under.
    nonisolated static func disclosureID(_ model: TypeSafe.Model) -> String { "money.\(model.rawValue)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MONEY")
                .font(TowerType.font(.header, weight: .semibold))

            switch orOutcome {
            case .notConfigured:
                EmptyView()
            case .ok(let budget):
                HStack(spacing: 4) {
                    ProviderIcon(provider: .openrouter)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("openrouter")
                            .font(TowerType.font(.body, weight: .semibold))
                        Text("cash")
                            .font(TowerType.font(.minimum))
                            .foregroundStyle(TowerType.secondary)
                    }
                    .frame(width: TowerTextSize.pt(SeatBoardRow.seatWidth + 10), alignment: .leading)
                    .padding(.leading, 2)

                    MoneyMeter(remaining: budget.available, total: budget.limit)
                        .frame(width: TowerTextSize.pt(SeatBoardRow.meterWidth), alignment: .leading)

                    VStack(alignment: .trailing, spacing: 0) {
                        Text("$\(String(format: "%.2f", budget.available)) left")
                            .font(TowerType.font(.small, weight: .bold, design: .monospaced))
                            .foregroundStyle(Self.balanceTint(budget.availablePct))
                        Text(deltaText)
                            .font(TowerType.font(.minimum))
                            .foregroundStyle(TowerType.secondary)
                    }
                    .frame(width: TowerTextSize.pt(SeatBoardRow.roomWidth + SeatBoardRow.resetWidth + 6),
                           alignment: .trailing)
                }
            case .rejected(let code, _, _):
                HStack(spacing: 4) {
                    ProviderIcon(provider: .openrouter)
                    Text("openrouter key rejected · http \(code)")
                        .font(TowerType.font(.small))
                        .foregroundStyle(.red)
                }
            case .unavailable:
                HStack(spacing: 4) {
                    ProviderIcon(provider: .openrouter)
                    Text("openrouter unreachable")
                        .font(TowerType.font(.small))
                        .foregroundStyle(TowerType.secondary)
                }
            }

            // TypeSafe sells credits per decision model, so its models render as one group
            // under one header. No group until some model has an entered balance, and no
            // row for a model without one: nothing ships by default.
            let entered = TypeSafe.enteredModels()
            if !entered.isEmpty {
                HStack(spacing: 4) {
                    Text("credits")
                        .font(TowerType.font(.body, weight: .semibold))
                    Text(TypeSafeCreditRow.groupDetail)
                        .font(TowerType.font(.minimum))
                        .foregroundStyle(TowerType.secondary)
                        .lineLimit(1)
                }
                ForEach(entered, id: \.self) { model in
                    let open = creditOpen(model)
                    Button(action: { open.wrappedValue.toggle() }) {
                        Text(TypeSafeCreditRow.foldedLine(model: model, now: now, open: open.wrappedValue))
                            .font(TowerType.font(.small))
                            .foregroundStyle(TypeSafeCreditRow.foldedColor(model: model, now: now))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, TowerTextSize.pt(SeatBoardRow.leadWidth + 4))
                    .help("\(model.name) credit is entered by hand; nothing can read it")
                    if open.wrappedValue { TypeSafeCreditRow(model: model, now: now) }
                }
            }
        }
    }

    static func balanceTint(_ pct: Double) -> Color {
        pct <= 10 ? .red : pct <= 25 ? .orange : .green
    }

    private var deltaText: String {
        guard let trend = OpenRouter.History.trend(orHistory) else { return "no history yet" }
        let delta = trend.changeSincePrevious
        if abs(delta) < 0.005 { return "flat \(BoardText.span(trend.changeSpan))" }
        let sign = delta > 0 ? "+" : "-"
        return "\(sign)$\(String(format: "%.2f", abs(delta))) in \(BoardText.span(trend.changeSpan))"
    }
}

struct MoneyMeter: View {
    let remaining: Double
    let total: Double

    private var pct: Double {
        total > 0 ? remaining / total * 100 : 0
    }

    /// Cash left, so the meter fills with what remains and takes the balance's one colour:
    /// the quota gradient heats as a bar fills, which would read backwards for money.
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: TowerTextSize.pt(4)) {
                BrailleMeter(percent: pct, cells: SegmentedMeter.cells,
                             flat: MoneyBoard.balanceTint(pct))
                Text("\(Int(pct.rounded()))% left")
                    .foregroundStyle(MoneyBoard.balanceTint(pct))
            }
            .font(TowerType.font(.small, design: .monospaced))
            Text("of $\(String(format: "%.2f", total)) added")
                .font(TowerType.font(.minimum, design: .monospaced))
                .foregroundStyle(TowerType.secondary)
                .lineLimit(1)
        }
    }
}

/// One TypeSafe decision model's credit (Jev or Clef): the entered balance on a $25 scale
/// as a braille meter coloured by the threshold state (red under $5, amber under $10), so
/// the state is visible before the number is read. The balance is operator-entered, and
/// the row says so every time.
struct TypeSafeCreditRow: View {
    let model: TypeSafe.Model
    let now: Date

    private static let scale: Double = 25

    /// The group header's second line: what the rows under it are, and that they are
    /// prepaid, so nobody reads them as quotas.
    static let groupDetail = "decision models, entered by hand"

    private var balance: Double { TypeSafe.entry(model: model)?.usd ?? 0 }
    private var level: TypeSafe.BalanceLevel { TypeSafe.balanceLevel(balance) }
    /// Over three days an entered figure is too old to plan against; the row
    /// greys out instead of presenting it with live-colour confidence.
    private var stale: Bool { TypeSafe.balanceIsStale(model: model, now: now) }

    /// The one line the row folds into: state word and figure, so a low balance is still
    /// visible without opening it.
    nonisolated static func stateWord(level: TypeSafe.BalanceLevel, stale: Bool) -> String {
        stale ? "stale" : level == .red ? "low" : level == .amber ? "watch" : "ok"
    }

    nonisolated static func foldedLine(model: TypeSafe.Model, now: Date, open: Bool,
                           defaults: UserDefaults = TowerPreferences.shared) -> String {
        let balance = TypeSafe.entry(model: model, defaults: defaults)?.usd ?? 0
        let word = stateWord(level: TypeSafe.balanceLevel(balance),
                             stale: TypeSafe.balanceIsStale(model: model, now: now, defaults: defaults))
        return "\(open ? "-" : "+") \(model.rawValue) · \(model.vendor) credits \(TypeSafe.money(balance)) \(word)"
    }

    /// Quiet while the figure is fine or too old to trust; amber or red only for a live
    /// low balance, the case worth interrupting a folded line for.
    static func foldedColor(model: TypeSafe.Model, now: Date) -> Color {
        guard !TypeSafe.balanceIsStale(model: model, now: now) else { return TowerType.secondary }
        switch TypeSafe.balanceLevel(TypeSafe.entry(model: model)?.usd ?? 0) {
        case .green: return TowerType.secondary
        case .amber: return .orange
        case .red: return .red
        }
    }

    private var levelColor: Color {
        guard !stale else { return TowerType.dim }
        switch level {
        case .green: return .green
        case .amber: return .orange
        case .red: return .red
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ProviderIcon(provider: .typesafe)
                .opacity(stale ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(model.rawValue) credits")
                    .font(TowerType.font(.body, weight: .semibold))
                    .opacity(stale ? 0.7 : 1)
                Text(TypeSafe.enteredAgeLabel(model: model, now: now))
                    .font(TowerType.font(.small))
                    .foregroundStyle(TowerType.secondary)
                    .lineLimit(1)
            }
            .frame(width: TowerTextSize.pt(SeatBoardRow.seatWidth + 10), alignment: .leading)
            .padding(.leading, 2)

            HStack(spacing: TowerTextSize.pt(4)) {
                BrailleMeter(percent: min(balance / Self.scale, 1) * 100,
                             cells: SegmentedMeter.cells, flat: levelColor)
                Text(TypeSafe.money(balance))
                    .foregroundStyle(levelColor)
            }
            .font(TowerType.font(.small, design: .monospaced))
            .frame(width: TowerTextSize.pt(SeatBoardRow.meterWidth), alignment: .leading)

            // Greying out alone tells the operator the figure is old, not what to do.
            // Nothing can fetch it, so the fix is a re-entry: the row names that action,
            // and the exact config command lives in the tooltip, never in the panel text
            // (bug c, 2026-09-30: the raw tool call leaked into the UI).
            VStack(alignment: .trailing, spacing: 0) {
                if let command = TypeSafe.reenterHint(model: model, now: now) {
                    Text(TypeSafe.panelReenterAction)
                        .font(TowerType.font(.small, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .help(command)
                } else {
                    Text(Self.stateWord(level: level, stale: stale))
                        .font(TowerType.font(.small))
                        .foregroundStyle(TowerType.secondary)
                }
            }
            .frame(width: TowerTextSize.pt(SeatBoardRow.roomWidth + SeatBoardRow.resetWidth + 6),
                   alignment: .trailing)
        }
    }
}

// MARK: - Agent lanes

/// Harness rows for providers that dispatch rather than expose quotas. Same
/// tile language as the seat board; usage stays honest (quota / not readable /
/// not exposed) exactly as AgentLane reports it.
struct LaneBoard: View {
    let outcomes: [Provider: AgentLane.Outcome]
    let now: Date
    /// The Cursor seat row, for the Opus flag and the pool line on the Cursor CLI lane.
    var cursorSeat: AccountSnapshot? = nil
    /// The MONEY band's OpenRouter outcome, so Pi's month reads against the same balance.
    var openRouter: OpenRouter.Outcome = .notConfigured

    /// The width the usage line gets in the 430 pt panel: 10 pt panel padding each side,
    /// the 24 pt icon and the 6 pt gap. The line may wrap to `usageLines`; tests measure
    /// the longest real lines against this budget.
    /// Plain constants, so nonisolated: tests and non-UI code read them off the main actor.
    nonisolated static let panelWidth: CGFloat = TowerType.panelWidth
    nonisolated static let usageWidth: CGFloat = panelWidth - 2 * 10 - 24 - 6
    nonisolated static let usageLines = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("LANES")
                .font(TowerType.font(.header, weight: .semibold))

            ForEach(AgentLane.lanes, id: \.self) { provider in
                switch outcomes[provider] ?? .notConfigured {
                case .notConfigured:
                    EmptyView()
                case .unavailable(let why):
                    HStack(spacing: 4) {
                        ProviderIcon(provider: provider)
                        Text("\(provider.label.lowercased()) config unreadable")
                            .font(TowerType.font(.small))
                            .foregroundStyle(.orange)
                            .help(why)
                    }
                case .ok(let reading):
                    // Two lines with a width budget instead of one packed row. Line one
                    // is identity (name, model, last dispatch); line two gets the full
                    // row width for the usage text, which wraps rather than truncates.
                    // The old single row gave that text what was left after a 110 pt
                    // name column and the flags, so Devin's quota and the Cursor reason
                    // were squeezed at 430 pt.
                    HStack(alignment: .top, spacing: 6) {
                        ProviderIcon(provider: provider)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(provider.label.lowercased())
                                    .font(TowerType.font(.body, weight: .semibold))
                                    .fixedSize()
                                Text(AgentLane.modelLine(reading))
                                    .font(TowerType.font(.minimum))
                                    .foregroundStyle(TowerType.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 6)
                                Text(AgentLane.dispatchLine(reading, now: now))
                                    .font(TowerType.font(.minimum))
                                    .foregroundStyle(TowerType.secondary)
                                    .fixedSize()
                            }
                            if case .spend(let spend) = reading.usage {
                                piShare(spend)
                            }
                            let meters = AgentLane.meters(reading, cursorSeat: cursorSeat, now: now)
                            if !meters.isEmpty {
                                HStack(spacing: TowerTextSize.pt(10)) {
                                    ForEach(meters, id: \.label) { meter in
                                        let stale = meter.age != nil
                                        HStack(spacing: TowerTextSize.pt(4)) {
                                            Text(meter.label).foregroundStyle(TowerType.secondary)
                                            BrailleMeter(percent: meter.usedPct, cells: SegmentedMeter.cells,
                                                         flat: stale ? TowerType.dim : nil)
                                            Text(SegmentedMeter.displayPercent(meter.usedPct))
                                                .foregroundStyle(stale ? TowerType.dim
                                                                 : SegmentedMeter.levelColor(meter.usedPct))
                                        }
                                    }
                                    if let age = meters.first?.age {
                                        Text(age)
                                            .font(TowerType.font(.minimum))
                                            .foregroundStyle(TowerType.dim)
                                    }
                                }
                                .font(TowerType.font(.small, design: .monospaced))
                            }
                            Text(usageText(reading))
                                .font(TowerType.font(.small))
                                .lineLimit(Self.usageLines)
                                .fixedSize(horizontal: false, vertical: true)
                            flags(provider, reading)
                        }
                    }
                    .help("\(provider.label), \(provider.vendorName) account")
                }
            }
        }
    }

    /// Pi's month as a share of the OpenRouter balance: a meter of the share, then the
    /// dollars left on the key. Without a share the reason prints instead of a bar, so a
    /// missing balance never reads as zero spend.
    @ViewBuilder
    private func piShare(_ spend: PiLane.Spend) -> some View {
        let share = PiLane.share(spend, openRouter: openRouter)
        switch share {
        case .openRouter(let pct, _, _):
            HStack(spacing: TowerTextSize.pt(4)) {
                Text("or").foregroundStyle(TowerType.secondary)
                BrailleMeter(percent: min(pct, 100), cells: SegmentedMeter.cells)
                Text(PiLane.shareLine(share))
                    .foregroundStyle(SegmentedMeter.levelColor(pct))
                    .lineLimit(1)
            }
            .font(TowerType.font(.small, design: .monospaced))
        case .spendOnly:
            Text(PiLane.shareLine(share))
                .font(TowerType.font(.small))
                .foregroundStyle(TowerType.secondary)
                .lineLimit(Self.usageLines)
        }
    }

    private func usageText(_ reading: AgentLane.Reading) -> String {
        let usage = AgentLane.usageLine(reading, cursorSeat: cursorSeat, now: now)
            ?? AgentLane.headerDetail(reading, cursorSeat: cursorSeat, now: now)
        return AgentLane.usageAgeLine(reading, now: now).map { "\(usage) · \($0)" } ?? usage
    }

    /// The Opus flag and the newest refusal. A refusal that no longer describes the
    /// lane (`AgentLane.limitIsCurrent`) stays visible as dim history, never orange.
    @ViewBuilder
    private func flags(_ provider: Provider, _ reading: AgentLane.Reading) -> some View {
        let opus = provider == .cursor
            ? CursorPool.laneFlag(cursorSeat, laneModel: reading.modelPin, now: now) : nil
        let hit = reading.lastLimitHit.flatMap { hit in
            AgentLane.limitIsCurrent(reading, now: now) || AgentLane.showsPastLimit(hit, now: now)
                ? hit : nil
        }
        if opus != nil || hit != nil {
            HStack(spacing: 6) {
                if let opus {
                    Text("Opus refused · Auto runs")
                        .font(TowerType.font(.minimum, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(opus)
                }
                if let hit {
                    if AgentLane.limitIsCurrent(reading, now: now) {
                        Text(AgentLane.limitLine(hit, now: now))
                            .font(TowerType.font(.minimum, weight: .medium))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .help(hit.message)
                    } else {
                        Text(AgentLane.pastLimitLine(hit, now: now))
                            .font(TowerType.font(.minimum))
                            .foregroundStyle(TowerType.dim)
                            .lineLimit(1)
                            .help(hit.message)
                    }
                }
            }
        }
    }
}

// MARK: - Sessions

/// Same data as before, table-tight: interactive groups only, backgrounds as a
/// header count. The seat column shows the resolved account's nickname.
struct SessionsBoard: View {
    let agents: AgentSummary?
    /// False before the first refresh: a nil `agents` is then not read yet, not a
    /// probe that failed.
    var probed = true
    /// Whether the idle sessions are listed. They fold into one line by default; the sessions
    /// worth a glance are the busy ones.
    @Binding var idleOpen: Bool

    /// An unknown count is "?", never 0: zero sessions is a reading, and there is none.
    nonisolated static func heading(_ agents: AgentSummary?) -> String {
        "SESSIONS · " + (agents.map { "\($0.interactive.count)" } ?? "?")
    }

    /// "9 busy · 3 idle", or nil when there is no summary to count.
    nonisolated static func busyIdleLine(_ agents: AgentSummary?) -> String? {
        guard let agents else { return nil }
        let busy = agents.interactive.filter(\.isBusy).count
        return "\(busy) busy · \(agents.interactive.count - busy) idle"
    }

    /// The line under the heading when there is no summary to list.
    nonisolated static func missingLine(probed: Bool) -> String {
        probed ? "session probe unavailable" : "not read yet"
    }

    nonisolated static func idleLine(count: Int, open: Bool) -> String {
        "\(open ? "-" : "+") \(count) idle"
    }

    private func groupRow(_ group: SessionGroup, showAccount: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(group.busy ? Color.green : TowerType.dim)
                .frame(width: TowerTextSize.pt(6), height: TowerTextSize.pt(6))
            Text(group.label + group.suffix)
                .font(TowerType.font(.small))
                .lineLimit(1)
                .help(group.rawName)
            Spacer()
            if showAccount {
                Text(group.accountEmail == nil ? "?" : group.accountLabel)
                    .font(TowerType.font(.small, design: .monospaced))
                    .foregroundStyle(group.accountEmail == nil ? TowerType.dim : TowerType.secondary)
                    .help(group.accountEvidence ?? "Session account could not be established")
            }
            Text(group.busy ? "busy" : "idle")
                .font(TowerType.font(.minimum, design: .monospaced))
                .foregroundStyle(group.busy ? Color.green : TowerType.secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.heading(agents))
                    .font(TowerType.font(.header, weight: .semibold))
                if let line = Self.busyIdleLine(agents) {
                    Text(line)
                        .font(TowerType.font(.small))
                        .foregroundStyle(TowerType.secondary)
                }
                if let count = agents?.backgroundCount, count > 0 {
                    Text("+\(count) bg")
                        .font(TowerType.font(.minimum))
                        .foregroundStyle(TowerType.secondary)
                }
                Spacer()
                if let tally = agents?.accountTally {
                    Text(tally)
                        .font(TowerType.font(.small, design: .monospaced))
                        .foregroundStyle(TowerType.secondary)
                        .lineLimit(1)
                }
            }
            if let reason = agents?.unattributedReason {
                Text(reason)
                    .font(TowerType.font(.small))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Tower names a session's account from the reset anchor the statusline "
                          + "writes per session. Run the installer from a terminal; Claude Code "
                          + "cannot write under ~/.claude.")
            }

            if agents == nil {
                // A probe that could not run stays loud; one that has not run yet is not
                // a failure and reads quiet.
                Text(Self.missingLine(probed: probed))
                    .font(TowerType.font(.small))
                    .foregroundStyle(probed ? Color.orange : TowerType.secondary)
            } else if agents!.groups.isEmpty {
                Text("none")
                    .font(TowerType.font(.small))
                    .foregroundStyle(TowerType.secondary)
            } else {
                let groups = agents!.groups
                let idle = groups.filter { !$0.busy }
                let showAccount = agents!.unattributedReason == nil
                ForEach(groups.filter(\.busy)) { groupRow($0, showAccount: showAccount) }
                if !idle.isEmpty {
                    Button(action: { idleOpen.toggle() }) {
                        Text(Self.idleLine(count: idle.count, open: idleOpen))
                            .font(TowerType.font(.small))
                            .foregroundStyle(TowerType.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if idleOpen { ForEach(idle) { groupRow($0, showAccount: showAccount) } }
                }
            }
        }
    }
}

// MARK: - Connect Cursor

enum CursorConnectState: Equatable {
    case idle
    case waiting
    case failed(String)
}

/// The Cursor row's one action when Tower has no Cursor sign-in of its own: open Cursor's
/// sign-in page, then show that Tower is waiting for it.
struct CursorConnectButton: View {
    @ObservedObject var model = LimitsModel.shared

    var body: some View {
        switch model.cursorConnect {
        case .waiting:
            Text("waiting for Cursor sign-in").foregroundStyle(.orange)
        case .idle:
            Button("Connect Cursor") { model.connectCursor() }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
        case .failed(let why):
            HStack(spacing: 4) {
                Button("Connect Cursor") { model.connectCursor() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                Text(why).foregroundStyle(.red).lineLimit(1)
            }
        }
    }
}
