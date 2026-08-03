import Foundation

struct InstructionSourceFile: Sendable {
    let relativePath: String
    let data: Data
}

enum InstructionImportError: LocalizedError, Equatable {
    case unsupportedSource
    case sourceTooLarge
    case lineTooLong(file: String, line: Int)
    case unsafePath(String)
    case duplicateSection(String)
    case noAuthoredSteps
    case unresolvedReference(String, section: String, line: Int)
    case rootSelectionRequired([String])
    case cyclicReference([String])
    case limitExceeded(String)
    case invalidDocument(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSource:
            return "Choose an MPD, a stepped LDR, or a folder containing those files."
        case .sourceTooLarge:
            return "The instruction source is larger than 100 MB."
        case let .lineTooLong(file, line):
            return "\(file) contains a line longer than 64 KB at line \(line)."
        case let .unsafePath(path):
            return "The reference ‘\(path)’ is absolute or escapes the imported folder."
        case let .duplicateSection(section):
            return "The instruction source defines ‘\(section)’ more than once."
        case .noAuthoredSteps:
            return "This model has no STEP or ROTSTEP boundaries. Bricky never invents instructions."
        case let .unresolvedReference(reference, section, line):
            return "‘\(section)’ references missing custom model ‘\(reference)’ at line \(line)."
        case let .rootSelectionRequired(candidates):
            return "Choose the root model: \(candidates.joined(separator: ", "))."
        case let .cyclicReference(path):
            return "Cyclic submodel reference: \(path.joined(separator: " → "))."
        case let .limitExceeded(message), let .invalidDocument(message):
            return message
        }
    }
}

/// Native, deterministic parser for authored LDraw instructions.
///
/// pyldraw3 schema-v1 is the development-time semantic oracle. This parser is
/// deliberately independent so Python and GPL code never enter the app bundle.
struct LDrawInstructionParser {
    static let partPackVersion = "2026-07"

    private struct RawSection {
        let name: String
        let normalizedName: String
        let lines: [(number: Int, text: String)]
    }

    private struct BOMKey: Hashable {
        let reference: String
        let colorCode: Int
    }

    private struct ParsedSection {
        let section: InstructionSection
        let diagnostics: [InstructionDiagnostic]
    }

    func parse(files: [InstructionSourceFile], rootRelativePath: String) throws -> InstructionDocument {
        guard !files.isEmpty else { throw InstructionImportError.unsupportedSource }
        let totalBytes = files.reduce(0) { $0 + $1.data.count }
        guard totalBytes <= InstructionLimits.maximumSourceBytes else {
            throw InstructionImportError.sourceTooLarge
        }

        let normalizedRoot = try Self.normalizeReference(rootRelativePath)
        var rawSections: [RawSection] = []
        for file in files.sorted(by: { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }) {
            rawSections.append(contentsOf: try split(file: file))
        }

        var seen = Set<String>()
        for section in rawSections where !seen.insert(section.normalizedName).inserted {
            throw InstructionImportError.duplicateSection(section.name)
        }

        // In an MPD the first FILE section is authoritative. For a folder, the
        // selected root filename is authoritative.
        let rootName: String
        if rawSections.contains(where: { $0.normalizedName == normalizedRoot }) {
            rootName = normalizedRoot
        } else if let first = rawSections.first {
            rootName = first.normalizedName
        } else {
            throw InstructionImportError.invalidDocument("The source has no LDraw sections.")
        }

        let embeddedNames = Set(rawSections.map(\.normalizedName))
        let parsed = try rawSections.map {
            try parse(section: $0, isRoot: $0.normalizedName == rootName, embeddedNames: embeddedNames)
        }
        var sections = parsed.map(\.section)
        var diagnostics = parsed.flatMap(\.diagnostics)

        guard let root = sections.first(where: { $0.normalizedName == rootName }),
              root.hasAuthoredBoundaries else {
            throw InstructionImportError.noAuthoredSteps
        }

        let graph = Dictionary(uniqueKeysWithValues: sections.map { ($0.normalizedName, $0.references.filter(embeddedNames.contains)) })
        let reachable = try reachableSections(from: rootName, graph: graph)
        // pyldraw3 schema-v1 exposes authored instruction sections. Embedded
        // geometry-only FILE sections remain resolvable atomic custom parts,
        // but are not promoted to instruction sections or orphan warnings.
        let buildableNames = Set(sections.filter(\.hasAuthoredBoundaries).map(\.normalizedName))
        let orphans = buildableNames.subtracting(reachable).sorted()
        for orphan in orphans {
            diagnostics.append(.init(
                severity: .warning,
                code: "orphan-section",
                message: "Embedded section is not reachable from the root model.",
                section: orphan
            ))
        }

        // Root-first reachable sections, then stable orphan order.
        sections = sections.filter(\.hasAuthoredBoundaries).map { section in
            InstructionSection(
                name: section.name,
                normalizedName: section.normalizedName,
                isRoot: section.isRoot,
                hasAuthoredBoundaries: true,
                references: section.references.filter(buildableNames.contains),
                steps: section.steps
            )
        }
        sections.sort {
            let lhsRank = $0.normalizedName == rootName ? 0 : (reachable.contains($0.normalizedName) ? 1 : 2)
            let rhsRank = $1.normalizedName == rootName ? 0 : (reachable.contains($1.normalizedName) ? 1 : 2)
            return lhsRank == rhsRank ? $0.normalizedName < $1.normalizedName : lhsRank < rhsRank
        }

        // The bill of materials counts every expanded instance: a stepped
        // submodel placed N times contributes N copies of its parts. Instance
        // counts are a DP over the (cycle-checked) reachable section DAG.
        let sectionsByName = Dictionary(uniqueKeysWithValues: sections.map { ($0.normalizedName, $0) })
        var instanceCounts: [String: Int] = [rootName: 1]
        for name in topologicalOrder(from: rootName, sectionsByName: sectionsByName, buildableNames: buildableNames) {
            let count = instanceCounts[name, default: 0]
            guard count > 0, let section = sectionsByName[name] else { continue }
            for placement in section.steps.flatMap(\.directPlacements) {
                let child = Self.normalizedName(placement.partReference)
                guard buildableNames.contains(child) else { continue }
                let (updated, overflow) = instanceCounts[child, default: 0].addingReportingOverflow(count)
                guard !overflow, updated <= InstructionLimits.maximumPlacements else {
                    throw InstructionImportError.limitExceeded("The expanded guide exceeds 50,000 placements.")
                }
                instanceCounts[child] = updated
            }
        }

        var quantities: [BOMKey: Int] = [:]
        for section in sections where reachable.contains(section.normalizedName) {
            let multiplier = instanceCounts[section.normalizedName, default: 0]
            guard multiplier > 0 else { continue }
            for placement in section.steps.flatMap(\.directPlacements)
            where !buildableNames.contains(Self.normalizedName(placement.partReference)) {
                let key = BOMKey(reference: Self.normalizedName(placement.partReference), colorCode: placement.colorCode)
                let (updated, overflow) = quantities[key, default: 0].addingReportingOverflow(multiplier)
                guard !overflow, updated <= InstructionLimits.maximumPlacements else {
                    throw InstructionImportError.limitExceeded("The expanded guide exceeds 50,000 placements.")
                }
                quantities[key] = updated
            }
        }
        let bom = quantities
            .map { key, quantity in
                BOMEntry(partReference: key.reference, colorCode: key.colorCode, quantity: quantity)
            }
            .sorted { ($0.partReference, $0.colorCode) < ($1.partReference, $1.colorCode) }

        return InstructionDocument(
            rootSectionName: rootName,
            sections: sections,
            orphanSectionNames: orphans,
            diagnostics: diagnostics,
            partPackVersion: Self.partPackVersion,
            billOfMaterials: bom,
            bounds: nil
        )
    }

    private func split(file: InstructionSourceFile) throws -> [RawSection] {
        let normalizedPath = try Self.normalizeReference(file.relativePath)
        guard ["mpd", "ldr"].contains((normalizedPath as NSString).pathExtension.lowercased()) else {
            return []
        }
        guard let text = String(data: file.data, encoding: .utf8) ?? String(data: file.data, encoding: .isoLatin1) else {
            throw InstructionImportError.invalidDocument("\(file.relativePath) is not UTF-8 or ISO Latin-1 text.")
        }
        var sourceLines = Self.splitLines(text)
        while sourceLines.last?.isEmpty == true { sourceLines.removeLast() }
        for (offset, line) in sourceLines.enumerated() where line.lengthOfBytes(using: .utf8) > InstructionLimits.maximumLineBytes {
            throw InstructionImportError.lineTooLong(file: file.relativePath, line: offset + 1)
        }

        var result: [RawSection] = []
        var currentName: String?
        var currentLines: [(Int, String)] = []
        var sawFileDirective = false
        var createdImplicitSection = false

        func publish() {
            guard let name = currentName else { return }
            result.append(RawSection(name: name, normalizedName: Self.normalizedName(name), lines: currentLines))
            currentLines.removeAll(keepingCapacity: true)
        }

        for (offset, rawLine) in sourceLines.enumerated() {
            let lineNumber = offset + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            if tokens.count >= 3, tokens[0] == "0", tokens[1].uppercased() == "FILE" {
                publish()
                let name = tokens.dropFirst(2).joined(separator: " ")
                _ = try Self.normalizeReference(name)
                currentName = name
                sawFileDirective = true
                continue
            }
            if tokens.count >= 2, tokens[0] == "0", tokens[1].uppercased() == "NOFILE" {
                publish()
                currentName = nil
                continue
            }
            if currentName == nil, !sawFileDirective {
                currentName = normalizedPath
                createdImplicitSection = true
            }
            if currentName != nil {
                currentLines.append((lineNumber, rawLine))
            }
        }
        publish()
        // A comment-only preamble above the first `0 FILE` (a license header,
        // for example) must not become a phantom root candidate.
        if createdImplicitSection, sawFileDirective,
           let first = result.first,
           first.normalizedName == Self.normalizedName(normalizedPath),
           first.lines.allSatisfy({ Self.isCommentOrBlank($0.text) }) {
            result.removeFirst()
        }
        return result
    }

    private static func isCommentOrBlank(_ line: String) -> Bool {
        let tokens = line.split(whereSeparator: \.isWhitespace)
        guard let first = tokens.first else { return true }
        guard first == "0" else { return false }
        guard tokens.count >= 2 else { return true }
        return !["STEP", "ROTSTEP", "LPUB", "!LPUB"].contains(tokens[1].uppercased())
    }

    private func parse(section raw: RawSection, isRoot: Bool, embeddedNames: Set<String>) throws -> ParsedSection {
        var diagnostics: [InstructionDiagnostic] = []
        var placements: [PartPlacement] = []
        var directives: [InstructionDirective] = []
        var steps: [SectionInstructionStep] = []
        var references: [String] = []
        var globalCamera = CameraCue()
        var localCamera = CameraCue()
        var stepStart = raw.lines.first?.number ?? 1
        var sawBoundary = false

        func closeStep(endLine: Int, rotation: RotationCue?) {
            let number = steps.count + 1
            steps.append(SectionInstructionStep(
                normalizedSectionName: raw.normalizedName,
                number: number,
                sourceStartLine: stepStart,
                sourceEndLine: endLine,
                directPlacements: placements,
                rotationCue: rotation,
                cameraCue: mergedCamera(global: globalCamera, local: localCamera),
                directives: directives
            ))
            placements.removeAll(keepingCapacity: true)
            directives.removeAll(keepingCapacity: true)
            localCamera = CameraCue()
            stepStart = endLine + 1
        }

        for source in raw.lines {
            let tokens = source.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let type = tokens.first else { continue }

            if type == "1" {
                guard tokens.count >= 15,
                      let color = Self.colorCode(tokens[1]),
                      let x = Double(tokens[2]), let y = Double(tokens[3]), let z = Double(tokens[4]),
                      let a = Double(tokens[5]), let b = Double(tokens[6]), let c = Double(tokens[7]),
                      let d = Double(tokens[8]), let e = Double(tokens[9]), let f = Double(tokens[10]),
                      let g = Double(tokens[11]), let h = Double(tokens[12]), let i = Double(tokens[13]) else {
                    diagnostics.append(.init(severity: .error, code: "invalid-type-1", message: "Invalid type-1 placement.", section: raw.normalizedName, lineNumber: source.number))
                    continue
                }
                let reference = tokens.dropFirst(14).joined(separator: " ")
                let normalizedReference = try Self.normalizeReference(reference)
                let isEmbedded = embeddedNames.contains(normalizedReference)
                let extensionName = (normalizedReference as NSString).pathExtension.lowercased()
                if !isEmbedded, extensionName != "dat" {
                    throw InstructionImportError.unresolvedReference(reference, section: raw.name, line: source.number)
                }
                references.append(normalizedReference)
                placements.append(PartPlacement(
                    id: "\(raw.normalizedName):\(source.number)",
                    partReference: normalizedReference,
                    colorCode: color,
                    transform: LDrawTransform(x: x, y: y, z: z, a: a, b: b, c: c, d: d, e: e, f: f, g: g, h: h, i: i),
                    sourceSection: raw.normalizedName,
                    sourceLine: source.number,
                    isSubmodelReference: isEmbedded
                ))
                continue
            }

            guard type == "0", tokens.count >= 2 else { continue }
            let command = tokens[1].uppercased()
            if command == "STEP" {
                sawBoundary = true
                closeStep(endLine: source.number, rotation: nil)
            } else if command == "ROTSTEP" {
                sawBoundary = true
                closeStep(endLine: source.number, rotation: parseRotation(Array(tokens.dropFirst(2))))
            } else if command == "!LPUB" || command == "LPUB" {
                let payload = Array(tokens.dropFirst(2))
                directives.append(.init(namespace: "LPUB", command: payload.first ?? "", arguments: Array(payload.dropFirst()), sourceLine: source.number))
                if let camera = parseCamera(payload) {
                    if camera.isGlobal {
                        apply(camera.cue, to: &globalCamera)
                    } else {
                        apply(camera.cue, to: &localCamera)
                    }
                }
            }
        }

        if sawBoundary, !placements.isEmpty || !directives.isEmpty {
            closeStep(endLine: raw.lines.last?.number ?? stepStart, rotation: nil)
        }
        if !sawBoundary {
            steps.removeAll()
        }

        return ParsedSection(
            section: InstructionSection(
                name: raw.name,
                normalizedName: raw.normalizedName,
                isRoot: isRoot,
                hasAuthoredBoundaries: sawBoundary,
                references: Array(Set(references)).sorted(),
                steps: steps
            ),
            diagnostics: diagnostics
        )
    }

    private func parseRotation(_ tokens: [String]) -> RotationCue? {
        if tokens.first?.uppercased() == "END" {
            return RotationCue(x: 0, y: 0, z: 0, mode: .end)
        }
        guard tokens.count >= 3,
              let x = Double(tokens[0]), let y = Double(tokens[1]), let z = Double(tokens[2]) else { return nil }
        let modeToken = tokens.count > 3 ? tokens[3].uppercased() : "REL"
        let mode: RotationMode = switch modeToken {
        case "ABS": .absolute
        case "ADD": .additive
        default: .relative
        }
        return RotationCue(x: x, y: y, z: z, mode: mode)
    }

    private func mergedCamera(global: CameraCue, local: CameraCue) -> CameraCue? {
        var result = global
        apply(local, to: &result)
        return result.isEmpty ? nil : result
    }

    private func apply(_ override: CameraCue, to target: inout CameraCue) {
        if let value = override.anglePreset { target.anglePreset = value; target.angles = nil }
        if let value = override.angles { target.angles = value; target.anglePreset = nil }
        if let value = override.position { target.position = value }
        if let value = override.target { target.target = value }
        if let value = override.upVector { target.upVector = value }
        if let value = override.distance { target.distance = value }
        if let value = override.fieldOfView { target.fieldOfView = value }
        if let value = override.name { target.name = value }
        if let value = override.orthographic { target.orthographic = value }
        if let value = override.nearClip { target.nearClip = value }
        if let value = override.farClip { target.farClip = value }
    }

    private func parseCamera(_ tokens: [String]) -> (isGlobal: Bool, cue: CameraCue)? {
        // pyldraw3's schema-v1 assembly camera grammar:
        // ASSEM CAMERA_<FIELD> [GLOBAL|LOCAL] <value...>. Callout and
        // multi-step cameras remain preserved in the directive stream.
        guard tokens.count >= 2, tokens[0].uppercased() == "ASSEM",
              tokens[1].uppercased().hasPrefix("CAMERA_") else { return nil }
        let field = String(tokens[1].uppercased().dropFirst("CAMERA_".count))
        var values = Array(tokens.dropFirst(2))
        let isGlobal: Bool
        if let scope = values.first?.uppercased(), scope == "GLOBAL" || scope == "LOCAL" {
            isGlobal = scope == "GLOBAL"
            values.removeFirst()
        } else {
            isGlobal = true
        }
        var cue = CameraCue()
        switch field {
        case "ANGLES":
            if values.count == 1 {
                cue.anglePreset = values[0].uppercased()
            } else if values.count == 3, values[0].uppercased() == "LAT_LON",
                      let first = Double(values[1]), let second = Double(values[2]) {
                cue.angles = [first, second]
            } else if values.count == 2, let first = Double(values[0]), let second = Double(values[1]) {
                cue.angles = [first, second]
            } else { return nil }
        case "POSITION", "TARGET", "UPVECTOR":
            guard values.count == 3 else { return nil }
            let vector = values.compactMap(Double.init)
            guard vector.count == 3 else { return nil }
            if field == "POSITION" { cue.position = vector }
            if field == "TARGET" { cue.target = vector }
            if field == "UPVECTOR" { cue.upVector = vector }
        case "DISTANCE", "FOV", "ZNEAR", "ZFAR":
            guard values.count == 1, let scalar = Double(values[0]) else { return nil }
            if field == "DISTANCE" { cue.distance = scalar }
            if field == "FOV" { cue.fieldOfView = scalar }
            if field == "ZNEAR" { cue.nearClip = scalar }
            if field == "ZFAR" { cue.farClip = scalar }
        case "ORTHOGRAPHIC":
            guard values.count == 1, ["TRUE", "FALSE"].contains(values[0].uppercased()) else { return nil }
            cue.orthographic = values[0].uppercased() == "TRUE"
        case "NAME":
            guard !values.isEmpty else { return nil }
            cue.name = values.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        default:
            return nil
        }
        return (isGlobal, cue)
    }

    /// Parents-before-children order over the buildable section DAG. Cycles
    /// among reachable sections were already rejected by `reachableSections`.
    private func topologicalOrder(
        from root: String,
        sectionsByName: [String: InstructionSection],
        buildableNames: Set<String>
    ) -> [String] {
        var visited = Set<String>()
        var postorder: [String] = []

        func visit(_ node: String) {
            guard visited.insert(node).inserted, let section = sectionsByName[node] else { return }
            for placement in section.steps.flatMap(\.directPlacements) {
                let child = Self.normalizedName(placement.partReference)
                if buildableNames.contains(child) { visit(child) }
            }
            postorder.append(node)
        }

        visit(root)
        return postorder.reversed()
    }

    private func reachableSections(from root: String, graph: [String: [String]]) throws -> Set<String> {
        var reachable = Set<String>()
        var active: [String] = []

        func visit(_ node: String, depth: Int) throws {
            guard depth <= InstructionLimits.maximumRecursionDepth else {
                throw InstructionImportError.limitExceeded("Submodel recursion exceeds 64 levels.")
            }
            if let cycleStart = active.firstIndex(of: node) {
                throw InstructionImportError.cyclicReference(Array(active[cycleStart...]) + [node])
            }
            if reachable.contains(node) { return }
            active.append(node)
            defer { active.removeLast() }
            reachable.insert(node)
            for child in graph[node, default: []] {
                try visit(child, depth: depth + 1)
            }
        }

        try visit(root, depth: 0)
        return reachable
    }

    /// Splits source text into lines with Windows (`\r\n`) and classic Mac
    /// (`\r`) line endings normalized first, so `\r\n` counts as one line and
    /// reported line numbers match the authored file.
    static func splitLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// Parses an LDraw colour token: a decimal palette code, or a direct
    /// colour such as `0x2RRGGBB` whose value is the literal hex integer.
    static func colorCode(_ token: String) -> Int? {
        if let decimal = Int(token) { return decimal }
        let lowered = token.lowercased()
        guard lowered.hasPrefix("0x") else { return nil }
        return Int(lowered.dropFirst(2), radix: 16)
    }

    static func normalizeReference(_ reference: String) throws -> String {
        let raw = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !raw.isEmpty,
              !raw.hasPrefix("/"),
              !(raw as NSString).isAbsolutePath,
              !raw.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              !raw.contains(":"),
              !raw.contains("\0") else {
            throw InstructionImportError.unsafePath(reference)
        }
        let normalized = normalizedName(raw)
        guard !normalized.isEmpty,
              !normalized.split(separator: "/").contains(".."),
              !normalized.contains(":") else {
            throw InstructionImportError.unsafePath(reference)
        }
        return normalized
    }

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
            .lowercased()
    }
}
