import Foundation
import RecoveryEvidenceKit

/// Remembers which physical build a person is photographing, per
/// instruction model, so a build re-shot later keeps its label (ADR 0019).
/// Training and test data are split by this label as well as by authored
/// model; a wrong label only merges builds, which costs data but never
/// leaks a build across the split.
struct PhysicalBuildLabelStore {
    private static let keyPrefix = "evidence.physicalBuild."
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The remembered label for an instruction model, by its content hash.
    func label(forInstruction sha256: String) -> String? {
        guard let label = defaults.string(forKey: Self.keyPrefix + sha256),
              EvidenceSessionFile.isValidPhysicalBuildID(label) else { return nil }
        return label
    }

    /// Stores `label`, or forgets it when nil or empty. An invalid label is
    /// refused and changes nothing.
    @discardableResult
    func setLabel(_ label: String?, forInstruction sha256: String) -> Bool {
        guard let label, !label.isEmpty else {
            defaults.removeObject(forKey: Self.keyPrefix + sha256)
            return true
        }
        guard EvidenceSessionFile.isValidPhysicalBuildID(label) else { return false }
        defaults.set(label, forKey: Self.keyPrefix + sha256)
        return true
    }

    /// A fresh label for a build not photographed before: `b-` and four hex
    /// digits.
    static func newLabel<Generator: RandomNumberGenerator>(using generator: inout Generator) -> String {
        "b-" + String(format: "%04x", UInt16.random(in: .min ... .max, using: &generator))
    }

    static func newLabel() -> String {
        var generator = SystemRandomNumberGenerator()
        return newLabel(using: &generator)
    }

    /// What a person typed, as a slug: lowercased, spaces to dashes, and
    /// anything else dropped.
    static func normalized(_ typed: String) -> String {
        String(typed.lowercased().unicodeScalars.compactMap { scalar -> Character? in
            if scalar == " " || scalar == "_" { return "-" }
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-" { return Character(scalar) }
            return nil
        }.prefix(32))
    }
}
