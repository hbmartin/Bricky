import XCTest
@testable import Bricky

final class PhysicalBuildLabelStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "PhysicalBuildLabelStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testRemembersALabelPerInstructionModel() {
        let store = PhysicalBuildLabelStore(defaults: defaults)
        XCTAssertNil(store.label(forInstruction: "sha-a"))
        XCTAssertTrue(store.setLabel("b-1a2b", forInstruction: "sha-a"))
        XCTAssertEqual(store.label(forInstruction: "sha-a"), "b-1a2b")
        XCTAssertNil(store.label(forInstruction: "sha-b"))
        XCTAssertTrue(store.setLabel("", forInstruction: "sha-a"))
        XCTAssertNil(store.label(forInstruction: "sha-a"), "an empty label forgets it")
    }

    func testAnInvalidLabelIsRefusedAndChangesNothing() {
        let store = PhysicalBuildLabelStore(defaults: defaults)
        store.setLabel("kitchen", forInstruction: "sha-a")
        XCTAssertFalse(store.setLabel("Two Words", forInstruction: "sha-a"))
        XCTAssertEqual(store.label(forInstruction: "sha-a"), "kitchen")
        // Something written behind the store's back is not trusted either.
        defaults.set("Not A Slug", forKey: "evidence.physicalBuild.sha-b")
        XCTAssertNil(store.label(forInstruction: "sha-b"))
    }

    func testNewLabelsAreValidSlugs() {
        var generator = SeededGenerator(seed: 7)
        let labels = (0..<20).map { _ in PhysicalBuildLabelStore.newLabel(using: &generator) }
        for label in labels {
            XCTAssertTrue(label.hasPrefix("b-"))
            XCTAssertEqual(label.count, 6)
            XCTAssertTrue(EvidenceSessionFile.isValidPhysicalBuildID(label), label)
        }
        XCTAssertGreaterThan(Set(labels).count, 15)
    }

    func testTypedLabelsNormaliseToSlugs() {
        XCTAssertEqual(PhysicalBuildLabelStore.normalized("Kitchen Table_2!"), "kitchen-table-2")
        XCTAssertEqual(PhysicalBuildLabelStore.normalized(String(repeating: "x", count: 40)).count, 32)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
