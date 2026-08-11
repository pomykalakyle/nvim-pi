import {
  createBashToolDefinition,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { highlightBashCommand } from "./highlighter.ts";

/** Reviewed: false. */
export default function bashSyntaxHighlighting(pi: ExtensionAPI): void {
  const base = createBashToolDefinition(process.cwd());

  pi.registerTool({
    ...base,

    // Keep execution anchored to Pi's live cwd instead of the extension-load cwd.
    /** Reviewed: false. */
    execute(toolCallId, params, signal, onUpdate, ctx) {
      return createBashToolDefinition(ctx.cwd).execute(
        toolCallId,
        params,
        signal,
        onUpdate,
        ctx,
      );
    },

    /** Reviewed: false. */
    renderCall(args, theme, context) {
      const state = context.state;
      if (context.executionStarted && state.startedAt === undefined) {
        state.startedAt = Date.now();
        state.endedAt = undefined;
      }

      const command =
        typeof args?.command === "string" && args.command.length > 0
          ? highlightBashCommand(args.command, theme)
          : theme.fg("toolOutput", "...");
      const timeout =
        typeof args?.timeout === "number"
          ? theme.fg("muted", ` (timeout ${args.timeout}s)`)
          : "";
      const text =
        context.lastComponent instanceof Text
          ? context.lastComponent
          : new Text("", 0, 0);
      text.setText(`${theme.fg("accent", theme.bold("$ "))}${command}${timeout}`);
      return text;
    },
  });
}
