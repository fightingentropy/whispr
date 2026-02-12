import Foundation

enum ASRModelKind: String, Hashable {
    case transducer
    case whisper
}

enum DictationStatus: String {
    case idle
    case listening
    case transcribing
    case error

    var label: String {
        switch self {
        case .idle:
            return "Idle"
        case .listening:
            return "Listening"
        case .transcribing:
            return "Transcribing"
        case .error:
            return "Error"
        }
    }

    var systemImage: String {
        switch self {
        case .idle:
            return "mic"
        case .listening:
            return "waveform.circle.fill"
        case .transcribing:
            return "hourglass.circle"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}

struct TranscriptionModel: Identifiable, Hashable {
    let path: URL
    let sizeBytes: Int64
    let kind: ASRModelKind

    var id: String { path.path }

    var displayName: String {
        path.deletingLastPathComponent().lastPathComponent
    }

    var fileName: String {
        path.lastPathComponent
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var profileHint: String {
        let name = displayName.lowercased()
        switch kind {
        case .transducer:
            return "Parakeet"
        case .whisper:
            if name.contains("distil") {
                return "Fast"
            }
            if name.contains("turbo") {
                return "Balanced"
            }
            return "Whisper"
        }
    }
}
