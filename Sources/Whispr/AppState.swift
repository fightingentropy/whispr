import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var status: DictationStatus = .idle
    @Published var hotkeyDisplay = "Right Command (hold)"
    @Published var selectedLanguage = "en"
    @Published var autoPunctuation = true
    @Published var transcriptionThreads = 4
    @Published var latestTranscript = ""
    @Published var lastError: String?
    @Published var whisperCLIPath = ""
    @Published var microphonePermissionGranted = false
    @Published var accessibilityPermissionGranted = false
    @Published var liveInputLevel: Float = 0

    @Published private(set) var modelStore: ModelStore

    private let defaults = UserDefaults.standard
    private let audioCapture: AudioCaptureService
    private let sherpaTranscriptionEngine: SherpaOnnxTranscriptionEngine
    private let whisperCppTranscriptionEngine: WhisperCppTranscriptionEngine
    private let textInjector: TextInjectionService
    private var hotkeyService: HotkeyService
    private let permissionManager: PermissionManager
    private var modelStoreObservation: AnyCancellable?

    private var didBootstrap = false
    private var isBenchmarkingThreads = false

    init(
        modelStore: ModelStore = ModelStore(),
        audioCapture: AudioCaptureService = LiveAudioCaptureService(),
        textInjector: TextInjectionService = ActiveAppTextInjectionService(),
        permissionManager: PermissionManager = PermissionManager()
    ) {
        self.modelStore = modelStore
        self.audioCapture = audioCapture
        self.textInjector = textInjector
        self.permissionManager = permissionManager

        let persistedCLIPath = defaults.string(forKey: Self.whisperCLIPathKey) ?? ""
        let persistedThreads = Self.loadTranscriptionThreads(from: defaults)
        self.whisperCLIPath = persistedCLIPath
        self.selectedLanguage = defaults.string(forKey: Self.languageKey) ?? "en"
        self.autoPunctuation = defaults.object(forKey: Self.autoPunctuationKey) as? Bool ?? true
        self.transcriptionThreads = persistedThreads

        if let persistedModelPath = defaults.string(forKey: Self.modelPathKey) {
            modelStore.selectModel(path: persistedModelPath)
        }

        self.sherpaTranscriptionEngine = SherpaOnnxTranscriptionEngine(
            customBinaryPath: persistedCLIPath,
            threadCount: persistedThreads
        )
        self.whisperCppTranscriptionEngine = WhisperCppTranscriptionEngine(
            threadCount: persistedThreads
        )

        let preset = Self.loadHotkeyPreset(from: defaults)
        self.hotkeyService = ConfigurableHotkeyService(preset: preset)
        self.audioCapture.setInputLevelHandler { [weak self] level in
            self?.liveInputLevel = level
        }
        observeModelStore()
        hotkeyDisplay = hotkeyService.displayName
        refreshPermissions()
        bootstrapIfNeeded()
    }

    deinit {
        audioCapture.setInputLevelHandler(nil)
        hotkeyService.stop()
    }

    var models: [TranscriptionModel] {
        modelStore.availableModels
    }

    var activeModel: TranscriptionModel? {
        modelStore.selectedModel
    }

    var languageOptions: [String] {
        ["en", "es", "fr", "de", "it", "pt", "nl", "sv", "tr", "ja"]
    }

    var selectedModelPathBinding: Binding<String?> {
        Binding(
            get: { self.modelStore.selectedModelPath },
            set: { [weak self] path in
                self?.modelStore.selectModel(path: path)
                self?.persistSelectedModelPath()
                self?.scheduleAutomaticThreadBenchmarkIfNeeded()
            }
        )
    }

    var whisperBinaryResolvedPath: String? {
        guard let model = activeModel else { return nil }
        return runtimeBinaryPath(for: model)
    }

    func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        registerHotkey()
        refreshPermissions()
        reloadModels()
    }

    func reloadModels() {
        modelStore.reloadModelsInBackground { [weak self] in
            Task { @MainActor in
                self?.persistSelectedModelPath()
                self?.scheduleAutomaticThreadBenchmarkIfNeeded()
            }
        }
    }

    func refreshPermissions() {
        microphonePermissionGranted = permissionManager.microphonePermissionGranted()
        accessibilityPermissionGranted = permissionManager.accessibilityPermissionGranted()
    }

    func requestMicrophonePermission() {
        NSApp.activate(ignoringOtherApps: true)
        permissionManager.requestMicrophonePermission { [weak self] granted in
            Task { @MainActor in
                self?.microphonePermissionGranted = granted
                if !granted {
                    self?.lastError = DictationError.permission(
                        "Microphone access is required for dictation."
                    ).errorDescription
                }
            }
        }
    }

    func requestAccessibilityPermission() {
        permissionManager.requestAccessibilityPrompt()
        permissionManager.openAccessibilitySettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            Task { @MainActor in
                self?.refreshPermissions()
            }
        }
    }

    func openModelFolder() {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let appSupportModels = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Whispr/Models", directoryHint: .isDirectory)
        let homeWhispr = home.appending(path: "whispr", directoryHint: .isDirectory)
        let homeWhisprModels = homeWhispr.appending(path: "models", directoryHint: .isDirectory)

        if let appSupportModels {
            try? fileManager.createDirectory(at: appSupportModels, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([appSupportModels])
            return
        }

        let existing = [homeWhisprModels, homeWhispr]
            .first(where: { fileManager.fileExists(atPath: $0.path) })
            ?? homeWhisprModels

        try? fileManager.createDirectory(at: existing, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([existing])
    }

    func pickWhisperCLIPath() {
        let panel = NSOpenPanel()
        panel.title = "Select sherpa-onnx-offline binary"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Binary"

        if panel.runModal() == .OK, let url = panel.url {
            setWhisperCLIPathOverride(url.path)
        }
    }

    func clearWhisperCLIPathOverride() {
        whisperCLIPath = ""
        defaults.set("", forKey: Self.whisperCLIPathKey)
        sherpaTranscriptionEngine.customBinaryPath = nil
        scheduleAutomaticThreadBenchmarkIfNeeded()
    }

    func setWhisperCLIPathOverride(_ path: String) {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        whisperCLIPath = normalizedPath
        defaults.set(normalizedPath, forKey: Self.whisperCLIPathKey)
        let storedPath = normalizedPath.isEmpty ? nil : normalizedPath
        sherpaTranscriptionEngine.customBinaryPath = storedPath
        scheduleAutomaticThreadBenchmarkIfNeeded()
    }

    func setLanguage(_ language: String) {
        selectedLanguage = language
        defaults.set(language, forKey: Self.languageKey)
    }

    func setAutoPunctuation(_ enabled: Bool) {
        autoPunctuation = enabled
        defaults.set(enabled, forKey: Self.autoPunctuationKey)
    }

    func setTranscriptionThreads(_ threads: Int) {
        let normalizedThreads = Self.normalizedTranscriptionThreads(threads)
        transcriptionThreads = normalizedThreads
        defaults.set(normalizedThreads, forKey: Self.transcriptionThreadsKey)
        sherpaTranscriptionEngine.threadCount = normalizedThreads
        whisperCppTranscriptionEngine.threadCount = normalizedThreads
    }

    func setHotkeyPreset(_ preset: HotkeyPreset) {
        defaults.set(preset.rawValue, forKey: Self.hotkeyPresetKey)
        hotkeyDisplay = preset.displayName
        hotkeyService.stop()
        hotkeyService = ConfigurableHotkeyService(preset: preset)
        if didBootstrap {
            registerHotkey()
        }
    }

    var hotkeyPreset: HotkeyPreset {
        Self.loadHotkeyPreset(from: defaults)
    }

    func toggleDictation() {
        switch status {
        case .idle, .error:
            startDictation()
        case .listening:
            stopDictation()
        case .transcribing:
            break
        }
    }

    func copyLastTranscript() {
        guard !latestTranscript.isEmpty else { return }
        _ = NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latestTranscript, forType: .string)
    }

    private func registerHotkey() {
        do {
            try hotkeyService.start(
                onPressed: { [weak self] in
                    Task { @MainActor in
                        self?.handleHotkeyPressed()
                    }
                },
                onReleased: { [weak self] in
                    Task { @MainActor in
                        self?.handleHotkeyReleased()
                    }
                }
            )
        } catch {
            status = .error
            lastError = (error as? LocalizedError)?.errorDescription
                ?? DictationError.hotkey(error.localizedDescription).errorDescription
        }
    }

    private func handleHotkeyPressed() {
        if status == .idle || status == .error {
            startDictation()
        }
    }

    private func handleHotkeyReleased() {
        if status == .listening {
            stopDictation()
        }
    }

    private func startDictation() {
        liveInputLevel = 0
        lastError = nil
        refreshPermissions()

        guard let model = activeModel else {
            status = .error
            liveInputLevel = 0
            lastError = DictationError.missingModel.errorDescription
            return
        }

        guard runtimeBinaryPath(for: model) != nil else {
            status = .error
            liveInputLevel = 0
            lastError = DictationError.missingASRRuntime.errorDescription
            return
        }

        guard microphonePermissionGranted else {
            requestMicrophonePermission()
            status = .error
            liveInputLevel = 0
            lastError = DictationError.permission("Microphone permission is not granted.").errorDescription
            return
        }

        do {
            try audioCapture.start()
            status = .listening
        } catch {
            status = .error
            liveInputLevel = 0
            lastError = (error as? LocalizedError)?.errorDescription
                ?? DictationError.audioCapture(error.localizedDescription).errorDescription
        }
    }

    private func stopDictation() {
        guard status == .listening else { return }

        status = .transcribing
        liveInputLevel = 0

        let audioData: Data
        do {
            audioData = try audioCapture.stop()
        } catch {
            status = .error
            liveInputLevel = 0
            lastError = (error as? LocalizedError)?.errorDescription
                ?? DictationError.audioCapture(error.localizedDescription).errorDescription
            return
        }

        guard let model = activeModel else {
            status = .error
            liveInputLevel = 0
            lastError = DictationError.missingModel.errorDescription
            return
        }

        let language = selectedLanguage
        let punctuationEnabled = autoPunctuation

        Task {
            do {
                let transcript: String
                switch model.kind {
                case .transducer:
                    transcript = try await sherpaTranscriptionEngine.transcribe(
                        audioData: audioData,
                        modelPath: model.path.path,
                        language: language,
                        autoPunctuation: punctuationEnabled
                    )
                case .whisper:
                    transcript = try await whisperCppTranscriptionEngine.transcribe(
                        audioData: audioData,
                        modelPath: model.path.path,
                        language: language,
                        autoPunctuation: punctuationEnabled
                    )
                }

                latestTranscript = transcript

                do {
                    try textInjector.insert(text: transcript)
                    status = .idle
                    liveInputLevel = 0
                    scheduleAutomaticThreadBenchmarkIfNeeded()
                } catch {
                    status = .idle
                    liveInputLevel = 0
                    lastError = (error as? LocalizedError)?.errorDescription
                        ?? DictationError.textInjection(error.localizedDescription).errorDescription
                    scheduleAutomaticThreadBenchmarkIfNeeded()
                }
            } catch {
                status = .error
                liveInputLevel = 0
                lastError = (error as? LocalizedError)?.errorDescription
                    ?? DictationError.transcription(error.localizedDescription).errorDescription
            }
        }
    }

    private func scheduleAutomaticThreadBenchmarkIfNeeded() {
        guard !isBenchmarkingThreads else { return }
        guard status == .idle else { return }
        guard let model = activeModel else { return }
        guard model.kind == .transducer else { return }
        guard let binaryPath = sherpaTranscriptionEngine.resolveBinaryPath() else { return }
        let engine = sherpaTranscriptionEngine

        let signature = Self.threadBenchmarkSignature(
            modelPath: model.path.path,
            whisperBinaryPath: binaryPath,
            cores: ProcessInfo.processInfo.activeProcessorCount
        )
        guard defaults.string(forKey: Self.threadBenchmarkSignatureKey) != signature else { return }

        let language = selectedLanguage
        let punctuationEnabled = autoPunctuation
        let benchmarkAudio = Self.makeThreadBenchmarkAudio()
        let candidates = Self.threadBenchmarkCandidates(
            current: transcriptionThreads,
            cores: ProcessInfo.processInfo.activeProcessorCount
        )

        isBenchmarkingThreads = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBenchmarkingThreads = false }
            var timings: [(threads: Int, seconds: TimeInterval)] = []

            for threads in candidates {
                guard self.status == .idle else { return }
                let startedAt = Date()
                do {
                    _ = try await engine.transcribe(
                        audioData: benchmarkAudio,
                        modelPath: model.path.path,
                        language: language,
                        autoPunctuation: punctuationEnabled,
                        threadCountOverride: threads,
                        allowEmptyResult: true
                    )
                } catch {
                    return
                }
                guard self.status == .idle else { return }
                timings.append((threads, Date().timeIntervalSince(startedAt)))
            }

            guard let best = timings.min(by: { $0.seconds < $1.seconds }) else { return }
            self.setTranscriptionThreads(best.threads)
            self.defaults.set(signature, forKey: Self.threadBenchmarkSignatureKey)
        }
    }

    private func runtimeBinaryPath(for model: TranscriptionModel) -> String? {
        switch model.kind {
        case .transducer:
            return sherpaTranscriptionEngine.resolveBinaryPath()
        case .whisper:
            return whisperCppTranscriptionEngine.resolveBinaryPath()
        }
    }

    private func observeModelStore() {
        modelStoreObservation = modelStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    private func persistSelectedModelPath() {
        defaults.set(modelStore.selectedModelPath, forKey: Self.modelPathKey)
    }

    private static func loadHotkeyPreset(from defaults: UserDefaults) -> HotkeyPreset {
        guard let raw = defaults.string(forKey: Self.hotkeyPresetKey),
              let preset = HotkeyPreset(rawValue: raw) else {
            return .rightCommand
        }
        return preset
    }

    private static func loadTranscriptionThreads(from defaults: UserDefaults) -> Int {
        let persisted = defaults.integer(forKey: Self.transcriptionThreadsKey)
        if persisted <= 0 {
            return normalizedTranscriptionThreads(defaultTranscriptionThreads)
        }
        return normalizedTranscriptionThreads(persisted)
    }

    private static func normalizedTranscriptionThreads(_ threads: Int) -> Int {
        max(1, min(threads, 128))
    }

    private static var defaultTranscriptionThreads: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return normalizedTranscriptionThreads(max(4, cores * 2))
    }

    private static func threadBenchmarkCandidates(current: Int, cores: Int) -> [Int] {
        let safeCoreCount = max(1, cores)
        let lower = normalizedTranscriptionThreads(max(1, safeCoreCount / 2))
        let middle = normalizedTranscriptionThreads(safeCoreCount)
        let upper = normalizedTranscriptionThreads(max(safeCoreCount + 1, safeCoreCount * 2))
        let current = normalizedTranscriptionThreads(current)

        return Array(Set([lower, middle, upper, current])).sorted()
    }

    private static func makeThreadBenchmarkAudio() -> Data {
        let sampleRate = 16_000
        let durationSeconds = 3.0
        let frameCount = max(1, Int(Double(sampleRate) * durationSeconds))

        var pcmData = Data(capacity: frameCount * MemoryLayout<Int16>.size)
        var randomState: UInt32 = 0x57A1_0B3D

        for _ in 0..<frameCount {
            randomState = 1_664_525 &* randomState &+ 1_013_904_223
            let centered = Int32(randomState >> 16) - 32_768
            let attenuated = centered / 3
            let clamped = max(Int32(Int16.min), min(Int32(Int16.max), attenuated))
            var sample = Int16(clamped).littleEndian
            withUnsafeBytes(of: &sample) { pcmData.append(contentsOf: $0) }
        }

        return buildWAV(fromPCM16: pcmData, sampleRate: sampleRate)
    }

    private static func buildWAV(fromPCM16 pcmData: Data, sampleRate: Int) -> Data {
        let channelCount = 1
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let byteRate = sampleRate * channelCount * bytesPerSample
        let blockAlign = UInt16(channelCount * bytesPerSample)
        let dataChunkSize = UInt32(pcmData.count)
        let riffChunkSize = UInt32(36) + dataChunkSize

        var wav = Data(capacity: Int(riffChunkSize + 8))
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(littleEndianData(riffChunkSize))
        wav.append("WAVE".data(using: .ascii)!)

        wav.append("fmt ".data(using: .ascii)!)
        wav.append(littleEndianData(UInt32(16)))
        wav.append(littleEndianData(UInt16(1)))
        wav.append(littleEndianData(UInt16(channelCount)))
        wav.append(littleEndianData(UInt32(sampleRate)))
        wav.append(littleEndianData(UInt32(byteRate)))
        wav.append(littleEndianData(blockAlign))
        wav.append(littleEndianData(UInt16(bitsPerSample)))

        wav.append("data".data(using: .ascii)!)
        wav.append(littleEndianData(dataChunkSize))
        wav.append(pcmData)
        return wav
    }

    private static func littleEndianData<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndian = value.littleEndian
        return Data(bytes: &littleEndian, count: MemoryLayout<T>.size)
    }

    private static func threadBenchmarkSignature(modelPath: String, whisperBinaryPath: String, cores: Int) -> String {
        let safeCoreCount = max(1, cores)
        return "v1|\(modelPath)|\(whisperBinaryPath)|\(safeCoreCount)"
    }

    private static let modelPathKey = "whispr.selectedModelPath"
    private static let whisperCLIPathKey = "whispr.whisperCLIPathOverride"
    private static let languageKey = "whispr.language"
    private static let autoPunctuationKey = "whispr.autoPunctuation"
    private static let transcriptionThreadsKey = "whispr.transcriptionThreads"
    private static let threadBenchmarkSignatureKey = "whispr.threadBenchmarkSignature"
    private static let hotkeyPresetKey = "whispr.hotkeyPreset"
}
