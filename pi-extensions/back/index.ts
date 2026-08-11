import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { findLatestUserMessageId } from "./find-latest-user-message.js";

/**
 * Register an immediate one-turn rewind command.
 * Provenance: vibed=true, reviewed=false.
 */
export default function backExtension(pi: ExtensionAPI): void {
  pi.registerCommand("back", {
    description: "Abort active work and restore the latest user message",
    handler: /** Provenance: vibed=true, reviewed=false. */ async (_args, ctx) => {
      if (!ctx.isIdle()) {
        ctx.abort();
        await ctx.waitForIdle();
      }

      const entryId = findLatestUserMessageId(ctx.sessionManager.getBranch());
      if (!entryId) {
        ctx.ui.notify("No previous user message to restore", "info");
        return;
      }

      await ctx.navigateTree(entryId, { summarize: false });
    },
  });
}
