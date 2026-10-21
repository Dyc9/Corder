import AVFoundation
import GRDB
import XCTest
@testable import Corder

/// Regression tests for paths that used to delete or strand a user's
/// recordings (audit 2026-10-21).
@MainActor
final class DataSafetyTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corder-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        AppSettings.setDemoTitleSweepDone(false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        AppSettings.setDemoTitleSweepDone(false)
    }

    private func repo() throws -> MeetingRepository {
        let dbq = try DatabaseQueue()
        try Migrations.register().migrate(dbq)
        return MeetingRepository(dbq: dbq)
    }

    private func meeting(id: String, title: String, audioPath: String) -> Meeting {
        var m = Meeting(id: id, startedAt: 1_000, endedAt: 2_000, durationMs: 1_000,
                        videoPath: "/nonexistent/video.mov", audioPath: audioPath,
                        transcribedAt: 2_000, status: .ready)
        m.title = title
        return m
    }

    /// DL-1: a real meeting the auto-titler named "Daily standup" survives
    /// every launch; only a demo-looking row (uppercase id, no audio) goes,
    /// and only on the first sweep.
    func test_demoSweep_keepsRealMeetingWithDemoTitle() throws {
        let repo = try repo()
        let audio = dir.appendingPathComponent("mic.wav")
        try writeWav(audio, seconds: 1)
        let realId = UUID().uuidString.lowercased()
        let demoId = UUID().uuidString
        try repo.insertMeeting(meeting(id: realId, title: "Daily standup", audioPath: audio.path))
        try repo.insertMeeting(meeting(id: demoId, title: "Daily standup", audioPath: "/nonexistent/audio.wav"))

        DemoSeeder.removeAll(repo: repo)
        XCTAssertNotNil(try repo.meeting(id: realId), "real meeting must never be swept by title")
        XCTAssertNil(try repo.meeting(id: demoId), "demo row with no audio is swept once")

        // The sweep is one-shot: a later launch leaves even demo-looking rows.
        let laterId = UUID().uuidString
        try repo.insertMeeting(meeting(id: laterId, title: "All hands, Q1 review", audioPath: "/nonexistent/audio.wav"))
        DemoSeeder.removeAll(repo: repo)
        XCTAssertNotNil(try repo.meeting(id: laterId))
        XCTAssertNotNil(try repo.meeting(id: realId))
    }

    /// A lowercase id is never demo-looking, audio or not.
    func test_isDemoLookingRow_requiresUppercaseIdAndNoAudio() {
        XCTAssertFalse(DemoSeeder.isDemoLookingRow(
            meeting(id: UUID().uuidString.lowercased(), title: "Daily standup", audioPath: "/nonexistent/a.wav")))
        XCTAssertTrue(DemoSeeder.isDemoLookingRow(
            meeting(id: UUID().uuidString, title: "Daily standup", audioPath: "/nonexistent/a.wav")))
    }

    /// DL-6: originals are only dropped when the playback mix covers them.
    func test_mixCoversOriginals() throws {
        try writeWav(dir.appendingPathComponent("mic.wav"), seconds: 10)
        try writeWav(dir.appendingPathComponent("system.wav"), seconds: 10)
        XCTAssertFalse(AppDelegate.mixCoversOriginals(in: dir), "no audio.wav")

        try writeWav(dir.appendingPathComponent("audio.wav"), seconds: 3)
        XCTAssertFalse(AppDelegate.mixCoversOriginals(in: dir), "partial mix")

        try writeWav(dir.appendingPathComponent("audio.wav"), seconds: 10)
        XCTAssertTrue(AppDelegate.mixCoversOriginals(in: dir))

        try Data("not a wav".utf8).write(to: dir.appendingPathComponent("audio.wav"))
        XCTAssertFalse(AppDelegate.mixCoversOriginals(in: dir), "unreadable mix")
    }

    /// DL-5 / 5.2: a failed mix never leaves a partial audio.wav (or a temp)
    /// that later checks would take for the finished mix; a good one lands
    /// complete, and two concurrent builds share one write.
    func test_mix_isAtomic() async throws {
        let out = dir.appendingPathComponent("audio.wav")
        do {
            try await AudioMixer.produceWhisperInput(
                systemURL: nil, micURL: dir.appendingPathComponent("missing.wav"), outputURL: out)
            XCTFail("expected bothStreamsMissing")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])

        let mic = dir.appendingPathComponent("mic.wav")
        try writeWav(mic, seconds: 2)
        async let a: Void = AudioMixer.produceWhisperInput(systemURL: nil, micURL: mic, outputURL: out)
        async let b: Void = AudioMixer.produceWhisperInput(systemURL: nil, micURL: mic, outputURL: out)
        _ = try await (a, b)
        let f = try AVAudioFile(forReading: out)
        XCTAssertEqual(Double(f.length) / f.processingFormat.sampleRate, 2, accuracy: 0.05)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["mic.wav", "audio.wav"])
    }

    /// DL-14: capture tracks are written as 16-bit integer (half the bytes
    /// of float, so the 4 GiB WAV ceiling is twice as far away) while the
    /// writers keep feeding float buffers.
    func test_captureFileSettings_writeInt16FromFloatBuffers() throws {
        let tap = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let url = dir.appendingPathComponent("system.wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: CaptureEngine.captureFileSettings(for: tap),
                                       commonFormat: tap.commonFormat, interleaved: tap.isInterleaved)
            let buf = AVAudioPCMBuffer(pcmFormat: tap, frameCapacity: 48_000)!
            buf.frameLength = 48_000
            try file.write(from: buf)
            XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
        }   // closing the file writes its header
        let back = try AVAudioFile(forReading: url)
        XCTAssertEqual(back.length, 48_000)
        XCTAssertEqual(back.fileFormat.channelCount, 2)
        XCTAssertEqual(back.fileFormat.sampleRate, 48_000)
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertLessThanOrEqual(bytes, 48_000 * 2 * 2 + 4096, "2 bytes per sample, not 4")
    }

    private func writeWav(_ url: URL, seconds: Double) throws {
        try? FileManager.default.removeItem(at: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        try file.write(from: buf)
    }
}

/// CR-2: only a file SQLite calls corrupt is set aside; anything that
/// could still hold the user's library is never deleted.
final class DatabaseOpenTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corder-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    func test_corruptFile_isQuarantinedAndRecreated() throws {
        let path = dir.appendingPathComponent("corder.db").path
        try Data(repeating: 0x42, count: 8192).write(to: URL(fileURLWithPath: path))
        let dbq = try Database.open(path: path)
        XCTAssertNoThrow(try MeetingRepository(dbq: dbq).listMeetings())
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("corder.db.corrupt-") }, "the bad file is kept aside: \(names)")
    }

    func test_corruptFile_isKeptWhenItCannotBeMovedAside() throws {
        let url = dir.appendingPathComponent("corder.db")
        let bytes = Data(repeating: 0x42, count: 8192)
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertThrowsError(try Database.open(path: url.path))
        XCTAssertEqual(try Data(contentsOf: url), bytes, "the only copy must not be deleted")
    }

    func test_healthyFile_opensWithItsRows() throws {
        let path = dir.appendingPathComponent("corder.db").path
        try MeetingRepository(dbq: try Database.open(path: path)).insertMeeting(Meeting.fixture(id: "keep"))
        XCTAssertNotNil(try MeetingRepository(dbq: try Database.open(path: path)).meeting(id: "keep"))
    }
}
