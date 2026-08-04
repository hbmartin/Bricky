import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The single authoritative implementation of the 1024×1024 comparison-board
/// layout, shared by the iOS app and the `bricky-harness` CLI. Pure
/// CoreGraphics/CoreText so it renders byte-comparable boards on both
/// platforms, and pinned to exactly 1024×1024 pixels — the previous UIKit
/// composer rendered at screen scale, so on-device boards were 2–3× larger
/// on disk than documented (the model still saw 1024 after input resize).
public enum RecoveryBoardLayoutV1 {
    public enum LayoutError: Error {
        case invalidCandidateCount(Int)
        case contextUnavailable
        case renderFailed
        case imageUnreadable(URL)
        case writeFailed(URL)
    }

    public struct Candidate: Sendable {
        public let slot: String
        public let image: CGImage
        public let stepNumber: Int

        public init(slot: String, image: CGImage, stepNumber: Int) {
            self.slot = slot
            self.image = image
            self.stepNumber = stepNumber
        }
    }

    // Geometry shared with Tools/RecoveryEvaluation/make_board.py (which is
    // deprecated as an authority in favor of this file).
    public static let boardSide = 1024
    public static let physicalRect = CGRect(x: 16, y: 16, width: 992, height: 420)
    public static let columns = 4
    public static let tileGap: CGFloat = 12
    public static let tileWidth: CGFloat = (992 - 12 * 3) / 4
    public static let tileHeight: CGFloat = 266
    public static let tileTop: CGFloat = 452
    public static let cornerRadius: CGFloat = 14

    /// Draws the board in UIKit-style top-left coordinates (the context is
    /// flipped once; images and text are locally unflipped).
    public static func composeBoard(physical: CGImage, candidates: [Candidate]) throws -> CGImage {
        guard (1...8).contains(candidates.count) else {
            throw LayoutError.invalidCandidateCount(candidates.count)
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: boardSide,
                  height: boardSide,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw LayoutError.contextUnavailable
        }
        context.translateBy(x: 0, y: CGFloat(boardSide))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high

        context.setFillColor(gray(0.06))
        context.fill(CGRect(x: 0, y: 0, width: boardSide, height: boardSide))

        drawAspectFill(physical, in: physicalRect, cornerRadius: cornerRadius, context: context)

        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 19, nil)
        for (offset, candidate) in candidates.enumerated() {
            let row = offset / columns
            let column = offset % columns
            let frame = CGRect(
                x: 16 + CGFloat(column) * (tileWidth + tileGap),
                y: tileTop + CGFloat(row) * (tileHeight + tileGap),
                width: tileWidth,
                height: tileHeight
            )
            context.setFillColor(gray(0.14))
            context.addPath(CGPath(
                roundedRect: frame,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            ))
            context.fillPath()
            drawAspectFit(candidate.image, in: frame.insetBy(dx: 8, dy: 30), context: context)
            drawLabel(
                "\(candidate.slot) · Step \(candidate.stepNumber)",
                topLeft: CGPoint(x: frame.minX + 10, y: frame.minY + 7),
                font: font,
                context: context
            )
        }

        guard let image = context.makeImage() else { throw LayoutError.renderFailed }
        return image
    }

    public static func loadImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw LayoutError.imageUnreadable(url)
        }
        return image
    }

    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.9) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw LayoutError.writeFailed(url) }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { throw LayoutError.writeFailed(url) }
    }

    // MARK: - Drawing helpers (top-left coordinate space)

    private static func gray(_ white: CGFloat) -> CGColor {
        CGColor(srgbRed: white, green: white, blue: white, alpha: 1)
    }

    /// Draws an image into a rect in the flipped (top-left) context by
    /// locally unflipping, so the image itself renders upright.
    private static func drawUpright(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    private static func drawAspectFill(_ image: CGImage, in rect: CGRect, cornerRadius: CGFloat, context: CGContext) {
        let size = CGSize(width: image.width, height: image.height)
        let scale = max(rect.width / size.width, rect.height / size.height)
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let drawRect = CGRect(
            x: rect.midX - target.width / 2,
            y: rect.midY - target.height / 2,
            width: target.width,
            height: target.height
        )
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        context.clip()
        drawUpright(image, in: drawRect, context: context)
        context.restoreGState()
    }

    private static func drawAspectFit(_ image: CGImage, in rect: CGRect, context: CGContext) {
        let size = CGSize(width: max(1, image.width), height: max(1, image.height))
        let scale = min(rect.width / size.width, rect.height / size.height)
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        drawUpright(
            image,
            in: CGRect(
                x: rect.midX - target.width / 2,
                y: rect.midY - target.height / 2,
                width: target.width,
                height: target.height
            ),
            context: context
        )
    }

    private static func drawLabel(_ text: String, topLeft: CGPoint, font: CTFont, context: CGContext) {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.saveGState()
        // Un-flip glyphs while keeping the top-left position convention.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: topLeft.x, y: topLeft.y + CTFontGetAscent(font))
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
