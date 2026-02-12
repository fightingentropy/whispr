import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            Form {
                Section("Dictation") {
                    Picker("Global hotkey", selection: hotkeyBinding) {
                        ForEach(HotkeyPreset.allCases, id: \.self) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Language", selection: languageBinding) {
                        ForEach(appState.languageOptions, id: \.self) { code in
                            Text(languageLabel(for: code))
                                .tag(code)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle("Auto punctuation", isOn: punctuationBinding)
                }

                Section("Vocabulary") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Preferred terms (comma or newline separated)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    TextEditor(text: customVocabularyBinding)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 56)
                    Text("Examples: TypeScript, PostgreSQL, Next.js, GraphQL")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Replacement rules (`wrong => right`, one per line)")
                        .font(.caption)
                            .foregroundStyle(.secondary)
                    TextEditor(text: replacementRulesBinding)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 72)
                    Text("Examples:\npostgress => PostgreSQL\nnext js => Next.js\ntype script => TypeScript")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

                Section("Permissions") {
                    HStack {
                        permissionDot(appState.microphonePermissionGranted)
                        Text("Microphone")
                        Spacer()
                        Button("Request") {
                            appState.requestMicrophonePermission()
                        }
                    }

                    HStack {
                        permissionDot(appState.accessibilityPermissionGranted)
                        Text("Accessibility (for auto-paste)")
                        Spacer()
                        Button("Open Prompt") {
                            appState.requestAccessibilityPermission()
                        }
                    }
                }

                Section("Engine") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Runtime binary")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(engineStatusLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(appState.whisperBinaryResolvedPath == nil ? .red : .green)
                        }

                        Text(engineSummaryLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Section("Models") {
                    if appState.models.isEmpty {
                        Text("No available models were found.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Model", selection: appState.selectedModelPathBinding) {
                            ForEach(appState.models) { model in
                                Text("\(model.displayName) (\(model.displaySize))")
                                    .tag(Optional(model.path.path))
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Button("Reload") {
                        appState.reloadModels()
                    }
                }

                Section("Updates") {
                    HStack {
                        Text("Current version")
                        Spacer()
                        Text(appState.currentAppVersion)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Button(isCheckingForUpdates ? "Checking..." : "Check for Updates") {
                            appState.checkForUpdates()
                        }
                        .disabled(isCheckingForUpdates || isInstallingUpdate)

                        if canInstallUpdate || isInstallingUpdate {
                            Button(isInstallingUpdate ? "Updating..." : "Update Now") {
                                appState.installAvailableUpdate()
                            }
                            .disabled(isInstallingUpdate || !canInstallUpdate)
                        }

                        if canOpenLatestRelease {
                            Button("Open Release") {
                                appState.openLatestReleasePage()
                            }
                        }
                    }

                    Text(updateStatusMessage)
                        .font(.caption)
                        .foregroundStyle(updateStatusColor)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private var hotkeyBinding: Binding<HotkeyPreset> {
        Binding(
            get: { appState.hotkeyPreset },
            set: { appState.setHotkeyPreset($0) }
        )
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { appState.selectedLanguage },
            set: { appState.setLanguage($0) }
        )
    }

    private var punctuationBinding: Binding<Bool> {
        Binding(
            get: { appState.autoPunctuation },
            set: { appState.setAutoPunctuation($0) }
        )
    }

    private var customVocabularyBinding: Binding<String> {
        Binding(
            get: { appState.customVocabularyText },
            set: { appState.setCustomVocabularyText($0) }
        )
    }

    private var replacementRulesBinding: Binding<String> {
        Binding(
            get: { appState.replacementRulesText },
            set: { appState.setReplacementRulesText($0) }
        )
    }

    private func permissionDot(_ granted: Bool) -> some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 9))
            .foregroundStyle(granted ? .green : .orange)
    }

    private func languageLabel(for code: String) -> String {
        switch code {
        case "en":
            return "English (en)"
        case "es":
            return "Spanish (es)"
        case "fr":
            return "French (fr)"
        case "de":
            return "German (de)"
        case "it":
            return "Italian (it)"
        case "pt":
            return "Portuguese (pt)"
        case "nl":
            return "Dutch (nl)"
        case "sv":
            return "Swedish (sv)"
        case "tr":
            return "Turkish (tr)"
        case "ja":
            return "Japanese (ja)"
        default:
            return code
        }
    }

    private var engineStatusLabel: String {
        appState.whisperBinaryResolvedPath == nil ? "Missing" : "Ready"
    }

    private var engineSummaryLabel: String {
        guard let resolvedPath = appState.whisperBinaryResolvedPath else {
            return "Runtime for selected model is not available."
        }

        let binaryName = URL(fileURLWithPath: resolvedPath).lastPathComponent
        return "Using runtime (\(binaryName))."
    }

    private var isCheckingForUpdates: Bool {
        if case .checking = appState.updateCheckState {
            return true
        }
        return false
    }

    private var canOpenLatestRelease: Bool {
        if case .updateAvailable = appState.updateCheckState {
            return true
        }
        return false
    }

    private var canInstallUpdate: Bool {
        if case let .updateAvailable(_, _, _, downloadURL) = appState.updateCheckState {
            return downloadURL != nil
        }
        return false
    }

    private var isInstallingUpdate: Bool {
        if case .installing = appState.updateCheckState {
            return true
        }
        return false
    }

    private var updateStatusMessage: String {
        switch appState.updateCheckState {
        case .idle:
            return "Check GitHub Releases for a newer app build."
        case .checking:
            return "Checking for updates..."
        case let .upToDate(currentVersion):
            return "No updates available (current: v\(currentVersion))."
        case let .updateAvailable(currentVersion, latestVersion, _, downloadURL):
            if downloadURL == nil {
                return "Update available: v\(latestVersion) (current: v\(currentVersion)). No DMG asset found."
            }
            return "Update available: v\(latestVersion) (current: v\(currentVersion))."
        case let .installing(currentVersion, latestVersion, message):
            return "\(message) (v\(currentVersion) -> v\(latestVersion))."
        case let .failed(message):
            return message
        }
    }

    private var updateStatusColor: Color {
        switch appState.updateCheckState {
        case .upToDate:
            return .green
        case .updateAvailable, .installing:
            return .orange
        case .failed:
            return .red
        case .idle, .checking:
            return .secondary
        }
    }
}
