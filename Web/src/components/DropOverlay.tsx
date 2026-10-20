import React from "react";
import { FileAudio } from "lucide-react";
import { T } from "../i18n";

// Shown while files are dragged over the Library window. The drop itself is
// handled natively (LibraryWebView → AudioImporter), the page only learns
// about it through the `corder-drop` event, so the overlay never takes
// pointer events.
export function DropOverlay({ t }: { t: T }) {
  const [active, setActive] = React.useState(false);
  React.useEffect(() => {
    const onDrop = (e: Event) => setActive(!!(e as CustomEvent).detail);
    window.addEventListener("corder-drop", onDrop);
    return () => window.removeEventListener("corder-drop", onDrop);
  }, []);
  if (!active) return null;
  return (
    <div className="update-overlay drop-overlay" aria-live="polite">
      <div className="drop-zone">
        <FileAudio size={32} strokeWidth={1.75} className="drop-zone-icon" />
        <div className="clarify-body">{t.drop_title}</div>
        <div className="dash-sub">{t.drop_sub}</div>
      </div>
    </div>
  );
}
