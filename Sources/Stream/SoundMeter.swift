import Foundation

/// Turns the monitor's μ-law audio into a 0…3 room sound level, like the official app's three bars.
/// Works whether or not playback is muted.
final class SoundMeter: @unchecked Sendable { // confined to the stream queue
    /// dBFS thresholds for levels 1, 2 and 3.
    static let thresholds: [Float] = [-32, -22, -12]

    /// Called on the stream queue whenever the level changes.
    var onLevel: ((Int) -> Void)?
    /// Called on the stream queue for every 100 ms window at level 2 or more.
    var onLoud: (() -> Void)?
    static let loudLevel = 2
    /// Consecutive loud windows (100 ms each) before it counts as sound, so clicks and bumps are ignored.
    static let loudWindowsNeeded = 5
    private var loudWindows = 0

    private let windowFrames = 800 // 100 ms at 8 kHz
    private let releaseWindows = 5 // hold a level 500 ms before dropping
    private var sumSquares: Float = 0
    private var frames = 0
    private var level = -1
    private var heldWindows = 0

    func push(_ payload: Data) {
        payload.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                let sample = AudioOutput.table[Int(byte)]
                sumSquares += sample * sample
                frames += 1
                if frames == windowFrames { finishWindow() }
            }
        }
    }

    func reset() {
        sumSquares = 0
        frames = 0
        level = -1
        loudWindows = 0
        heldWindows = 0
    }

    private func finishWindow() {
        let rms = (sumSquares / Float(frames)).squareRoot()
        sumSquares = 0
        frames = 0
        let db = 20 * log10(max(rms, 1e-6))
        let measured = Self.thresholds.filter { db >= $0 }.count
        loudWindows = measured >= Self.loudLevel ? loudWindows + 1 : 0
        if loudWindows >= Self.loudWindowsNeeded { onLoud?() }

        // Fast attack, slow release, so short sounds stay readable.
        if measured >= level {
            heldWindows = 0
            update(measured)
        } else {
            heldWindows += 1
            if heldWindows >= releaseWindows {
                heldWindows = 0
                update(level - 1)
            }
        }
    }

    private func update(_ newLevel: Int) {
        guard newLevel != level else { return }
        level = newLevel
        onLevel?(newLevel)
    }
}
