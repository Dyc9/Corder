/// A working mic has some noise even in a quiet room. Only exact digital
/// zeroes throughout the initial window indicate a dead replacement input.
struct InitialDigitalSilenceDetector {
    private var seconds = 0.0
    private(set) var finished = false

    mutating func observe(peak: Float, frameCount: Int, sampleRate: Double) -> Bool {
        guard !finished, frameCount > 0, sampleRate > 0 else { return false }
        guard peak == 0 else {
            finished = true
            return false
        }
        seconds += Double(frameCount) / sampleRate
        // Allow rounding at the boundary when the window spans many buffers.
        guard seconds >= 2.0 - 1e-9 else { return false }
        finished = true
        return true
    }
}
