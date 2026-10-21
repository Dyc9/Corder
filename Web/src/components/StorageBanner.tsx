import React from "react";
import type { T } from "../i18n";
import { getStorageAdvice, archiveOldSessions, dismissStorageAdvice, type StorageAdvice } from "../api";
import { usePoll } from "../activity";

function gb(bytes: number): string {
  const v = bytes / 1e9;
  return v >= 10 ? `${Math.round(v)} GB` : `${v.toFixed(1)} GB`;
}

/// Welcome-screen nudge when recordings take a lot of space (or the disk is
/// tight): offers to move sessions older than ~3 months to the Archive,
/// where they are deleted after 7 days. Corder never deletes recordings on
/// its own. Same outline card as NewsBanner (`.trans-banner.clarify-banner`).
export function StorageBanner({ t, onArchived }: { t: T; onArchived?: (n: number) => void }) {
  const [advice, setAdvice] = React.useState<StorageAdvice | null>(null);
  const [busy, setBusy] = React.useState(false);
  // The size walk is not free, and the answer changes slowly.
  usePoll(async () => { setAdvice(await getStorageAdvice()); }, 30 * 60 * 1000);
  if (!advice?.warn) return null;

  const months = Math.round(advice.older_than_days / 30);
  const title = (t.storage_title ?? "Recordings take {total}")
    .replace("{total}", gb(advice.total_bytes));
  const body = (t.storage_body ?? "{count} sessions are older than {months} months and take {old}. Move them to the Archive? They are deleted after 7 days there, until then you can restore them.")
    .replace("{count}", String(advice.old_count))
    .replace("{months}", String(months))
    .replace("{old}", gb(advice.old_bytes));

  return (
    <div className="trans-banner clarify-banner storage-banner">
      <div className="clarify-text">
        <div className="clarify-body">{title}</div>
        <div className="summary-banner-sub">{body}</div>
      </div>
      <div className="clarify-actions clarify-actions-stack">
        <button
          type="button"
          className="clarify-btn accent"
          disabled={busy}
          onClick={async () => {
            setBusy(true);
            try {
              const n = await archiveOldSessions();
              setAdvice(null);
              onArchived?.(n);
            } catch { /* keep the card; the user can retry */ }
            setBusy(false);
          }}
        >
          {t.storage_archive ?? "Move to Archive"}
        </button>
        <button
          type="button"
          className="clarify-btn"
          disabled={busy}
          onClick={() => { setAdvice(null); void dismissStorageAdvice(); }}
        >
          {t.storage_later ?? "Not now"}
        </button>
      </div>
    </div>
  );
}
