import React from "react";

// The Library WebView lives for the whole process, also while its window is
// closed, minimised, hidden or covered. Native posts `corder-window-active`
// (LibraryWindow.setWebActive) on show / close / settled occlusion changes;
// `document.hidden` covers the rest. Every poller goes through `usePoll` so
// a closed window makes no requests at all: before, it kept hitting
// /api/settings 1.5-3.5 times a second for as long as Corder ran.

let nativeActive = true;
const listeners = new Set<() => void>();
const notify = () => listeners.forEach((l) => l());

window.addEventListener("corder-window-active", (e: Event) => {
  const next = !!(e as CustomEvent).detail;
  if (next !== nativeActive) { nativeActive = next; notify(); }
});
document.addEventListener("visibilitychange", notify);

function snapshot(): boolean {
  return nativeActive && !document.hidden;
}

function subscribe(cb: () => void): () => void {
  listeners.add(cb);
  return () => { listeners.delete(cb); };
}

export function useWindowActive(): boolean {
  return React.useSyncExternalStore(subscribe, snapshot);
}

/// Calls `tick` now and every `ms` while the Library window is visible;
/// pauses while it isn't and ticks again right away when it comes back.
/// `ms = null` turns the poll off.
export function usePoll(tick: () => void | Promise<unknown>, ms: number | null): void {
  const active = useWindowActive();
  const ref = React.useRef(tick);
  ref.current = tick;
  React.useEffect(() => {
    if (!active || ms == null) return;
    void ref.current();
    const id = window.setInterval(() => { void ref.current(); }, ms);
    return () => window.clearInterval(id);
  }, [active, ms]);
}
