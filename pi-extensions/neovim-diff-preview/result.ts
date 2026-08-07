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

/** Return whether an RPC value has the required preview-fit result shape. */
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

/** Explain how to resize an edit/write proposal after a live viewport rejection. */
export function formatPreviewFailure(result: PreviewFailure): string {
  const limit = typeof result.viewport_rows === "number"
    ? ` Each proposal must fit within the current ${result.viewport_rows}-row Neovim viewport.`
    : "";
  return `${result.message}.${limit} Split the change into smaller edit/write calls and retry.`;
}
