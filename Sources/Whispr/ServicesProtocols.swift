import Foundation

protocol AudioCaptureService {
    func start() throws
    func stop() throws -> Data
    func setInputLevelHandler(_ handler: ((Float) -> Void)?)
}

extension AudioCaptureService {
    func setInputLevelHandler(_ handler: ((Float) -> Void)?) {}
}

protocol TranscriptionEngine {
    func transcribe(
        audioData: Data,
        modelPath: String,
        language: String,
        autoPunctuation: Bool
    ) async throws -> String
}

protocol TextInjectionService {
    func insert(text: String) throws
}

enum DictationError: LocalizedError {
    case missingModel
    case missingASRRuntime
    case hotkey(String)
    case permission(String)
    case audioCapture(String)
    case transcription(String)
    case textInjection(String)

    var errorDescription: String? {
        switch self {
        case .missingModel:
            return "No model selected. Add a model file and reload."
        case .missingASRRuntime:
            return "Required ASR runtime was not found for the selected model. Ensure sherpa-onnx-offline (Parakeet) or whisper-cli (Whisper) is bundled."
        case let .hotkey(message):
            return "Hotkey setup failed: \(message)"
        case let .permission(message):
            return "Permission error: \(message)"
        case let .audioCapture(message):
            return "Audio capture failed: \(message)"
        case let .transcription(message):
            return "Transcription failed: \(message)"
        case let .textInjection(message):
            return "Text insertion failed: \(message)"
        }
    }
}
