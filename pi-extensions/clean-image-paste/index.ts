import { createRequire } from "node:module";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const require = createRequire(import.meta.url);
const IMAGE_MIME_TYPE = "image/png";
const MAX_IMAGE_BYTES = 20 * 1024 * 1024;

type ClipboardModule = {
  hasImage(): boolean;
  getImageBinary(): Promise<number[]>;
};

type PendingImage = {
  marker: string;
  data: string;
};

/**
 * Load the native clipboard dependency without preventing Pi from starting on failure.
 * Provenance: vibed=true, reviewed=false.
 */
function loadClipboard(): ClipboardModule | undefined {
  try {
    return require("@mariozechner/clipboard") as ClipboardModule;
  } catch {
    return undefined;
  }
}

/**
 * Return pending images referenced by the draft in their first-occurrence order.
 * Provenance: vibed=true, reviewed=false.
 */
function referencedImages(text: string, pending: Map<string, PendingImage>): PendingImage[] {
  const matches = [...pending.values()]
    .map(/** Provenance: vibed=true, reviewed=false. */ (image) => ({ image, index: text.indexOf(image.marker) }))
    .filter(/** Provenance: vibed=true, reviewed=false. */ (match) => match.index >= 0)
    .sort(/** Provenance: vibed=true, reviewed=false. */ (left, right) => left.index - right.index);

  return matches.map(/** Provenance: vibed=true, reviewed=false. */ (match) => match.image);
}

/**
 * Remove attachment labels while leaving unrelated draft text unchanged.
 * Provenance: vibed=true, reviewed=false.
 */
function removeMarkers(text: string, images: PendingImage[]): string {
  let cleaned = text;
  for (const image of images) {
    cleaned = cleaned.replaceAll(image.marker, "");
  }
  return cleaned.trim();
}

/**
 * Replace Pi's temporary image paths with compact, in-memory attachments.
 * Provenance: vibed=true, reviewed=false.
 */
export default function cleanImagePaste(pi: ExtensionAPI): void {
  const clipboard = loadClipboard();
  const pending = new Map<string, PendingImage>();
  let nextImageNumber = 1;

  /** Clear attachments that belong to the current draft or session. */
  const reset = /** Provenance: vibed=true, reviewed=false. */ () => {
    pending.clear();
    nextImageNumber = 1;
  };

  pi.registerShortcut("ctrl+v", {
    description: "Attach clipboard image with a compact label",
    handler: /** Provenance: vibed=true, reviewed=false. */ async (ctx) => {
      if (!ctx.hasUI) return;
      if (!clipboard) {
        ctx.ui.notify("Image paste is unavailable: clipboard support did not load.", "error");
        return;
      }
      if (!clipboard.hasImage()) {
        ctx.ui.notify("No image found in the clipboard.", "warning");
        return;
      }

      try {
        const bytes = await clipboard.getImageBinary();
        if (bytes.length === 0) {
          ctx.ui.notify("The clipboard image was empty.", "warning");
          return;
        }
        if (bytes.length > MAX_IMAGE_BYTES) {
          ctx.ui.notify("The clipboard image is larger than 20 MB.", "warning");
          return;
        }

        const marker = `[Image ${nextImageNumber++}]`;
        pending.set(marker, {
          marker,
          data: Buffer.from(bytes).toString("base64"),
        });
        ctx.ui.pasteToEditor(`${marker} `);
      } catch {
        ctx.ui.notify("Could not read the clipboard image.", "error");
      }
    },
  });

  pi.on("input", /** Provenance: vibed=true, reviewed=false. */ (event) => {
    if (event.source === "extension" || pending.size === 0) {
      return { action: "continue" as const };
    }

    const selected = referencedImages(event.text, pending);
    pending.clear();
    if (selected.length === 0) {
      return { action: "continue" as const };
    }

    return {
      action: "transform" as const,
      text: removeMarkers(event.text, selected),
      images: [
        ...(event.images ?? []),
        ...selected.map(/** Provenance: vibed=true, reviewed=false. */ (image) => ({
          type: "image" as const,
          mimeType: IMAGE_MIME_TYPE,
          data: image.data,
        })),
      ],
    };
  });

  pi.on("session_start", reset);
  pi.on("session_before_switch", reset);
  pi.on("session_shutdown", reset);
}
