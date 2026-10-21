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

/// CR-3: the streamed window RMS matches the old whole-file computation.
final class StreamedRMSTests: XCTestCase {
    func test_streamedWindowRMS_matchesWholeFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("corder-rms-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let frames = 300_017   // not a multiple of the 64k block
        do {
            let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
            buf.frameLength = AVAudioFrameCount(frames)
            var seed: UInt64 = 42
            for c in 0..<2 {
                for i in 0..<frames {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let r = Float(Int64(bitPattern: seed >> 11) % 2000) / 2000
                    buf.floatChannelData![c][i] = r * (i % 40_000 < 20_000 ? 0.5 : 0.01)
                }
            }
            try f.write(from: buf)
        }
        let file = try AVAudioFile(forReading: url)
        let window = 1440, hop = 480
        let got = try XCTUnwrap(VoiceActivityDetector.streamedWindowRMS(file, windowFrames: window, hopFrames: hop))
        XCTAssertEqual(got.frames, frames)

        let whole = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        file.framePosition = 0
        try file.read(into: whole)
        var want: [Float] = []
        var pos = 0
        while pos + window <= frames {
            var sum: Float = 0
            for c in 0..<2 { for i in 0..<window { let v = whole.floatChannelData![c][pos + i]; sum += v * v } }
            want.append(sqrtf(sum / Float(window * 2)))
            pos += hop
        }
        XCTAssertEqual(got.values.count, want.count)
        for (a, b) in zip(got.values, want) { XCTAssertEqual(a, b, accuracy: max(1e-6, b * 1e-4)) }
    }
}

extension StreamedRMSTests {
    /// CR-3: the block-wise 16 kHz mono decode keeps the whole length and level.
    func test_echoSuppressorLoad_streamsWholeFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("corder-aec-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let frames = 48_000 * 7 / 2   // 3.5 s, several 64k blocks
        do {
            let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
            buf.frameLength = AVAudioFrameCount(frames)
            for c in 0..<2 { for i in 0..<frames { buf.floatChannelData![c][i] = 0.5 * sinf(Float(i) * 2 * .pi * 440 / 48_000) } }
            try f.write(from: buf)
        }
        let mono = try XCTUnwrap(EchoSuppressor.loadMono16k(url))
        XCTAssertEqual(Double(mono.count), 56_000, accuracy: 200)
        let mid = mono[8_000..<48_000]
        let rms = sqrtf(mid.reduce(0) { $0 + $1 * $1 } / Float(mid.count))
        XCTAssertEqual(rms, 0.3536, accuracy: 0.01)
    }
}

/// MCP endpoint: auth, handshake and tool list (tools/call needs the app).
final class MCPServiceTests: XCTestCase {
    private func call(_ json: String, auth: String = "Bearer t0ken-for-tests-0123456789abcdef0123") -> (Int, [String: Any]?) {
        let (status, body) = MCPService.respond(to: Data(json.utf8), authorization: auth)
        let obj = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (status, obj)
    }

    override func setUp() { MCPService.setTokenForTesting("t0ken-for-tests-0123456789abcdef0123") }

    func test_rejectsWithoutToken() {
        XCTAssertEqual(call(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, auth: "").0, 401)
        XCTAssertEqual(call(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, auth: "Bearer wrong").0, 401)
    }

    func test_initialize_negotiatesVersion() {
        let (status, obj) = call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        XCTAssertEqual(status, 200)
        let result = obj?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((result?["capabilities"] as? [String: Any])?["tools"])
    }

    func test_notification_isAccepted() {
        XCTAssertEqual(call(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).0, 202)
    }

    func test_toolsList_hasTranscribe() {
        let tools = (call(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#).1?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        let names = Set(tools?.compactMap { $0["name"] as? String } ?? [])
        XCTAssertEqual(names, ["transcribe_audio", "list_meetings", "get_meeting", "search_transcripts"])
    }

    func test_unknownMethod_isError() {
        let err = call(#"{"jsonrpc":"2.0","id":3,"method":"nope"}"#).1?["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, -32601)
    }
}

/// HALMicCapture on the built-in mic. Opens a real microphone, so it only
/// runs with CORDER_MIC_TEST=1 (run it with a Bluetooth headset as the
/// default input: the point is that the headset is never opened).
final class HALMicCaptureTests: XCTestCase {
    func test_builtInMic_deliversBuffersQuickly() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CORDER_MIC_TEST"] == "1", "needs a microphone")
        let builtIn = try XCTUnwrap(AudioInputDevices.builtInInput(), "no built-in mic")
        let id = try XCTUnwrap(AudioInputDevices.resolveDeviceID(forUID: builtIn.uid))
        let got = expectation(description: "first buffer")
        let lock = NSLock()
        var frames = 0
        var fulfilled = false
        let t0 = Date()
        let hal = try HALMicCapture(deviceID: id) { buf, when in
            lock.lock(); defer { lock.unlock() }
            frames += Int(buf.frameLength)
            XCTAssertTrue(when.isHostTimeValid)
            if !fulfilled { fulfilled = true; got.fulfill() }
        }
        wait(for: [got], timeout: 2)
        let firstAfter = Date().timeIntervalSince(t0)
        Thread.sleep(forTimeInterval: 0.5)
        hal.stop()
        lock.lock(); let total = frames; lock.unlock()
        XCTAssertLessThan(firstAfter, 1.0, "first buffer took \(firstAfter) s")
        XCTAssertGreaterThan(Double(total), hal.format.sampleRate * 0.4)
        print("HALMicCaptureTests: first buffer after \(firstAfter) s, \(total) frames at \(hal.format.sampleRate) Hz, default input \(AudioInputDevices.defaultInputSummary())")
    }
}
