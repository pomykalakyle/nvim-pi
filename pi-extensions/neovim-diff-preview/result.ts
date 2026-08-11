export type PreviewSuccess = {
  ok: true;
  file_path: string;
  preview_rows: number;
  viewport_rows: number;
};

export type PreviewFailure = {
  ok: false;
  reason: string;
  message: string;
  file_path?: string;
  preview_rows?: number;
  viewport_rows?: number;
};

export type PreviewResult = PreviewSuccess | PreviewFailure;

/**
 * Return whether an RPC value has the required preview-fit result shape.
 * Provenance: vibed=true, reviewed=false.
 */
export function isPreviewResult(value: unknown): value is PreviewResult {
  if (!value || typeof value !== "object" || !("ok" in value)) return false;
  const result = value as Record<string, unknown>;
  if (result.ok === false) {
    return typeof result.reason === "string" && typeof result.message === "string";
  }
  if (result.ok !== true) return false;

  return typeof result.file_path === "string"
    && typeof result.preview_rows === "number"
    && typeof result.viewport_rows === "number";
}

const RETRY_GUIDANCE: Record<string, string> = {
  preview_change_not_visible:
    "Expand unfolded_ranges so every changed hunk is fully visible, then retry.",
  preview_invalid_request:
    "Provide valid nonempty unfolded_ranges using 1-based inclusive proposed-file lines, then retry.",
  preview_range_out_of_bounds:
    "Correct unfolded_ranges using 1-based inclusive lines from the proposed file, then retry.",
  preview_render_failed:
    "The edit/write call was not executed. Restore the Neovim preview and retry.",
  workspace_unavailable:
    "The edit/write call was not executed. Return to the originating Pi workspace and retry.",
};

/**
 * Return actionable model feedback for a rejected Neovim preview.
 * Provenance: vibed=true, reviewed=false.
 */
export function formatPreviewFailure(result: PreviewFailure): string {
  const guidance = RETRY_GUIDANCE[result.reason];
  if (guidance) return `${result.message}. ${guidance}`;

  const limit = typeof result.viewport_rows === "number"
    ? ` Each proposal must fit within the current ${result.viewport_rows}-row Neovim viewport.`
    : "";
  return `${result.message}.${limit} Tighten unfolded_ranges or split the change into smaller edit/write calls and retry.`;
}
