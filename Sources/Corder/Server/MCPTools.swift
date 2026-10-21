import Foundation

/// The tools `MCPService` exposes. Everything runs on the main actor (the
/// importer, the pipeline and the repository live there) and returns plain
/// text: MCP clients hand the text to the model as is.
@MainActor
enum MCPTools {
    struct Output: Sendable {
        var text: String
        var isError = false
    }

    nonisolated static let definitions: [[String: Any]] = [
        [
            "name": "transcribe_audio",
            "title": "Transcribe an audio file and save it in Corder",
            "description": """
                Transcribe an audio or video file that is on this Mac (voice messages such as Telegram .ogg/.oga, \
                m4a, mp3, wav, mp4, mov…) and save it as a new session in the user's Corder library, with speakers \
                and timestamps. By default the on-device model is used and nothing leaves the Mac. Waits for the \
                transcript and returns it; for long files it may return while still transcribing, then call \
                get_meeting with the returned id.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path of the audio or video file (~ is expanded)."],
                    "title": ["type": "string", "description": "Session title. Omit to let Corder title it from the transcript."],
                    "engine": ["type": "string", "enum": ["local", "default"],
                               "description": "local (default): on-device model. default: whatever the user picked in Corder's settings."],
                    "wait_seconds": ["type": "integer", "minimum": 0, "maximum": 3600,
                                     "description": "How long to wait for the transcript before returning (default 900, 0 = return right away)."],
                ],
                "required": ["path"],
            ],
        ],
        [
            "name": "list_meetings",
            "title": "List Corder sessions",
            "description": "Newest first: id, exact date, duration, status and title of the user's Corder sessions (recordings and imported files).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "minimum": 1, "maximum": 200, "description": "Default 20."],
                    "title_contains": ["type": "string", "description": "Only sessions whose title contains this text (case-insensitive)."],
                ],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "get_meeting",
            "title": "Read a Corder session",
            "description": "Title, date, duration, status, summary and the full transcript (speaker + timestamp per turn) of one session.",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "Session id from list_meetings, search_transcripts or transcribe_audio."]],
                "required": ["id"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "search_transcripts",
            "title": "Search Corder transcripts",
            "description": "Full-text search across every transcript; returns matching lines with their session, speaker and timestamp.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Words or a phrase to find."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 200, "description": "Max matching lines, default 30."],
                ],
                "required": ["query"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
    ]

    /// How long the HTTP side waits for a call (the transcribe wait plus
    /// room to decode the file first).
    nonisolated static func timeout(for name: String, args: [String: Any]) -> Double {
        guard name == "transcribe_audio" else { return 60 }
        return Double(waitSeconds(args)) + 300
    }

    nonisolated private static func waitSeconds(_ args: [String: Any]) -> Int {
        let raw = (args["wait_seconds"] as? Int) ?? (args["wait_seconds"] as? Double).map(Int.init) ?? 900
        return min(max(raw, 0), 3600)
    }

    static func call(name: String, args: [String: Any]) async -> Output {
        switch name {
        case "transcribe_audio": return await transcribe(args)
        case "list_meetings": return listMeetings(args)
        case "get_meeting": return getMeeting(args)
        case "search_transcripts": return search(args)
        default: return Output(text: "Unknown tool \(name).", isError: true)
        }
    }

    // MARK: - transcribe_audio

    private static func transcribe(_ args: [String: Any]) async -> Output {
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty else {
            return Output(text: "`path` is required.", isError: true)
        }
        let url = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return Output(text: "No file at \(url.path).", isError: true)
        }
        let engineLocal = (args["engine"] as? String ?? "local") != "default"
        if engineLocal && !LocalWhisperTranscriber.isAvailable() {
            return Output(text: "The on-device model needs a Mac with Apple silicon. Use engine \"default\" to transcribe with Corder's cloud setting.", isError: true)
        }
        let title = args["title"] as? String
        let started: (id: String, done: Task<Void, Never>)
        do {
            started = try await AudioImporter.importForAPI(url, title: title,
                                                           provider: engineLocal ? .whisperLocal : nil)
        } catch {
            return Output(text: "Corder could not import \(url.lastPathComponent): \(error.localizedDescription)", isError: true)
        }
        FileLogger.log("MCP: transcribe_audio \(url.lastPathComponent) → \(started.id) (engine \(engineLocal ? "local" : "default"))")

        let wait = waitSeconds(args)
        if wait > 0 {
            let done = started.done
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await done.value }
                group.addTask { try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000) }
                await group.next()
                group.cancelAll()
            }
        }
        let repo = AppContext.shared.repo
        guard let m = try? repo.meeting(id: started.id) else {
            return Output(text: "The session \(started.id) is gone (deleted from Corder?).", isError: true)
        }
        switch m.status {
        case .ready:
            return Output(text: "Saved in Corder.\n" + render(m, includeSummary: false))
        case .failed:
            let reason = TranscriptionErrors.read(meetingId: m.id) ?? "unknown error"
            return Output(text: "Transcription failed (session \(m.id) is kept in Corder, it can be re-transcribed there): \(reason)", isError: true)
        default:
            let stage = TranscriptionProgressStore.readStage(meetingId: m.id)?.rawValue ?? "queued"
            return Output(text: "Saved in Corder as session \(m.id), still transcribing (stage: \(stage)). Call get_meeting with this id to read the transcript when it is done.")
        }
    }

    // MARK: - read tools

    private static func listMeetings(_ args: [String: Any]) -> Output {
        let limit = min(max((args["limit"] as? Int) ?? 20, 1), 200)
        let needle = (args["title_contains"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        guard let all = try? AppContext.shared.repo.listMeetings() else {
            return Output(text: "Could not read the Corder library.", isError: true)
        }
        let rows = all
            .filter { $0.status != .preroll }
            .filter { needle.isEmpty || ($0.title ?? "").lowercased().contains(needle) }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(limit)
        guard !rows.isEmpty else { return Output(text: "No sessions found.") }
        let lines = rows.map { m in
            "- \(m.id) · \(exactDate(m.startedAt)) · \(duration(m.durationMs)) · \(m.status.rawValue) · \(m.title?.nilIfEmpty ?? "(untitled)")"
        }
        return Output(text: lines.joined(separator: "\n"))
    }

    private static func getMeeting(_ args: [String: Any]) -> Output {
        guard let id = (args["id"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
              let m = try? AppContext.shared.repo.meeting(id: id) else {
            return Output(text: "No session with that id.", isError: true)
        }
        return Output(text: render(m, includeSummary: true))
    }

    private static func search(_ args: [String: Any]) -> Output {
        guard let query = args["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Output(text: "`query` is required.", isError: true)
        }
        let limit = min(max((args["limit"] as? Int) ?? 30, 1), 200)
        let repo = AppContext.shared.repo
        guard let hits = try? repo.searchSegments(query: query) else {
            return Output(text: "Search failed.", isError: true)
        }
        guard !hits.isEmpty else { return Output(text: "No matches.") }
        var meetings: [String: Meeting] = [:]
        var speakers: [String: [String: Speaker]] = [:]
        var lines: [String] = []
        for seg in hits.prefix(limit) {
            if meetings[seg.meetingId] == nil, let m = try? repo.meeting(id: seg.meetingId) { meetings[seg.meetingId] = m }
            if speakers[seg.meetingId] == nil {
                speakers[seg.meetingId] = Dictionary(uniqueKeysWithValues:
                    ((try? repo.speakers(forMeeting: seg.meetingId)) ?? []).map { ($0.id, $0) })
            }
            let m = meetings[seg.meetingId]
            let who = TranscriptFormatter.displayName(for: speakers[seg.meetingId]?[seg.speakerId])
            lines.append("- \(m?.title?.nilIfEmpty ?? "(untitled)") (\(seg.meetingId), \(m.map { exactDate($0.startedAt) } ?? "?")) [\(clock(seg.startMs))] \(who): \(seg.text)")
        }
        return Output(text: lines.joined(separator: "\n"))
    }

    // MARK: - formatting

    private static func render(_ m: Meeting, includeSummary: Bool) -> String {
        let repo = AppContext.shared.repo
        let segs = (try? repo.segments(forMeeting: m.id)) ?? []
        let spk = Dictionary(uniqueKeysWithValues: ((try? repo.speakers(forMeeting: m.id)) ?? []).map { ($0.id, $0) })
        var out = """
            Title: \(m.title?.nilIfEmpty ?? "(untitled)")
            Id: \(m.id)
            Date: \(exactDate(m.startedAt))
            Duration: \(duration(m.durationMs))
            Status: \(m.status.rawValue)
            """
        if includeSummary, let summary = m.summary?.nilIfEmpty {
            out += "\n\nSummary:\n\(summary)"
        }
        // One block per speaker turn, stamped with where it starts.
        var blocks: [(start: Int64, name: String, text: String)] = []
        for seg in segs {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let name = TranscriptFormatter.displayName(for: spk[seg.speakerId])
            if let last = blocks.last, last.name == name {
                blocks[blocks.count - 1].text += " " + text
            } else {
                blocks.append((seg.startMs, name, text))
            }
        }
        out += "\n\nTranscript:\n"
        out += blocks.isEmpty
            ? "(no speech found)"
            : blocks.map { "[\(clock($0.start))] \($0.name): \($0.text)" }.joined(separator: "\n")
        return out
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        return f
    }()

    private static func exactDate(_ ms: Int64) -> String {
        dateFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private static func duration(_ ms: Int64?) -> String {
        guard let ms, ms > 0 else { return "?" }
        let s = Int(ms / 1000)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func clock(_ ms: Int64) -> String { duration(max(ms, 1)).replacingOccurrences(of: "?", with: "0:00") }
}
