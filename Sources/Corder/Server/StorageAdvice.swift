import Foundation

/// "Your recordings take a lot of space, archive the old ones?" Corder never
/// deletes recordings on its own (the originals used to be dropped after 30
/// days, reverted 2026-10-21), so when the library grows large, or the disk
/// gets tight, the Welcome screen suggests moving sessions older than
/// `oldAfterDays` to the Archive, where they are deleted after the usual
/// 7 days. Pinned and in-flight sessions are never included.
enum StorageAdvice {
    static let oldAfterDays = 90
    /// Recordings this big are worth a nudge even on a roomy disk.
    static let largeLibraryBytes: Int64 = 20 * 1_000_000_000
    /// Below this much free space, nudge whatever the library size.
    static let lowFreeBytes: Int64 = 20 * 1_000_000_000
    private static let snoozeKey = "Corder.set.storageAdviceSnoozedUntil"

    struct Report: Codable {
        let warn: Bool
        let total_bytes: Int64
        let free_bytes: Int64
        let old_count: Int
        let old_bytes: Int64
        let older_than_days: Int
    }

    static func report(repo: MeetingRepository) -> Report {
        let old = oldMeetings(repo: repo)
        let oldBytes = old.reduce(Int64(0)) { $0 + folderSize(AppPaths.recordingDir(for: $1.id)) }
        let total = folderSize(AppPaths.recordingsDir)
        let free = (try? AppPaths.recordingsDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        let snoozed = Date().timeIntervalSince1970 < UserDefaults.standard.double(forKey: snoozeKey)
        let pressure = total >= largeLibraryBytes || free < lowFreeBytes
        return Report(warn: !snoozed && pressure && !old.isEmpty && oldBytes > 0,
                      total_bytes: total, free_bytes: free, old_count: old.count,
                      old_bytes: oldBytes, older_than_days: oldAfterDays)
    }

    /// Moves every old session to the Archive. Returns how many.
    static func archiveOld(repo: MeetingRepository) -> Int {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var n = 0
        for m in oldMeetings(repo: repo) where (try? repo.setArchived(meetingId: m.id, archivedAt: now)) != nil {
            n += 1
        }
        FileLogger.log("StorageAdvice: archived \(n) session(s) older than \(oldAfterDays) days")
        return n
    }

    static func snooze(days: Int = 30) {
        UserDefaults.standard.set(Date().timeIntervalSince1970 + Double(days) * 86_400, forKey: snoozeKey)
    }

    private static func oldMeetings(repo: MeetingRepository) -> [Meeting] {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - Int64(oldAfterDays) * 86_400_000
        let live: String? = {
            switch RecordingStateSnapshot.read() {
            case .recording(let id, _), .preroll(let id, _): return id
            case .idle, .stopping: return nil
            }
        }()
        return ((try? repo.listMeetings()) ?? []).filter {
            $0.startedAt < cutoff && $0.pinnedAt == nil && $0.archivedAt == nil
                && ($0.status == .ready || $0.status == .failed) && $0.id != live
        }
    }

    static func folderSize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in walker {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}
