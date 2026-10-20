import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Imports audio (or video) files dropped onto the Library window as new
/// sessions and transcribes them.
///
/// An import is stored exactly like an in-person recording: the file is
/// decoded to a 16 kHz mono 16-bit `mic.wav` in a fresh recording folder and
/// no `system.wav` exists, so `TranscriptionPipeline` takes its mic-only
/// branch (diarizes every speaker in the one track) and everything downstream
/// (playback mix, cache key, auto-title, folder rename, cloud sync) works with
/// no import-specific code.
@MainActor
enum AudioImporter {
    /// Container/codec families AVFoundation can decode on macOS 14+.
    static func isImportable(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .audiovisualContent)
    }

    /// Queue of files still to import. Files are converted one at a time so a
    /// drop of ten long recordings does not decode ten files in parallel.
    private static var queue: [URL] = []
    private static var running = false
    /// Imported sessions transcribe one after another. Two on-device model
    /// loads racing Core ML / Metal is a known SIGABRT (the same reason launch
    /// recovery enqueues sequentially), and a ten-file drop would otherwise
    /// start ten transcriptions at once.
    private static var transcribeChain: Task<Void, Never>?

    static func importFiles(_ urls: [URL]) {
        let files = urls.filter(isImportable)
        let skipped = urls.count - files.count
        if skipped > 0 {
            FileLogger.log("AudioImporter: skipped \(skipped) non-audio file(s)")
            LibraryWindow.shared.postToast(title: L.notif("import_unsupported"), body: "", kind: "error")
        }
        guard !files.isEmpty else { return }
        queue.append(contentsOf: files)
        guard !running else { return }
        running = true
        Task { @MainActor in
            while !queue.isEmpty {
                let next = queue.removeFirst()
                await importOne(next)
            }
            running = false
        }
    }

    private static func importOne(_ source: URL) async {
        let name = source.deletingPathExtension().lastPathComponent
        // Same gates as Start recording: a guest holds at most
        // `guestSessionLimit` sessions, and we never write into a full disk.
        if RecordingController.guestAtSessionCap() {
            FileLogger.log("AudioImporter: guest at session cap, offering sign-in instead of importing \(source.lastPathComponent)")
            queue.removeAll()
            AuthController.shared.present()
            return
        }
        let recordingsRoot = AppPaths.recordingDir(for: "probe").deletingLastPathComponent()
        if let free = (try? recordingsRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage, free < 500 * 1024 * 1024 {
            LibraryWindow.shared.postToast(title: L.notif("import_low_disk"), body: "", kind: "error")
            queue.removeAll()
            return
        }

        let id = UUID().uuidString.lowercased()
        let dir = AppPaths.recordingDir(for: id)
        let micURL = dir.appendingPathComponent("mic.wav")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var meeting = Meeting(
            id: id,
            startedAt: now,
            videoPath: dir.appendingPathComponent("video.mov").path,
            audioPath: micURL.path,
            status: .transcribing
        )
        // Insert first so the row shows up (with its loader) while the file
        // is still decoding; a long file can take a few seconds.
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try AppContext.shared.repo.insertMeeting(meeting)
        } catch {
            FileLogger.log("AudioImporter: could not create session for \(source.lastPathComponent): \(error)")
            LibraryWindow.shared.postToast(title: L.notif("import_failed"), body: "", kind: "error")
            try? FileManager.default.removeItem(at: dir)
            return
        }
        LibraryWindow.shared.openMeeting(id)
        FileLogger.log("AudioImporter: importing \(source.lastPathComponent) as \(id)")

        let durationMs: Int64
        do {
            durationMs = try await Task.detached(priority: .userInitiated) {
                try await decodeToTranscriptionWav(source: source, output: micURL)
            }.value
        } catch {
            FileLogger.log("AudioImporter: decode failed for \(source.lastPathComponent): \(error)")
            try? AppContext.shared.repo.deleteMeeting(id: id)
            try? FileManager.default.removeItem(at: dir)
            LibraryWindow.shared.postToast(title: L.notif("import_failed"), body: "", kind: "error")
            return
        }

        meeting.endedAt = now + durationMs
        meeting.durationMs = durationMs
        do { try AppContext.shared.repo.updateMeeting(meeting) }
        catch { FileLogger.log("AudioImporter: duration update failed for \(id): \(error)") }
        FileLogger.log("AudioImporter: \(id) decoded (\(durationMs / 1000)s), scheduling transcription")

        // Transcription runs in the background, chained after the previous
        // import's; the next file in the queue starts decoding right away.
        let previous = transcribeChain
        transcribeChain = Task { @MainActor in
            await previous?.value
            await TranscriptionPipeline.shared.enqueue(meetingId: id).value
            // The auto-titler names a session from its transcript. When there
            // is none (failed run, silence), keep the file's own name so the
            // user can still tell which file this row came from.
            let repo = AppContext.shared.repo
            if let m = try? repo.meeting(id: id),
               m.title?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
                try? repo.setTitle(meetingId: id, title: name)
                RecordingDirNaming.renameToTitled(repo: repo, meetingId: id)
            }
            if AppSettings.notificationsEnabled {
                NotificationsService.post(
                    title: L.notif("notif_ready_title"),
                    body: L.notif("notif_ready_body"))
            }
        }
    }

    /// Decodes any AVFoundation-readable file (mp3, m4a, aac, wav, aiff, caf,
    /// flac, the audio track of mp4/mov) into a 16 kHz mono 16-bit WAV, the
    /// same format `AudioMixer.compactToTranscriptionFormat` produces for
    /// recordings. Streams sample buffers, so memory stays flat on long files.
    /// Returns the duration in milliseconds.
    nonisolated static func decodeToTranscriptionWav(source: URL, output: URL) async throws -> Int64 {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ImportError.noAudioTrack }

        let settings = AudioMixer.playbackInt16Settings(sampleRate: 16_000, channels: 1)
        let reader = try AVAssetReader(asset: asset)
        // The mix output downmixes every audio track (a video with separate
        // voice/music tracks keeps both), the settings resample to 16 kHz mono.
        let readerOut = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        readerOut.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOut) else { throw ImportError.unreadable }
        reader.add(readerOut)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .wav)
        let writerIn = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writerIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerIn) else { throw ImportError.unwritable }
        writer.add(writerIn)

        guard reader.startReading() else { throw reader.error ?? ImportError.unreadable }
        guard writer.startWriting() else { throw writer.error ?? ImportError.unwritable }
        writer.startSession(atSourceTime: .zero)

        var frames: Int64 = 0
        while let sample = readerOut.copyNextSampleBuffer() {
            try Task.checkCancellation()
            while !writerIn.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            frames += Int64(CMSampleBufferGetNumSamples(sample))
            guard writerIn.append(sample) else { throw writer.error ?? ImportError.unwritable }
        }
        if reader.status == .failed { throw reader.error ?? ImportError.unreadable }
        writerIn.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? ImportError.unwritable }
        guard frames > 0 else { throw ImportError.noAudioTrack }
        return frames * 1000 / 16_000
    }

    enum ImportError: Error {
        case noAudioTrack, unreadable, unwritable
    }
}
