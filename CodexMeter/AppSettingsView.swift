import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shares existing settings objects so reorganizing controls never migrates preferences.
struct AppSettingsView: View {
    @ObservedObject var service: UsageCoordinator
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: UsageHistoryModel
    @ObservedObject var updateChecker: UpdateChecker
    @Environment(\.openWindow) private var openWindow
    @State private var selection: String? = "settings.category.general"
    @State private var showsClearConfirmation = false
    @State private var actionError: String?
    @State private var balanceKeyDrafts: [String: String] = [:]
    @State private var balanceKeyErrors: [String: String] = [:]

    private let categories = [
        ("settings.category.general", "gearshape"),
        ("settings.category.menu", "menubar.rectangle"),
        ("settings.category.notifications", "bell"),
        ("settings.category.history", "externaldrive"),
        ("developer.title", "hammer"),
        ("about.title", "info.circle")
    ]

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(categories, id: \.0) { key, symbol in
                    Label(L10n.string(key), systemImage: symbol).tag(key)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch selection {
                case "settings.category.menu":
                    PopoverCustomizationView(service: service, settings: settings)
                case "settings.category.history":
                    historySettings
                case "settings.category.notifications":
                    NotificationsSettingsView(service: service, settings: settings,
                                              push: service.pushNotificationService)
                case "developer.title":
                    DeveloperOptionsView(settings: settings, history: history,
                                         updateChecker: updateChecker, embedded: true)
                case "about.title":
                    AboutView(settings: settings, history: history,
                              updateChecker: updateChecker, embedded: true)
                default:
                    generalSettings
                }
            }
            .navigationTitle(L10n.string(selection ?? "settings.category.general"))
        }
        .frame(minWidth: 760, minHeight: 600)
        .onAppear { settings.refreshLaunchAtLoginStatus() }
        .alert(L10n.string("settings.error_title"), isPresented: Binding(
            get: { settings.settingsError != nil || actionError != nil },
            set: { if !$0 { settings.clearSettingsError(); actionError = nil } }
        )) {
            Button(L10n.string("action.ok")) { settings.clearSettingsError(); actionError = nil }
            if settings.settingsDestination != nil {
                Button(L10n.string("action.open_system_settings")) {
                    settings.openRelevantSystemSettings()
                    settings.clearSettingsError()
                }
            }
        } message: {
            Text(settings.settingsError ?? actionError ?? "")
        }
        .alert(L10n.string("history.clear.title"), isPresented: $showsClearConfirmation) {
            Button(L10n.string("action.cancel"), role: .cancel) { }
            Button(L10n.string("history.clear.confirm"), role: .destructive) {
                Task { await history.clearAll(); actionError = history.errorMessage }
            }
        } message: { Text(L10n.string("history.clear.message")) }
    }

    private var generalSettings: some View {
        Form {
            Section(L10n.string("settings.accounts.section")) {
                ForEach(service.accounts) { account in
                    accountRow(account)
                }
                Button(L10n.string("settings.accounts.add")) { addCodexAccount() }
                if !missingProviders.isEmpty {
                    Menu(L10n.string("settings.accounts.add_source")) {
                        ForEach(missingProviders, id: \.self) { provider in
                            Button(provider.localizedName) { service.addProvider(provider) }
                        }
                    }
                }
                Text(L10n.string("settings.accounts.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L10n.string("settings.provider.section")) {
                Picker(L10n.string("settings.provider.source"), selection: Binding(
                    get: { service.accountID },
                    set: { service.select($0) }
                )) {
                    ForEach(service.accounts) { account in
                        Text(accountTitle(account)).tag(account.id)
                    }
                }
                if service.activeAccount.provider == .openCodeGo {
                    Picker(L10n.string("settings.provider.opencode_channel"), selection: Binding(
                        get: { settings.openCodeGoChannel },
                        set: { settings.openCodeGoChannel = $0; service.openCodeGo.updateChannel($0) }
                    )) {
                        ForEach(OpenCodeGoChannel.allCases, id: \.self) { Text($0.localizedName).tag($0) }
                    }
                    Text(L10n.string("settings.provider.opencode_help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(L10n.string("settings.provider.open_console")) {
                        if let url = service.openCodeGo.consoleURL {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            ForEach(BalanceSource.allCases, id: \.self) { source in
                if let account = service.balanceAccount(for: source),
                   let balanceService = service.balanceService(for: account.id) {
                    balanceSettingsSection(source: source, balanceService: balanceService)
                }
            }
            Section(L10n.string("settings.reset_strategy.section")) {
                Picker(L10n.string("settings.reset_strategy.section"), selection: $settings.resetStrategy) {
                    ForEach(ResetStrategy.allCases) { strategy in
                        Text(strategy.localizedName).tag(strategy)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(L10n.string("settings.reset_strategy.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L10n.string("settings.reset_forecast.section")) {
                Toggle(L10n.string("settings.reset_forecast.toggle"), isOn: $settings.resetForecastEnabled)
                Text(L10n.string("settings.reset_forecast.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Picker(L10n.string("settings.language"), selection: Binding(
                    get: { settings.language },
                    set: { settings.language = $0; service.refresh() }
                )) {
                    ForEach(AppLanguage.allCases) { Text($0.localizedName).tag($0) }
                }
                Picker(L10n.string("settings.appearance"), selection: $settings.appearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { Text($0.localizedName).tag($0) }
                }
                Toggle(L10n.string("settings.launch_at_login"), isOn: Binding(
                    get: { settings.launchAtLoginEnabled }, set: { settings.setLaunchAtLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func balanceSettingsSection(
        source: BalanceSource,
        balanceService: any BalanceSourceService
    ) -> some View {
        Section(source.displayName) {
            SecureField(L10n.string("settings.balance.key_placeholder"), text: Binding(
                get: { balanceKeyDrafts[source.rawValue] ?? "" },
                set: { balanceKeyDrafts[source.rawValue] = $0 }
            ))
            HStack {
                Button(L10n.string("settings.balance.save")) {
                    saveKey(for: source, service: balanceService)
                }
                .disabled((balanceKeyDrafts[source.rawValue] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if balanceService.hasStoredKey {
                    Button(L10n.string("settings.balance.remove"), role: .destructive) {
                        removeKey(for: source, service: balanceService)
                    }
                }

                if let url = source.helpURL {
                    Spacer()
                    Button(L10n.string("settings.balance.get_key")) {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.link)
                }
            }

            LabeledContent(L10n.string("settings.balance.status")) {
                Text(keyStatus(for: balanceService))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(L10n.string("settings.balance.budget"))
                TextField(L10n.string("settings.balance.budget_placeholder"), value: Binding(
                    get: { settings.budget(for: source) },
                    set: { settings.setBudget($0, for: source) }
                ), format: .number)
                .frame(width: 110)
            }

            Text(L10n.string("settings.balance.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message = balanceKeyErrors[source.rawValue] {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func keyStatus(for balanceService: any BalanceSourceService) -> String {
        switch (balanceService.hasEnvironmentKey, balanceService.hasStoredKey) {
        case (true, _): return L10n.string("settings.balance.status_environment")
        case (false, true): return L10n.string("settings.balance.status_keychain")
        default: return L10n.string("settings.balance.status_missing")
        }
    }

    private func saveKey(for source: BalanceSource, service balanceService: any BalanceSourceService) {
        balanceKeyErrors[source.rawValue] = nil
        do {
            // Saving a key goes straight to the keychain; the draft text is the
            // only place the full key is ever held in memory.
            try balanceService.saveKey(balanceKeyDrafts[source.rawValue] ?? "")
            balanceKeyDrafts[source.rawValue] = ""
        } catch {
            balanceKeyErrors[source.rawValue] = L10n.string("settings.balance.save_failed")
        }
    }

    private func removeKey(for source: BalanceSource, service balanceService: any BalanceSourceService) {
        balanceKeyErrors[source.rawValue] = nil
        do {
            try balanceService.removeKey()
        } catch {
            balanceKeyErrors[source.rawValue] = L10n.string("settings.balance.save_failed")
        }
    }

    private func accountTitle(_ account: StoredQuotaAccount) -> String {
        guard let remaining = service.remainingPercent(for: account.id) else {
            return account.displayName
        }
        return "\(account.displayName) \(remaining)%"
    }

    /// Sources the user removed and can add back without restarting the app.
    private var missingProviders: [UsageProvider] {
        UsageProvider.optionalProviders.filter { provider in
            !service.accounts.contains { $0.provider == provider }
        }
    }

    private func accountRow(_ account: StoredQuotaAccount) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let home = account.codexHomeDirectory {
                    Text(home.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if account.isRemovable {
                    Button {
                        service.removeAccount(id: account.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("settings.accounts.remove"))
                    .accessibilityLabel(L10n.string("settings.accounts.remove"))
                }
            }
        } label: {
            Text(account.displayName)
        }
    }

    /// A Codex account is a separate `CODEX_HOME`, so adding one is choosing the
    /// folder that login was written to.
    private func addCodexAccount() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = L10n.string("settings.accounts.add_message")
        panel.prompt = L10n.string("settings.accounts.add")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let existingCodexCount = service.accounts.filter { $0.provider == .codex }.count
            service.addCodexAccount(
                homeDirectory: url,
                displayName: "\(L10n.string("settings.accounts.codex_name")) \(existingCodexCount + 1)"
            )
        }
    }

    private var historySettings: some View {
        Form {
            Section(L10n.string("history.storage.title")) {
                Picker(L10n.string("history.retention"), selection: $settings.historyRetention) {
                    ForEach(HistoryRetention.allCases) { Text($0.localizedName).tag($0) }
                }
                .onChange(of: settings.historyRetention) { value in
                    Task { await history.applyRetention(value); actionError = history.errorMessage }
                }
                LabeledContent(L10n.string("history.storage.title")) {
                    Text(ByteCountFormatter.string(fromByteCount: history.storageSize, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                Button(L10n.string("history.export"), action: exportCSV)
                    .disabled(history.activeAccountKey == nil)
                Button(L10n.string("history.clear"), role: .destructive) { showsClearConfirmation = true }
                Text(L10n.string("history.storage.privacy")).font(.caption).foregroundStyle(.secondary)
            }
            .disabled(history.isRestoring || history.needsRestart)
            HistoryBackupView(settings: settings, history: history)
        }
        .formStyle(.grouped)
        .task { await history.refreshMetadata() }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "CodexMeter-History.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let data = try await history.exportCSV()
                    try data.write(to: url, options: .atomic)
                } catch { actionError = L10n.string("backup.failed") }
            }
        }
    }
}
