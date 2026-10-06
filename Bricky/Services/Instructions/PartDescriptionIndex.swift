import Foundation

/// A part's human name from its LDraw header, e.g. "Brick 2 x 4" for
/// `3001.dat`, or the file name when no header can be read.
struct PartDescription: Sendable, Equatable {
    let reference: String
    let title: String
    /// True when `title` is only the file name.
    let isFallback: Bool
}

/// Reads part descriptions from the first line of each part file — the
/// LDraw convention (`0 Brick  2 x  4`). Lookups are lazy and cached: a step
/// names a handful of parts, and each costs one 512-byte read.
///
/// Custom parts in an imported model are untrusted text (an author can
/// write anything in a header), so titles are stripped of control
/// characters and capped before anything displays or speaks them.
actor PartDescriptionIndex {
    static let maximumTitleLength = 80
    private static let headerBytes = 512

    private let modelSourceRoot: URL?
    private let partPackRoot: URL
    private var cache: [String: PartDescription] = [:]

    init(modelSourceRoot: URL?, partPackRoot: URL) {
        self.modelSourceRoot = modelSourceRoot
        self.partPackRoot = partPackRoot
    }

    func description(for reference: String) -> PartDescription {
        if let cached = cache[reference] { return cached }
        let resolved = resolve(reference, followingMoves: 1)
        cache[reference] = resolved
        return resolved
    }

    private func resolve(_ reference: String, followingMoves hops: Int) -> PartDescription {
        guard let header = headerLine(for: reference), let title = Self.title(fromHeader: header) else {
            return PartDescription(reference: reference, title: reference, isFallback: true)
        }
        // "~Moved to 3040b": the library keeps the old number as an alias.
        if hops > 0, let target = Self.movedTarget(title) {
            let moved = resolve(target.hasSuffix(".dat") ? target : "\(target).dat", followingMoves: hops - 1)
            if !moved.isFallback {
                return PartDescription(reference: reference, title: moved.title, isFallback: false)
            }
        }
        return PartDescription(reference: reference, title: title, isFallback: false)
    }

    /// Same search order as the geometry engine: the model's own files, then
    /// the part pack's parts, primitives, and models folders.
    private func headerLine(for reference: String) -> String? {
        let candidates = [modelSourceRoot?.appendingPathComponent(reference)].compactMap { $0 } + [
            partPackRoot.appendingPathComponent("parts/\(reference)"),
            partPackRoot.appendingPathComponent("p/\(reference)"),
            partPackRoot.appendingPathComponent("models/\(reference)")
        ]
        for url in candidates {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: Self.headerBytes), !data.isEmpty else { continue }
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            return text.split(whereSeparator: \.isNewline).first.map(String.init)
        }
        return nil
    }

    /// The description on a `0 ` header line, with runs of spaces collapsed,
    /// LDraw's status prefixes (`~` alias, `=` physical colour, `_` obsolete,
    /// `|` alias) dropped, control characters removed, and length capped.
    static func title(fromHeader line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("0 ") else { return nil }
        var body = String(trimmed.dropFirst(2))
        while let first = body.first, "~=_|".contains(first) { body.removeFirst() }
        let cleaned = body.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maximumTitleLength))
    }

    static func movedTarget(_ title: String) -> String? {
        let prefix = "Moved to "
        guard title.hasPrefix(prefix) else { return nil }
        let target = title.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return target.isEmpty ? nil : target
    }
}

/// Human wording for parts and colours, shared by the guide and (later) the
/// repair phrasebook and spoken steps.
enum PartNaming {
    /// Codes at or above this are direct colours (`0x2RRGGBB`).
    private static let directColorThreshold = 0x2000000

    /// "Light_Bluish_Grey" → "Light bluish grey"; direct colours have no name.
    static func colourName(code: Int, definitionName: String?) -> String {
        guard code < directColorThreshold else { return "Custom colour" }
        guard let definitionName, !definitionName.isEmpty else { return "Colour \(code)" }
        let words = definitionName.split(separator: "_").map { $0.lowercased() }
        guard let first = words.first else { return "Colour \(code)" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    /// "Red · Brick 2 x 4".
    static func label(colour: String, part: PartDescription) -> String {
        "\(colour) · \(part.title)"
    }

    /// "red Brick 2 x 4", for the middle of a sentence.
    static func inSentence(colour: String, part: PartDescription) -> String {
        "\(colour.lowercased()) \(part.title)"
    }
}

/// One description index per model and part pack, shared by the guide and
/// the AR guide so descriptions stay cached across steps and screens.
@MainActor
enum PartDescriptionIndexCache {
    private static var shared: [String: PartDescriptionIndex] = [:]

    static func index(for plan: InstructionPlan, partPackRoot: URL) -> PartDescriptionIndex? {
        guard let root = try? InstructionModelImporter.applicationSupportRoot() else { return nil }
        let key = "\(plan.sourceSHA256)|\(partPackRoot.path)"
        if let existing = shared[key] { return existing }
        let index = PartDescriptionIndex(
            modelSourceRoot: root.appendingPathComponent("Models/\(plan.sourceSHA256)/Source"),
            partPackRoot: partPackRoot
        )
        shared[key] = index
        return index
    }
}
