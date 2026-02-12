import Foundation

final class SherpaOnnxTranscriptionEngine: TranscriptionEngine {
    private enum ResolvedModelBundle {
        case transducer(TransducerModelBundle)
        case whisper(WhisperModelBundle)

        var directory: URL {
            switch self {
            case let .transducer(bundle):
                return bundle.directory
            case let .whisper(bundle):
                return bundle.directory
            }
        }
    }

    private struct TransducerModelBundle {
        let directory: URL
        let tokensFileName: String
        let encoderFileName: String
        let decoderFileName: String
        let joinerFileName: String
    }

    private struct WhisperModelBundle {
        let directory: URL
        let tokensFileName: String
        let encoderFileName: String
        let decoderFileName: String
    }

    private final class ThreadSafeDataBuffer {
        private var data = Data()
        private let lock = NSLock()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func trimmedUTF8String() -> String {
            lock.lock()
            let snapshot = data
            lock.unlock()
            return String(data: snapshot, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    var customBinaryPath: String?
    var threadCount: Int

    init(customBinaryPath: String? = nil, threadCount: Int = 4) {
        self.customBinaryPath = customBinaryPath
        self.threadCount = Self.normalizedThreadCount(threadCount)
    }

    func transcribe(
        audioData: Data,
        modelPath: String,
        language: String,
        autoPunctuation: Bool
    ) async throws -> String {
        try await transcribe(
            audioData: audioData,
            modelPath: modelPath,
            language: language,
            autoPunctuation: autoPunctuation,
            threadCountOverride: nil,
            allowEmptyResult: false
        )
    }

    func transcribe(
        audioData: Data,
        modelPath: String,
        language: String,
        autoPunctuation: Bool,
        threadCountOverride: Int?,
        allowEmptyResult: Bool
    ) async throws -> String {
        let customBinaryPath = self.customBinaryPath
        let threadCount = Self.normalizedThreadCount(threadCountOverride ?? self.threadCount)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let transcript = try Self.runSherpaOnnxOffline(
                        audioData: audioData,
                        modelPath: modelPath,
                        language: language,
                        autoPunctuation: autoPunctuation,
                        customBinaryPath: customBinaryPath,
                        threadCount: threadCount,
                        allowEmptyTranscript: allowEmptyResult
                    )
                    continuation.resume(returning: transcript)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func resolveBinaryPath() -> String? {
        Self.resolveBinaryPath(customBinaryPath: customBinaryPath)
    }

    private static func runSherpaOnnxOffline(
        audioData: Data,
        modelPath: String,
        language: String,
        autoPunctuation: Bool,
        customBinaryPath: String?,
        threadCount: Int,
        allowEmptyTranscript: Bool
    ) throws -> String {
        let fileManager = FileManager.default

        guard let binaryPath = resolveBinaryPath(customBinaryPath: customBinaryPath) else {
            throw DictationError.missingASRRuntime
        }

        let modelBundle = try resolveModelBundle(from: modelPath)

        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("whispr-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let wavPath = tempDir.appendingPathComponent("input.wav")
        try audioData.write(to: wavPath, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.currentDirectoryURL = modelBundle.directory
        process.arguments = sherpaArguments(
            modelBundle: modelBundle,
            audioPath: wavPath.path,
            language: language,
            threadCount: threadCount
        )

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw DictationError.transcription(
                "Unable to execute sherpa-onnx-offline at \(binaryPath): \(error.localizedDescription)"
            )
        }

        let (stdoutText, stderrText) = captureOutput(
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )

        guard process.terminationStatus == 0 else {
            let combinedOutput = [stderrText, stdoutText]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw DictationError.transcription(
                "sherpa-onnx-offline exited with code \(process.terminationStatus). \(combinedOutput)"
            )
        }

        let rawTranscript = extractTranscript(stdout: stdoutText, stderr: stderrText)
        let cleaned = cleanTranscript(rawTranscript, autoPunctuation: autoPunctuation)

        guard !cleaned.isEmpty || allowEmptyTranscript else {
            throw DictationError.transcription("No transcript was produced.")
        }

        return cleaned
    }

    private static func resolveModelBundle(from selectedModelPath: String) throws -> ResolvedModelBundle {
        let selectedURL = URL(fileURLWithPath: selectedModelPath)
        let candidateDirectory = selectedURL.hasDirectoryPath
            ? selectedURL
            : selectedURL.deletingLastPathComponent()

        let transducerBundle = TransducerModelBundle(
            directory: candidateDirectory,
            tokensFileName: "tokens.txt",
            encoderFileName: "encoder.onnx",
            decoderFileName: "decoder.onnx",
            joinerFileName: "joiner.onnx"
        )

        if transducerBundleLooksValid(transducerBundle) {
            return .transducer(transducerBundle)
        }

        if let whisperBundle = resolveWhisperModelBundle(
            selectedURL: selectedURL,
            candidateDirectory: candidateDirectory
        ) {
            return .whisper(whisperBundle)
        }

        throw DictationError.transcription(
            "Selected model is not a supported sherpa-onnx bundle in \(candidateDirectory.path)"
        )
    }

    private static func transducerBundleLooksValid(_ bundle: TransducerModelBundle) -> Bool {
        let fileManager = FileManager.default
        let requiredFiles = [
            bundle.tokensFileName,
            bundle.encoderFileName,
            bundle.decoderFileName,
            bundle.joinerFileName,
            "encoder.weights"
        ]

        for file in requiredFiles {
            let path = bundle.directory.appendingPathComponent(file).path
            if !fileManager.fileExists(atPath: path) {
                return false
            }
        }

        return true
    }

    private static func resolveWhisperModelBundle(selectedURL: URL, candidateDirectory: URL) -> WhisperModelBundle? {
        let fileManager = FileManager.default
        guard let files = regularFiles(in: candidateDirectory, fileManager: fileManager) else { return nil }
        guard let tokensURL = pickWhisperTokensFile(files: files) else { return nil }
        guard let decoderURL = pickWhisperModelFile(files: files, keyword: "decoder") else { return nil }

        let selectedName = selectedURL.lastPathComponent.lowercased()
        let encoderFromSelection: URL?
        if selectedName.contains("encoder"), selectedURL.pathExtension.lowercased() == "onnx" {
            encoderFromSelection = files.first(where: { $0.standardizedFileURL.path == selectedURL.standardizedFileURL.path })
        } else {
            encoderFromSelection = nil
        }
        guard let encoderURL = encoderFromSelection ?? pickWhisperModelFile(files: files, keyword: "encoder") else {
            return nil
        }

        let encoderPrefix = prefix(before: "-encoder", in: encoderURL.deletingPathExtension().lastPathComponent)
        let decoderPrefix = prefix(before: "-decoder", in: decoderURL.deletingPathExtension().lastPathComponent)
        let tokensPrefix = prefix(before: "-tokens", in: tokensURL.deletingPathExtension().lastPathComponent)

        let basePrefix = [encoderPrefix, decoderPrefix, tokensPrefix]
            .compactMap { $0 }
            .first

        if let basePrefix {
            if let encoderPrefix, encoderPrefix != basePrefix { return nil }
            if let decoderPrefix, decoderPrefix != basePrefix { return nil }
            if let tokensPrefix, tokensPrefix != basePrefix { return nil }
        }

        return WhisperModelBundle(
            directory: candidateDirectory,
            tokensFileName: tokensURL.lastPathComponent,
            encoderFileName: encoderURL.lastPathComponent,
            decoderFileName: decoderURL.lastPathComponent
        )
    }

    private static func resolveBinaryPath(customBinaryPath: String?) -> String? {
        let fileManager = FileManager.default
        let fromSettings = customBinaryPath?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let fromSettings, !fromSettings.isEmpty, fileManager.isExecutableFile(atPath: fromSettings) {
            return fromSettings
        }

        if let envPath = ProcessInfo.processInfo.environment["SHERPA_ONNX_BIN"],
           fileManager.isExecutableFile(atPath: envPath) {
            return envPath
        }

        for candidate in candidatePaths() where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        return nil
    }

    private static func sherpaArguments(
        modelBundle: ResolvedModelBundle,
        audioPath: String,
        language: String,
        threadCount: Int
    ) -> [String] {
        switch modelBundle {
        case let .transducer(bundle):
            return [
                "--tokens=./\(bundle.tokensFileName)",
                "--encoder=./\(bundle.encoderFileName)",
                "--decoder=./\(bundle.decoderFileName)",
                "--joiner=./\(bundle.joinerFileName)",
                "--num-threads=\(normalizedThreadCount(threadCount))",
                "--decoding-method=greedy_search",
                audioPath
            ]
        case let .whisper(bundle):
            var args: [String] = [
                "--tokens=./\(bundle.tokensFileName)",
                "--whisper-encoder=./\(bundle.encoderFileName)",
                "--whisper-decoder=./\(bundle.decoderFileName)",
                "--num-threads=\(normalizedThreadCount(threadCount))"
            ]
            let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedLanguage.isEmpty {
                args.append("--whisper-language=\(normalizedLanguage)")
            }
            args.append(audioPath)
            return args
        }
    }

    private static func extractTranscript(stdout: String, stderr: String) -> String {
        let lines = [stdout, stderr]
            .joined(separator: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() {
            guard line.hasPrefix("{"),
                  line.hasSuffix("}"),
                  line.contains("\"text\"") else {
                continue
            }

            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = obj["text"] as? String {
                return text
            }
        }

        for line in lines.reversed() {
            if let range = line.range(of: "result is:", options: .caseInsensitive) {
                let candidate = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    return candidate
                }
            }
        }

        return ""
    }

    private static func cleanTranscript(_ transcript: String, autoPunctuation: Bool) -> String {
        let trimmed = transcript
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if autoPunctuation {
            return trimmed
        }

        let punctuation = CharacterSet(charactersIn: ".,!?;:\"'()[]{}")
        let withoutPunctuation = trimmed.unicodeScalars
            .map { punctuation.contains($0) ? " " : String($0) }
            .joined()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return withoutPunctuation
    }

    private static func normalizedThreadCount(_ value: Int) -> Int {
        max(1, min(value, 128))
    }

    private static func captureOutput(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) -> (stdout: String, stderr: String) {
        let stdoutBuffer = ThreadSafeDataBuffer()
        let stderrBuffer = ThreadSafeDataBuffer()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { handle in
            stdoutBuffer.append(handle.availableData)
        }
        stderrHandle.readabilityHandler = { handle in
            stderrBuffer.append(handle.availableData)
        }

        process.waitUntilExit()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil

        stdoutBuffer.append(stdoutHandle.readDataToEndOfFile())
        stderrBuffer.append(stderrHandle.readDataToEndOfFile())

        stdoutHandle.closeFile()
        stderrHandle.closeFile()

        return (stdoutBuffer.trimmedUTF8String(), stderrBuffer.trimmedUTF8String())
    }

    private static func candidatePaths() -> [String] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let cwd = fileManager.currentDirectoryPath
        let bundlePath = Bundle.main.bundlePath

        return [
            "\(bundlePath)/Contents/MacOS/sherpa-onnx-offline",
            "\(bundlePath)/Contents/Resources/sherpa-onnx-offline",
            "\(cwd)/sherpa-onnx-offline",
            "\(cwd)/tools/sherpa-onnx/bin/sherpa-onnx-offline",
            "\(home)/whispr/sherpa-onnx-offline",
            "\(home)/whispr/tools/sherpa-onnx/bin/sherpa-onnx-offline",
            "/opt/homebrew/bin/sherpa-onnx-offline",
            "/usr/local/bin/sherpa-onnx-offline"
        ]
    }

    private static func regularFiles(in directory: URL, fileManager: FileManager) -> [URL]? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.append(fileURL)
        }
        return files
    }

    private static func pickWhisperModelFile(files: [URL], keyword: String) -> URL? {
        let candidates = files.filter {
            let name = $0.lastPathComponent.lowercased()
            return $0.pathExtension.lowercased() == "onnx"
                && name.contains(keyword)
                && !name.contains(".weights")
                && !name.hasSuffix(".weights.onnx")
        }
        guard !candidates.isEmpty else { return nil }

        return candidates.sorted {
            let lhsName = $0.lastPathComponent.lowercased()
            let rhsName = $1.lastPathComponent.lowercased()
            let lhsScore = whisperFilePriority(name: lhsName)
            let rhsScore = whisperFilePriority(name: rhsName)
            if lhsScore == rhsScore {
                return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
            }
            return lhsScore < rhsScore
        }.first
    }

    private static func pickWhisperTokensFile(files: [URL]) -> URL? {
        let candidates = files.filter {
            $0.pathExtension.lowercased() == "txt"
                && $0.lastPathComponent.lowercased().contains("tokens")
        }
        guard !candidates.isEmpty else { return nil }

        return candidates.sorted {
            let lhsName = $0.lastPathComponent.lowercased()
            let rhsName = $1.lastPathComponent.lowercased()
            let lhsScore = lhsName == "tokens.txt" ? 0 : 1
            let rhsScore = rhsName == "tokens.txt" ? 0 : 1
            if lhsScore == rhsScore {
                return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
            }
            return lhsScore < rhsScore
        }.first
    }

    private static func whisperFilePriority(name: String) -> Int {
        if name.contains(".int8.") || name.contains("-int8.") {
            return 0
        }
        if name.hasSuffix(".onnx") {
            return 1
        }
        return 2
    }

    private static func prefix(before token: String, in value: String) -> String? {
        guard let range = value.range(of: token, options: .caseInsensitive) else { return nil }
        return String(value[..<range.lowerBound]).lowercased()
    }
}
