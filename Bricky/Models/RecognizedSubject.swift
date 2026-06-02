import Foundation

/// Broad category of subject the AI vision model identified in a photo.
/// Drives the icon and copy shown in the result card.
enum RecognizedSubjectCategory: String, Codable, CaseIterable, Sendable {
    case person
    case character
    case landmark
    case place
    case musician
    case artwork
    case animal
    case object
    case unknown

    /// SF Symbol used to represent the category in the UI.
    var systemImage: String {
        switch self {
        case .person, .musician: return "person.crop.square"
        case .character: return "face.smiling"
        case .landmark, .place: return "mappin.and.ellipse"
        case .artwork: return "paintpalette"
        case .animal: return "pawprint"
        case .object: return "cube"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// A single identification returned by the AI vision recognition feature.
///
/// `confidence` is a best-guess likelihood in `0...1`. The model is instructed
/// to never fabricate certainty — low-confidence guesses are surfaced as such
/// rather than presented as fact, which matters when recognizing real people.
struct RecognizedSubject: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let category: RecognizedSubjectCategory
    let confidence: Double
    /// One- or two-sentence factual description (who/what/where).
    let summary: String
    /// Optional location hint for landmarks/places (e.g. "Paris, France").
    let location: String?

    init(
        id: UUID = UUID(),
        name: String,
        category: RecognizedSubjectCategory,
        confidence: Double,
        summary: String,
        location: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.confidence = max(0, min(1, confidence))
        self.summary = summary
        self.location = location
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, category, confidence, summary, location
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        category = (try? c.decode(RecognizedSubjectCategory.self, forKey: .category)) ?? .unknown
        confidence = max(0, min(1, try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0))
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        location = try c.decodeIfPresent(String.self, forKey: .location)
    }
}

/// Full result of an AI recognition request: the subjects found plus the
/// remaining monthly quota the server reports back (source of truth).
struct RecognitionResult: Codable, Equatable, Sendable {
    let subjects: [RecognizedSubject]
    /// Recognitions left this month, as reported by the proxy. `nil` if the
    /// server didn't include it.
    let remainingQuota: Int?

    var isEmpty: Bool { subjects.isEmpty }
}
