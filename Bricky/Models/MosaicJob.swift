import Foundation

/// Data-transfer types for the LEGO Model Generation backend
/// (`services/lego-model-gen`, see `docs/LEGO Model Generation System/API_DESIGN.md`).
///
/// The backend exposes an asynchronous job workflow:
/// 1. `POST /jobs` — upload a photo + grid/palette config → `MosaicJobCreation`.
/// 2. `GET /jobs/{id}` — poll → `MosaicJobProgress`.
/// 3. `GET /jobs/{id}/result` — once done → `MosaicJobResult` (artifact URLs).
///
/// These mirror the JSON contracts exactly; `CodingKeys` translate the
/// backend's `snake_case` to Swift `camelCase`.

/// Lifecycle status of a generation job. Matches API_DESIGN.md §3.
enum MosaicJobStatus: String, Codable, Sendable {
    case queued
    case processing
    case done
    case error
}

/// Resolved (snapped) grid size echoed back by the server on job creation.
struct MosaicJobGrid: Codable, Sendable, Equatable {
    let width: Int
    let height: Int
}

/// Response from `POST /jobs` (HTTP 202).
struct MosaicJobCreation: Codable, Sendable, Equatable {
    let jobId: String
    let status: MosaicJobStatus
    let grid: MosaicJobGrid

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case status
        case grid
    }
}

/// Response from `GET /jobs/{id}`. `progress` is present while `queued` or
/// `processing`; `message` is present on `error` (and only then).
struct MosaicJobProgress: Codable, Sendable, Equatable {
    let jobId: String
    let status: MosaicJobStatus
    let progress: Int?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case status
        case progress
        case message
    }

    /// Progress clamped to 0...100; `done` reports 100, `error` reports the
    /// last known value (or 0).
    var percent: Int {
        if status == .done { return 100 }
        return min(100, max(0, progress ?? 0))
    }
}

/// Response from `GET /jobs/{id}/result`. URLs may be **relative** (the local
/// storage MVP returns `/artifacts/...`); resolve them against the service
/// base URL via `MosaicGenerationService.resolve(_:)`.
struct MosaicJobResult: Codable, Sendable, Equatable {
    let jobId: String
    let status: MosaicJobStatus
    let ldrURL: String
    let pdfURL: String
    let partsURL: String
    let thumbnailURL: String

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case status
        case ldrURL = "ldr_url"
        case pdfURL = "pdf_url"
        case partsURL = "parts_url"
        case thumbnailURL = "thumbnail_url"
    }
}

/// One aggregated part line from the downloaded `parts.json`
/// (see `docs/LEGO Model Generation System/PARTS_INVENTORY.md`).
struct MosaicPartLine: Codable, Sendable, Equatable, Identifiable {
    let part: String
    let color: String
    let qty: Int
    let ldrawColor: Int
    let bricklinkColor: Int
    let rebrickableColor: Int

    var id: String { "\(part)-\(color)" }

    enum CodingKeys: String, CodingKey {
        case part
        case color
        case qty
        case ldrawColor = "ldraw_color"
        case bricklinkColor = "bricklink_color"
        case rebrickableColor = "rebrickable_color"
    }
}

/// The decoded `parts.json` artifact.
struct MosaicPartsList: Codable, Sendable, Equatable {
    let paletteId: String
    let parts: [MosaicPartLine]
    let totalParts: Int

    enum CodingKeys: String, CodingKey {
        case paletteId = "palette_id"
        case parts
        case totalParts = "total_parts"
    }
}
