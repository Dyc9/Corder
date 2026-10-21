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
