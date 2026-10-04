import CoreGraphics
import Foundation
import RecoveryEvidenceKit
import XCTest

/// Boards for weights-gated tests: stacked coloured blocks, one more per
/// tile, so the model has a genuine (if crude) comparison to make.
enum TestBoards {
    static let rankPrompt = "The large top image is a physical brick build. The labeled renders A–H are cumulative authored instruction steps in one fixed model frame. Rank the closest labels from best to worst. Return insufficient when angle, occlusion, or evidence cannot support a comparison."
    static let checkPrompt = "Compare the physical build with render A. Return complete, incomplete, or uncertain."

    /// Skips the calling test unless `BRICKY_MODEL_DIR` names the pinned
    /// Qwen3-VL revision.
    static func modelDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["BRICKY_MODEL_DIR"] else {
            throw XCTSkip("set BRICKY_MODEL_DIR to the pinned Qwen3-VL revision to run model tests")
        }
        return URL(fileURLWithPath: path)
    }

    static func board(slots: Int, in directory: URL) throws -> URL {
        let composed = try RecoveryBoardLayoutV1.composeBoard(
            physical: try blocks(3, width: 1440, height: 1920),
            candidates: try (0..<slots).map { index in
                RecoveryBoardLayoutV1.Candidate(
                    slot: String(UnicodeScalar(UInt8(65 + index))),
                    image: try blocks(index + 1, width: 512, height: 384),
                    stepNumber: index + 1
                )
            }
        )
        let url = directory.appendingPathComponent("board-\(slots)-\(UUID().uuidString).jpg")
        try RecoveryBoardLayoutV1.writeJPEG(composed, to: url)
        return url
    }

    private static func blocks(_ count: Int, width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.92, green: 0.92, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let colours: [(CGFloat, CGFloat, CGFloat)] = [(0.8, 0.1, 0.1), (0.1, 0.3, 0.8), (0.95, 0.8, 0.1), (0.1, 0.6, 0.2)]
        for index in 0..<count {
            let (red, green, blue) = colours[index % colours.count]
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            let blockHeight = CGFloat(height) / 12
            context.fill(CGRect(
                x: CGFloat(width) * 0.3, y: CGFloat(height) * 0.15 + CGFloat(index) * blockHeight,
                width: CGFloat(width) * 0.4, height: blockHeight * 0.9
            ))
        }
        return try XCTUnwrap(context.makeImage())
    }
}
