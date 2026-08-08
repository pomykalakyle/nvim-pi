import {
  createEditToolDefinition,
  createWriteToolDefinition,
  type EditToolInput,
  type ExtensionAPI,
  type WriteToolInput,
} from "@earendil-works/pi-coding-agent";
import { Box, Container, Text } from "@earendil-works/pi-tui";
import { type Static, Type } from "typebox";

const unfoldedRangeSchema = Type.Object({
  start_line: Type.Integer({
    minimum: 1,
    description: "First visible line in the proposed file (1-based, inclusive).",
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
  path: Type.String({ description: "Path to the file to edit (relative or absolute)." }),
  edits: Type.Array(
    Type.Object({
      oldText: Type.String({
        description:
          "Exact text for one targeted replacement. It must be unique in the original file and must not overlap another replacement.",
      }),
      newText: Type.String({ description: "Replacement text for this targeted edit." }),
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
  path: Type.String({ description: "Path to the file to write (relative or absolute)." }),
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
      range
      && typeof range === "object"
      && typeof (range as { start_line?: unknown }).start_line === "number"
      && typeof (range as { end_line?: unknown }).end_line === "number"
      && (range as { end_line: number }).end_line
        < (range as { start_line: number }).start_line
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

function renderCompactResult(result: { content: Array<{ type: string; text?: string }> }, theme: {
  fg: (color: "error", text: string) => string;
}, isError: boolean) {
  if (!isError) return new Container();
  const message = result.content
    .filter((item) => item.type === "text")
    .map((item) => item.text ?? "")
    .join("\n");
  return new Text(theme.fg("error", message || "File mutation failed"), 0, 0);
}

/** Override Pi's mutation schemas and route their diffs to one visible surface. */
export function registerPreviewAwareMutationTools(
  pi: ExtensionAPI,
  showTerminalDiff: TerminalDiffSelector = () => false,
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
        return edit.renderCall!(args, theme, {
          ...context,
          lastComponent: priorMode === "native" ? context.lastComponent : undefined,
        });
      }
      const component = context.lastComponent instanceof Box && priorMode === "compact"
        ? context.lastComponent
        : new Box(1, 1, (text) => text);
      component.clear();
      component.addChild(new Text(
        `${theme.fg("toolTitle", theme.bold("edit"))} ${theme.fg("muted", args.path)}`,
        0,
        0,
      ));
      return component;
    },
    renderResult(result, options, theme, context) {
      if (context.state.terminalRenderer === "native") {
        return edit.renderResult!(
          result as Parameters<NonNullable<typeof edit.renderResult>>[0],
          options,
          theme,
          context,
        );
      }
      return renderCompactResult(result, theme, context.isError);
    },
    prepareArguments(args) {
      const prepared = edit.prepareArguments?.(args) ?? args;
      if (!prepared || typeof prepared !== "object") {
        return prepared as PreviewEditInput;
      }
      validateRangeOrder(args);
      const unfoldedRanges = args && typeof args === "object"
        ? (args as { unfolded_ranges?: unknown }).unfolded_ranges
        : undefined;
      return { ...prepared, unfolded_ranges: unfoldedRanges } as PreviewEditInput;
    },
    async execute(toolCallId, params, signal, onUpdate, ctx) {
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
    promptGuidelines: [...(write.promptGuidelines ?? []), WRITE_RANGE_GUIDELINE],
    parameters: previewWriteSchema,
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
        return write.renderCall!(args, theme, {
          ...context,
          lastComponent: priorMode === "native" ? context.lastComponent : undefined,
        });
      }
      const component = context.lastComponent instanceof Text && priorMode === "compact"
        ? context.lastComponent
        : new Text("", 0, 0);
      component.setText(
        `${theme.fg("toolTitle", theme.bold("write"))} ${theme.fg("muted", args.path)}`,
      );
      return component;
    },
    renderResult(result, options, theme, context) {
      if (context.state.terminalRenderer === "native") {
        return write.renderResult!(
          result as Parameters<NonNullable<typeof write.renderResult>>[0],
          options,
          theme,
          context,
        );
      }
      return renderCompactResult(result, theme, context.isError);
    },
    prepareArguments(args) {
      validateRangeOrder(args);
      return args as PreviewWriteInput;
    },
    async execute(toolCallId, params, signal, onUpdate, ctx) {
      const input: WriteToolInput = { path: params.path, content: params.content };
      const runtimeTool = createWriteToolDefinition(ctx.cwd);
      return runtimeTool.execute(toolCallId, input, signal, onUpdate, ctx);
    },
  });
}
