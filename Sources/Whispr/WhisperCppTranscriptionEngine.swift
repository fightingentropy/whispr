import Foundation

final class WhisperCppTranscriptionEngine: TranscriptionEngine {
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

    var threadCount: Int

    init(threadCount: Int = 4) {
        self.threadCount = Self.normalizedThreadCount(threadCount)
    }

    func transcribe(
        audioData: Data,
        modelPath: String,
        language: String,
        autoPunctuation: Bool
    ) async throws -> String {
        let threadCount = Self.normalizedThreadCount(self.threadCount)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let transcript = try Self.runWhisperCLI(
                        audioData: audioData,
                        modelPath: modelPath,
                        language: language,
                        autoPunctuation: autoPunctuation,
                        threadCount: threadCount
                    )
                    continuation.resume(returning: transcript)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func resolveBinaryPath() -> String? {
        Self.resolveBinaryPath()
    }

    private static func runWhisperCLI(
        audioData: Data,
        modelPath: String,
        language: String,
        autoPunctuation: Bool,
        threadCount: Int
    ) throws -> String {
        let fileManager = FileManager.default

        guard let binaryPath = resolveBinaryPath() else {
            throw DictationError.missingASRRuntime
        }

        guard fileManager.fileExists(atPath: modelPath) else {
            throw DictationError.transcription("Whisper model file not found at \(modelPath)")
        }

        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("whispr-whisper-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let wavPath = tempDir.appendingPathComponent("input.wav")
        try audioData.write(to: wavPath, options: .atomic)

        let outputPrefix = tempDir.appendingPathComponent("result")
        let outputJSONPath = outputPrefix.appendingPathExtension("json")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = whisperArguments(
            modelPath: modelPath,
            audioPath: wavPath.path,
            language: language,
            outputPrefix: outputPrefix.path,
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
                "Unable to execute whisper-cli at \(binaryPath): \(error.localizedDescription)"
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
                "whisper-cli exited with code \(process.terminationStatus). \(combinedOutput)"
            )
        }

        guard fileManager.fileExists(atPath: outputJSONPath.path) else {
            throw DictationError.transcription("whisper-cli did not produce JSON output.")
        }

        let rawTranscript = try extractTranscript(from: outputJSONPath)
        let cleaned = cleanTranscript(rawTranscript, autoPunctuation: autoPunctuation)
        guard !cleaned.isEmpty else {
            throw DictationError.transcription("No transcript was produced.")
        }

        return cleaned
    }

    private static func resolveBinaryPath() -> String? {
        let fileManager = FileManager.default

        if let envPath = ProcessInfo.processInfo.environment["WHISPER_CPP_BIN"],
           fileManager.isExecutableFile(atPath: envPath) {
            return envPath
        }

        for candidate in candidatePaths() where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        return nil
    }

    private static func whisperArguments(
        modelPath: String,
        audioPath: String,
        language: String,
        outputPrefix: String,
        threadCount: Int
    ) -> [String] {
        var args = [
            "-m", modelPath,
            "-f", audioPath,
            "-t", "\(normalizedThreadCount(threadCount))",
            "-oj",
            "-of", outputPrefix,
            "-np"
        ]

        let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedLanguage.isEmpty {
            args.append(contentsOf: ["-l", normalizedLanguage])
        }

        return args
    }

    private static func extractTranscript(from outputJSONPath: URL) throws -> String {
        let data = try Data(contentsOf: outputJSONPath)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }

        if let items = root["transcription"] as? [[String: Any]] {
            let joined = items
                .compactMap { $0["text"] as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                return joined
            }
        }

        if let text = root["text"] as? String {
            return text
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
            "\(bundlePath)/Contents/MacOS/whisper-cli",
            "\(bundlePath)/Contents/Resources/whisper-cli",
            "\(cwd)/whisper-cli",
            "\(cwd)/whisper.cpp/build/bin/whisper-cli",
            "\(home)/whispr/whisper-cli",
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli"
        ]
    }
}
