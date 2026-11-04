import AppKit
import SwiftUI

// The two views of approved-design/onboarding-mockup.txt: 01 the first run, where the user
// chooses what Tower watches, and 02 Settings, the same choices, always editable.

private func toggleRow(_ title: String, note: String, found: Bool?, isOn: Binding<Bool>) -> some View {
    HStack(spacing: 8) {
        Text(title).font(TowerType.font(.body)).frame(width: TowerTextSize.pt(170), alignment: .leading)
        Text(note).font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
            .frame(width: TowerTextSize.pt(170), alignment: .leading)
        if let found {
            Text(found ? "✅ found" : "?  not found").font(TowerType.font(.small))
                .foregroundStyle(found ? .green : TowerType.secondary)
                .frame(width: TowerTextSize.pt(80), alignment: .leading)
        }
        Spacer()
        Toggle(isOn.wrappedValue ? "on" : "off", isOn: isOn).toggleStyle(.switch).font(TowerType.font(.small))
    }
}

/// 01 / First run: you choose what Tower watches.
struct FirstRunView: View {
    let detection: Detection
    var onDone: () -> Void = {}
    @State private var choices: SetupChoices

    init(detection: Detection, onDone: @escaping () -> Void = {}) {
        self.detection = detection
        self.onDone = onDone
        _choices = State(initialValue: SetupChoices.prefilled(detection))
    }

    private func binding(_ p: WatchedProvider) -> Binding<Bool> {
        Binding(get: { choices.watch[p] ?? false }, set: { choices.watch[p] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose what Tower watches. Nothing is read until you turn it on.")
                .font(TowerType.font(.body, weight: .semibold))
            Text("\"found\" means Tower saw it installed; it has not read anything yet.")
                .font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)

            Text("CODING AGENTS").font(TowerType.font(.small, weight: .semibold)).padding(.top, 6)
            ForEach(WatchedProvider.allCases.filter { !$0.isMoney }, id: \.self) { p in
                toggleRow(p.title, note: detection.note(p), found: detection.found.contains(p), isOn: binding(p))
            }
            Text("MONEY").font(TowerType.font(.small, weight: .semibold)).padding(.top, 6)
            ForEach(WatchedProvider.allCases.filter(\.isMoney), id: \.self) { p in
                toggleRow(p.title, note: detection.note(p), found: nil, isOn: binding(p))
            }

            Divider()
            HStack {
                Text("ALERTS  warn at").font(TowerType.font(.body))
                // One first level on the first run (the 5-hour window); 7d and Fable keep
                // their 90 % defaults and are set per window in Settings ▸ Alerts.
                Stepper("\(Int(choices.alerts.fiveHour)) % of the 5-hour window",
                        value: $choices.alerts.fiveHour, in: AlertSettings.allowedWarn, step: 5)
                    .font(TowerType.font(.body))
                Spacer()
                Toggle("notifications", isOn: $choices.alerts.notify).font(TowerType.font(.body))
            }
            HStack {
                Toggle("Start at login", isOn: $choices.startAtLogin).font(TowerType.font(.body))
                Spacer()
                Toggle("Remember Claude seats", isOn: $choices.rememberSeats).font(TowerType.font(.body))
            }
            Toggle("Let agents ask Tower over MCP (config in Settings)", isOn: $choices.mcp).font(TowerType.font(.body))

            Text(FirstRun.closingLine).font(TowerType.font(.body)).padding(.top, 6)
            HStack {
                Button("Start watching") {
                    FirstRun.startWatching(choices)
                    _ = LaunchAtLogin.set(choices.startAtLogin)
                    ClaudeSeatRetention.setEnabled(choices.rememberSeats)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Skip, set up later") { FirstRun.skip(); onDone() }
            }
        }
        .padding(16)
        .frame(width: TowerTextSize.pt(620))
    }
}

/// 02 / Settings (menu ▸ Settings…): the same choices, always editable.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case providers = "Providers", accounts = "Accounts", alerts = "Alerts", general = "General", agents = "Agents (MCP)"
        var id: String { rawValue }
    }

    @ObservedObject var model: LimitsModel
    @State var tab: Tab = .providers
    @State private var toggles: [WatchedProvider: Bool] = Dictionary(
        uniqueKeysWithValues: WatchedProvider.allCases.map { ($0, ProviderToggles.isEnabled($0)) })
    @State private var alerts = AlertSettings.current()
    @State private var mcpOn = MCPAccess.isEnabled()
    @State private var forgetting: String?
    @State private var forgetError: String?

    init(model: LimitsModel, tab: Tab = .providers) {
        self.model = model
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Group {
                switch tab {
                case .providers: providers
                case .accounts: accounts
                case .alerts: alertsTab
                case .general: general
                case .agents: agents
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: TowerTextSize.pt(620), height: TowerTextSize.pt(420), alignment: .topLeading)
    }

    private var providers: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("One toggle each. OFF stops reading at once and hides the row.")
                .font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
            ForEach(WatchedProvider.allCases, id: \.self) { p in
                HStack {
                    Text(p.title).font(TowerType.font(.body))
                    Spacer()
                    Toggle("", isOn: Binding(get: { toggles[p] ?? false }, set: { on in
                        toggles[p] = on
                        ProviderToggles.set(p, on)
                        model.applyProviderToggles()
                    })).toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }

    private var claudeSeats: [AccountSnapshot] {
        model.accounts.filter { ($0.provider ?? .claude) == .claude }
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(claudeSeats, id: \.email) { seat in
                HStack {
                    Text(seat.nickname).font(TowerType.font(.body))
                    Spacer()
                    Text("Keep").font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
                    Button("Forget") { forgetting = seat.email }
                }
            }
            if claudeSeats.isEmpty {
                Text("No Claude seats yet.").font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
            }
            Divider()
            Text("+ Add an account: run claude, then /login (once per account). Tower remembers each one.")
                .font(TowerType.font(.body))
            if let forgetError {
                Text("Forget: \(forgetError)").font(TowerType.font(.small)).foregroundStyle(.red)
            }
        }
        .confirmationDialog("Forget this seat? Tower drops its saved Keychain item and stops showing it.",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Forget", role: .destructive) {
                if let email = forgetting { forgetError = SeatForget.forget(email) }
                forgetting = nil
                Task { await model.refresh() }
            }
            Button("Cancel", role: .cancel) { forgetting = nil }
        }
    }

    private func warnStepper(_ label: String, _ key: String, _ value: Binding<Double>) -> some View {
        Stepper("\(label)  \(Int(value.wrappedValue)) %", value: Binding(get: { value.wrappedValue }, set: { v in
            value.wrappedValue = v
            TowerPreferences.shared.set(v, forKey: key)
        }), in: AlertSettings.allowedWarn, step: 5).font(TowerType.font(.body))
    }

    private var alertsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("First warning per window; 95 % and 100 % always alert too.")
                .font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
            warnStepper("5h", AlertSettings.fiveHourKey, $alerts.fiveHour)
            warnStepper("7d", AlertSettings.weeklyKey, $alerts.weekly)
            warnStepper("Fable", AlertSettings.fableKey, $alerts.fable)
            Toggle("Notify", isOn: Binding(get: { alerts.notify }, set: { on in
                alerts.notify = on
                TowerPreferences.shared.set(on, forKey: AlertSettings.notifyKey)
            })).font(TowerType.font(.body))
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Start at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.toggleLaunchAtLogin($0) }))
            Toggle("Remember Claude seats", isOn: Binding(get: { model.retainClaudeSeats }, set: { model.toggleClaudeSeatRetention($0) }))
            HStack {
                Text("Text size")
                Picker("Text size", selection: Binding(get: { model.textSize }, set: { model.setTextSize($0) })) {
                    ForEach(TowerTextSize.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
        .font(TowerType.font(.body))
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Let agents ask Tower over MCP", isOn: Binding(get: { mcpOn }, set: { on in
                mcpOn = on
                TowerPreferences.shared.set(on, forKey: MCPAccess.enabledKey)
            })).font(TowerType.font(.body))
            Text("Paste these two lines in a terminal:").font(TowerType.font(.small)).foregroundStyle(TowerType.secondary)
            Text(MCPConfigLines.both).font(TowerType.font(.small, design: .monospaced)).textSelection(.enabled)
            Button("Copy config") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(MCPConfigLines.both, forType: .string)
            }
        }
    }
}
