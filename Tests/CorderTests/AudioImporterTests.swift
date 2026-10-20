import AVFoundation
import XCTest
@testable import Corder

/// Dropped files are decoded to the 16 kHz mono 16-bit `mic.wav` the
/// in-person pipeline reads. The fixtures are made with `say` + `afconvert`,
/// the same encoders a Voice Memos / QuickTime export goes through.
final class AudioImporterTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corder-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "\(tool) \(args)")
    }

    /// ~3 s of speech as AIFF (22.05 kHz mono from `say`).
    private func speech() throws -> URL {
        let aiff = dir.appendingPathComponent("speech.aiff")
        try run("/usr/bin/say", ["-o", aiff.path, "Testing the audio import of Corder, one two three four five."])
        return aiff
    }

    private func assertTranscriptionWav(_ url: URL, durationMs: Int64, file: StaticString = #filePath, line: UInt = #line) throws {
        let f = try AVAudioFile(forReading: url)
        XCTAssertEqual(f.fileFormat.sampleRate, 16_000, file: file, line: line)
        XCTAssertEqual(f.fileFormat.channelCount, 1, file: file, line: line)
        let bits = f.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int
        XCTAssertEqual(bits, 16, file: file, line: line)
        XCTAssertEqual(f.fileFormat.settings[AVLinearPCMIsFloatKey] as? Bool, false, file: file, line: line)
        XCTAssertEqual(Int64(f.length) * 1000 / 16_000, durationMs, accuracy: 20, file: file, line: line)
        XCTAssertGreaterThan(durationMs, 2_000, file: file, line: line)
        // Not silence: the converter must carry the voice through.
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let peak = (0..<Int(buf.frameLength)).reduce(Float(0)) { max($0, abs(buf.floatChannelData![0][$1])) }
        XCTAssertGreaterThan(peak, 0.05, file: file, line: line)
    }

    func testAIFFSpeech() async throws {
        let out = dir.appendingPathComponent("mic.wav")
        let ms = try await AudioImporter.decodeToTranscriptionWav(source: try speech(), output: out)
        try assertTranscriptionWav(out, durationMs: ms)
    }

    func testAACStereo48k() async throws {
        let m4a = dir.appendingPathComponent("memo.m4a")
        try run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac@48000", "-c", "2", try speech().path, m4a.path])
        let out = dir.appendingPathComponent("mic.wav")
        let ms = try await AudioImporter.decodeToTranscriptionWav(source: m4a, output: out)
        try assertTranscriptionWav(out, durationMs: ms)
    }

    func testFloatWav44k() async throws {
        let wav = dir.appendingPathComponent("raw.wav")
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32@44100", try speech().path, wav.path])
        let out = dir.appendingPathComponent("mic.wav")
        let ms = try await AudioImporter.decodeToTranscriptionWav(source: wav, output: out)
        try assertTranscriptionWav(out, durationMs: ms)
    }

    func testNonAudioFileThrows() async throws {
        let txt = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: txt, atomically: true, encoding: .utf8)
        do {
            _ = try await AudioImporter.decodeToTranscriptionWav(source: txt, output: dir.appendingPathComponent("mic.wav"))
            XCTFail("a text file must not import")
        } catch {}
    }

    @MainActor
    func testImportableTypes() {
        XCTAssertTrue(AudioImporter.isImportable(URL(fileURLWithPath: "/x/a.mp3")))
        XCTAssertTrue(AudioImporter.isImportable(URL(fileURLWithPath: "/x/a.m4a")))
        XCTAssertTrue(AudioImporter.isImportable(URL(fileURLWithPath: "/x/a.wav")))
        XCTAssertTrue(AudioImporter.isImportable(URL(fileURLWithPath: "/x/a.mp4")))
        XCTAssertTrue(AudioImporter.isImportable(URL(fileURLWithPath: "/x/a.mov")))
        XCTAssertFalse(AudioImporter.isImportable(URL(fileURLWithPath: "/x/a.pdf")))
        XCTAssertFalse(AudioImporter.isImportable(URL(fileURLWithPath: "/x/a.txt")))
    }
}
