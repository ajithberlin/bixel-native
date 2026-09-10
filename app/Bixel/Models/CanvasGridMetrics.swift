import CoreGraphics

/// Shared geometry rules for the drawing guide. The grid must remain useful at
/// both pixel-editing zoom levels and canvas overview zoom levels.
enum CanvasGridMetrics {
    static func lineStride(width: Int, height: Int, zoom: CGFloat) -> Int {
        let safeZoom = max(0.01, zoom)
        let maxDimension = max(1, max(width, height))
        let readableStride = Int(ceil(10.0 / safeZoom))
        let boundedStride = Int(ceil(Double(maxDimension) / 256.0))
        return max(1, max(readableStride, boundedStride))
    }
}
