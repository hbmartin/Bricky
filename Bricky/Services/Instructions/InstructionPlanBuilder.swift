import CryptoKit
import Foundation

/// The identity an imported model is stored and recorded under: SHA-256
/// over every imported file, sorted by relative path, each path and body
/// NUL-terminated. Shared by the importer and by SyntheticRGBD, which must
/// match a bundle's `instruction_sha256` before replaying its windows.
enum InstructionSourceIdentity {
    static func sha256(of files: [InstructionSourceFile]) -> String {
        var hasher = SHA256()
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            hasher.update(data: Data(file.relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: file.data)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct InstructionPlanBuilder {
    func build(
        document: InstructionDocument,
        title: String,
        sourceFilename: String,
        sourceSHA256: String,
        importedAt: Date = .now
    ) throws -> InstructionPlan {
        let sectionMap = Dictionary(uniqueKeysWithValues: document.sections.map { ($0.normalizedName, $0) })
        guard let root = sectionMap[document.rootSectionName] else {
            throw InstructionImportError.invalidDocument("The root instruction section is missing.")
        }

        var authoredSteps: [AuthoredStep] = []
        var timeline: [PartPlacement] = []

        func expand(
            _ section: InstructionSection,
            instancePath: String,
            inheritedTransform: LDrawTransform,
            inheritedColor: Int,
            depth: Int
        ) throws {
            guard depth <= InstructionLimits.maximumRecursionDepth else {
                throw InstructionImportError.limitExceeded("Submodel recursion exceeds 64 levels.")
            }

            for localStep in section.steps {
                var directLeafPlacements: [PartPlacement] = []
                for local in localStep.directPlacements {
                    let childTransform = inheritedTransform.multiplied(by: local.transform)
                    let childColor = local.transform.applyingInheritedColor(inheritedColor, ownColor: local.colorCode)
                    if let childSection = sectionMap[LDrawInstructionParser.normalizedName(local.partReference)],
                       childSection.hasAuthoredBoundaries {
                        let childInstancePath = "\(instancePath)/\(childSection.normalizedName)@\(local.sourceLine)"
                        try expand(
                            childSection,
                            instancePath: childInstancePath,
                            inheritedTransform: childTransform,
                            inheritedColor: childColor,
                            depth: depth + 1
                        )
                    } else {
                        let occurrenceID = "\(instancePath):\(local.sourceSection):\(local.sourceLine)"
                        directLeafPlacements.append(PartPlacement(
                            id: occurrenceID,
                            partReference: local.partReference,
                            colorCode: childColor,
                            transform: childTransform,
                            sourceSection: local.sourceSection,
                            sourceLine: local.sourceLine,
                            isSubmodelReference: local.isSubmodelReference
                        ))
                    }
                }

                let lowerBound = timeline.count
                timeline.append(contentsOf: directLeafPlacements)
                let upperBound = timeline.count
                let globalIndex = authoredSteps.count + 1
                authoredSteps.append(AuthoredStep(
                    id: "\(instancePath)#\(localStep.number)",
                    index: globalIndex,
                    sectionName: section.normalizedName,
                    instancePath: instancePath,
                    sectionStepNumber: localStep.number,
                    sourceStartLine: localStep.sourceStartLine,
                    sourceEndLine: localStep.sourceEndLine,
                    directPlacements: localStep.directPlacements,
                    addedPlacementRange: PlacementRange(lowerBound: lowerBound, upperBound: upperBound),
                    cumulativePlacementCount: upperBound,
                    rotationCue: localStep.rotationCue,
                    cameraCue: localStep.cameraCue,
                    directives: localStep.directives
                ))

                guard authoredSteps.count <= InstructionLimits.maximumSteps else {
                    throw InstructionImportError.limitExceeded("The expanded guide exceeds 10,000 authored steps.")
                }
                guard timeline.count <= InstructionLimits.maximumPlacements else {
                    throw InstructionImportError.limitExceeded("The expanded guide exceeds 50,000 placements.")
                }
            }
        }

        try expand(
            root,
            instancePath: document.rootSectionName,
            inheritedTransform: .identity,
            inheritedColor: 16,
            depth: 0
        )

        guard !authoredSteps.isEmpty else { throw InstructionImportError.noAuthoredSteps }
        return InstructionPlan(
            id: UUID(),
            title: title,
            sourceFilename: sourceFilename,
            sourceSHA256: sourceSHA256,
            importedAt: importedAt,
            document: document,
            steps: authoredSteps,
            placementTimeline: timeline
        )
    }
}
