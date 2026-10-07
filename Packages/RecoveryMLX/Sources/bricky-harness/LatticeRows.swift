import ArgumentParser
import Foundation
import RecoveryEvidenceKit

/// Extracts lattice evidence from a bundle's verification windows (iOS 27
/// Phase 4): one `lattice_window` row per window. No model, no weights.
struct LatticeRows: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lattice-rows",
        abstract: "Write lattice_window rows from a bundle's verification windows (stud-keypoint entry evidence).",
        discussion: """
        Then read the entry line:
        python3 Tools/RecoveryEvaluation/score_results.py <out> --informational
        Only device windows of staged complete or shifted_one_stud builds count
        toward the stud-keypoint entry criterion (ADR 0020).
        """
    )

    @Option(help: "An unzipped evidence bundle directory; repeat for several.")
    var bundle: [String]

    @Option(help: "Output NDJSON path.")
    var out: String

    mutating func run() throws {
        var rows: [LatticeWindowRowV1] = []
        for path in bundle {
            let reader = try EvidenceBundleReader(bundleDirectory: URL(fileURLWithPath: path))
            let issues = reader.validate()
            guard issues.isEmpty else {
                for issue in issues { FileHandle.standardError.write(Data("invalid bundle \(path): \(issue)\n".utf8)) }
                throw ExitCode(1)
            }
            rows += try reader.loadSessions().flatMap(LatticeWindowRowV1.rows(session:))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = try rows.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(toFile: out, atomically: true, encoding: .utf8)
        let staged = rows.filter { $0.stagedScenario != nil }.count
        print("wrote \(rows.count) lattice_window rows (\(staged) staged) to \(out)")
    }
}
