import {
  createEditToolDefinition,
  createWriteToolDefinition,
  type EditToolInput,
  type ExtensionAPI,
  type ExtensionContext,
  type WriteToolInput,
} from "@earendil-works/pi-coding-agent";
import {
  Box,
  type Component,
  Container,
  Text,
} from "@earendil-works/pi-tui";
import { type Static, Type } from "typebox";

const unfoldedRangeSchema = Type.Object({
  start_line: Type.Integer({
    minimum: 1,
    description:
      "First visible line in the proposed file (1-based, inclusive).",
  }),
  end_line: Type.Integer({
    minimum: 1,
    description: "Last visible line in the proposed file (1-based, inclusive).",
  }),
});

const unfoldedRangesSchema = Type.Array(unfoldedRangeSchema, {
  minItems: 1,
  description:
    "One or more proposed-file ranges to leave unfolded in Neovim. Every changed hunk must be fully contained, but ranges may also show unchanged supporting context. The combined folded preview must fit in the live Neovim window.",
});

export const previewEditSchema = Type.Object({
  path: Type.String({
    description: "Path to the file to edit (relative or absolute).",
  }),
  justification: Type.String({
    minLength: 1,
    maxLength: 500,
    description: "Concise user-facing reason for the edit and its intended effect.",
  }),
  edits: Type.Array(
    Type.Object({
      oldText: Type.String({
        description:
          "Exact text for one targeted replacement. It must be unique in the original file and must not overlap another replacement.",
      }),
      newText: Type.String({
        description: "Replacement text for this targeted edit.",
      }),
    }),
    {
      minItems: 1,
      description:
        "Targeted replacements matched against the original file, not incrementally.",
    },
  ),
  unfolded_ranges: unfoldedRangesSchema,
});

export const previewWriteSchema = Type.Object({
  path: Type.String({
    description: "Path to the file to write (relative or absolute).",
  }),
  justification: Type.String({
    minLength: 1,
    maxLength: 500,
    description: "Concise user-facing reason for the write and its intended effect.",
  }),
  content: Type.String({ description: "Content to write to the file." }),
  unfolded_ranges: unfoldedRangesSchema,
});

export type UnfoldedRange = Static<typeof unfoldedRangeSchema>;
export type PreviewEditInput = Static<typeof previewEditSchema>;
export type PreviewWriteInput = Static<typeof previewWriteSchema>;

const EDIT_RANGE_GUIDELINE =
  "Every edit call must include unfolded_ranges using 1-based inclusive line numbers from the proposed file. Cover every changed hunk completely, include any unchanged context needed for review, and keep the initial folded preview small enough for the Neovim window.";
const WRITE_RANGE_GUIDELINE =
  "Every write call must include unfolded_ranges using 1-based inclusive line numbers from the proposed file. Cover every changed hunk completely, include any unchanged context needed for review, and keep the initial folded preview small enough for the Neovim window.";

function validateRangeOrder(args: unknown): void {
  if (!args || typeof args !== "object") return;
  const ranges = (args as { unfolded_ranges?: unknown }).unfolded_ranges;
  if (!Array.isArray(ranges)) return;
  for (const [index, range] of ranges.entries()) {
    if (
      range &&
      typeof range === "object" &&
      typeof (range as { start_line?: unknown }).start_line === "number" &&
      typeof (range as { end_line?: unknown }).end_line === "number" &&
      (range as { end_line: number }).end_line <
        (range as { start_line: number }).start_line
    ) {
      throw new Error(
        `unfolded_ranges[${index}] must have end_line greater than or equal to start_line`,
      );
    }
  }
}

export type TerminalDiffSelector = (
  toolName: "edit" | "write",
  path: string,
) => boolean;

export type DeferredMutationResult = {
  content: Array<{ type: "text"; text: string }>;
  details: Record<string, unknown> | undefined;
  terminate?: boolean;
};

export type DeferredMutationExecutor = (
  toolCallId: string,
  toolName: "edit" | "write",
  input: PreviewEditInput | PreviewWriteInput,
  ctx: ExtensionContext,
) => Promise<DeferredMutationResult | undefined>;

function terminalRendererMode(
  state: { terminalRenderer?: "compact" | "native" },
  argsComplete: boolean,
  selector: TerminalDiffSelector,
  toolName: "edit" | "write",
  path: unknown,
): "compact" | "native" {
  if (state.terminalRenderer) return state.terminalRenderer;
  if (!argsComplete || typeof path !== "string") return "compact";
  try {
    state.terminalRenderer = selector(toolName, path) ? "native" : "compact";
  } catch {
    state.terminalRenderer = "compact";
  }
  return state.terminalRenderer;
}

/** Build the transcript-native card that identifies a manual file review. */
function renderManualReviewCard(
  args: { path?: unknown; justification?: unknown },
  outcome: "pending" | "accepted" | "rejected",
  theme: {
    bold: (text: string) => string;
    fg: (color: string, text: string) => string;
    bg: (color: string, text: string) => string;
  },
): Box {
  // Tool arguments stream incrementally, so keep the card readable before completion.
  const path = typeof args.path === "string" ? args.path : "Preparing path…";
  const justification =
    typeof args.justification === "string" && args.justification.trim()
      ? args.justification.trim()
      : "Preparing justification…";

  // A real Box carries Pi's pending-tool background across the full card width.
  const box = new Box(1, 1, (text) => theme.bg("toolPendingBg", text));
  box.addChild(
    new Text(
      [
        theme.fg("accent", theme.bold("Manual Review")),
        `${theme.fg("muted", "File:")} ${path}`,
        `${theme.fg("muted", "Why:")} ${justification}`,
        `${theme.fg("muted", "Status:")} ${outcome}`,
        "",
        theme.fg(
          "dim",
          outcome === "pending"
            ? "File unchanged · Option+R to review"
            : outcome === "accepted"
              ? "File changed"
              : "File unchanged",
        ),
      ].join("\n"),
      0,
      0,
    ),
  );
  return box;
}

/** Render the durable manual proposal outcome after focused review closes. */
function renderManualResult(
  args: { path?: unknown; justification?: unknown },
  result: {
    content: Array<{ type: string; text?: string }>;
    details?: { proposalPending?: unknown; proposalResolution?: unknown };
  },
  theme: {
    bold: (text: string) => string;
    fg: (color: string, text: string) => string;
    bg: (color: string, text: string) => string;
  },
  isError: boolean,
): Component {
  // Compact rendering still surfaces the complete error returned by the tool.
  if (isError) {
    const message = result.content
      .filter((item) => item.type === "text")
      .map((item) => item.text ?? "")
      .join("\n");
    return new Text(
      theme.fg("error", message || "File mutation failed"),
      0,
      0,
    );
  }

  if (result.details?.proposalPending === true) {
    return renderManualReviewCard(args, "pending", theme);
  }
  if (
    result.details?.proposalResolution === "accepted" ||
    result.details?.proposalResolution === "rejected"
  ) {
    return renderManualReviewCard(
      args,
      result.details.proposalResolution,
      theme,
    );
  }
  return new Container();
}

/** Override Pi's mutation schemas and route their diffs to one visible surface. */
export function registerPreviewAwareMutationTools(
  pi: ExtensionAPI,
  showTerminalDiff: TerminalDiffSelector = () => false,
  deferMutation?: DeferredMutationExecutor,
): void {
  const edit = createEditToolDefinition(process.cwd());
  pi.registerTool({
    name: "edit",
    label: edit.label,
    description: `${edit.description} ${EDIT_RANGE_GUIDELINE}`,
    promptSnippet: edit.promptSnippet,
    promptGuidelines: [...(edit.promptGuidelines ?? []), EDIT_RANGE_GUIDELINE],
    parameters: previewEditSchema,
    renderShell: "self",
    renderCall(args, theme, context) {
      const priorMode = context.state.terminalRenderer;
      const mode = terminalRendererMode(
        context.state,
        context.argsComplete,
        showTerminalDiff,
        "edit",
        args.path,
      );
      if (mode === "native") {
        if (!edit.renderCall)
          throw new Error("Pi edit renderer is unavailable");
        return edit.renderCall(args, theme, {
          ...context,
          lastComponent:
            priorMode === "native" ? context.lastComponent : undefined,
        });
      }
      return new Container();
    },
    renderResult(result, options, theme, context) {
      if (context.state.terminalRenderer === "native") {
        if (!edit.renderResult)
          throw new Error("Pi edit result renderer is unavailable");
        return edit.renderResult(
          result as Parameters<NonNullable<typeof edit.renderResult>>[0],
          options,
          theme,
          context,
        );
      }
      return renderManualResult(
        context.args,
        result,
        theme,
        context.isError,
      );
    },
    prepareArguments(args) {
      const prepared = edit.prepareArguments?.(args) ?? args;
      if (!prepared || typeof prepared !== "object") {
        return prepared as PreviewEditInput;
      }
      validateRangeOrder(args);
      const unfoldedRanges =
        args && typeof args === "object"
          ? (args as { unfolded_ranges?: unknown }).unfolded_ranges
          : undefined;
      return {
        ...prepared,
        unfolded_ranges: unfoldedRanges,
      } as PreviewEditInput;
    },
    async execute(toolCallId, params, signal, onUpdate, ctx) {
      const deferred = await deferMutation?.(toolCallId, "edit", params, ctx);
      if (deferred) return deferred;

      const input: EditToolInput = { path: params.path, edits: params.edits };
      const runtimeTool = createEditToolDefinition(ctx.cwd);
      return runtimeTool.execute(toolCallId, input, signal, onUpdate, ctx);
    },
  });

  const write = createWriteToolDefinition(process.cwd());
  pi.registerTool({
    name: "write",
    label: write.label,
    description: `${write.description} ${WRITE_RANGE_GUIDELINE}`,
    promptSnippet: write.promptSnippet,
    promptGuidelines: [
      ...(write.promptGuidelines ?? []),
      WRITE_RANGE_GUIDELINE,
    ],
    parameters: previewWriteSchema,
    renderShell: "self",
    renderCall(args, theme, context) {
      const priorMode = context.state.terminalRenderer;
      const mode = terminalRendererMode(
        context.state,
        context.argsComplete,
        showTerminalDiff,
        "write",
        args.path,
      );
      if (mode === "native") {
        if (!write.renderCall)
          throw new Error("Pi write renderer is unavailable");
        return write.renderCall(args, theme, {
          ...context,
          lastComponent:
            priorMode === "native" ? context.lastComponent : undefined,
        });
      }
      return new Container();
    },
    renderResult(result, options, theme, context) {
      if (context.state.terminalRenderer === "native") {
        if (!write.renderResult)
          throw new Error("Pi write result renderer is unavailable");
        return write.renderResult(
          result as Parameters<NonNullable<typeof write.renderResult>>[0],
          options,
          theme,
          context,
        );
      }
      return renderManualResult(
        context.args,
        result,
        theme,
        context.isError,
      );
    },
    prepareArguments(args) {
      validateRangeOrder(args);
      return args as PreviewWriteInput;
    },
    async execute(toolCallId, params, signal, onUpdate, ctx) {
      const deferred = await deferMutation?.(toolCallId, "write", params, ctx);
      if (deferred) return deferred;

      const input: WriteToolInput = {
        path: params.path,
        content: params.content,
      };
      const runtimeTool = createWriteToolDefinition(ctx.cwd);
      return runtimeTool.execute(toolCallId, input, signal, onUpdate, ctx);
    },
  });
}
