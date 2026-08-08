import {
  createEditToolDefinition,
  createWriteToolDefinition,
  type EditToolInput,
  type ExtensionAPI,
  type WriteToolInput,
} from "@earendil-works/pi-coding-agent";
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

/** Override Pi's mutation schemas while delegating execution to the built-in tools. */
export function registerPreviewAwareMutationTools(pi: ExtensionAPI): void {
  const edit = createEditToolDefinition(process.cwd());
  pi.registerTool({
    name: "edit",
    label: edit.label,
    description: `${edit.description} ${EDIT_RANGE_GUIDELINE}`,
    promptSnippet: edit.promptSnippet,
    promptGuidelines: [...(edit.promptGuidelines ?? []), EDIT_RANGE_GUIDELINE],
    parameters: previewEditSchema,
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
