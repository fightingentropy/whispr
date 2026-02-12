import Foundation

final class ModelStore: ObservableObject {
    @Published private(set) var availableModels: [TranscriptionModel] = []
    @Published var selectedModelPath: String?

    private let fileManager: FileManager
    private let searchDirectories: [URL]
    private let discoveryQueue = DispatchQueue(label: "whispr.models.discovery", qos: .userInitiated)

    init(
        fileManager: FileManager = .default,
        searchDirectories: [URL] = ModelStore.defaultSearchDirectories()
    ) {
        self.fileManager = fileManager
        self.searchDirectories = searchDirectories
    }

    var selectedModel: TranscriptionModel? {
        guard let selectedModelPath else { return availableModels.first }
        return availableModels.first(where: { $0.path.path == selectedModelPath })
    }

    func reloadModels() {
        applyDiscoveredModels(discoverModels())
    }

    func reloadModelsInBackground(completion: (() -> Void)? = nil) {
        discoveryQueue.async { [weak self] in
            guard let self else { return }
            let discovered = self.discoverModels()
            DispatchQueue.main.async {
                self.applyDiscoveredModels(discovered)
                completion?()
            }
        }
    }

    func selectModel(path: String?) {
        guard let path else {
            selectedModelPath = nil
            return
        }
        if availableModels.isEmpty || availableModels.contains(where: { $0.path.path == path }) {
            selectedModelPath = path
        }
    }

    static func defaultSearchDirectories(fileManager: FileManager = .default) -> [URL] {
        let currentDir = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let modelsFolder = currentDir.appending(path: "models", directoryHint: .isDirectory)
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let homeWhispr = homeDir.appending(path: "whispr", directoryHint: .isDirectory)
        let homeWhisprModels = homeWhispr.appending(path: "models", directoryHint: .isDirectory)
        let executableDir = URL(fileURLWithPath: CommandLine.arguments.first ?? currentDir.path, isDirectory: false)
            .deletingLastPathComponent()
        let executableModelsFolder = executableDir
            .appending(path: "../Resources/models", directoryHint: .isDirectory)
            .standardizedFileURL

        let bundledModelsFolder = Bundle.main.resourceURL?
            .appending(path: "models", directoryHint: .isDirectory)
        let appSupportModelsFolder = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Whispr/Models", directoryHint: .isDirectory)

        var directories = [
            modelsFolder,
            executableModelsFolder,
            homeWhisprModels,
            homeWhispr
        ]
        if let appSupportModelsFolder {
            directories.append(appSupportModelsFolder)
        }
        if let bundledModelsFolder {
            directories.append(bundledModelsFolder)
        }
        return Array(Set(directories))
    }

    private func discoverModels() -> [TranscriptionModel] {
        let discovered = searchDirectories
            .filter { fileManager.fileExists(atPath: $0.path) }
            .flatMap(discoverModels(in:))

        let dedupedByPath = Dictionary(
            discovered.map { ($0.path.path, $0) },
            uniquingKeysWith: { first, second in
                first.sizeBytes <= second.sizeBytes ? first : second
            }
        )

        return dedupedByPath.values.sorted {
            if $0.sizeBytes == $1.sizeBytes {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.sizeBytes > $1.sizeBytes
        }
    }

    private func applyDiscoveredModels(_ discovered: [TranscriptionModel]) {
        availableModels = discovered
        let preferredPath = preferredDefaultModel(in: availableModels)?.path.path

        if let selectedModelPath, availableModels.contains(where: { $0.path.path == selectedModelPath }) {
            if shouldPromotePreferredDefault(currentSelectionPath: selectedModelPath, preferredPath: preferredPath) {
                self.selectedModelPath = preferredPath
            }
            return
        }
        selectedModelPath = preferredPath
    }

    private func preferredDefaultModel(in models: [TranscriptionModel]) -> TranscriptionModel? {
        let lowercasedName: (TranscriptionModel) -> String = { model in
            model.displayName.lowercased()
        }

        if let distilWhisper = models.first(where: {
            $0.kind == .whisper && lowercasedName($0).contains("distil-large-v3")
        }) {
            return distilWhisper
        }

        if let whisperTurbo = models.first(where: {
            $0.kind == .whisper && lowercasedName($0).contains("turbo")
        }) {
            return whisperTurbo
        }

        if let parakeet = models.first(where: {
            $0.kind == .transducer && lowercasedName($0).contains("parakeet-tdt-0.6b-v2")
        }) {
            return parakeet
        }

        return models.first
    }

    private func shouldPromotePreferredDefault(currentSelectionPath: String, preferredPath: String?) -> Bool {
        guard let preferredPath else { return false }
        guard preferredPath != currentSelectionPath else { return false }

        let currentName = URL(fileURLWithPath: currentSelectionPath).lastPathComponent.lowercased()
        let legacyDefaults: Set<String> = ["ggml-large-v3-turbo-q8_0.bin", "ggml-large-v3-turbo.bin", "ggml-large-v3.bin", "parakeet-tdt-0.6b-v2.nemo"]
        return legacyDefaults.contains(currentName)
    }

    private func discoverModels(in rootDirectory: URL) -> [TranscriptionModel] {
        let candidateDirectories = discoverCandidateDirectories(in: rootDirectory)
        var discovered: [TranscriptionModel] = []

        for directory in candidateDirectories {
            if let transducerModel = transducerModel(in: directory) {
                discovered.append(transducerModel)
                continue
            }
            if let whisperCppModel = whisperCppModel(in: directory) {
                discovered.append(whisperCppModel)
            }
        }

        return discovered
    }

    private func discoverCandidateDirectories(in rootDirectory: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var directories = Set<URL>([rootDirectory.standardizedFileURL])
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            directories.insert(url.standardizedFileURL)
        }

        return Array(directories)
    }

    private func transducerModel(in directory: URL) -> TranscriptionModel? {
        let requiredFiles = [
            "tokens.txt",
            "encoder.onnx",
            "encoder.weights",
            "decoder.onnx",
            "joiner.onnx"
        ]

        let hasAllRequiredFiles = requiredFiles.allSatisfy { fileName in
            fileManager.fileExists(atPath: directory.appendingPathComponent(fileName).path)
        }

        guard hasAllRequiredFiles else { return nil }

        let encoderPath = directory.appendingPathComponent("encoder.onnx")
        return TranscriptionModel(
            path: encoderPath,
            sizeBytes: bundleSize(at: directory),
            kind: .transducer
        )
    }

    private func whisperCppModel(in directory: URL) -> TranscriptionModel? {
        guard let files = regularFiles(in: directory), !files.isEmpty else { return nil }

        let supported = files.filter { file in
            let name = file.lastPathComponent.lowercased()
            guard file.pathExtension.lowercased() == "bin", name.hasPrefix("ggml-") else { return false }
            return name.contains("distil-large-v3") || name.contains("large-v3-turbo")
        }

        guard !supported.isEmpty else { return nil }

        let selectedModelFile = supported.sorted {
            let lhsName = $0.lastPathComponent.lowercased()
            let rhsName = $1.lastPathComponent.lowercased()
            let lhsScore = Self.whisperCppModelPriority(name: lhsName)
            let rhsScore = Self.whisperCppModelPriority(name: rhsName)
            if lhsScore == rhsScore {
                return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
            }
            return lhsScore < rhsScore
        }.first

        guard let selectedModelFile else { return nil }

        let fileSize = modelFileSize(at: selectedModelFile)
        return TranscriptionModel(
            path: selectedModelFile,
            sizeBytes: max(fileSize, bundleSize(at: directory)),
            kind: .whisper
        )
    }

    private func modelFileSize(at fileURL: URL) -> Int64 {
        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { return 0 }
        return Int64(values?.fileSize ?? 0)
    }

    private static func whisperCppModelPriority(name: String) -> Int {
        if name.contains("-q8_0") {
            return 0
        }
        if name.contains("-q5_0") || name.contains("-q5_1") {
            return 1
        }
        return 2
    }

    private func regularFiles(in directory: URL) -> [URL]? {
        let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        guard let entries else { return nil }

        return entries.filter { entry in
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
    }

    private func bundleSize(at directory: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return 0
        }

        var totalBytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            totalBytes += Int64(values?.fileSize ?? 0)
        }

        return totalBytes
    }
}
