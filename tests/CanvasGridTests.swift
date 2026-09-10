import CoreGraphics

@main struct CanvasGridTests {
    static func main() {
        precondition(CanvasGridMetrics.lineStride(width: 32, height: 32, zoom: 1) == 10)
        precondition(CanvasGridMetrics.lineStride(width: 2048, height: 2048, zoom: 0.29) >= 34)
        precondition(CanvasGridMetrics.lineStride(width: 16, height: 16, zoom: 12) == 1)
        precondition(CanvasGridMetrics.lineStride(width: 1, height: 1, zoom: 0) >= 1)
        print("Canvas grid tests passed")
    }
}
