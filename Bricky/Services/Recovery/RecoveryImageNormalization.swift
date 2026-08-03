import UIKit

extension UIImage {
    /// Bakes EXIF orientation and bounds the VLM input to one 1024×1024 board.
    /// ✅ VERIFIED: normalizing before image encoding avoids mismatched camera
    /// and model orientation across the guided recovery views.
    func normalizedForInference(maxDimension: CGFloat = 1024) -> UIImage {
        let source = normalizedOrientation()
        let scale = min(1, maxDimension / max(source.size.width, source.size.height))
        guard scale < 1 else { return source }
        let target = CGSize(width: floor(source.size.width * scale), height: floor(source.size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: target))
            source.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
