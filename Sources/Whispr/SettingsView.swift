import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
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
        }
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
}
