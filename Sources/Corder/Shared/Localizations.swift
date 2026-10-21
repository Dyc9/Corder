import Foundation

/// Shared string table for everything that renders outside the Vite/React
/// frontend, the menu-bar popover, the meeting-invite panel, and any
/// other native chrome that needs to follow `AppContext.language`.
///
/// Keep keys short and topical (`invite_subtitle`, not `meeting_invite_record_question`),
/// the dictionary stays readable that way.
enum L {
    static func t(_ key: String, lang: String) -> String {
        let dict = lang == "ru" ? ru : en
        return dict[key] ?? en[key] ?? key
    }
    private static let en: [String: String] = [
        // Recording errors (RecordingController.present)
        "record_start_failed": "Could not start recording",
        "record_save_failed": "Could not save the recording",
        "record_low_disk": "Not enough disk space ({mb} MB free). Free up space first; the recording was not started so it cannot be lost when the disk fills up.",
        // Audio import (drag and drop onto the Library window)
        "import_unsupported": "Only audio and video files can be transcribed",
        "import_failed": "Could not read this file. Try an mp3, m4a or wav.",
        "import_low_disk": "Not enough disk space to import this file",
        // Menu-bar popover
        "idle": "Not recording",
        "recording": "Recording",
        "saving": "Saving…",
        "start": "Start recording",
        "stop": "Stop recording",
        "open_library": "Open library",
        "open_account": "Open account",
        "open_corder": "Open Corder",
        "locked_status": "Cannot record yet",
        "quit": "Quit",
        // Meeting invite panel
        "invite_question": "Record meeting?",
        "invite_tap_hint": "Tap to start recording",
        "invite_not_now": "Not now",
        // Loading state shown after the user accepts an invite (or
        // hits manual Start) while the capture engine warms up, gives
        // the user feedback that something is happening between click
        // and the floating blob appearing.
        "starting_recording": "Starting recording…",
        // Native macOS notification banners. `{s}` is substituted with
        // the recording length in seconds at call time.
        "notif_saved_title": "Recording saved",
        "notif_saved_body": "Transcribing {s}s…",
        "notif_ready_title": "Transcript ready",
        "notif_ready_body": "Open the library to view it.",
        "notif_silent_title": "No sound recorded",
        "notif_silent_body": "Mic was silent. Check device and permissions.",
        // Short by design, it's a passing toast/notification, not a
        // help article. The library shows the row in Archive; if the
        // user cares why, the Settings panel covers Microphone /
        // device tips. Keep this to one short clause.
        "notif_silent_archived_title": "Recording archived",
        "notif_silent_archived_body": "Nothing was captured.",
        // Surfaced inside the menu-bar popover (not as a system
        // notification) when recording has been going for > 10 min
        // without any audible speech. Body stays short, the popover
        // is 320 pt wide and the warning sits above the Stop button.
        "silence_warning_title": "Still recording",
        "silence_warning_body": "No voice for 10 min. Still recording?",
        "notif_bt_title": "Other side not recorded",
        "notif_bt_body": "We couldn't capture the other side of this call. Wired output is the most reliable, so re-record to try again.",
        "notif_mic_title": "Your mic wasn't recorded",
        "notif_mic_body": "Your microphone captured no sound this session (the other side was recorded). Check your input device and mic permission, then re-record.",
        "notif_update_recording_title": "Finish recording to update",
        "notif_update_recording_body": "Corder won't install the update mid-recording (it would end your meeting). Stop the recording, then click Install.",
        "notif_stopped_title": "Recording stopped",
        "notif_video_lost_title": "Screen video stopped",
        "notif_disk_low_title": "Your disk is almost full",
        "notif_disk_low_body": "Corder is still recording, but less than 1 GB is left. Free up space or stop the recording soon.",
        "notif_disk_full_title": "Recording stopped: disk full",
        "notif_disk_full_body": "The disk ran out of space, so Corder stopped and saved the recording up to this point.",
        "notif_write_error_title": "Part of the recording wasn't saved",
        "notif_write_error_body": "Corder couldn't write some of the audio to disk. Check free space; the rest of the meeting is still being recorded.",
        "notif_video_lost_body": "Screen sharing ended, so the video stops here. Audio is still recording.",
        "notif_net_restored_title": "Internet restored",
        "notif_net_restored_body": "Catching up on meetings that failed offline.",
        "notif_net_lost_title": "No internet",
        "notif_net_lost_body": "Recording without internet. We'll transcribe later.",
        // Pill that appears under Start/Stop in the popover while the
        // on-device Whisper model is pre-fetching. Just the label
        // the progress fill is visual, no narration needed.
        "whisper_prefetch_label": "Downloading model",
        // Single, deliberately-plain failure toast for the entire
        // transcription pipeline. Whatever broke, Whisper local,
        // Whisper cloud, Gemini, network, auth, the user sees this
        // exact line. Power users hit the 🐞 button in the toolbar
        // to send logs.
        "transcribe_failed_title": "Transcription error. Send a report.",
    ]
    private static let ru: [String: String] = [
        "record_start_failed": "Не удалось начать запись",
        "record_save_failed": "Не удалось сохранить запись",
        "record_low_disk": "Мало места на диске ({mb} МБ). Освободи место, запись не начата, чтобы не потерять её при заполнении диска.",
        "import_unsupported": "Расшифровать можно только аудио и видео",
        "import_failed": "Не удалось прочитать файл. Попробуй mp3, m4a или wav.",
        "import_low_disk": "Мало места на диске для этого файла",
        "idle": "Запись не идёт",
        "recording": "Идёт запись",
        "saving": "Сохраняем…",
        "start": "Начать запись",
        "stop": "Остановить запись",
        "open_library": "Открыть библиотеку",
        "open_account": "Открыть аккаунт",
        "open_corder": "Открыть Corder",
        "locked_status": "Нельзя записывать",
        "quit": "Выйти",
        "invite_question": "Записать встречу?",
        "invite_tap_hint": "Нажми, чтобы начать запись",
        "invite_not_now": "Не сейчас",
        "starting_recording": "Начинаем запись…",
        "notif_saved_title": "Запись сохранена",
        "notif_saved_body": "Расшифровка {s}с…",
        "notif_ready_title": "Расшифровка готова",
        "notif_ready_body": "Открой библиотеку чтобы посмотреть.",
        "notif_silent_title": "Звука нет",
        "notif_silent_body": "Микрофон молчал. Проверь устройство и доступ.",
        "notif_silent_archived_title": "Запись в архиве",
        "notif_silent_archived_body": "Ничего не записалось.",
        "silence_warning_title": "Всё ещё идёт запись",
        "silence_warning_body": "Никто не говорил 10 минут. Продолжать?",
        "notif_bt_title": "Собеседник не записан",
        "notif_bt_body": "Не удалось записать собеседника. Надёжнее всего проводной вывод, перезапиши.",
        "notif_mic_title": "Твой микрофон не записан",
        "notif_mic_body": "В этой сессии микрофон не поймал звук (собеседник записан). Проверь устройство ввода и доступ к микрофону, потом перезапиши.",
        "notif_update_recording_title": "Заверши запись для обновления",
        "notif_update_recording_body": "Corder не ставит обновление во время записи (это оборвёт встречу). Останови запись и нажми Install.",
        "notif_stopped_title": "Запись остановлена",
        "notif_video_lost_title": "Видео экрана остановлено",
        "notif_disk_low_title": "Диск почти заполнен",
        "notif_disk_low_body": "Corder продолжает запись, но свободно меньше 1 ГБ. Освободите место или скоро остановите запись.",
        "notif_disk_full_title": "Запись остановлена: диск заполнен",
        "notif_disk_full_body": "На диске закончилось место, поэтому Corder остановил запись и сохранил её до этого момента.",
        "notif_write_error_title": "Часть записи не сохранилась",
        "notif_write_error_body": "Corder не смог записать часть звука на диск. Проверьте свободное место; остальная встреча продолжает записываться.",
        "notif_video_lost_body": "Показ экрана закончился, поэтому видео дальше не пишется. Звук продолжает записываться.",
        "notif_net_restored_title": "Сеть вернулась",
        "notif_net_restored_body": "Доделаю встречи, что упали без сети.",
        "notif_net_lost_title": "Нет интернета",
        "notif_net_lost_body": "Без интернета. Расшифрую, когда сеть вернётся.",
        "whisper_prefetch_label": "Скачиваем модель",
        "transcribe_failed_title": "Ошибка с транскрипцией. Отправьте репорт.",
    ]

    /// Convenience for native notifications: resolves against the
    /// persisted language (these fire from non-MainActor contexts
    /// SleepWatchdog / NetworkMonitor, so we read the thread-safe
    /// `AppLanguage.current`, not `AppContext.shared.language`).
    static func notif(_ key: String) -> String {
        t(key, lang: AppLanguage.current)
    }
}
