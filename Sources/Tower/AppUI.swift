import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Launch at login

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) -> String? {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Notifications

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    FileHandle.standardError.write(
                        Data("notification auth failed: \(error.localizedDescription)\n".utf8))
                } else if !granted {
                    FileHandle.standardError.write(
                        Data("notifications not granted; alerts will be silent\n".utf8))
                }
            }
    }

    static func post(_ a: Alert) {
        let c = UNMutableNotificationContent()
        let window = a.window == "5h" ? "5-hour" : "weekly"
        if a.pct >= 100 {
            c.title = "⛔ \(a.nickname): \(window) limit reached"
        } else {
            c.title = "⚠️ \(a.nickname) at \(Int(a.pct.rounded()))% of \(window)"
        }
        if let r = a.resetsAt {
            c.body = "Resets \(CLI.clock(r)). Consider switching accounts."
        } else {
            c.body = "Consider switching accounts."
        }
        c.sound = .default
        let req = UNNotificationRequest(
            identifier: "\(a.nickname)-\(a.window)-\(Int(a.pct))",
            content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error {
                FileHandle.standardError.write(
                    Data("notification post failed: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    /// Stable per account and level, so the crossing a toast announced can be withdrawn
    /// by the same name when the account drops back below the mark.
    static func railIdentifier(_ nickname: String, _ level: Rail.Level) -> String {
        "rail-\(nickname)-\(level.label ?? "none")"
    }

    /// The rail crossing toast, in the wording the issue pins. Title and body split the
    /// pinned shape across the two notification lines; read together they are one
    /// sentence: "account A at 83 %: no new stations on A, rotation brief due at 90 %".
    static func post(_ crossing: RailCrossing) {
        let content = UNMutableNotificationContent()
        content.title = "\(crossing.level == .red ? "🔴" : "🟠") \(crossing.toastTitle)"
        content.body = crossing.toastBody
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: railIdentifier(crossing.nickname, crossing.level),
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error {
                FileHandle.standardError.write(
                    Data("notification post failed: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    /// The blast radius toast: the active login is near the mark that stops every
    /// session riding it. Stable identifier, so a later level replaces an earlier banner.
    static func post(_ blast: BlastRadius) {
        let content = UNMutableNotificationContent()
        content.title = blast.level == .stopped
            ? "⛔ \(blast.nickname) is full" : "⚠️ \(blast.nickname) at \(blast.percentUsed.map { "\(Int($0.rounded()))" } ?? "?") %"
        content.body = blast.line
        content.sound = .default
        let req = UNNotificationRequest(identifier: "blast-\(blast.nickname)",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error {
                FileHandle.standardError.write(
                    Data("notification post failed: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    /// Withdraws the blast banner once the login drops back below the warn mark.
    static func clearBlast(nickname: String) {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ["blast-\(nickname)"])
    }

    /// Withdraws the toasts for levels the account no longer holds. A banner that keeps
    /// claiming "no new stations" after the account dropped below the mark is the stale
    /// claim this repo refuses on every other surface.
    static func clearRail(nickname: String, standing: Rail.Level) {
        let gone = [Rail.Level.amber, .red]
            .filter { $0 > standing }
            .map { railIdentifier(nickname, $0) }
        guard !gone.isEmpty else { return }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: gone)
    }
}

// MARK: - Model

@MainActor
final class LimitsModel: ObservableObject {
    static let shared = LimitsModel()

    @Published var accounts: [AccountSnapshot] = []
    /// Chrome display profiles (and optional account-chooser rows), keyed by account email.
    @Published var switchProfiles: [String: ChromeProfileHint] = [:]
    @Published var activeEmail: String?
    /// Last SUCCESSFUL refresh. A failure must not move this, or the age shown in the
    /// header becomes a lie about data that never arrived.
    @Published var lastRefresh: Date?
    @Published var refreshError: String?
    @Published var refreshing = false
    @Published var launchAtLogin = LaunchAtLogin.isEnabled
    @Published var loginError: String?
    @Published var retainClaudeSeats = ClaudeSeatRetention.isEnabled()
    @Published var seatRetentionError: String?
    /// #121: the panel's text size, stored in the shared settings domain.
    @Published var textSize = TowerTextSize.stored()
    /// nil = the probe failed or has not run; the UI must say "unavailable",
    /// not render an empty list as "nothing running".
    @Published var agents: AgentSummary?
    /// The machine half of "room"; nil when the kernel reads failed or have not run.
    @Published var machine: MachineLoad?
    /// False until a refresh has run the session probe and sampled the machine. Until
    /// then a nil `agents` or `machine` means not read yet, not a failed read: launch
    /// and every panelshot render in this state and must not report failures.
    @Published var probed = false
    /// Last blast radius level announced, per login, so one crossing toasts once.
    private var blastAnnounced: [String: BlastRadius.Level] = [:]

    /// The full outcome, not just a value. `.notConfigured` hides the section; `.rejected`
    /// must be LOUD, because a refused key that hides looks identical to no key at all.
    @Published var orOutcome: OpenRouter.Outcome = .notConfigured
    /// A chart is only as honest as the local observations behind it. Starts empty and fills
    /// on successful OpenRouter reads; failures do not masquerade as zero-spend candles.
    @Published var orHistory: [OpenRouter.History.Sample] = OpenRouter.History.load()
    /// Muse, Devin and Antigravity. Panel state only, never the persisted store: these rows
    /// carry no usage reading, and the store's mirror is what the dispatcher routes on.
    @Published var laneOutcomes: [Provider: AgentLane.Outcome] = [:]


    /// Transient "copied" confirmation on the advice banner. Cleared on every refresh so it
    /// cannot sit there claiming a clipboard write from ten minutes ago.
    @Published var copiedCommand = false

    /// Which sections have a disclosure expanded, keyed by section id. Persisted so a
    /// deliberate expansion survives a relaunch.
    ///
    /// This was ONE shared bool, justified by "only one pane is on screen at a time" — true
    /// while a tab strip showed a single provider, and false the instant the tabs were
    /// removed. With flat sections that single bool expanded EVERY drawer at once, so four
    /// "not checked" rows and a blocked Codex row rendered together and cost more height
    /// than the accounts they were hiding behind.
    ///
    /// Empty by default: a collapsed section still states its summary in the header
    /// ("4 need refresh"), so closed loses no information, only rows.
    @Published var expanded: Set<String> {
        didSet {
            guard persistExpanded else { return }
            expandedWriter(expanded)
        }
    }
    private let persistExpanded: Bool
    private let expandedWriter: (Set<String>) -> Void

    init(
        expanded: Set<String>? = nil,
        persistExpanded: Bool = true,
        expandedWriter: @escaping (Set<String>) -> Void = { expanded in
            TowerPreferences.shared.set(Array(expanded).sorted(), forKey: "expandedSections")
        }
    ) {
        self.persistExpanded = persistExpanded
        self.expandedWriter = expandedWriter
        self.expanded = expanded ?? Set(
            TowerPreferences.shared.stringArray(forKey: "expandedSections") ?? [])
    }

    /// A Bool binding onto one section's membership in `expanded`, so each disclosure keeps
    /// the simple `@Binding var open: Bool` interface.
    func disclosure(_ id: String) -> Binding<Bool> {
        Binding(get: { self.expanded.contains(id) },
                set: { on in
                    if on { self.expanded.insert(id) } else { self.expanded.remove(id) }
                })
    }

    private var timer: Timer?
    private var expirySweep: Task<Void, Never>?
    private var loginTimer: Timer?
    private var started = false
    private var wakeObserver: NSObjectProtocol?
    private var loginTracker = ClaudeLoginTracker()
    private var loginPollInFlight = false
    private var loginRetentionEpoch = 0
    private struct ObservedLogin {
        let credential: ClaudeCredential
        let observation: Result<ClaudeSeatObservation, ClaudeSeatVaultError>
    }
    private var queuedLoginCredentials: [ObservedLogin] = []

    /// Refresh the configured roster every five minutes; login changes also fetch the
    /// affected profile promptly without repeating other providers.
    private static let pollInterval: TimeInterval = 300
    /// `/login` writes profile Keychain items independently of Tower.  A short
    /// local poll makes the just-signed-in seat visible before the next five-minute cadence.
    private static let loginPollInterval: TimeInterval = 5

    /// Menu opens arrive in bursts, so skip the poll if one just happened.
    private static let openDebounce: TimeInterval = 20

    /// Debounce on the last ATTEMPT, not the last success. `lastRefresh` deliberately does
    /// not advance on failure, so debouncing against it meant an offline user re-ran two
    /// 20-second request timeouts on every single menu open.
    private var lastAttempt: Date?

    func start() {
        guard !started else { return }
        started = true
        hydrateFromDisk()
        let identity = ClaudeConfigIdentity.read(at: ClaudeConfigIdentity.defaultURL())
        _ = loginTracker.observe(
            credentials: Keychain.activeOAuth().map { [$0] } ?? [],
            identity: identity)
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor in await LimitsModel.shared.refresh() }
        }
        loginTimer = Timer.scheduledTimer(withTimeInterval: Self.loginPollInterval, repeats: true) { _ in
            Task { @MainActor in LimitsModel.shared.pollForLoginChange() }
        }
        // A timer does not fire while the Mac is asleep, so catch up explicitly on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await LimitsModel.shared.refresh() }
        }
    }

    /// After a failure, wait longer before retrying on menu open. The usage endpoint really
    /// does rate-limit (an HTTP 429 was provoked from it while testing this), and retrying
    /// every 20 seconds of menu activity makes a 429 last longer rather than shorter.
    private static let failureBackoff: TimeInterval = 60

    /// Called when the menu opens. No-op when we just tried, successfully or not.
    func refreshIfStale() async {
        let gap = refreshError == nil ? Self.openDebounce : Self.failureBackoff
        if let last = lastAttempt, Date().timeIntervalSince(last) < gap { return }
        await refresh()
    }

    func hydrateFromDisk() {
        hydrateFromDisk(verifiedEmail: Store.shared.verifiedActiveSeat()?.email)
    }

    /// Panelshot is a cached renderer: unlike the running panel, it never reads a
    /// credential. The active marker comes only from the last verified seat record;
    /// the config file any session rewrites is not identity.
    func hydrateForPanelShot() {
        let state = PanelShotHydration.load(
            store: Store.shared,
            switchProfiles: { Store.shared.switchProfilesByEmail() },
            diskIdentityHint: { Store.shared.verifiedActiveSeat()?.email },
            openRouterLastSuccess: { DemoMode.openRouterLastSuccess() },
            // A demo shot shows the invented store only, not this Mac's agent CLIs. The one
            // exception is an invented Pi directory the demo names with TOWER_PI_DIR.
            lanes: DemoMode.supportDirectory() == nil ? { AgentLane.readAll() } : { DemoMode.lanes() })
        accounts = state.accounts
        switchProfiles = state.switchProfiles
        activeEmail = state.activeEmail
        orOutcome = state.openRouter
        laneOutcomes = state.laneOutcomes
    }

    private func hydrateFromDisk(verifiedEmail: String?) {
        accounts = SeatCacheHydration.rows(from: Store.shared)
        switchProfiles = Store.shared.switchProfilesByEmail()
        activeEmail = SeatCacheHydration.activeEmail(
            hint: verifiedEmail, accounts: accounts)
        // The MONEY band shows what the store already proves until the first poll lands,
        // so a refused key is red from launch instead of absent.
        orOutcome = OpenRouter.persistedOutcome(
            from: accounts, lastSuccessAt: OpenRouter.lastSuccessTime())
    }

    private func pollForLoginChange() {
        guard !loginPollInFlight else { return }
        loginPollInFlight = true
        let epoch = loginRetentionEpoch
        Task.detached {
            let credentials = Keychain.activeOAuth().map { [$0] } ?? []
            let identity = ClaudeConfigIdentity.read(at: ClaudeConfigIdentity.defaultURL())
            await MainActor.run {
                self.loginPollInFlight = false
                guard self.loginRetentionEpoch == epoch else { return }
                let observed = self.loginTracker.observe(
                    credentials: credentials, identity: identity)
                if observed.watchDegraded {
                    self.refreshError = "login watch: ~/.claude.json unreadable"
                }
                if observed.changedCredentials.isEmpty,
                   observed.identityChanged,
                   credentials.isEmpty {
                    self.requestLoginRefresh(nil)
                    return
                }
                for credential in observed.changedCredentials {
                    self.requestLoginRefresh(credential)
                }
            }
        }
    }

    private func requestLoginRefresh(_ credential: ClaudeCredential?) {
        guard let credential else {
            refreshError = "needs login"
            return
        }
        let login = ObservedLogin(credential: credential,
                                  observation: ClaudeSeatVault.shared.beginObservationResult())
        guard !refreshing else {
            // `/login` can finish while the regular roster refresh is awaiting another
            // provider. Keep each observed token, so A then B logins cannot drop A.
            enqueueLoginCredential(login)
            return
        }
        let epoch = loginRetentionEpoch
        Task {
            guard loginRetentionEpoch == epoch else { return }
            await refreshLoggedInAccount(login)
        }
    }

    private func enqueueLoginCredential(_ login: ObservedLogin) {
        guard !queuedLoginCredentials.contains(where: {
            $0.credential.service == login.credential.service
                && $0.credential.accessToken == login.credential.accessToken
        }) else { return }
        queuedLoginCredentials.append(login)
    }

    private func runNextQueuedLoginRefresh() {
        guard !queuedLoginCredentials.isEmpty else { return }
        let credential = queuedLoginCredentials.removeFirst()
        let epoch = loginRetentionEpoch
        Task {
            guard loginRetentionEpoch == epoch else { return }
            await self.refreshLoggedInAccount(credential)
        }
    }

    private func refreshLoggedInAccount(_ login: ObservedLogin) async {
        guard !refreshing else {
            enqueueLoginCredential(login)
            return
        }
        refreshing = true
        defer {
            refreshing = false
            runNextQueuedLoginRefresh()
        }
        let result = await Refresher.refreshLoggedInAccount(login.credential, observation: login.observation)
        accounts = result.accounts.values.sorted { AccountSnapshot.ranked($0, $1) }
        scheduleExpirySweep()
        switchProfiles = Store.shared.switchProfilesByEmail()
        if login.credential.service == Keychain.defaultService {
            // The persisted fallback still has to describe THIS login: a record
            // bound to another token is a memory of a previous session.
            let persisted = Store.shared.verifiedActiveSeat()
            activeEmail = result.verifiedActiveEmail
                ?? persisted.flatMap { $0.binds(to: login.credential, now: Date()) ? $0.email : nil }
        }
        if let error = result.saveError {
            refreshError = error
        } else if let failure = result.failureText {
            refreshError = failure
        } else if result.attemptedServices.isEmpty {
            refreshError = "needs login"
        } else {
            lastRefresh = Date()
            refreshError = nil
        }
    }

    func toggleLaunchAtLogin(_ on: Bool) {
        loginError = LaunchAtLogin.set(on)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    /// Turning retention off must first remove every Tower-owned access token.  Leaving the
    /// switch on after a Keychain failure makes the remaining state explicit instead of
    /// presenting a successful opt-out that did not actually remove the stored seats.
    func toggleClaudeSeatRetention(_ on: Bool) {
        seatRetentionError = nil
        guard !on else {
            ClaudeSeatVault.shared.enableRetention()
            retainClaudeSeats = ClaudeSeatRetention.isEnabled()
            return
        }
        // Drop observations already waiting in this process before advancing the persistent
        // vault fence. The vault also suppresses the unchanged active token, so the next
        // normal poll cannot retain it again.
        loginRetentionEpoch += 1
        queuedLoginCredentials.removeAll()
        if let error = ClaudeSeatVault.shared.disableAndForget(suppressing: Keychain.activeOAuth()) {
            seatRetentionError = error
            retainClaudeSeats = ClaudeSeatRetention.isEnabled()
            return
        }
        retainClaudeSeats = ClaudeSeatRetention.isEnabled()
    }

    /// Forget advances the vault observation fence before removing items.  Clearing this
    /// in-memory queue completes the UI half of that fence: a login noticed before Forget
    /// cannot be refreshed from the queue afterwards.
    /// Stores the size, re-renders the panel from its root, then refits the window to the
    /// new content size.
    func setTextSize(_ size: TowerTextSize) {
        TowerTextSize.store(size)
        textSize = TowerTextSize.stored()
        DispatchQueue.main.async { AppDelegate.shared?.fitPanel() }
    }

    /// The one place the Keychain dialog may appear: after an identity change the operator
    /// approves remembered seats once, here, instead of every poll prompting per seat.
    func retrustRetainedClaudeSeats() {
        seatRetentionError = nil
        switch ClaudeSeatVault.shared.retrust() {
        case .failure(let error): seatRetentionError = error.message
        case .success(let counts) where counts.unreadable > 0:
            seatRetentionError = "\(counts.unreadable) remembered seat(s) still not readable"
        case .success: Task { await refresh() }
        }
    }

    func forgetRetainedClaudeSeats() {
        seatRetentionError = nil
        loginRetentionEpoch += 1
        queuedLoginCredentials.removeAll()
        if let error = ClaudeSeatVault.shared.forgetAll(suppressing: Keychain.activeOAuth()) {
            seatRetentionError = error
            return
        }
    }

    /// The identity advise may act on after a refresh. A failed poll keeps the
    /// last verified record, but a noCredential cycle means no live login exists
    /// at all: the persisted record is a memory of a previous one and advise
    /// must reach `.activeUnknown`, not resurrect it.
    nonisolated static func activeEmail(
        after outcome: RefreshOutcome, cycle: String?, persisted: String?
    ) -> String? {
        switch outcome {
        case .ok(let email): return email
        case .failed: return persisted ?? cycle
        case .noCredential: return nil
        }
    }

    /// Refreshes usage, sessions, and derived panel state from one coordinated observation.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        lastAttempt = Date()
        copiedCommand = false
        defer {
            refreshing = false
            runNextQueuedLoginRefresh()
        }

        // Sessions and usage are independent probes; run them concurrently so a
        // slow `claude agents` cannot delay the numbers this app exists for.
        async let agentProbe = AgentProbe.fetch()
        // The lanes are read inside the refresh (file reads plus one bounded `muse usage`),
        // so the panel shows the same answer that was folded into the store and the mirror.
        let result = await Refresher.refreshActive()
        agents = await agentProbe
        laneOutcomes = result.lanes
        // Refresher already fetched and persisted this exact observation. Reuse it so the
        // panel, history and mirror cannot report three different answers from two requests.
        orOutcome = result.openRouterOutcome
        if let observation = Refresher.openRouterObservation(
            outcome: orOutcome, accounts: result.accounts,
            foldCommitted: result.openRouterFoldCommitted
        ) {
            orHistory = OpenRouter.History.record(
                observation.budget, now: observation.capturedAt)
        } else {
            orHistory = OpenRouter.History.load()
        }
        var stored = result.accounts
        var alerts: [Alert] = []
        var bookkeepingError: String?

        // Announce thresholds for the account we actually have live numbers for. This is a
        // second read-modify-write, so it goes through the same lock instead of racing the
        // CLI with a copy of the store it read moments ago.
        // Every row we have a CURRENT reading for, not just the Claude one. Cursor is
        // refreshed on the same cycle from its own endpoint, so its 80/95/100 crossings are
        // exactly as announceable — and a lane that silently fills up until Cursor starts
        // refusing requests is the guessing game this row exists to kill.
        var keys: [String] = []
        if case .ok(let email) = result.outcome { keys.append(email) }
        if let cursorKey = result.cursorKey { keys.append(cursorKey) }
        var railToasts: [RailCrossing] = []
        var railClears: [(nickname: String, standing: Rail.Level)] = []
        if !keys.isEmpty {
            let (after, saveError) = Store.shared.mutate { accounts in
                // The rail machine runs for EVERY row: the railed windows of an inactive
                // account can still end while it rests, and a standing flag must clear
                // when that happens instead of waiting for the account to be refreshed.
                // Only a capture can raise a level, so toasts stay tied to the rows this
                // cycle actually observed. Same save as the threshold bookkeeping, so
                // the flag and the numbers it was derived from never disagree on disk.
                for key in Array(accounts.keys) {
                    guard var snap = accounts[key] else { continue }
                    if keys.contains(key) { alerts += Thresholds.evaluate(&snap) }
                    Self.railStep(&snap, toasts: &railToasts, clears: &railClears)
                    accounts[key] = snap
                }
            }
            stored = after
            bookkeepingError = saveError
        }

        // Sorted here only so the stored order is deterministic. This is NOT the
        // authoritative display order: trust decays with the clock, so the panel
        // re-sorts at render. See the ForEach in the popover body.
        accounts = stored.values.sorted { AccountSnapshot.ranked($0, $1) }
        scheduleExpirySweep()
        switchProfiles = Store.shared.switchProfilesByEmail()
        activeEmail = Self.activeEmail(
            after: result.outcome, cycle: result.activeEmail,
            persisted: Store.shared.verifiedActiveSeat()?.email)
        machine = MachineLoad.sample()
        probed = true
        let blast = blastRadius(now: Date())

        if result.outcome.isOK {
            lastRefresh = Date()
            refreshError = nil
        } else {
            refreshError = result.outcome.errorText
        }
        if let bookkeepingError { refreshError = bookkeepingError }

        // Only announce if the "already announced" bookkeeping actually persisted. Posting
        // after a failed save would re-announce the same threshold on every poll until the
        // disk recovered.
        if let blast {
            // Unknown (a missed capture) neither announces nor re-arms: warn, unknown, warn
            // is one standing warning, not two. Back to clear withdraws the banner.
            if blast.level != .unknown {
                if blast.announces(after: blastAnnounced[blast.nickname]) { Notifier.post(blast) }
                if blast.level == .clear, blastAnnounced[blast.nickname].map({ $0 > .clear }) == true {
                    Notifier.clearBlast(nickname: blast.nickname)
                }
                blastAnnounced[blast.nickname] = blast.level
            }
        }
        if bookkeepingError == nil {
            for a in alerts { Notifier.post(a) }
            for c in railToasts { Notifier.post(c) }
            for c in railClears { Notifier.clearRail(nickname: c.nickname, standing: c.standing) }
        }
    }

    /// Advances the rail machine for one row inside the caller's locked mutate: writes
    /// the standing crossing field and records the toast or withdrawal to post once the
    /// save is known to have landed. Shared by refresh and the expiry sweep so the flag
    /// and the numbers it was derived from always land in the same save.
    private static func railStep(
        _ snap: inout AccountSnapshot, toasts: inout [RailCrossing],
        clears: inout [(nickname: String, standing: Rail.Level)]
    ) {
        let before = Rail.Level(field: snap.crossing)
        if let crossing = Rail.evaluate(&snap) { toasts.append(crossing) }
        let standing = Rail.Level(field: snap.crossing)
        if standing < before { clears.append((snap.nickname, standing)) }
    }

    /// Rewrites the store, and with it quota-cache.json, the moment a stored percentage
    /// expires rather than at the next five minute poll. See
    /// `AccountSnapshot.nextWindowExpiry` for which readers that gap fooled.
    private func scheduleExpirySweep() {
        expirySweep?.cancel()
        guard let due = AccountSnapshot.nextWindowExpiry(accounts) else { return }
        // One second past the reset: the store zeroes a window only once `now >= reset`.
        let delay = max(0, due.timeIntervalSinceNow) + 1
        expirySweep = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // A refresh in flight saves through the same normalization and reschedules.
            guard !self.refreshing else { return }
            var railToasts: [RailCrossing] = []
            var railClears: [(nickname: String, standing: Rail.Level)] = []
            let (after, saveError) = Store.shared.mutate { accounts in
                // The zeroed window drops the account's rail level in the same save, so
                // the flag never sits next to a percentage it no longer describes.
                for key in Array(accounts.keys) {
                    guard var snap = accounts[key] else { continue }
                    Self.railStep(&snap, toasts: &railToasts, clears: &railClears)
                    accounts[key] = snap
                }
            }
            self.accounts = after.values.sorted { AccountSnapshot.ranked($0, $1) }
            if let saveError { self.refreshError = saveError }
            for c in railToasts { Notifier.post(c) }
            for c in railClears { Notifier.clearRail(nickname: c.nickname, standing: c.standing) }
            self.scheduleExpirySweep()
        }
    }

    /// Up to how many sessions a full active meter stops. nil when the session probe or
    /// the active login is unknown, which the panel says rather than drawing "clear".
    func blastRadius(now: Date) -> BlastRadius? {
        let active = accounts.first { $0.email == activeEmail && $0.kind == .claude }
        return BlastRadius.evaluate(active: active, sessions: agents, now: now)
    }

    /// Menubar title: active account plus its binding constraint. The active account was
    /// just polled, so its raw number is the live one.
    var title: String {
        // Match the PROVIDER too. One email can hold both a Claude subscription and a
        // ChatGPT one, so an email-only lookup picked whichever
        // row happened to sort first. Observed 2026-08-03: the menubar showed the Codex
        // weekly figure instead of the active Claude account's own figure.
        guard let activeEmail,
              let a = accounts.first(where: { $0.email == activeEmail && $0.kind == .claude })
        else { return refreshError == nil ? "CC ??" : "CC ⚠️" }
        // A failing refresh keeps the account and its last number, but says so, rather than
        // presenting a number it could not confirm as if it were current.
        let pct = a.usedPct()
        let glyph = MenubarTitle.glyph(pct: pct, failing: refreshError != nil)
        guard let pct else { return glyph + a.nickname }
        return "\(glyph)\(a.nickname) \(Int(pct.rounded()))%"
    }
}

/// The panelshot data boundary. Its callers supply only local, synchronous reads;
/// no refresh closure can enter this path.
enum PanelShotHydration {
    struct State {
        let accounts: [AccountSnapshot]
        let switchProfiles: [String: ChromeProfileHint]
        let activeEmail: String?
        /// Derived from the persisted row, never a live poll: a shot of a refused key
        /// must show the refusal, not an empty MONEY band.
        let openRouter: OpenRouter.Outcome
        let laneOutcomes: [Provider: AgentLane.Outcome]
    }

    /// Lanes are hydrated too: `AgentLane.readAll` is bounded file reads of each CLI's
    /// config, logs and the optional dispatch ledgers, no credential and no network, so the LANES
    /// section renders offscreen instead of coming out empty.
    static func load(
        store: Store,
        switchProfiles: () -> [String: ChromeProfileHint],
        diskIdentityHint: () -> String?,
        openRouterLastSuccess: () -> Date? = { OpenRouter.lastSuccessTime() },
        lanes: () -> [Provider: AgentLane.Outcome] = { AgentLane.readAll() }
    ) -> State {
        let accounts = SeatCacheHydration.rows(from: store)
        return State(
            accounts: accounts,
            switchProfiles: switchProfiles(),
            activeEmail: SeatCacheHydration.activeEmail(
                hint: diskIdentityHint(), accounts: accounts),
            openRouter: OpenRouter.persistedOutcome(
                from: accounts, lastSuccessAt: openRouterLastSuccess()),
            laneOutcomes: lanes())
    }
}

enum PanelRefreshMode {
    case live
    case cached

    var refreshesOnAppear: Bool { self == .live }
}

// MARK: - Views

/// The rail marks are fixed threshold positions, not data, so their color is a plain
/// mapping from the level. System colors adapt to light and dark material, matching the
/// traffic light the row already uses.
extension Rail.Mark {
    var color: Color {
        switch level {
        case .amber: return .orange
        case .red: return .red
        case .none: return .clear
        }
    }
}

struct AccountRow: View {
    let account: AccountSnapshot
    let isActive: Bool
    /// Set when another provider owns a row with the SAME nickname. One address here holds
    /// both a Claude and a ChatGPT subscription, so the panel showed two bold rows both
    /// reading "eve" with only a section header between them.
    var showProvider: Bool = false
    /// Whatever the header is already showing, so the row does not repeat it verbatim.
    let headerError: String?
    /// Wall-clock time as an EXPLICIT input. SwiftUI decides whether to re-run this body
    /// by diffing the stored properties, and every other property here only changes when
    /// the account's own snapshot changes. But only the ACTIVE account's snapshot ever
    /// changes, so inactive rows froze at their last data change: the age label, the
    /// reset-zeroing in `effective`, and the trust styling all kept rendering the moment
    /// the snapshot landed, hours later. Observed 2026-08-01: a row captured at 17:24
    /// still said "5m ago" with a solid-red 97% at 20:10, three hours and one reset
    /// boundary later. Feeding `now` from the TimelineView in MenuContent makes time a
    /// diffable input, so rows re-evaluate on the timeline cadence.
    let now: Date

    /// A traffic light is a claim about the present, so only a live reading earns one.
    /// A day-old 35% used to render in exactly the same green as a live 35%.
    private func color(_ pct: Double?, _ trust: Trust) -> Color {
        guard let pct, trust == .live else { return TowerType.secondary }
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .green
    }

    private func meter(
        _ label: String, _ pct: Double?, _ resetsAt: Date?, _ didReset: Bool, _ trust: Trust,
        isBinding: Bool = false,
        marks: [Rail.Mark] = []
    ) -> some View {
        HStack(spacing: 6) {
            Text(isBinding ? "◆ \(label)" : "  \(label)")
                .font(TowerType.font(.small, design: .monospaced))
                .foregroundStyle(TowerType.secondary)
                // 30 clipped a 5-character scoped label to "Fab…". There is spare width in
                // the row, so the column gets it rather than the label losing characters.
                // 38 clipped "5h used" to "5h us…" and wrapped Cursor's "month used" onto
                // two lines. Sized to the longest label the providers actually emit rather
                // than to whatever fitted the first one.
                .frame(width: TowerTextSize.pt(account.kind == .cursor ? 104 : 64), alignment: .leading)
            ProgressView(value: trust == .live ? min((pct ?? 0) / 100.0, 1.0) : 0)
                .progressViewStyle(.linear)
                .tint(color(pct, trust))
                .frame(width: TowerTextSize.pt(account.kind == .cursor ? 78 : 118))
                // Rail marks: fixed threshold ticks at their fraction of the 118pt bar,
                // centered on the position. The tick is taller than the bar on purpose:
                // the parts above and below the track stay legible even where the fill
                // underneath shares the mark's hue (an orange bar at 83 percent crosses
                // an orange mark at 80). Overlay overflow draws, but does not layout, so
                // the row height is unchanged.
                .overlay(alignment: .leading) {
                    ForEach(marks) { mark in
                        Rectangle()
                            .fill(mark.color)
                            .frame(width: TowerTextSize.pt(1.5), height: TowerTextSize.pt(9))
                            .offset(x: 118 * mark.position - 0.75)
                    }
                }
                .opacity(trust == .live ? 1 : 0.4)
            // An old percentage cannot establish current usage, even for the active seat.
            Text(trust == .live ? (pct.map { "\(Int($0.rounded()))%" } ?? "?") : "?")
                .font(TowerType.font(.small).monospacedDigit())
                .foregroundStyle(color(pct, trust))
                .frame(width: TowerTextSize.pt(34), alignment: .trailing)
            Text(trust != .live ? "unknown" : (didReset ? "reset" : (resetsAt.map { CLI.clock($0) } ?? "-")))
                .font(TowerType.font(.small).monospacedDigit())
                .foregroundStyle(TowerType.secondary)
        }
    }

    /// The bar answers "how much have I used?" but the account-picker decision is
    /// "how much room do I have?" State both, once, at the account heading so
    /// people do not have to subtract red percentages across different clocks.
    func availableSummary() -> String? {
        guard account.isRecommendable(now: now) else {
            return account.capturedAt == nil ? "never captured"
                : "unknown since " + CLI.age(account.capturedAt, now: now)
        }
        guard let binding = account.presentableBindingQuota(now: now) else { return nil }
        let room = Int(max(0, 100 - binding.percent).rounded())
        if binding.percent > 100 {
            return "\(room)% room, over cap (\(Int(binding.percent.rounded()))% used)"
        }
        let state = binding.percent >= AccountSnapshot.cappedPct ? " capped" : ""
        return "\(room)% room · \(binding.label(for: account.kind))\(state)"
    }

    /// Keep the reset and model guidance on their own line: the compact account heading
    /// still fits alongside the seat name, while the cap remains explicit and actionable.
    private func bindingDetail(_ binding: AccountSnapshot.BindingQuota?) -> String? {
        guard let binding, binding.percent >= AccountSnapshot.cappedPct else { return nil }
        let reset = binding.didReset ? "reset" : (binding.resetsAt.map { "resets \(CLI.clock($0))" } ?? "reset unknown")
        var parts = ["\(binding.label(for: account.kind)) capped", reset]
        if let usable = account.bindingUsableFor(now: now) { parts.append("usable for \(usable)") }
        if binding.limit == .fable, account.kind.hasFiveHourWindow,
           let five = account.effectiveFiveHour(now: now).pct {
            parts.append("5h \(Int(five.rounded()))% used")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let fh = account.effectiveFiveHour(now: now)
        let wk = account.effectiveWeekly(now: now)
        let binding = account.presentableBindingQuota(now: now)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? Color.accentColor : TowerType.secondary.opacity(0.3))
                    .frame(width: TowerTextSize.pt(7), height: TowerTextSize.pt(7))
                Text(account.nickname).font(TowerType.font(.body, weight: .semibold))
                if showProvider {
                    Text(account.kind.label)
                        .font(TowerType.font(.small))
                        .foregroundStyle(TowerType.secondary)
                }
                Text(account.plan).font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
                if let summary = availableSummary() {
                    Text(summary)
                        .font(TowerType.font(.small, weight: .semibold).monospacedDigit())
                        .foregroundStyle(color(binding?.percent, account.worstTrust(now: now)))
                }
                Spacer()
                if !isActive && account.isRecommendable(now: now) {
                    Text(CLI.age(account.capturedAt, now: now)).font(TowerType.font(.small))
                        .foregroundStyle(
                            account.worstTrust(now: now) == .live ? TowerType.secondary : Color.orange)
                }
            }
            if let detail = bindingDetail(binding) {
                Text(detail)
                    .font(TowerType.font(.small, design: .monospaced))
                    .foregroundStyle(color(binding?.percent, account.worstTrust(now: now)))
                    .padding(.leading, 13)
            }
            // Only draw windows the provider actually publishes. Codex on the ChatGPT plans
            // reports a 7d window and nothing else, so a 5h meter here would be a limit we
            // invented: an empty bar reads as "0% used", which is a claim, not a blank.
            if account.kind.hasFiveHourWindow {
                meter("5h used", fh.pct, account.fiveHourResetsAt, fh.reset,
                      account.trustFiveHour(now: now), isBinding: binding?.limit == .fiveHour,
                      marks: Rail.marks(fiveHour: true))
            }
            // Named per provider: "7d used" over Cursor's monthly credit allowance would
            // promise a refill three quarters sooner than it arrives.
            if account.kind == .cursor {
                ForEach(RestingDrawer.meterWindows(account, now: now), id: \.label) { window in
                    meter(CursorPool.displayLabel(window.label), window.percent, window.resetsAt, window.didReset,
                          window.trust, isBinding: window.isBinding)
                }
            } else {
                meter("\(account.kind.primaryWindowLabel) used", wk.pct, account.weeklyResetsAt,
                      wk.reset, account.trustWeekly(now: now), isBinding: binding?.limit == .sevenDay,
                      marks: Rail.marks(fiveHour: false))
            }
            if account.kind != .cursor, let bal = account.creditBalance {
                Text("credits \(bal)").font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
            }
            ForEach(account.scoped.filter {
                account.kind != .cursor && (($0.percent ?? 0) > 0
                    || $0.label.caseInsensitiveCompare("Fable") == .orderedSame)
            }, id: \.self) { s in
                // Scoped rows go through `effective` like the two main windows do. Passing
                // the raw percentage while computing reset-aware trust put "92%" in solid
                // red next to a trust value that meant "this is 0 and I can prove it".
                let eff = AccountSnapshot.effective(pct: s.percent, resetsAt: s.resetsAt, now: now)
                let isFable = s.label.caseInsensitiveCompare("Fable") == .orderedSame
                meter((isFable ? s.label : String(s.label.prefix(4))) + " used", eff.pct, s.resetsAt, eff.reset,
                      AccountSnapshot.trust(pct: s.percent, resetsAt: s.resetsAt,
                                            capturedAt: account.capturedAt, now: now),
                      isBinding: isFable && binding?.limit == .fable)
            }
            if account.kind == .claude, account.fableScope() == nil {
                // All three Claude windows stay visible. A missing Fable reading is unknown,
                // not an empty 0% bucket the provider never reported.
                meter("Fable used", nil, nil, false, .unknown, isBinding: false)
            }
            // The CLI has always printed this. The menubar, which is the surface actually
            // used, silently dropped it.
            //
            // Shown only while it describes the account we are actually on. `lastError` is
            // cleared only by a successful refresh of that same account, and only the active
            // account can be refreshed, so an error recorded before a switch would otherwise
            // sit there in red for days.
            //
            // And skipped when the header already says the same thing. Since only the active
            // account is refreshable, the two are usually the identical string, which printed
            // "HTTP 429 for /api/oauth/usage" twice in one popover.
            // `isActive` is a CLAUDE precondition: only the active Claude account is
            // refreshable, so an older account's error would sit there for days. Cursor is
            // re-read on every single cycle, so its error is current by construction and
            // suppressing it would hide the one signal a refused session token produces.
            if let e = account.lastError, isActive || account.kind == .cursor,
               e != headerError {
                Text("⚠️ \(e)")
                    .font(TowerType.font(.small)).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Provider heading. Quiet on purpose: it groups rows, it does not compete with them.
///
/// The grouping is not decoration. Claude, Codex and OpenRouter have different window
/// shapes and different failure modes, and a flat list silently claims they are comparable
/// row for row. They are not: one refills on a 5h clock, one on a 7d clock, one never.
struct ProviderHeader: View {
    let provider: Provider
    let detail: String

    private var dot: Color {
        switch provider {
        case .claude:     return Color(red: 0.79, green: 0.39, blue: 0.26)
        case .codex:      return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .cursor:     return Color(red: 0.55, green: 0.55, blue: 0.58)
        case .openrouter: return Color(red: 0.43, green: 0.43, blue: 0.94)
        case .typesafe:   return Color(red: 0.62, green: 0.36, blue: 0.90)
        case .muse:       return Color(red: 0.00, green: 0.51, blue: 0.98)
        case .devin:      return Color(red: 0.36, green: 0.73, blue: 0.62)
        case .agy:        return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .pi:         return Color(red: 0.64, green: 0.47, blue: 0.33)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: TowerTextSize.pt(6), height: TowerTextSize.pt(6))
            Text(provider.label.uppercased())
                .font(TowerType.font(.small, weight: .bold))
                .foregroundStyle(TowerType.secondary)
            Spacer()
            Text(detail)
                .font(TowerType.font(.small).monospacedDigit())
                .foregroundStyle(TowerType.secondary)
        }
        .padding(.top, 3)
    }
}

/// The single line that answers the question the panel exists for.
///
/// Everything needed for this was already computed (`ranked`, `isRecommendable`); it was
/// just never stated, leaving the user to derive it from fifteen bars. Restricted to Claude
/// accounts on purpose: this recommends what to pass to `claude-switch`, and a Codex row is
/// not a candidate for that no matter how much headroom it has.
struct RecommendBanner: View {
    static let stayLabel = "keychain holds"

    /// The answer line when the active seat's reply carried no 5h window.
    static func fiveHourUnknownLine(nick: String, weekRoom: Double?) -> String {
        "\(nick): 5h unknown, week " + (weekRoom.map { "\(Int($0.rounded()))% room" } ?? "? room")
    }

    /// The answer line when Tower cannot verify which seat the CLI holds. It reads as a
    /// recommendation with its basis, not an error: "active seat unknown" sounded broken
    /// on every fresh Mac and every demo, where an unverified seat is the normal state.
    static func unverifiedActiveLine(nick: String, roomPct: Double?) -> String {
        "no verified active seat; most room: \(nick)" + (roomPct.map { " (\(Int($0.rounded()))%)" } ?? "")
    }
    let advice: AccountSnapshot.Advice
    /// Set briefly after a click so the banner can confirm what it put on the clipboard.
    @Binding var copied: Bool

    private var glyph: String { Self.glyph(for: advice) }

    /// The mark before the answer. A seat whose 5h is unknown gets "?", never the stay mark: a
    /// missing 5h window may hide a full one (HOLD 6560661767).
    nonisolated static func glyph(for advice: AccountSnapshot.Advice) -> String {
        switch advice {
        case .stay: return "✓"
        case .switchTo: return "→"
        case .activeUnknown, .activeFiveHourUnknown: return "?"
        case .allResting: return "!"
        }
    }

    private var tint: Color {
        switch advice {
        case .stay: return .green
        case .switchTo: return .accentColor
        // Unverified is the normal state of a fresh login, so it is neutral, not a warning.
        case .activeUnknown: return TowerType.secondary
        case .activeFiveHourUnknown: return .orange
        case .allResting: return .red
        }
    }

    /// Only a switch is actionable. Copying rather than executing is deliberate: the real
    /// `claude-switch` is a zsh FUNCTION, and the credential this app reads lives in the
    /// keychain rather than in the file that function swaps. A menubar app inventing its own
    /// half of that mechanism could desync a working login, which is a bad trade for saving
    /// one paste.
    private var command: String? { advice.command }

    @ViewBuilder
    private var label: some View {
        switch advice {
        case .stay(let nick, let pct, let next):
            Text(Self.stayLabel).font(TowerType.font(.body)).foregroundStyle(TowerType.secondary)
            Text(nick).font(TowerType.font(.body, weight: .bold)).foregroundStyle(.green)
            if let pct {
                Text("· \(Int(pct.rounded()))% used")
                    .font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
            }
            if let next {
                Text("· next \(next)")
                    .font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
            }
        case .switchTo(let nick, let pct, let via):
            Text("switch to").font(TowerType.font(.body)).foregroundStyle(TowerType.secondary)
            Text(nick).font(TowerType.font(.body, weight: .bold)).foregroundStyle(Color.accentColor)
            if let pct {
                Text("· \(Int(pct.rounded()))% used")
                    .font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
            }
            // The switch is `/login` and then a sign-in in the right Chrome profile, so
            // naming the profile is the half the operator cannot look up from here.
            if let via {
                Text("· /login as Chrome \(via.label)")
                    .font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
            }
        case .activeUnknown(let nick, let room, let via):
            Text(Self.unverifiedActiveLine(nick: nick, roomPct: room))
                .font(TowerType.font(.body)).foregroundStyle(TowerType.secondary)
            if let via {
                Text("· /login as Chrome \(via.label)")
                    .font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
            }
        case .activeFiveHourUnknown(let nick, let weekRoom, let next):
            // "<seat>: 5h unknown, week <n>% room": the seat in use, what is not known, and
            // the room that is
            Text(Self.fiveHourUnknownLine(nick: nick, weekRoom: weekRoom))
                .font(TowerType.font(.body, weight: .semibold)).foregroundStyle(.orange)
            if let next {
                Text("· next \(next)").font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
            }
        case .allResting(let first):
            Text("No ready Claude account")
                .font(TowerType.font(.body, weight: .semibold)).foregroundStyle(.red)
            if let first {
                Text("· earliest reset \(CLI.clock(first))")
                    .font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
            }
        }
    }

    var body: some View {
        Button {
            guard let command else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied = true
        } label: {
            HStack(spacing: 6) {
                Text(glyph).font(TowerType.font(.body, weight: .bold)).foregroundStyle(tint)
                label
                Spacer()
                if let command {
                    Text(copied ? "copied" : command)
                        .font(TowerType.font(.body, weight: .semibold, design: .monospaced))
                        .foregroundStyle(copied ? Color.green : Color.primary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.10)))
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(command == nil)
        .help(command.map { "Click to copy: \($0)" } ?? "")
    }
}


/// The four numbers that answer "what capacity do I have right now" without reading a bar.
///
/// Every tile states a value AND its denominator or qualifier. That is the whole point: the
/// heading this replaces said "2 available", which cannot distinguish two-of-three from
/// two-of-nine, and the panel exists to answer exactly that difference. A bare count is a
/// number; a count over a total is a decision.
///
/// Tiles are omitted, never blanked. An absent OpenRouter key yields no CREDIT tile rather
/// than a "$0.00" one, for the same reason the money section hides itself: an empty money
/// reading is indistinguishable from "you have spent it all", which is a lie.
/// Sessions as one more section header, matching ProviderHeader's shape so the list has a
/// single rhythm. Load belongs in the same visual language as the quotas it consumes.
struct SessionsHeader: View {
    let agents: AgentSummary?

    private var detail: String {
        guard let a = agents else { return "probe unavailable" }
        var parts = ["\(a.groups.count)"]
        let busy = a.groups.filter(\.busy).count
        if busy > 0 { parts.append("\(busy) busy") }
        if a.backgroundCount > 0 { parts.append("+\(a.backgroundCount) bg") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(TowerType.secondary.opacity(0.45)).frame(width: TowerTextSize.pt(6), height: TowerTextSize.pt(6))
            Text("SESSIONS")
                .font(TowerType.font(.small, weight: .bold))
                .foregroundStyle(TowerType.secondary)
            Spacer()
            Text(detail)
                .font(TowerType.font(.small, design: .monospaced))
                .foregroundStyle(agents == nil ? Color.orange : TowerType.secondary)
        }
        .padding(.top, 3)
    }
}

/// What is RUNNING, as its own pane rather than a block wedged under the money section.
///
/// Lifted out of `MenuContent` unchanged in behaviour: still grouped by directory, still
/// capped, still explicit about a probe that could not run. What changed is where it lives —
/// Claude Code load sat two dividers below the Claude quota it consumes, with Cursor and
/// OpenRouter in between.
struct SessionsPane: View {
    let agents: AgentSummary?

    /// Session rows are context, not the subject. Past this the list stops informing and
    /// starts pushing the limits off the top of the panel.
    static let cap = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Running sessions may use other accounts")
                .font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let a = agents {
            if a.interactive.isEmpty {
                Text("no interactive sessions").font(TowerType.font(.small))
                    .foregroundStyle(TowerType.secondary)
            } else {
                let groups = a.groups
                let shown = groups.prefix(Self.cap)
                ForEach(shown) { g in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(g.busy ? Color.orange : Color.green)
                            .frame(width: TowerTextSize.pt(6), height: TowerTextSize.pt(6))
                        Text(g.label + g.suffix)
                            .font(TowerType.font(.body, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .help(g.rawName)
                        Spacer()
                        Text(g.accountLabel)
                            .font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
                            .help(g.accountEvidence ?? "Session account could not be established")
                        Text(g.busy ? "busy" : "idle")
                            .font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
                    }
                }
                if groups.count > shown.count {
                    Text("+\(groups.count - shown.count) more interactive")
                        .font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
                }
            }
        } else {
            // A probe that could not run is not "zero sessions". Kept loud.
            Text("session probe unavailable").font(TowerType.font(.small))
                .foregroundStyle(.orange)
        }
    }
}

/// A section header that toggles its own body.
///
/// Generic over the header so `ProviderHeader` keeps owning the provider's colour and
/// layout; this adds only the chevron and the tap target. Deliberately the same affordance
/// as the not-ready drawer, so the panel has ONE disclosure gesture rather than two that
/// look different and behave the same.
struct DisclosableSection<Header: View, Content: View>: View {
    let header: Header
    @Binding var open: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(open ? "▼" : "▶")
                        .font(TowerType.font(.minimum))
                        .foregroundStyle(TowerType.secondary)
                    header
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { content() }
        }
    }
}

/// Accounts you cannot act on, kept out of the list but not out of the app.
///
/// Collapsed it costs one line and still carries the only fact that matters while resting:
/// how many there are and when the first one comes back.
struct RestingDrawer: View {
    let rows: [(AccountSnapshot, AccountSnapshot.RestReason)]
    /// Whose accounts these are. Was hardcoded to Claude in the title while `rows` came from
    /// an unfiltered partition, so a resting Codex or Cursor row rendered under the heading
    /// "CLAUDE ACCOUNTS NOT READY" — a heading that names the wrong provider is worse than
    /// no heading, because the reader acts on it.
    let provider: Provider
    @Binding var open: Bool
    let now: Date
    /// True when resting outnumbers what is available. The collapsed line is then the most
    /// important fact on screen and must not read as a grey footnote under an all-green
    /// panel, which is exactly how it looked with five of six accounts capped.
    let prominent: Bool

    private func meterColor(_ pct: Double?, _ trust: Trust) -> Color {
        guard let pct, trust == .live else { return TowerType.secondary }
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .green
    }

    /// The collapsed drawer still needs the compact comparison bars: capped seats are the
    /// primary GH-52 case, and text-only detail hid which of their windows was binding.
    private func meter(_ label: String, _ pct: Double?, _ resetsAt: Date?, _ didReset: Bool,
                       _ trust: Trust, isBinding: Bool) -> some View {
        HStack(spacing: 6) {
            Text(isBinding ? "◆ \(label)" : "  \(label)")
                .font(TowerType.font(.small, design: .monospaced))
                .foregroundStyle(TowerType.secondary)
                .frame(width: TowerTextSize.pt(provider == .cursor ? 104 : 64), alignment: .leading)
            ProgressView(value: trust == .live ? min((pct ?? 0) / 100.0, 1.0) : 0)
                .progressViewStyle(.linear)
                .tint(meterColor(pct, trust))
                .frame(width: TowerTextSize.pt(provider == .cursor ? 78 : 118))
                .opacity(trust == .live ? 1 : 0.4)
            Text(trust == .live ? (pct.map { "\(Int($0.rounded()))%" } ?? "?") : "?")
                .font(TowerType.font(.small).monospacedDigit())
                .foregroundStyle(meterColor(pct, trust))
                .frame(width: TowerTextSize.pt(34), alignment: .trailing)
            Text(trust != .live ? "unknown" : (didReset ? "reset" : (resetsAt.map { CLI.clock($0) } ?? "-")))
                .font(TowerType.font(.small).monospacedDigit())
                .foregroundStyle(TowerType.secondary)
        }
    }

    /// The rendered drawer bars share one model with their tests. A stale row deliberately
    /// has no binding marker because cached numbers cannot claim current room.
    struct MeterWindow: Equatable {
        let label: String
        let percent: Double?
        let resetsAt: Date?
        let didReset: Bool
        let trust: Trust
        let isBinding: Bool
    }

    static func meterWindows(_ account: AccountSnapshot, now: Date) -> [MeterWindow] {
        if account.kind == .cursor {
            return ["Cursor Models", "Other Models"].map { label in
                let scope = account.scoped.first { $0.label == label }
                let value = AccountSnapshot.effective(
                    pct: scope?.percent, resetsAt: scope?.resetsAt, now: now)
                let trust = AccountSnapshot.trust(
                    pct: scope?.percent, resetsAt: scope?.resetsAt,
                    capturedAt: account.capturedAt, now: now)
                return MeterWindow(label: label, percent: value.pct,
                                   resetsAt: scope?.resetsAt, didReset: value.reset,
                                   trust: trust,
                                   isBinding: trust == .live && value.pct != nil
                                       && value.pct == account.effectiveWeekly(now: now).pct)
            }
        }
        let binding = account.presentableBindingQuota(now: now)
        var windows: [MeterWindow] = []
        if account.kind.hasFiveHourWindow {
            let value = account.effectiveFiveHour(now: now)
            windows.append(MeterWindow(label: "5h used", percent: value.pct,
                                       resetsAt: account.fiveHourResetsAt, didReset: value.reset,
                                       trust: account.trustFiveHour(now: now),
                                       isBinding: binding?.limit == .fiveHour))
        }
        let weekly = account.effectiveWeekly(now: now)
        windows.append(MeterWindow(label: "\(account.kind.primaryWindowLabel) used", percent: weekly.pct,
                                   resetsAt: account.weeklyResetsAt, didReset: weekly.reset,
                                   trust: account.trustWeekly(now: now),
                                   isBinding: binding?.limit == .sevenDay))
        guard account.kind == .claude else { return windows }
        if let fable = account.fableScope() {
            let value = AccountSnapshot.effective(pct: fable.percent, resetsAt: fable.resetsAt, now: now)
            windows.append(MeterWindow(label: "Fable used", percent: value.pct,
                                       resetsAt: fable.resetsAt, didReset: value.reset,
                                       trust: AccountSnapshot.trust(pct: fable.percent,
                                                                    resetsAt: fable.resetsAt,
                                                                    capturedAt: account.capturedAt, now: now),
                                       isBinding: binding?.limit == .fable))
        } else {
            windows.append(MeterWindow(label: "Fable used", percent: nil, resetsAt: nil,
                                       didReset: false, trust: .unknown, isBinding: false))
        }
        return windows
    }

    /// Colour by WHY, so the drawer is scannable without reading every word: amber marks a
    /// real ceiling you have to wait out, plain secondary marks a merely-unknown reading.
    ///
    /// Deliberately not a third dim level. The previous version stacked `.secondary` and
    /// `.tertiary` foreground styles under a blanket `.opacity(0.6)` on the whole row, and
    /// tertiary times 0.6 is close to invisible. De-emphasis is ONE decision, applied once.
    static func reasonColor(_ r: AccountSnapshot.RestReason) -> Color {
        r.isCapped ? Color.orange.opacity(0.9) : TowerType.secondary
    }

    /// Full readings are intentionally opt-in per account. The default drawer needs to be
    /// a fast list of states, not a dense grid of two windows per account.
    @State private var disclosed: Set<String> = []

    /// Soonest reopening across the TIME-GATED rows only. A stale row has no reopening to
    /// promise: it is not waiting on a clock, it is waiting on a refresh.
    private var firstOpens: Date? {
        rows.filter { $0.1.isTimeGated }
            .compactMap { AccountSnapshot.reopening($0.0, now: now) }.min()
    }

    /// Exact per-window readings, shown only after disclosure. A missing reading stays
    /// explicit instead of silently resembling 0% used.
    ///
    /// Effective, not stored, percentages: rows arrive from the last save, so a window that
    /// resets between polls would otherwise keep printing its old number (#17).
    static func limitWindows(_ account: AccountSnapshot, now: Date) -> [String] {
        guard account.isRecommendable(now: now) else {
            return [account.capturedAt == nil ? "never captured"
                : "unknown since " + CLI.age(account.capturedAt, now: now)]
        }
        func window(_ label: String, _ value: (pct: Double?, reset: Bool), resetsAt: Date?,
                    trust: Trust) -> String? {
            guard let pct = value.pct else { return "\(label): not captured" }
            let reading = trust == .stale ? "last seen \(Int(pct.rounded()))% used"
                : "\(Int(pct.rounded()))% used"
            let resetText = value.reset ? " · reset ✓"
                : (resetsAt.map { " · reset \(CLI.clock($0))" } ?? " · reset unknown")
            return "\(label): \(reading)\(resetText)"
        }
        var parts: [String] = []
        if account.kind.hasFiveHourWindow,
           let text = window("5h", account.effectiveFiveHour(now: now),
                             resetsAt: account.fiveHourResetsAt,
                             trust: account.trustFiveHour(now: now)) { parts.append(text) }
        if let text = window("7d", account.effectiveWeekly(now: now),
                             resetsAt: account.weeklyResetsAt,
                             trust: account.trustWeekly(now: now)) { parts.append(text) }
        if let fable = account.fableScope() {
            let effective = AccountSnapshot.effective(pct: fable.percent, resetsAt: fable.resetsAt, now: now)
            if let text = window("Fable", effective, resetsAt: fable.resetsAt,
                                 trust: AccountSnapshot.trust(pct: fable.percent,
                                                              resetsAt: fable.resetsAt,
                                                              capturedAt: account.capturedAt, now: now)) {
                parts.append(text)
            }
        }
        return parts
    }

    private static func cappedWindows(_ account: AccountSnapshot, now: Date) -> String {
        var names: [String] = []
        if account.kind.hasFiveHourWindow,
           (account.effectiveFiveHour(now: now).pct ?? 0) >= AccountSnapshot.cappedPct {
            names.append("5-hour")
        }
        if (account.effectiveWeekly(now: now).pct ?? 0) >= AccountSnapshot.cappedPct {
            names.append("7-day")
        }
        return names.joined(separator: " + ")
    }

    /// The default row names the actionable category, while percentages and ages stay in
    /// detail. This keeps capped, stale, and never-captured semantics visibly distinct.
    static func state(_ account: AccountSnapshot,
                      _ reason: AccountSnapshot.RestReason,
                      now: Date) -> String {
        if account.needsLogin {
            let age = account.capturedAt.map { " · \(ageText(max(0, now.timeIntervalSince($0)))) ago" } ?? ""
            return "needs login" + age
        }
        let capState: String
        if let binding = account.presentableBindingQuota(now: now) {
            let room = Int(max(0, 100 - binding.percent).rounded())
            capState = "\(room)% room · \(binding.label(for: account.kind)) capped"
        } else {
            capState = cappedWindows(account, now: now) + " blocked"
        }
        switch reason {
        case .capped: return capState
        case .meteredCapped: return reason.text
        case .cappedAndStale, .stale:
            if account.fiveHourUnreported(now: now) { return SeatUsagePresentation.fiveHourUnreportedText }
            return "unknown since " + CLI.age(account.capturedAt, now: now)
        case .neverCaptured: return "not checked"
        }
    }

    private static func ageText(_ age: TimeInterval) -> String {
        if age < 3_600 { return "\(max(1, Int(age / 60)))m" }
        if age < 86_400 { return "\(Int(age / 3_600))h" }
        let days = Int(age / 86_400)
        let hours = Int((age - Double(days) * 86_400) / 3_600)
        return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
    }

    static func action(_ account: AccountSnapshot,
                       _ reason: AccountSnapshot.RestReason,
                       now: Date) -> String {
        if reason.isTimeGated, let binding = account.presentableBindingQuota(now: now) {
            guard let reset = binding.resetsAt else { return "reset unknown" }
            return reset > now ? "reset \(CLI.clock(reset))" : "await reset"
        }
        if reason.isTimeGated, let opens = AccountSnapshot.reopening(account, now: now) {
            return "reset \(CLI.clock(opens))"
        }
        return reason.isTimeGated ? "await reset" : "switch to check"
    }

    private var cappedCount: Int { rows.filter { $0.1.isCapped }.count }
    private var refreshCount: Int { rows.filter { $0.1.isStale }.count }

    private var headerSummary: String {
        var parts: [String] = []
        if cappedCount > 0 { parts.append("\(cappedCount) capped") }
        if let firstOpens { parts.append("next reset \(CLI.clock(firstOpens))") }
        if refreshCount > 0 { parts.append("\(refreshCount) need refresh") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(open ? "▼" : "▶")
                        .font(TowerType.font(.minimum)).foregroundStyle(TowerType.secondary)
                    Text("\(provider.label.uppercased()) NOT READY")
                        .font(TowerType.font(.small, weight: .bold)).foregroundStyle(TowerType.secondary)
                    Spacer()
                    Text(headerSummary)
                        .font(TowerType.font(.small, weight: .medium))
                        .foregroundStyle(prominent ? Color.orange : TowerType.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                ForEach(rows, id: \.0.id) { row in
                    let isDisclosed = disclosed.contains(row.0.id)
                    VStack(alignment: .leading, spacing: 3) {
                        Button {
                            if isDisclosed { disclosed.remove(row.0.id) }
                            else { disclosed.insert(row.0.id) }
                        } label: {
                            HStack(spacing: 7) {
                                // a nickname two products share names its product (bug 2, 2026-11-01)
                                Text(AccountSnapshot.listName(row.0, among: rows.map(\.0)))
                                    .font(TowerType.font(.body, weight: .semibold, design: .monospaced))
                                    .frame(minWidth: TowerTextSize.pt(52), alignment: .leading)
                                Text(Self.state(row.0, row.1, now: now))
                                    .font(TowerType.font(.body, weight: .medium))
                                    .foregroundStyle(Self.reasonColor(row.1))
                                    .layoutPriority(1)
                                Spacer(minLength: 4)
                                Text(Self.action(row.0, row.1, now: now))
                                    .font(TowerType.font(.small, weight: .medium, design: .monospaced))
                                    .foregroundStyle(row.1.isTimeGated ? TowerType.secondary : Color.accentColor)
                                    .fixedSize(horizontal: true, vertical: false)
                                Text(isDisclosed ? "⌃" : "⌄")
                                    .font(TowerType.font(.body, weight: .semibold))
                                    .foregroundStyle(TowerType.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if isDisclosed {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Self.meterWindows(row.0, now: now), id: \.label) { window in
                                    meter(CursorPool.displayLabel(window.label), window.percent, window.resetsAt, window.didReset,
                                          window.trust, isBinding: window.isBinding)
                                }
                                switch row.1 {
                                case .stale(let age), .cappedAndStale(_, let age):
                                    Text("Last checked \(Self.ageText(age)) ago; switch into this account to refresh.")
                                        .font(TowerType.font(.small))
                                        .foregroundStyle(TowerType.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                case .neverCaptured:
                                    Text("No usage reading yet; switch into this account to capture one.")
                                        .font(TowerType.font(.small))
                                        .foregroundStyle(TowerType.secondary)
                                case .capped:
                                    EmptyView()
                                case .meteredCapped:
                                    Text("Opus and other metered models are refused until the reset; Auto keeps running.")
                                        .font(TowerType.font(.small))
                                        .foregroundStyle(TowerType.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if let error = row.0.lastError {
                                    Text("⚠️ " + error)
                                        .font(TowerType.font(.small))
                                        .foregroundStyle(TowerType.secondary)
                                }
                            }
                            .padding(.leading, 59)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(open ? 0.045 : 0))
        )
        .padding(.top, 2)
    }
}

/// Money, drawn as money.
///
/// A quota bar and a budget bar mean opposite things: one empties and refills on a clock at
/// no cost, the other is spend you do not get back. Giving them the same shape teaches the
/// wrong reflex, so this carries a currency figure rather than a bare percentage.
struct BudgetRow: View {
    let budget: OpenRouter.Budget
    let history: [OpenRouter.History.Sample]

    /// Alarms on what is LEFT. A balance at 8% remaining is urgent; 8% *spent* is fine.
    private var tint: Color {
        budget.availablePct <= 10 ? .red : budget.availablePct <= 25 ? .orange : .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("CURRENT BALANCE").font(TowerType.font(.small, weight: .bold)).foregroundStyle(TowerType.secondary)
                Spacer()
                Text(String(format: "$%.2f", budget.available))
                    .font(TowerType.font(.header, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
            }
            // Fills with what is LEFT, so the bar empties as the balance drains.
            ProgressView(value: budget.availablePct / 100.0)
                .progressViewStyle(.linear)
                .tint(tint)
            Text(String(format: "Total: $%.2f added · $%.2f spent · $%.2f left",
                        budget.limit, budget.spent, budget.available))
                .font(TowerType.font(.small, design: .monospaced)).foregroundStyle(TowerType.secondary)
                .fixedSize(horizontal: false, vertical: true)
            BalanceTrend(samples: history)
        }
        .padding(.vertical, 2)
    }
}

/// A labelled point-to-point balance history. Samples are exact observed balances; this
/// deliberately does not draw candles, whose intraperiod high/low would be made up.
struct BalanceTrend: View {
    let samples: [OpenRouter.History.Sample]

    private var trend: OpenRouter.History.Trend? { OpenRouter.History.trend(samples) }

    private func money(_ value: Double) -> String { String(format: "$%.2f", value) }

    private func elapsed(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    private func changeLabel(_ trend: OpenRouter.History.Trend) -> String {
        let delta = trend.changeSincePrevious
        let prefix = delta > 0 ? "+" : delta < 0 ? "−" : "±"
        let direction = delta > 0 ? "added" : delta < 0 ? "spent" : "unchanged"
        return "\(prefix)\(money(abs(delta))) \(direction) since previous observation (\(elapsed(trend.changeSpan)))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let trend {
                Text(changeLabel(trend))
                    .font(TowerType.font(.small, weight: .medium))
                    .foregroundStyle(trend.changeSincePrevious < 0 ? Color.orange : TowerType.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if trend.hasMeaningfulChange {
                    HStack {
                        Text("OBSERVED BALANCE TREND")
                            .font(TowerType.font(.small, weight: .bold)).foregroundStyle(TowerType.secondary)
                        Spacer()
                        Text(elapsed(trend.observedSpan))
                            .font(TowerType.font(.small, design: .monospaced)).foregroundStyle(TowerType.secondary)
                    }
                    BalanceLine(samples: samples)
                    HStack {
                        Text(money(trend.first.available))
                        Spacer()
                        Text(money(trend.latest.available))
                    }
                    .font(TowerType.font(.small, weight: .medium, design: .monospaced))
                    .foregroundStyle(TowerType.secondary)
                } else {
                    Text("No balance change yet across \(elapsed(trend.observedSpan)) of observations.")
                        .font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
                }
            } else {
                Text("Collecting balance history — one observation so far.")
                    .font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
            }
        }
        .padding(.top, 3)
    }
}

/// Draws only lines between actual observation points. Endpoint labels outside the plot make
/// the balance legible without relying on color alone.
private struct BalanceLine: View {
    let samples: [OpenRouter.History.Sample]

    var body: some View {
        let points = samples.sorted { $0.capturedAt < $1.capturedAt }
        Canvas { context, size in
            guard let first = points.first, let last = points.last else { return }
            let values = points.map(\.available)
            let low = values.min() ?? 0
            let high = values.max() ?? 1
            let valueSpan = max(high - low, 0.01)
            let timeSpan = max(last.capturedAt.timeIntervalSince(first.capturedAt), 1)
            func point(_ sample: OpenRouter.History.Sample) -> CGPoint {
                let x = CGFloat(sample.capturedAt.timeIntervalSince(first.capturedAt) / timeSpan)
                    * max(size.width - 8, 1) + 4
                let y = size.height - CGFloat((sample.available - low) / valueSpan)
                    * max(size.height - 12, 1) - 6
                return CGPoint(x: x, y: y)
            }
            var line = Path()
            line.move(to: point(first))
            for sample in points.dropFirst() { line.addLine(to: point(sample)) }
            context.stroke(line, with: .color(.accentColor), lineWidth: 1.5)
            for sample in points {
                let p = point(sample)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)),
                             with: .color(.accentColor))
            }
        }
        .frame(height: TowerTextSize.pt(76))
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.035)))
    }
}

/// A provider row that is BROKEN rather than absent.
///
/// Exists because hiding on failure is indistinguishable from hiding on "not configured",
/// and an operator lost a rotated key that way: the section simply vanished and they found
/// out by opening the OpenRouter dashboard himself. A refusal gets a row, a colour, and the
/// exact command that fixes it.
struct OpenRouterProblem: View {
    let message: String
    let hint: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text("!").font(TowerType.font(.body, weight: .bold)).foregroundStyle(tint)
                Text(message).font(TowerType.font(.small, weight: .medium)).foregroundStyle(tint)
            }
            Text(hint)
                .font(TowerType.font(.small, design: .monospaced))
                .foregroundStyle(TowerType.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.10)))
    }
}

/// The TypeSafe group beside the OpenRouter balance: one header, then a row per decision
/// model (Jev, Clef) that has an entered balance.
///
/// There is no fetch behind these rows: TypeSafe publishes no billing or usage endpoint, so
/// the only fact per model is the OPERATOR-ENTERED credit balance, tinted by the traffic
/// light the issue pins (amber under USD 10, red under USD 5) and labelled with its as-of
/// date. It carries no capture time and no refresh outcome, because nothing is observed and
/// nothing can fail; the label is what keeps an entered figure from masquerading as a live
/// one. Each row greys out on its own, because the two figures are entered on different days.
struct TypeSafeSection: View {
    private func stale(_ model: TypeSafe.Model) -> Bool { TypeSafe.balanceIsStale(model: model) }

    private func balanceTint(_ model: TypeSafe.Model) -> Color {
        guard !stale(model) else { return TowerType.dim }
        switch TypeSafe.balanceLevel(TypeSafe.entry(model: model)?.usd ?? 0) {
        case .green: return .green
        case .amber: return .orange
        case .red:   return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ProviderHeader(provider: .typesafe, detail: TypeSafeCreditRow.groupDetail)
            ForEach(TypeSafe.enteredModels(), id: \.self) { model in
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(TowerType.font(.small, weight: .semibold))
                    Text(TypeSafe.money(TypeSafe.entry(model: model)?.usd ?? 0))
                        .font(TowerType.font(.body, weight: .bold, design: .monospaced))
                        .foregroundStyle(balanceTint(model))
                    Text("\(TypeSafe.enteredLabel(model: model)), not live")
                        .font(TowerType.font(.small))
                        .foregroundStyle(TowerType.secondary)
                }
                .padding(.leading, 12)
                .opacity(stale(model) ? 0.55 : 1)
            }
        }
        .padding(.top, 3)
    }
}

/// One agent lane: Muse, Devin or Antigravity.
///
/// No meter, on purpose. The header says "usage not exposed" and the lines below are the
/// three things that ARE observable. A drawn bar here would be a number nobody measured.
struct AgentLaneSection: View {
    let provider: Provider
    let outcome: AgentLane.Outcome
    let now: Date

    var body: some View {
        switch outcome {
        case .notConfigured:
            EmptyView()
        case .unavailable(let why):
            ProviderHeader(provider: provider, detail: "config unreadable")
            OpenRouterProblem(message: why, hint: "the file exists but is not valid JSON",
                              tint: .orange)
        case .ok(let reading):
            ProviderHeader(provider: provider, detail: AgentLane.headerDetail(reading))
            VStack(alignment: .leading, spacing: 1) {
                Text(AgentLane.modelLine(reading))
                    .font(TowerType.font(.small, design: .monospaced))
                Text(AgentLane.dispatchLine(reading, now: now))
                    .font(TowerType.font(.small))
                    .foregroundStyle(TowerType.secondary)
                if let line = AgentLane.usageLine(reading) {
                    Text(line)
                        .font(TowerType.font(.small))
                        .foregroundStyle(TowerType.secondary)
                }
                if let line = AgentLane.usageAgeLine(reading, now: now) {
                    Text(line)
                        .font(TowerType.font(.small))
                        .foregroundStyle(TowerType.dim)
                }
                if let hit = reading.lastLimitHit,
                   AgentLane.limitIsCurrent(reading, now: now) || AgentLane.showsPastLimit(hit, now: now) {
                    let current = AgentLane.limitIsCurrent(reading, now: now)
                    Text(current ? AgentLane.limitLine(hit, now: now)
                                 : AgentLane.pastLimitLine(hit, now: now))
                        .font(TowerType.font(.small, weight: current ? .medium : .regular))
                        .foregroundStyle(current ? AnyShapeStyle(.orange) : AnyShapeStyle(TowerType.dim))
                        .help(hit.message)
                }
            }
            .padding(.leading, 12)
        }
    }
}

/// A keycap-styled hint. Dim and small on purpose: it should be findable when
/// looked for and ignorable otherwise, which a full-contrast label is not.
struct KeyHint: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .font(TowerType.font(.small, design: .monospaced))
            .foregroundStyle(TowerType.dim)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(TowerType.secondary.opacity(0.12))
            )
    }
}

/// Two lines of room that are not about any one seat: up to how many sessions the
/// active login stops at 100 %, and whether the machine itself has room. Same words as
/// `tower status` (`CLI.fleetLines`), so the panel and the terminal cannot disagree.
struct FleetRoom: View {
    let blast: BlastRadius?
    let machine: MachineLoad?
    let read: CLI.FleetRead

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(CLI.fleetLines(blast: blast, machine: machine, read: read), id: \.self) { line in
                Text(line.trimmingCharacters(in: .whitespaces))
                    .font(TowerType.font(.small, weight: .medium))
                    .foregroundStyle(Self.tint(line))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func tint(_ line: String) -> Color {
        if line.contains("⛔") || line.contains("🔴") { return .red }
        if line.contains("⚠️") || line.contains("🟠") { return .orange }
        return TowerType.secondary
    }
}

struct MenuContent: View {
    @ObservedObject var model: LimitsModel
    /// The live panel refreshes when it opens; panelshot uses cached mode so its
    /// offscreen mount remains a read-only cached render.
    var refreshMode: PanelRefreshMode = .live

    /// "2 of 7 ready · next 18:40".
    ///
    /// The heading this replaces said "2 available", which cannot distinguish two-of-three
    /// from two-of-nine, and telling those apart is the decision the panel exists to serve.
    /// The reset clock is included only when something is actually waiting on one: a row
    /// that is merely unmeasured is not waiting for a time, it is waiting for a refresh.
    static func readySummary(ready: Int, total: Int,
                             resting: [(AccountSnapshot, AccountSnapshot.RestReason)],
                             now: Date) -> String {
        var parts = ["\(ready) of \(total) ready"]
        if let next = resting.filter({ $0.1.isTimeGated })
            .compactMap({ AccountSnapshot.reopening($0.0, now: now) }).min() {
            parts.append("next \(CLI.clock(next))")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Not "Claude Code Limits" any more: the panel covers Codex and, with a key,
                // OpenRouter. A title that names one provider misdescribes the other two.
                Text(ProductIdentity.displayName).font(TowerType.font(.header, weight: .semibold))
                Spacer()
                if model.refreshing {
                    ProgressView().controlSize(.small)
                } else if let d = model.lastRefresh {
                    Text(CLI.age(d)).font(TowerType.font(.small))
                        .foregroundStyle(
                            model.refreshError == nil ? TowerType.secondary : Color.orange)
                } else if model.probed || model.refreshError != nil {
                    Text("never").font(TowerType.font(.small)).foregroundStyle(.orange)
                } else {
                    // Rows hydrated from disk, no refresh attempted yet: each row
                    // carries its own capture age, so the header only says so.
                    Text("cached").font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
                }
            }
            if let e = model.refreshError {
                Text("⚠️ refresh failed: \(e)")
                    .font(TowerType.font(.small)).foregroundStyle(.red).lineLimit(2)
            }
            Divider()

            if model.accounts.isEmpty {
                Text("No accounts captured yet.").font(TowerType.font(.body))
                Text("Switch into an account in Claude Code, then refresh.")
                    .font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
            } else {
                // Sort HERE, at render, not once at refresh (2026-07-29: a 2-day-stale
                // account outranked two live ones because refreshIfStale's debounce
                // declined to re-sort). And drive BOTH the sort and the rows from one
                // TimelineView clock: "rows recompute on every body evaluation" turned
                // out to be false. SwiftUI skips a row body whose stored inputs did not
                // change, and only the active account's snapshot ever changes, so
                // inactive rows froze at their last data change (see AccountRow.now).
                // One shared `now` also keeps the order and the row contents consistent
                // with each other within a single frame.
                //
                // Partitioning lives inside the same TimelineView for the same reason:
                // resting is a function of the clock, so an account must be able to fall
                // out of the list (or climb back into it) without new data arriving.
                // #121: a larger text size can make the boards taller than the screen, so
                // the live panel scrolls them under a fixed header and footer. panelshot
                // renders the full height.
                BoardScroll(capped: refreshMode == .live) {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    let t = timeline.date
                    VStack(alignment: .leading, spacing: 5) {
                        RecommendBanner(
                            advice: AccountSnapshot.advise(
                                activeEmail: model.activeEmail,
                                accounts: model.accounts,
                                switchProfiles: model.switchProfiles,
                                rule: .either,
                                now: t),
                            copied: Binding(get: { model.copiedCommand },
                                            set: { model.copiedCommand = $0 }))

                        FleetRoom(blast: model.blastRadius(now: t), machine: model.machine,
                                  read: model.probed ? .done(sessions: model.agents != nil) : .notYet)

                        SeatBoard(
                            model: model,
                            accounts: model.accounts,
                            now: t,
                            activeEmail: model.activeEmail,
                            onSwitch: { _ in
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("/login", forType: .string)
                                model.copiedCommand = true
                            })

                        // Money, which is not a quota: cash balances on their own band.
                        MoneyBoard(orOutcome: model.orOutcome,
                                   orHistory: model.orHistory,
                                   now: t,
                                   creditOpen: { model.disclosure(MoneyBoard.disclosureID($0)) })

                        // Agent lanes: quotas where a CLI exposes them, Pi's spend against the
                        // OpenRouter balance above.
                        LaneBoard(outcomes: model.laneOutcomes, now: t,
                                  cursorSeat: model.accounts.first { $0.kind == .cursor },
                                  openRouter: model.orOutcome)

                        // Load, as one more section in the same list.
                        SessionsBoard(agents: model.agents, probed: model.probed,
                                      idleOpen: model.disclosure("sessions.idle"))
                    }
                }
                }
            }

            Divider()

            Toggle("Start at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.toggleLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            .font(TowerType.font(.body))

            if let e = model.loginError {
                Text(e).font(TowerType.font(.small)).foregroundStyle(.red)
            }

            HStack(spacing: 6) {
                Toggle("Remember Claude seats", isOn: Binding(
                    get: { model.retainClaudeSeats },
                    set: { model.toggleClaudeSeatRetention($0) }
                ))
                .toggleStyle(.checkbox)
                .font(TowerType.font(.body))
                Spacer()
                Button("Re-trust") { model.retrustRetainedClaudeSeats() }
                    .font(TowerType.font(.body))
                    .help("Approve remembered seats once after Tower's signature or bundle id changed")
                Button("Forget") { model.forgetRetainedClaudeSeats() }
                    .font(TowerType.font(.body))
            }
            Text("Keeps each seat's access token in your Keychain to read its usage until it expires.")
                .font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
            if let error = model.seatRetentionError {
                Text("Seat retention: \(error)")
                    .font(TowerType.font(.small)).foregroundStyle(.red).lineLimit(2)
            }

            // #121: the operator could not read the 8 to 12 pt panel. The size applies at
            // once and is stored beside the other Tower settings.
            HStack(spacing: 6) {
                Text("Text size").font(TowerType.font(.body))
                Picker("Text size", selection: Binding(
                    get: { model.textSize },
                    set: { model.setTextSize($0) }
                )) {
                    ForEach(TowerTextSize.allCases, id: \.self) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .font(TowerType.font(.body))
                Spacer()
            }

            HStack(spacing: 6) {
                Button("Refresh") { Task { await model.refresh() } }
                    .font(TowerType.font(.body))
                Spacer()
                // The two panel-level bindings, next to the panel's own
                // controls: one opens and closes it from anywhere, the other
                // dismisses it while it has focus.
                KeyHint("⌘. toggle")
                KeyHint("esc close")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .font(TowerType.font(.body))
            }
        }
        .padding(10)
        // 330 truncated the things worth reading: ledger summaries died at
        // "Scope resolved: [scope: acme/core] (expl…" and long repo
        // names clipped. The meters need ~200 of this; the rest is the text
        // column, which is the part with the information in it.
        .frame(width: TowerTextSize.pt(TowerType.panelWidth))
        // Every size in the panel reads TowerTextSize at render, and SwiftUI skips a row
        // whose stored inputs did not change, so a new size must rebuild from the root.
        .id(model.textSize)
        // The README promised an on-open refresh for a while before one existed.
        .onAppear {
            guard refreshMode.refreshesOnAppear else { return }
            Task { await model.refreshIfStale() }
        }
    }
}

private struct BoardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The boards at their natural height while they fit, and a scroll view no taller than the
/// screen allows once they do not (#121). A ScrollView alone reports no useful ideal height,
/// so the content's measured height sets the frame, capped by the screen.
struct BoardScroll<Content: View>: View {
    let capped: Bool
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0

    /// Room left for the boards: the screen's visible height minus the header, the footer
    /// and the panel's distance from the menubar, all of which grow with the text size.
    /// Pure arithmetic, so it stays off the View's main actor and tests can call it directly.
    nonisolated static func cap(visibleHeight: CGFloat, textFactor: CGFloat) -> CGFloat {
        max(240, visibleHeight - 300 * textFactor)
    }

    var body: some View {
        if capped {
            ScrollView(.vertical) {
                content()
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: BoardHeightKey.self, value: geo.size.height)
                    })
            }
            .frame(height: min(max(contentHeight, 1), Self.cap(
                visibleHeight: NSScreen.main?.visibleFrame.height ?? 800,
                textFactor: TowerTextSize.current * TowerType.layoutScale)))
            .onPreferenceChange(BoardHeightKey.self) { height in
                guard abs(height - contentHeight) > 0.5 else { return }
                contentHeight = height
                DispatchQueue.main.async { AppDelegate.shared?.fitPanel() }
            }
        } else {
            content()
        }
    }
}

final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        AppDelegate.shared?.hidePanel()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    private(set) var statusItem: NSStatusItem?
    private(set) var panel: StatusPanel?
    private var dismissMonitor: Any?
    private var titleCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        Notifier.requestAuthorization()
        LimitsModel.shared.start()
        setupStatusItem()
        setupPanel()
        installDismissMonitor()
        PanelHotkey.register()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // Tower's own mark beside the title (light, nickname, %). A template image,
            // so macOS tints it for the menu bar; a bundle without the art shows the
            // title alone, as before.
            if let glyph = StatusGlyph.bundled() {
                button.image = glyph
                button.imagePosition = .imageLeft
            }
            button.title = LimitsModel.shared.title
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp])
        }
        self.statusItem = item

        titleCancellable = LimitsModel.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.statusItem?.button?.title = LimitsModel.shared.title
                }
            }
    }

    private func setupPanel() {
        let hosting = NSHostingController(rootView: MenuContent(model: LimitsModel.shared))
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = [.preferredContentSize]
        }

        let p = StatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: TowerTextSize.pt(TowerType.panelWidth), height: 200),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.contentViewController = hosting
        p.isFloatingPanel = true
        p.level = .floating
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = false
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.hasShadow = true
        p.backgroundColor = .windowBackgroundColor
        self.panel = p
    }

    @objc func statusItemClicked(_ sender: Any?) {
        togglePanel()
    }

    func togglePanel() {
        if let panel = self.panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let panel = self.panel else { return }
        fitPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        Task { await LimitsModel.shared.refreshIfStale() }
    }

    func hidePanel() {
        panel?.orderOut(nil)
    }

    /// Sizes the panel to its content and re-anchors it under the menubar item. Runs on
    /// open, after a text size change, and when the scrolled boards change height (#121).
    func fitPanel() {
        guard let panel = self.panel else { return }
        if let hosting = panel.contentViewController {
            let targetSize = hosting.view.fittingSize
            if targetSize.width > 0 && targetSize.height > 0 {
                panel.setContentSize(targetSize)
            }
        }
        positionPanel()
    }

    private func positionPanel() {
        guard let panel = self.panel,
              let button = statusItem?.button,
              let buttonWindow = button.window else { return }
        let buttonScreenFrame = buttonWindow.frame
        let panelWidth = panel.frame.width
        let panelHeight = panel.frame.height
        var originX = buttonScreenFrame.midX - panelWidth / 2
        var originY = buttonScreenFrame.minY - panelHeight - 4
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if originX < visible.minX + 8 { originX = visible.minX + 8 }
            if originX + panelWidth > visible.maxX - 8 { originX = visible.maxX - panelWidth - 8 }
            if originY < visible.minY { originY = visible.minY }
        }
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    /// Outside click dismisser: clicks delivered to other applications close the panel.
    private func installDismissMonitor() {
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self = self, let panel = self.panel, panel.isVisible else { return }
            self.hidePanel()
        }
    }
}
