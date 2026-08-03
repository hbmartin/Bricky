import CryptoKit
import Foundation

enum InstructionImportSource: Sendable {
    case file(URL)
    case folder(URL, rootRelativePath: String? = nil)
}

protocol InstructionModelImporting: Sendable {
    func `import`(source: InstructionImportSource) async throws -> InstructionPlan
}

actor InstructionModelImporter: InstructionModelImporting {
    static let namespace = "BrickyInstructionsV1"

    private let fileManager: FileManager
    private let parser: LDrawInstructionParser
    private let builder: InstructionPlanBuilder

    init(
        fileManager: FileManager = .default,
        parser: LDrawInstructionParser = .init(),
        builder: InstructionPlanBuilder = .init()
    ) {
        self.fileManager = fileManager
        self.parser = parser
        self.builder = builder
    }

    func `import`(source: InstructionImportSource) async throws -> InstructionPlan {
        try Task.checkCancellation()
        let accessURL: URL = switch source {
        case let .file(url): url
        case let .folder(url, _): url
        }
        let hasSecurityAccess = accessURL.startAccessingSecurityScopedResource()
        defer { if hasSecurityAccess { accessURL.stopAccessingSecurityScopedResource() } }

        let prepared = try prepare(source)
        let identity = Self.identity(of: prepared.files)
        let storageRoot = try Self.applicationSupportRoot(fileManager: fileManager)
        let publishedDirectory = storageRoot.appendingPathComponent("Models/\(identity)", isDirectory: true)
        let planURL = publishedDirectory.appendingPathComponent("plan.json")

        if fileManager.fileExists(atPath: planURL.path) {
            return try JSONDecoder.bricky.decode(InstructionPlan.self, from: Data(contentsOf: planURL))
        }

        let sourceFiles = prepared.files.compactMap { file -> InstructionSourceFile? in
            let ext = (file.relativePath as NSString).pathExtension.lowercased()
            return ["mpd", "ldr"].contains(ext) ? InstructionSourceFile(relativePath: file.relativePath, data: file.data) : nil
        }
        let document = try parser.parse(files: sourceFiles, rootRelativePath: prepared.rootRelativePath)
        guard !document.hasErrors else {
            let summary = document.diagnostics.filter { $0.severity == .error }.map(\.message).joined(separator: "\n")
            throw InstructionImportError.invalidDocument(summary)
        }
        let title = URL(fileURLWithPath: prepared.rootRelativePath).deletingPathExtension().lastPathComponent
        let plan = try builder.build(
            document: document,
            title: title,
            sourceFilename: prepared.rootRelativePath,
            sourceSHA256: identity
        )

        // Build the complete import in a sibling staging directory, then publish
        // with one rename. A failed parse or copy is never visible to the library.
        let stagingRoot = storageRoot.appendingPathComponent("Staging", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let stage = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stage) }

        let stagedSource = stage.appendingPathComponent("Source", isDirectory: true)
        // Materialize embedded MPD sections beside the original source. The
        // parser continues to treat the MPD as authoritative, while the shared
        // geometry engine can resolve embedded custom parts through the same
        // safe file lookup it uses for folder imports.
        for file in try storageFiles(from: prepared.files) {
            try Task.checkCancellation()
            let destination = stagedSource.appendingPathComponent(file.relativePath)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: destination, options: .atomic)
        }
        try JSONEncoder.bricky.encode(plan).write(to: stage.appendingPathComponent("plan.json"), options: .atomic)
        try fileManager.createDirectory(at: publishedDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: stage, to: publishedDirectory)
        return plan
    }

    private struct PreparedFile {
        let relativePath: String
        let data: Data
    }

    private struct PreparedImport {
        let rootRelativePath: String
        let files: [PreparedFile]
    }

    private func prepare(_ source: InstructionImportSource) throws -> PreparedImport {
        switch source {
        case let .file(url):
            let rootName = try LDrawInstructionParser.normalizeReference(url.lastPathComponent)
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= InstructionLimits.maximumSourceBytes else { throw InstructionImportError.sourceTooLarge }
            let available = [rootName: PreparedFile(relativePath: rootName, data: data)]
            let closure = try sourceClosure(root: rootName, available: available)
            return PreparedImport(rootRelativePath: rootName, files: closure)

        case let .folder(url, selectedRoot):
            let available = try files(beneath: url)
            let root: String
            if let selectedRoot {
                root = try LDrawInstructionParser.normalizeReference(selectedRoot)
                guard available[root] != nil else {
                    throw InstructionImportError.invalidDocument("The selected root file is not inside the imported folder.")
                }
            } else {
                let candidates = try rootCandidates(in: available)
                guard candidates.count == 1 else {
                    throw InstructionImportError.rootSelectionRequired(candidates)
                }
                root = candidates[0]
            }
            return PreparedImport(rootRelativePath: root, files: try sourceClosure(root: root, available: available))
        }
    }

    private func files(beneath baseURL: URL) throws -> [String: PreparedFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: baseURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw InstructionImportError.unsupportedSource }

        var result: [String: PreparedFile] = [:]
        var totalBytes = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            let path = String(url.path.dropFirst(baseURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if values.isSymbolicLink == true { throw InstructionImportError.unsafePath(path) }
            guard values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard ["mpd", "ldr", "dat"].contains(ext) else { continue }
            let normalized = try LDrawInstructionParser.normalizeReference(path)
            guard result[normalized] == nil else { throw InstructionImportError.duplicateSection(normalized) }
            let byteCount = values.fileSize ?? 0
            totalBytes += byteCount
            guard totalBytes <= InstructionLimits.maximumSourceBytes else { throw InstructionImportError.sourceTooLarge }
            result[normalized] = PreparedFile(relativePath: normalized, data: try Data(contentsOf: url, options: .mappedIfSafe))
        }
        return result
    }

    private func rootCandidates(in files: [String: PreparedFile]) throws -> [String] {
        let documents = files.keys.filter { ["mpd", "ldr"].contains(($0 as NSString).pathExtension.lowercased()) }
        let referenced = Set(documents.flatMap { references(in: files[$0]!.data) }.filter { files[$0] != nil })
        let roots = documents.filter { !referenced.contains($0) }.sorted()
        return roots.isEmpty ? documents.sorted() : roots
    }

    private func sourceClosure(root: String, available: [String: PreparedFile]) throws -> [PreparedFile] {
        guard available[root] != nil else { throw InstructionImportError.unsupportedSource }
        var result: [String: PreparedFile] = [:]
        var pending = [root]
        while let name = pending.popLast() {
            guard result[name] == nil, let file = available[name] else { continue }
            result[name] = file
            for reference in references(in: file.data) where available[reference] != nil && result[reference] == nil {
                pending.append(reference)
            }
        }
        return result.values.sorted { $0.relativePath < $1.relativePath }
    }

    private func storageFiles(from sourceFiles: [PreparedFile]) throws -> [PreparedFile] {
        var filesByPath = Dictionary(uniqueKeysWithValues: sourceFiles.map { ($0.relativePath, $0) })
        for source in sourceFiles where ["mpd", "ldr"].contains((source.relativePath as NSString).pathExtension.lowercased()) {
            for embedded in try embeddedSections(in: source) where filesByPath[embedded.relativePath] == nil {
                filesByPath[embedded.relativePath] = embedded
            }
        }
        return filesByPath.values.sorted { $0.relativePath < $1.relativePath }
    }

    private func embeddedSections(in source: PreparedFile) throws -> [PreparedFile] {
        guard let text = String(data: source.data, encoding: .utf8) ?? String(data: source.data, encoding: .isoLatin1) else {
            return []
        }
        var result: [PreparedFile] = []
        var currentName: String?
        var currentLines: [String] = []

        func publish() {
            guard let currentName else { return }
            let data = Data((currentLines.joined(separator: "\n") + "\n").utf8)
            result.append(PreparedFile(relativePath: currentName, data: data))
            currentLines.removeAll(keepingCapacity: true)
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let tokens = rawLine.trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
            if tokens.count >= 3, tokens[0] == "0", tokens[1].uppercased() == "FILE" {
                publish()
                currentName = try LDrawInstructionParser.normalizeReference(tokens.dropFirst(2).joined(separator: " "))
            } else if tokens.count >= 2, tokens[0] == "0", tokens[1].uppercased() == "NOFILE" {
                publish()
                currentName = nil
            } else if currentName != nil {
                currentLines.append(rawLine)
            }
        }
        publish()
        return result
    }

    private func references(in data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.count >= 15, tokens[0] == "1" else { return nil }
            return try? LDrawInstructionParser.normalizeReference(tokens.dropFirst(14).joined(separator: " "))
        }
    }

    private static func identity(of files: [PreparedFile]) -> String {
        var hasher = SHA256()
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            hasher.update(data: Data(file.relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: file.data)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func applicationSupportRoot(fileManager: FileManager = .default) throws -> URL {
        let root = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(namespace, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = false
        var mutableRoot = root
        try mutableRoot.setResourceValues(resourceValues)
        return root
    }
}

private extension JSONEncoder {
    static var bricky: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var bricky: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
