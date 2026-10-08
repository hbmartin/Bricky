import SwiftData
import XCTest
@testable import Bricky

/// Spotlight holds model titles only while the user wants it to (ADR 0016).
@MainActor
final class InstructionModelEntityTests: XCTestCase {
    private actor RecordingIndex: InstructionModelIndexing {
        private(set) var indexed: [[InstructionModelEntity]] = []
        private(set) var removals = 0

        func index(_ entities: [InstructionModelEntity]) async throws { indexed.append(entities) }
        func removeAll() async throws { removals += 1 }
    }

    /// An index that tracks what Spotlight would hold. Its first
    /// `removeAll` waits until released, so a test can act while that sync
    /// is suspended.
    private actor GatedIndex: InstructionModelIndexing {
        private(set) var live: Set<UUID> = []
        private var held: CheckedContinuation<Void, Never>?
        private var arrival: CheckedContinuation<Void, Never>?
        private var holding = false
        private var hasHeld = false

        func index(_ entities: [InstructionModelEntity]) async throws { live.formUnion(entities.map(\.id)) }

        func removeAll() async throws {
            if !hasHeld {
                hasHeld = true
                holding = true
                arrival?.resume()
                arrival = nil
                await withCheckedContinuation { held = $0 }
            }
            live.removeAll()
        }

        func waitUntilHeld() async {
            guard !holding else { return }
            await withCheckedContinuation { arrival = $0 }
        }

        func release() {
            held?.resume()
            held = nil
        }
    }

    @MainActor
    private final class Setting {
        var on = true
    }

    private var context: ModelContext!
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try ModelContainer(
            for: InstructionPersistence.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = container.mainContext
        for (title, hash) in [("Tower", "c"), ("Bridge", "d")] {
            let document = try LDrawInstructionParser().parse(
                files: [InstructionSourceFile(
                    relativePath: "main.ldr",
                    data: Data("0 \(title)\n0 Name: main.ldr\n1 4 0 0 0 1 0 0 0 1 0 0 0 1 3001.dat\n0 STEP\n".utf8)
                )],
                rootRelativePath: "main.ldr"
            )
            let plan = try InstructionPlanBuilder().build(
                document: document, title: title, sourceFilename: "main.ldr", sourceSHA256: String(repeating: hash, count: 64)
            )
            context.insert(StoredInstructionModel(plan: plan))
        }
        try context.save()
    }

    func testIndexingOffOnlyRemoves() async throws {
        let index = RecordingIndex()
        try await InstructionModelSpotlight.sync(enabled: false, context: context, index: index)
        let indexed = await index.indexed
        let removals = await index.removals
        XCTAssertTrue(indexed.isEmpty, "nothing is indexed while Spotlight is off")
        XCTAssertEqual(removals, 1, "turning it off removes every entry")
    }

    func testIndexingOnRewritesEveryModelWithTitleAndStepsOnly() async throws {
        let index = RecordingIndex()
        try await InstructionModelSpotlight.sync(enabled: true, context: context, index: index)
        let indexed = await index.indexed
        let removals = await index.removals
        XCTAssertEqual(removals, 1, "stale entries go first")
        XCTAssertEqual(indexed.count, 1)
        XCTAssertEqual(Set(indexed.first?.map(\.title) ?? []), ["Tower", "Bridge"])
        XCTAssertEqual(indexed.first?.map(\.stepCount), [1, 1])
    }

    func testOptOutIsNeverUndoneByAnEarlierSync() async throws {
        let index = GatedIndex()
        let setting = Setting()
        // Spotlight on: this sync suspends in its first removeAll.
        InstructionModelSpotlight.requestSync(context: context, index: index, setting: { setting.on })
        await index.waitUntilHeld()
        // The user turns it off while that sync is suspended.
        setting.on = false
        let optOut = InstructionModelSpotlight.requestSync(context: context, index: index, setting: { setting.on })
        await index.release()
        await optOut.value
        let live = await index.live
        XCTAssertTrue(live.isEmpty, "turning Spotlight off must leave it empty, whatever was in flight")
    }

    func testQueryReturnsOnlyTheRequestedModels() throws {
        let all = try InstructionModelSpotlight.entities(in: context)
        XCTAssertEqual(all.count, 2)
        let stored = try context.fetch(FetchDescriptor<StoredInstructionModel>())
        XCTAssertEqual(Set(all.map(\.id)), Set(stored.map(\.id)))
    }
}
