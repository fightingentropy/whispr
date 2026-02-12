import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if appState.whisperBinaryResolvedPath == nil {
                warningRow("Required runtime for selected model is missing.")
            }

            if let lastError = appState.lastError {
                warningRow(lastError)
            }

            Button {
                appState.toggleDictation()
            } label: {
                Label(
                    appState.status == .listening ? "Stop Dictation" : "Start Dictation",
                    systemImage: appState.status == .listening ? "stop.circle.fill" : "mic.fill"
                )
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(appState.status == .transcribing)

            Button {
                appState.reloadModels()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if !appState.latestTranscript.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Transcript")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(appState.latestTranscript)
                        .font(.footnote)
                        .lineLimit(4)
                }
                Button("Copy Last Transcript") {
                    appState.copyLastTranscript()
                }
                .buttonStyle(.bordered)
            }

            Divider()

            HStack(spacing: 8) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openSettingsRequest, object: nil)
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            appState.bootstrapIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: appState.status.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 1) {
                Text("Whispr")
                    .font(.headline.weight(.semibold))
                Text(appState.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if appState.status == .listening || appState.status == .transcribing {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func warningRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
                .padding(.top, 2)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(10)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var statusColor: Color {
        switch appState.status {
        case .idle:
            return .secondary
        case .listening:
            return .green
        case .transcribing:
            return .orange
        case .error:
            return .red
        }
    }
}
