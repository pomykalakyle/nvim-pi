export type FocusSuccess = {
  ok: true;
  file_path: string;
  start_line: number;
  end_line: number;
  viewport_rows: number;
  range_rows: number;
  visible_start_line: number;
  visible_end_line: number;
};

export type FocusFailure = {
  ok: false;
  reason: string;
  message: string;
  restored?: boolean;
  suggested_start_line?: number;
  suggested_end_line?: number;
};

export type FocusResult = FocusSuccess | FocusFailure;

/** Return whether an RPC value has the required shape of a focus result. */
export function isFocusResult(value: unknown): value is FocusResult {
  if (!value || typeof value !== "object" || !("ok" in value)) return false;
  const result = value as Record<string, unknown>;
  if (result.ok === false) {
    return typeof result.reason === "string" && typeof result.message === "string";
  }
  if (result.ok !== true) return false;

  return typeof result.file_path === "string"
    && typeof result.start_line === "number"
    && typeof result.end_line === "number"
    && typeof result.viewport_rows === "number"
    && typeof result.range_rows === "number"
    && typeof result.visible_start_line === "number"
    && typeof result.visible_end_line === "number";
}

/** Format a Neovim rejection as an actionable failed tool result. */
export function formatFocusFailure(result: FocusFailure): string {
  const lines = [result.message];
  if (result.restored) lines.push("The previous editor view was restored.");
  if (
    typeof result.suggested_start_line === "number"
    && typeof result.suggested_end_line === "number"
  ) {
    lines.push(
      `Lines ${result.suggested_start_line}-${result.suggested_end_line} would fit; choose a smaller range and retry.`,
    );
  }
  return lines.join(" ");
}
