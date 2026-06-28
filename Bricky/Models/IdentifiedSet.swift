import Foundation

/// A single LEGO set proposed by the AI set-identifier for a scanned built
/// model.
///
/// `confidence` is the model's honest 0...1 likelihood. `catalogMatch` is filled
/// in by grounding the proposal against `LegoSetCatalog`: when present, the set
/// is **verified** against real reference data and the authoritative fields
/// (theme, year, piece count) come from the catalog rather than the model. We
/// never present an unresolved guess as a confirmed fact.
struct IdentifiedSet: Identifiable, Codable, Equatable, Sendable {
    let setNumber: String
    let name: String
    /// Model-proposed theme; superseded by `catalogMatch?.theme` when verified.
    let theme: String?
    /// Model-proposed year; superseded by `catalogMatch?.year` when verified.
    let year: Int?
    let confidence: Double
    /// One factual sentence: what the set is / why it was identified.
    let summary: String

    /// Resolved catalog row, attached during grounding. Not decoded from the
    /// wire; defaults to `nil` until grounding runs.
    var catalogMatch: LegoSet?

    var id: String { setNumber + "|" + name }

    /// True once the proposal resolves to a real catalog set.
    var isVerified: Bool { catalogMatch != nil }

    /// Best display values, preferring authoritative catalog data.
    var displayName: String { catalogMatch?.name ?? name }
    var displayTheme: String? { catalogMatch?.theme ?? theme }
    var displayYear: Int? { catalogMatch?.year ?? year }
    var pieceCount: Int? { catalogMatch?.pieceCount }

    init(
        setNumber: String,
        name: String,
        theme: String? = nil,
        year: Int? = nil,
        confidence: Double,
        summary: String,
        catalogMatch: LegoSet? = nil
    ) {
        self.setNumber = setNumber
        self.name = name
        self.theme = theme
        self.year = year
        self.confidence = max(0, min(1, confidence))
        self.summary = summary
        self.catalogMatch = catalogMatch
    }

    private enum CodingKeys: String, CodingKey {
        case setNumber, name, theme, year, confidence, summary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        setNumber = (try c.decodeIfPresent(String.self, forKey: .setNumber) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        name = try c.decode(String.self, forKey: .name)
        theme = try c.decodeIfPresent(String.self, forKey: .theme)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        confidence = max(0, min(1, try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0))
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        catalogMatch = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(setNumber, forKey: .setNumber)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(theme, forKey: .theme)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(summary, forKey: .summary)
    }

    /// Returns a copy with the catalog match attached.
    func grounded(with match: LegoSet?) -> IdentifiedSet {
        var copy = self
        copy.catalogMatch = match
        return copy
    }
}

/// Full result of a set-identification request: ranked candidates plus the
/// remaining monthly allowance the proxy reports back (the server is the source
/// of truth for quota).
struct SetIdentificationResult: Codable, Equatable, Sendable {
    let candidates: [IdentifiedSet]
    let remainingQuota: Int?

    var isEmpty: Bool { candidates.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case candidates, remainingQuota
    }

    init(candidates: [IdentifiedSet], remainingQuota: Int? = nil) {
        self.candidates = candidates
        self.remainingQuota = remainingQuota
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        candidates = try c.decodeIfPresent([IdentifiedSet].self, forKey: .candidates) ?? []
        remainingQuota = try c.decodeIfPresent(Int.self, forKey: .remainingQuota)
    }
}
