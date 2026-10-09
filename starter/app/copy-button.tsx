"use client";

import { useState } from "react";

export function CopyButton({ text }: { text: string }) {
  const [done, setDone] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setDone(true);
      setTimeout(() => setDone(false), 2000);
    } catch {
      // Clipboard blocked (http, permissions): the text is selectable, nothing else to do.
    }
  }

  return (
    <button type="button" className="copy" onClick={copy} aria-live="polite">
      {done ? "Copied" : "Copy"}
    </button>
  );
}
