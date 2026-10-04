import XCTest
@testable import RecoveryMLX

/// The pinned revision's index names shards it does not contain; the loader
/// must see a directory without that index, and nothing of the user's may be
/// modified to get there.
final class LoadableModelDirectoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loadable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeIndex(shards: [String]) throws {
        let map = Dictionary(uniqueKeysWithValues: shards.enumerated().map { ("layer.\($0.offset)", $0.element) })
        let data = try JSONSerialization.data(withJSONObject: ["metadata": [:], "weight_map": map])
        try data.write(to: directory.appendingPathComponent(LoadableModelDirectory.indexFilename))
    }

    func testDirectoryWithoutAnIndexIsUsedAsIs() throws {
        XCTAssertEqual(try LoadableModelDirectory.resolve(directory), directory)
    }

    func testConsistentIndexIsUsedAsIs() throws {
        try writeIndex(shards: ["model.safetensors"])
        XCTAssertEqual(try LoadableModelDirectory.resolve(directory), directory)
    }

    func testStaleIndexIsHiddenBehindSymlinks() throws {
        // The pinned revision: one real file, an index naming two absent shards.
        try writeIndex(shards: ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"])
        let resolved = try LoadableModelDirectory.resolve(directory)
        XCTAssertNotEqual(resolved, directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: resolved.path).sorted()
        XCTAssertEqual(names, ["config.json", "model.safetensors"])
        XCTAssertEqual(try Data(contentsOf: resolved.appendingPathComponent("model.safetensors")), Data("weights".utf8))
        // The user's directory is untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(LoadableModelDirectory.indexFilename).path))
        // Resolving again replaces the shadow rather than failing on it.
        XCTAssertEqual(try LoadableModelDirectory.resolve(directory), resolved)
    }
}
