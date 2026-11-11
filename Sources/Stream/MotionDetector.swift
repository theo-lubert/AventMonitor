import CoreVideo
import Foundation

/// Detects movement in the live picture by comparing small luma thumbnails a few times a second.
/// Fed with the BGRA frames FrameDecoder produces.
final class MotionDetector: @unchecked Sendable { // confined to the stream queue
    /// Called on the stream queue each time movement is seen.
    var onMotion: (() -> Void)?

    private static let gridWidth = 32
    private static let gridHeight = 18
    /// A cell has changed when its brightness moved by more than this, after removing the global shift.
    private static let cellThreshold: Float = 10
    /// Share of changed cells that counts as movement.
    private static let minChangedShare: Float = 0.015
    /// Above this share the whole picture changed: lighting or day/night switch, not movement.
    private static let maxChangedShare: Float = 0.6
    private static let analysisInterval: TimeInterval = 0.25

    private var previous: [Float]?
    private var lastAnalysis = Date.distantPast
    private var hits = 0

    func reset() {
        previous = nil
        hits = 0
    }

    /// `image` must be 32BGRA. Call before anything is drawn on top of it.
    func analyze(_ image: CVPixelBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) >= Self.analysisInterval else { return }
        lastAnalysis = now
        guard let grid = Self.lumaGrid(image) else { return }
        defer { previous = grid }
        guard let previous, previous.count == grid.count else { return }

        let diffs = zip(grid, previous).map { $0 - $1 }
        let shift = diffs.reduce(0, +) / Float(diffs.count)
        let changed = diffs.filter { abs($0 - shift) > Self.cellThreshold }.count
        let share = Float(changed) / Float(diffs.count)

        // Two analyses in a row, so a single compression glitch does not count.
        if share >= Self.minChangedShare && share <= Self.maxChangedShare {
            hits += 1
            if hits >= 2 { onMotion?() }
        } else {
            hits = 0
        }
    }

    /// Average luma of each grid cell, sampled sparsely.
    private static func lumaGrid(_ image: CVPixelBuffer) -> [Float]? {
        guard CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { return nil }
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        let stride = CVPixelBufferGetBytesPerRow(image)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let cellW = width / gridWidth, cellH = height / gridHeight
        guard cellW > 0, cellH > 0 else { return nil }
        let step = max(1, min(cellW, cellH) / 4)

        var grid = [Float](repeating: 0, count: gridWidth * gridHeight)
        for gy in 0..<gridHeight {
            for gx in 0..<gridWidth {
                var sum = 0, count = 0
                var y = gy * cellH
                while y < (gy + 1) * cellH {
                    let row = pixels + y * stride
                    var x = gx * cellW
                    while x < (gx + 1) * cellW {
                        let p = row + x * 4 // B, G, R, A
                        sum += (Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29) >> 8
                        count += 1
                        x += step
                    }
                    y += step
                }
                grid[gy * gridWidth + gx] = Float(sum) / Float(max(count, 1))
            }
        }
        return grid
    }
}
